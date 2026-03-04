#!/bin/bash
set -e

# --- 預設變數設定 ---
REPEAT_COUNT=100
BMC_USER=""
BMC_PASS=""
OS_USER=""
OS_PASS=""

# --- 基礎日誌函數 ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# --- 遠端 SSH 執行函數 ---
remote_exec() {
    sshpass -p "$OS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$OS_USER@$OS_IP" "$1" 2>/dev/null
}

# --- 狀態檢測函數 ---
wait_os_up() {
    log "等待 OS ($OS_IP) 上線..."
    while ! ping -c 1 -W 1 "$OS_IP" &>/dev/null || ! remote_exec "echo ok" | grep -q "ok"; do
        sleep 10
    done
    log "OS 已上線並可透過 SSH 連線！"
}

wait_os_down() {
    log "等待 OS ($OS_IP) 下線..."
    while ping -c 1 -W 1 "$OS_IP" &>/dev/null; do
        sleep 5
    done
    log "OS 已下線！"
}

get_bios_ver() {
    remote_exec "dmidecode -t 0 | grep -i version" | awk -F': ' '{print $2}' | tr -d '\r\n '
}

# --- 參數解析 ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --loop=*) REPEAT_COUNT="${1#*=}" ;;
        --bmc_ip=*) BMC_IP="${1#*=}" ;;
        --os_ip=*) OS_IP="${1#*=}" ;;
        --fw_a=*) FW_A="${1#*=}" ;;
        --fw_b=*) FW_B="${1#*=}" ;;
        --help|-h) 
            echo "用法: $0 --fw_a=FILE_A --fw_b=FILE_B --bmc_ip=IP --os_ip=IP [--loop=N]"
            exit 0 ;;
        *) echo "[錯誤] 未知參數: $1"; exit 1 ;;
    esac
    shift
done

# --- 必填參數檢查 ---
if [[ -z "$BMC_IP" || -z "$OS_IP" || -z "$FW_A" || -z "$FW_B" ]]; then
    echo "請提供完整的 IP 與 FW 路徑參數。使用 --help 查看說明。"
    exit 1
fi

# ==============================
# 主測試迴圈
# ==============================
for (( i=1; i<=REPEAT_COUNT; i++ )); do
    if (( i % 2 == 1 )); then
        FW_FILE="$FW_A"; SLOT="A"
    else
        FW_FILE="$FW_B"; SLOT="B"
    fi

    log "========== Cycle $i/$REPEAT_COUNT (Slot $SLOT) =========="
    log "準備使用韌體: $FW_FILE"

    wait_os_up
    CURRENT_VER=$(get_bios_ver)
    log "當前 BIOS 版本: $CURRENT_VER"

    # 1. 觸發 UpdateService (ForceUpdate)
    log "[執行] 設定 UpdateService 強制更新..."
    ETAG=$(curl -k -s -I -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP/redfish/v1/UpdateService" | grep -i ETag | awk '{print $2}' | tr -d '\r"')
    curl -sS -k -X PATCH -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP/redfish/v1/UpdateService" \
        -H "Content-Type: application/json" -H "If-Match: \"$ETAG\"" \
        -d '{"HttpPushUriOptions": {"ForceUpdate": true}}' > /dev/null

    # 2. 透過 Redfish 上傳韌體
    log "[執行] 上傳韌體檔案..."
    UPLOAD_OUT=$(curl -sS -k -u "$BMC_USER:$BMC_PASS" -X POST "https://$BMC_IP/redfish/v1/UpdateService/upload" \
        -F 'UpdateParameters={"Targets":[]};type=application/json' \
        -F 'OemParameters={"ImageType": "PLDM", "Platform": "HGX"};type=application/json' \
        -F "UpdateFile=@${FW_FILE}")

    # 解析 Task URI
    TASK_URI=$(echo "$UPLOAD_OUT" | jq -r '."@odata.id" // .TaskMonitor')
    if [[ -z "$TASK_URI" || "$TASK_URI" == "null" ]]; then
        log "[錯誤] 上傳失敗，無法取得 Task URI。回應內容: $UPLOAD_OUT"
        exit 1
    fi
    log "韌體上傳成功，開始監控 Task: $TASK_URI"

    # 3. 輪詢 Task 進度
    while true; do
        TASK_STATUS=$(curl -sS -k -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP$TASK_URI")
        STATE=$(echo "$TASK_STATUS" | jq -r '.TaskState')
        STATUS=$(echo "$TASK_STATUS" | jq -r '.TaskStatus')
        PCT=$(echo "$TASK_STATUS" | jq -r '.PercentComplete')
        
        log "Task 進度: ${PCT}% (State: $STATE, Status: $STATUS)"
        
        if [[ "$STATE" == "Completed" || "$STATE" == "Exception" ]]; then
            break
        fi
        sleep 30
    done

    if [[ "$STATUS" != "OK" ]]; then
        log "[錯誤] 更新 Task 完成但狀態為 $STATUS，腳本終止！"
        exit 1
    fi

    # 4. 執行 Graceful Restart 
    log "[執行] 透過 Redfish 發送 Graceful Restart..."
    curl -sS -k -X POST -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP/redfish/v1/Systems/System_0/Actions/ComputerSystem.Reset" \
        -H "Content-Type: application/json" -d '{"ResetType":"GracefulRestart"}' > /dev/null

    # 5. 等待重新開機並驗證版本
    wait_os_down
    wait_os_up

    NEW_VER=$(get_bios_ver)
    log "更新後 BIOS 版本: $NEW_VER"

    if [[ "$NEW_VER" == "$CURRENT_VER" ]]; then
        log "[錯誤] BIOS 版本未改變，更新可能未生效！"
        exit 1
    fi
    
    log "[成功] Cycle $i 測試通過！等待 60 秒後進入下一輪..."
    sleep 60
done

log "========== $REPEAT_COUNT 圈 Ping-pong 測試全數完成 =========="
