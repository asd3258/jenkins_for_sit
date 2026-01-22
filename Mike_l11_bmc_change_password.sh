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

# 接收 Jenkins 傳入的參數, 使用 while 迴圈解析外部參數 (-U, -DP, -P)
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -U) BMC_USER="$2"; shift ;;       # 接收使用者帳號
        -DP) DEFAULT_PASS="$2"; shift ;;  # 接收舊密碼
        -P) BMC_PASS="$2"; shift ;;       # 接收新密碼
        *) echo "未知參數: $1"; exit 1 ;;
    esac
    shift
done

# --- 函式區 ---

# 1. 統一 Log 輸出格式
log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

# 2. 檢查相依套件
check_dependencies() {
    for cmd in ipmitool sshpass curl jq netcat-openbsd; do
        if ! command -v $cmd &> /dev/null; then
            # 判斷是否為終端機環境 (Jenkins 回傳 false)
            if [ ! -t 1 ]; then
                log_msg "---------------------------------------------------"
                log_msg "[Fatal] 缺少必要套件。請進入 Jenkins Docker 容器執行安裝："
                log_msg "docker exec -u 0 -it <container_name> bash"
                log_msg "apt-get update && apt-get install -y ipmitool sshpass curl jq netcat-openbsd"
                log_msg "---------------------------------------------------"
                exit 1
            else
                log_msg "[Info] 檢測未安裝 $cmd，開始自動安裝"
                sudo apt-get update -y -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $cmd > /dev/null
            fi
        fi
    done
}

# 3. 解析 Server List
parse_server_list() {
    # 定義 IP 的正則表達式
    local IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
    
    : > "$EXECUTE_SERVER_LIST" # 清空暫存檔
    log_msg "[Info] 開始解析 $SERVER_LIST ..."

    if [ ! -f "$SERVER_LIST" ]; then
        log_msg "[Error] 找不到 $SERVER_LIST"
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
            log_msg "[Warn] 忽略無效 IP 格式: $ip"
        fi
    done

    if [ ! -s "$EXECUTE_SERVER_LIST" ]; then
        log_msg "[Error] 解析後無有效 IP，請檢查 $SERVER_LIST 內容。"
        exit 1
    fi
    log_msg "[Success] IP 解析完成，準備執行任務。"
}

# 4. 檢查 Server 健康狀態
check_server_health() {
    local ip=$1
    
    # L3 檢查: Ping
    if ! ping -c 1 -W 1 "$ip" &> /dev/null; then
        log_msg "[Fail] Network Unreachable (Ping fail) - $ip"
        return 1
    fi

    # L7 檢查: 嘗試 Redfish 連線
    # -f: fail silently (回傳非0), -s: silent
    if curl -s -k -f --connect-timeout 2 "https://$ip/redfish/v1/" &> /dev/null; then
        return 0
    else
        log_msg "[Fail] BMC Network OK but Service Down (Redfish fail) - $ip"
        return 2
    fi
}

# 5. 執行密碼修改
change_password() {
    local ip=$1
    local ret_code=0
    
    output=$(ipmitool -I lanplus -H "$ip" -U "$BMC_USER" -P "$DEFAULT_PASS" user set password 2 "$BMC_PASS" 2>&1)
    ret_code=$?

    echo "$output" >> "$LOG_FILE"

    if [ $ret_code -eq 0 ]; then
        return 0
    else
        log_msg "[Debug] ipmitool error output: $output"
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
    
    for cycle in $(seq 1 $MAX_CYCLES); do
        log_msg "----------------------------------------"
        log_msg "Cycle $cycle/$MAX_CYCLES | 剩餘: ${#current_ips[@]}"
        log_msg "----------------------------------------"

        local next_round_ips=()
        local i=0

        for ip in "${current_ips[@]}"; do
            ((i++))
            log_msg "[Process] Target: $ip"

            # 1. 檢查連線 (L3 + L7)
            if ! check_server_health "$ip"; then
                log_msg "[Retry] 連線檢查失敗 (Ping/Redfish)，排入下一輪。"
                next_round_ips+=("$ip")
                continue
            fi

            # 2. 執行修改
            log_msg "[Exec] 正在修改密碼..."
            if change_password "$ip"; then
                log_msg "[Successful] 密碼修改成功"
            else
                log_msg "[Retry] 密碼修改失敗 (可能原密碼錯誤或 Session 建立失敗)，加入下一圈: $ip"
                next_round_ips+=("$ip")
            fi
        done

        # 更新下一圈清單
        current_ips=("${next_round_ips[@]}")

        if [ ${#current_ips[@]} -eq 0 ]; then
            log_msg "========================================"
            log_msg "[Finished] 所有任務已成功完成！"
            log_msg "========================================"
            exit 0
        fi

        if [ "$cycle" -lt "$MAX_CYCLES" ]; then
            log_msg "[Wait] 30秒後進行下一輪嘗試..."
            sleep 30
        else
            log_msg "[Error] 已達最大重試次數。未完成清單: ${current_ips[*]}"
            exit 1
        fi
    done
}

# --- 執行 ---
main_cycle
