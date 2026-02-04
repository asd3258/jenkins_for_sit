#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""        # 要設定的新密碼
DEFAULT_PASS=""    # 預設/舊密碼
MAX_CYCLES=10      # 最大重試圈數
SERVER_LIST="servers.csv" # 來源清單
LOG_FILE="bmc_pwd_change_$(date '+%Y%m%d_%H%M').log"
EXECUTE_SERVER_LIST="execute_servers.csv"

: > "$LOG_FILE"

# 檢查檔案是否存在
if [ ! -f "$SERVER_LIST" ]; then
    echo "錯誤: 找不到 $SERVER_LIST"
    exit 1
fi
# 強制移除 Windows 換行符號 (\r)，避免讀取失敗
sed -i 's/\r//g' "$SERVER_LIST"

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        # 解析 --bmc_user=xxx
        --bmc_user=*)
            BMC_USER="${1#*=}"
            ;;
            
        # 解析 --bmc_def=xxx
        --bmc_def=*)
            DEFAULT_PASS="${1#*=}"
            ;;
            
        # 解析 --bmc_pass=xxx
        --bmc_pass=*)
            BMC_PASS="${1#*=}"
            ;;

        # --- 幫助與錯誤處理 ---
        --help|-h)
            echo "Usage: $0 --bmc_user=USER  --bmc_def=DefPASS --bmc_pass=PASS"
            exit 0
            ;;
            
        *)
            echo "[Error] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    
    # 移除目前參數 ($1)，繼續處理下一個
    shift 
done

# 解析 Server List
parse_server_list() {
    # 定義 IP 的正則表達式
    local IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    
    : > "$EXECUTE_SERVER_LIST" # 清空暫存檔
    echo "[Info] 開始解析 $SERVER_LIST ..."

    if [ ! -f "$SERVER_LIST" ]; then
        echo "[Error] 找不到 $SERVER_LIST"
        exit 1
    fi

    # 去除 Windows 換行符號 (\r) 與 空白
    awk -F',' 'NR>1 {print $2}' "$SERVER_LIST" | tr -d '\r' | sed 's/[[:space:]]//g' | while read -r ip; do
        # 過濾空行或標題
        [[ -z "$ip" ]] && continue
        [[ "${ip^^}" == *"IP"* ]] && continue 

        # 驗證 IP 格式
        if [[ "$ip" =~ $IP_REGEX ]]; then
            echo "$ip" >> "$EXECUTE_SERVER_LIST"
        else
            echo "[Warn] 忽略無效 IP 格式: $ip"
        fi
    done

    if [ ! -s "$EXECUTE_SERVER_LIST" ]; then
        echo "[Error] 解析後無有效 IP，請檢查 $SERVER_LIST 內容。"
        exit 1
    fi
    echo "[Success] IP 解析完成，準備執行任務。"
}

# 檢查 Server 健康狀態
check_server_health() {
    local ip=$1
    
    # L3 檢查: Ping
    if ! ping -c 1 -W 1 "$ip" &> /dev/null; then
        echo "[Fail] Network Unreachable (Ping fail) - $ip"
        return 1
    fi

    # L7 檢查: 嘗試 Redfish 連線
    # -f: fail silently (回傳非0), -s: silent
    if curl -s -k -f --connect-timeout 2 "https://$ip/redfish/v1/" &> /dev/null; then
        return 0
    else
        echo "[Fail] BMC Network OK but Service Down (Redfish fail) - $ip"
        return 2
    fi
}

# 執行密碼修改
change_password() {
    local ip=$1
    local ret_code=0
    
    output=$(ipmitool -I lanplus -H "$ip" -U "$BMC_USER" -P "$DEFAULT_PASS" user set password 2 "$BMC_PASS" 2>&1)
    ret_code=$?
    
    if [ $ret_code -eq 0 ]; then
        return 0
    else
        echo "[Debug] ipmitool error output: $output"
        return 1
    fi
}

# --- 主流程 ---
main_cycle() {
    # 檢查相依套件
    check_dependencies
    # 整理SEVER LIST
    parse_server_list
    
    
    # 讀取處理過後的 IP 清單到陣列
    local current_ips=($(cat "$EXECUTE_SERVER_LIST"))
    
    # echo USER:"$BMC_USER" DEF:"$DEFAULT_PASS" PASS:"$BMC_PASS"
    
    for cycle in $(seq 1 $MAX_CYCLES); do
        echo "----------------------------------------"
        echo "Cycle $cycle/$MAX_CYCLES | 剩餘: ${#current_ips[@]}"
        echo "----------------------------------------"

        local next_round_ips=()
        local i=0

        for ip in "${current_ips[@]}"; do
            ((i++))
            echo "[Process] Target: $ip"

            # 1. 檢查連線 (L3 + L7)
            if ! check_server_health "$ip"; then
                echo "[Retry] 連線檢查失敗 (Ping/Redfish)，排入下一輪。"
                next_round_ips+=("$ip")
                continue
            fi

            # 2. 執行修改
            echo "[Exec] 正在修改密碼..."
            if change_password "$ip"; then
                echo "[Successful] 密碼修改成功"
            else
                echo "[Retry] 密碼修改失敗 (可能原密碼錯誤或 Session 建立失敗)，加入下一圈: $ip"
                next_round_ips+=("$ip")
            fi
        done

        # 更新下一圈清單
        current_ips=("${next_round_ips[@]}")

        if [ ${#current_ips[@]} -eq 0 ]; then
            echo "========================================"
            echo "[Finished] 所有任務已成功完成！"
            echo "========================================"
            exit 0
        fi

        if [ "$cycle" -lt "$MAX_CYCLES" ]; then
            echo "[Wait] 30秒後進行下一輪嘗試..."
            sleep 30
        else
            echo "[Error] 已達最大重試次數。未完成清單: ${current_ips[*]}"
            exit 1
        fi
    done
}

# --- 執行 ---
main_cycle
