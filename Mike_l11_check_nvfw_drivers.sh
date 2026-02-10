#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""
OS_USER=""
OS_PASS=""

SERVER_LIST="servers.csv"
EXECUTE_SERVER_LIST="execute_servers.csv"
LOG_ROOT="FW_Check"
TIME_STAMP=$(date '+%Y%m%d_%H%M')

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --bmc_user=*)
            BMC_USER="${1#*=}"
            ;;
            
        --bmc_pass=*)
            BMC_PASS="${1#*=}"
            ;;

        --os_user=*)
            OS_USER="${1#*=}"
            ;;

        --os_pass=*)
            OS_PASS="${1#*=}"
            ;;
        # --- 幫助與錯誤處理 ---
        --help|-h)
            echo "Usage: $0 --bmc_user=USER --bmc_pass=PASS --os_user=USER --os_pass=PASS"
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

# --- 函式區 ---
log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # 如果有定義 LOG_FILE，則寫入
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}
# 整理SEVER LIST
parse_server_list() {
    # 定義 IP 的正則表達式 (重複三次 [0-9]. 最後接一個 [0-9])
    local IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

    # 清空之前的執行清單
    : > "$EXECUTE_SERVER_LIST"

    while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
        # 跳過空行或註解
        [[ "$NAME" =~ ^#.*$ ]] && continue
        [[ -z "$NAME" ]] && continue
        if [[ "${BMC_IP^^}" == *"BMC"* ]] || [[ "${OS_IP^^}" == *"OS"* ]]; then
            continue
        fi
        # 去除 Windows 換行符號 (\r) 與 空白
        NAME=$(echo "$NAME" | tr -d '\r' | xargs | sed 's/ /_/g')
        BMC_IP=$(echo "$BMC_IP" | tr -d '\r' | sed 's/[[:space:]]//g')
        OS_IP=$(echo "$OS_IP" | tr -d '\r' | sed 's/[[:space:]]//g')

        if [[ "$BMC_IP" =~ $IP_REGEX ]] && [[ "$OS_IP" =~ $IP_REGEX ]]; then
            echo "$NAME,$BMC_IP,$OS_IP" >> "$EXECUTE_SERVER_LIST"
            echo "[Add] $NAME BMC: $BMC_IP OS: $OS_IP"
        else
            echo "[Error] $NAME 的 IP 格式錯誤 (BMC: $BMC_IP, OS: $OS_IP)"
        fi
    done < "$SERVER_LIST"
    echo "[Success] 解析完成，有效清單已儲存至 $EXECUTE_SERVER_LIST"
}
# 遠端執行指令 (SSH) - 含重試機制
remote_exec() {
    local ip=$1
    local cmd=$2
    local retries=3       # 設定重試次數
    local wait_retry=5    # 重試間隔秒數
    local remote_count
    for (( remote_count=1; remote_count<=retries; remote_count++ )); do
        # 嘗試執行 SSH
        sshpass -p "$OS_PASS" ssh -n -o LogLevel=QUIET -o StrictHostKeyChecking=no \
            -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null \
            "$OS_USER@$ip" "$cmd"
        
        # 檢查指令回傳值 ($?)，0 代表成功
        if [ $? -eq 0 ]; then
            return 0
        else
            # 失敗時的處理
            if [ $remote_count -lt $retries ]; then
                # 訊息導向 stderr (>&2)，避免被變數捕捉
                log "[Debug] SSH 連線 $ip 失敗，第 $remote_count/$retries 次重試..." >&2
                sleep "$wait_retry"
            fi
        fi
    done

    log "[Error] SSH 連線 $ip 失敗，已重試 $retries 次。" >&2
    return 1
}

# 抓取 Version
get_version_with_redfish() {
    local ip=$1
    local path=$2
    curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip/redfish/v1/UpdateService/FirmwareInventory" | \
    jq -r '.Members[]."@odata.id"' | \
    xargs -I {} curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip{}" | \
    jq -r '"\(.Id) : \(.Version)"' > "$path"
    
    local cmd
    cmd="curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip/redfish/v1/UpdateService/FirmwareInventory" |"
    cmd="$cmd jq -r '.Members[]."@odata.id"' |"
    cmd="$cmd xargs -I {} curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip{}" |"
    local jq_filter='"\(.Id) : \(.Version)"'
    cmd="$cmd jq -r $jq_filter"

    echo "root@ubuntu-server:~# ${cmd}" | cat - "$path" > "$path.tmp"
}

# 單台 Server 測試流程
run_server_test() {
    local name=$1
    local bmc_ip=$2
    local os_ip=$3

    # 定義每個 Server 的 Log 目錄
    local server_dir="${LOG_ROOT}_${TIME_STAMP}/${bmc_ip}"
    mkdir -p "$server_dir"

    local LOG_FILE="${server_dir}/run.log"
    local CHECK_RESULT="${server_dir}/check_result.txt"

    log "----------------------------------------"

    # 1. 檢查 L3 (Ping)
    if ! ping -c 1 -W 1 "$bmc_ip" &> /dev/null; then
        echo "[Error] BMC $bmc_ip unreachable (L3)"
        return 1
    fi

    # 2. 檢查 L7 (Redfish API)
    if ! curl -s -k -f --connect-timeout 2 "https://$bmc_ip/redfish/v1/" &> /dev/null; then
        echo "[Error] BMC $bmc_ip Redfish unreachable (L7)"
        return 1
    fi

    # 3. 檢查電源狀態 (IPMI)
    local pwr_status
    if ! pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>&1); then
        echo "[Error] BMC $bmc_ip 連線失敗: $pwr_status"
        return 1
    fi
    # 檢查是否關機
    if [[ "${pwr_status,,}" == *"is off"* ]]; then
        echo "[Error] BMC $bmc_ip 目前為 Power Off 狀態"
        return 1
    fi

    # 4. 檢查OS狀態
    local boot_status
    boot_status=$(sshpass -p "$OS_PASS" ssh -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$OS_USER@$os_ip" "systemctl is-system-running" 2>/dev/null)
    if [[ "$boot_status" =~ ^(running|degraded)$ ]]; then
        log "[Info] BMC $bmc_ip ,OS Systemd Ready (Status: $boot_status)"
    else
        echo "[Error] BMC $bmc_ip ,System is still booting (Status: ${boot_status:-Unknown})..."
        return 1
    fi
    
    # 1. Firmware Version
    local path="${server_dir}/firmware_version.txt"
    get_version_with_redfish "$bmc_ip" "$path"
    cat "$path" > "$CHECK_RESULT"
    mv "$path.tmp" "$path"

    # 2. DOCA
    #ii  doca-host       3.2.0-125000-25.10-ubuntu2404     arm64        Software package
    local path="${server_dir}/doca.txt"
    local cmd="dpkg -l | grep -i doca-host"
    remote_exec "$os_ip" "$cmd" > "$path"
    local doca_ver=""
    if [ -f "$path" ]; then
        doca_ver=$(awk '$1=="ii" {print $3}' "$path" | awk -F '-' '{print $1 "-" $2}')
        echo "root@ubuntu-server:~# ${cmd}" | cat - "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    fi
    echo "DOCA_HOST : $doca_ver" >> "$CHECK_RESULT"

    # 3. GPU Driver & CUDA
    # 方式1 nvidia-smi 方式2 cat /proc/driver/nvidia/version
    # | NVIDIA-SMI 580.105.08             Driver Version: 580.105.08     CUDA Version: 13.0     |
    local path="${server_dir}/nvidia-smi.txt"
    local cmd="nvidia-smi"
    remote_exec "$os_ip" "$cmd" > "$path"
    local gpu_ver=""
    local cuda_ver=""
    if [ -f "$path" ]; then
        gpu_ver=$(grep "NVIDIA-SMI" "$path" | awk -F '[:]' '{print $2}' | awk '{print $1}')
        cuda_ver=$(grep "NVIDIA-SMI" "$path" | awk -F '[:]' '{print $3}' | awk '{print $1}')
        echo "root@ubuntu-server:~# ${cmd}" | cat - "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    fi
    {
        echo "GPU Driver : $gpu_ver"
        echo "CUDA : $cuda_ver"
    } >> "$CHECK_RESULT"

    # 4. IMEX version is: 580.105.08
    local path="${server_dir}/imex.txt"
    local cmd="/usr/bin/nvidia-imex --version"
    remote_exec "$os_ip" "$cmd" > "$path"
    local imex_ver=""
    if [ -f "$path" ]; then
        imex_ver=$(awk -F '[:]' '{print $2}' "$path")
        echo "root@ubuntu-server:~# ${cmd}" | cat - "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    fi
    echo "IMEX : $imex_ver" >> "$CHECK_RESULT"

    # 5. BF3_NIC FW
    local path="${server_dir}/nic_card.txt"
    local cmd="mlxfwmanager --query"
    remote_exec "$os_ip" "$cmd" > "$path"
    if [ -f "$path" ]; then
        #imex_ver=$(grep -iE "Device Type|FW" "$path" | awk '/Device Type:/ {dev=$3} /FW/ {print dev "-" ++i " : " $2}')
        #imex_ver=$(awk '/Device Type:/ {dev=$3} /FW/ {print dev " " $2}' "$path" | sort -k1,1 | awk '{print $1 "-" ++i " : " $2}')
        imex_ver=$(awk '/Device Type:/ {dev=$3} /FW/ {print dev " " $2}' "$path" | sort -k1,1 | awk '{count[$1]++; print $1 "-" count[$1] " : " $2}')
        echo "$imex_ver" >> "$CHECK_RESULT"
        echo "root@ubuntu-server:~# ${cmd}" | cat - "$path" > "$path.tmp" && mv "$path.tmp" "$path"
    fi
    #Device Type:      ConnectX8
    #    FW             40.47.1026     N/A
    #Device Type:      BlueField3
    #    FW             32.47.1026     N/A
    # ---------------------------------------
    #ConnectX8 : 40.47.1026
    #BlueField3 : 32.47.1026

    echo "[Info] BMC $name 完成資料收集。"
}

# --- Watchdog 包裝函式 ---
run_with_watchdog() {
    local timeout_sec=$1
    local name=$2  # 僅用於 Log 辨識
    shift 2        # 移除前兩個參數，剩下的($@)就是原本的指令與參數
    
    # 1. 啟動主要任務 (您的測試函式)
    "$@" &
    local task_pid=$!

    # 2. 啟動看門狗 (計時器)
    (
        sleep "$timeout_sec"
        # 檢查 task_pid 是否還活著 (-0 不發送訊號，只檢查存在)
        if kill -0 "$task_pid" 2>/dev/null; then
            echo "[Watchdog] Server: $name 測試超時 ($timeout_sec s)！強制終止 PID $task_pid..."
            # 發送 TERM 訊號，稍後強制 KILL
            kill "$task_pid" 2>/dev/null
            sleep 3
            kill -9 "$task_pid" 2>/dev/null
        fi
    ) &
    local watchdog_pid=$!

    # 3. 等待主要任務結束 (這會擋住，直到測試跑完 或 被看門狗殺掉)
    wait "$task_pid"
    local exit_code=$?

    # 4. 如果任務提早做完，殺掉看門狗，避免看門狗之後醒來誤殺其他重用 PID 的進程
    kill "$watchdog_pid" 2>/dev/null

    return $exit_code
}

# ==============================
# 主程式 (Main)
# ==============================
# 檢查檔案是否存在
if [ ! -f "$SERVER_LIST" ]; then
    echo "[Error] 找不到 $SERVER_LIST 檔案"
    exit 1
fi
# 強制移除 Windows 換行符號 (\r)，避免讀取失敗
sed -i 's/\r//g' "$SERVER_LIST"

# 整理SEVER LIST
parse_server_list

echo ""

# 設定Watchdog超時時間(秒)
CYCLE_TIMEOUT=90

# 1. 觸發所有任務
PID_LIST=""
SERVER_NAMES=""
row_count=1
row_total=$(wc -l < "$EXECUTE_SERVER_LIST")
while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
    echo "[$row_count/$row_total] $NAME BMC: $BMC_IP OS: $OS_IP"
    ((row_count++))
    # Watchdog 模式呼叫, 參數順序: 1.時間  2.Server名稱  3.原本的函式  4...原本的參數
    run_with_watchdog "$CYCLE_TIMEOUT" "$NAME" \
        run_server_test "$NAME" "$BMC_IP" "$OS_IP" &
    pid=$!
    PID_LIST="$PID_LIST $pid"
    SERVER_NAMES="$SERVER_NAMES $NAME"
done < "$EXECUTE_SERVER_LIST"

# 2. 等待所有任務完成
wait $PID_LIST

# 3. Summary Report
combine_result="${LOG_ROOT}_${TIME_STAMP}/combine_result.txt"
: > "$combine_result" # 初始化清空檔案

# a. 產生 Header (第一列：顯示各台 Server 的 BMC IP)
header="COMPONENT"
while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
    header="$header | $BMC_IP"
done < "$EXECUTE_SERVER_LIST"
echo "$header" >> "$combine_result"

# b. 以第一台 Server 為基準，取得所有要檢查的項目清單
first_bmc=$(head -n 1 "$EXECUTE_SERVER_LIST" | cut -d',' -f2)
main_file="${LOG_ROOT}_${TIME_STAMP}/${first_bmc}/check_result.txt"

if [ -f "$main_file" ]; then
    # 逐行讀取檢查項目名稱
    while IFS=':' read -r DRIVER VERSION || [ -n "$DRIVER" ]; do
        # 去除項目名稱前後空白
        item_name=$(echo "$DRIVER" | xargs)
        [ -z "$item_name" ] && continue
        
        row_data="$item_name"
        
        # 遍歷所有 Server，取出該項目對應的版本號
        while IFS=, read -r NAME2 BMC_IP2 OS_IP2 || [ -n "$NAME2" ]; do
            sub_file="${LOG_ROOT}_${TIME_STAMP}/${BMC_IP2}/check_result.txt"
            
            # 在該伺服器的結果檔中搜尋該項目，並只取出冒號後的版本號，使用 awk 取出第二欄並用 xargs 去除空白
            val=$(grep "^${item_name} " "$sub_file" | awk -F ':' '{print $2}' | xargs)
            
            # 如果沒找到該項目，填入 N/A
            [ -z "$val" ] && val="N/A"
            
            row_data="$row_data | $val"
        done < "$EXECUTE_SERVER_LIST"
        
        # 寫入報表
        echo "$row_data" >> "$combine_result"
        
    done < "$main_file"
fi

echo "[Success] 總表已產生: $combine_result"


# 4. 產生 HTML 報告 (Convert to HTML)
html_report="${LOG_ROOT}_${TIME_STAMP}/summary_report.html"

# 寫入 HTML 檔頭與 CSS 樣式 (讓表格變漂亮)
cat <<EOF > "$html_report"
<!DOCTYPE html>
<html>
<head>
<style>
    :root {
        --primary-color: #009879;
        --row-even: #f3f3f3;
        --row-even-sticky: #e8e8e8; /* 偶數列第一欄顏色 */
        --row-hover: #e0fcf0;
        --sticky-bg: #f1f1f1;       /* 奇數列第一欄顏色 */
    }
    .table-container {max-height: 85vh;overflow: auto;border: 1px solid #ccc;max-width: 100%;}
    table {border-collapse: collapse;width: auto;min-width: 600px;box-shadow: 0 0 20px rgba(0,0,0,0.1);}
    th, td {border: 1px solid #dddddd;text-align: left;padding: 8px;}
    th {position: sticky;top: 0;background-color: var(--primary-color);color: white;z-index: 2;}       /* 標題固定 (Top) */
    td:first-child {position: sticky; left: 0;z-index: 1;background-color: var(--sticky-bg);}            /* 第一欄固定 (Left) */
    th:first-child {position: sticky;left: 0;top: 0;z-index: 3;background-color: var(--primary-color);}  /* 左上角交集格 */
    tr:nth-child(even) {background-color: var(--row-even);}                        /* 偶數列背景 */
    tr:nth-child(even) td:first-child {background-color: var(--row-even-sticky);}  /* 偶數列的第一欄背景覆蓋 */
    tr:hover td {background-color: var(--row-hover) !important;}                   /* Hover 懸停效果 */
    .error { color: red; font-weight: bold; }
    body { font-family: Arial, sans-serif; margin: 20px; }
    h2 { color: #333; }
</style>
</head>
<body>
<h2>Server Firmware Check Report</h2>
<p>Generated time: $(date '+%Y-%m-%d %H:%M:%S')</p>
<table>
EOF

# 使用 awk 解析 txt 並轉換為 HTML 表格列
# -F '|'  : 指定分隔符號為 |
# !/^-/   : 忽略純分隔線 (例如 -------)
# gsub    : 去除前後空白
awk -F '|' '
    !/^-/ {
        print "<tr>"
        for(i=1; i<=NF; i++) {
            # 去除欄位前後空白
            gsub(/^ +| +$/, "", $i)
            
            # 第一行使用 <th> (標題)，其他行使用 <td> (內容)
            tag = (NR==1) ? "th" : "td"
            
            # 3. 設定樣式 class
            # 條件A: 內容是 "N/A"
            # 條件B: (僅針對數據列 NR>1 且 第3欄以後 i>2) 數值與第2欄(基準機台)不同
            if ( $i == "N/A" || (NR>1 && i>2 && $i != $2) ) {
                class = "class=\"error\""
            } else {
                class = ""
            }
            
            printf "<%s %s>%s</%s>\n", tag, class, $i, tag
        }
        print "</tr>"
    }
' "$combine_result" >> "$html_report"

# 寫入 HTML 結尾
cat <<EOF >> "$html_report"
</table>
</body>
</html>
EOF

echo "[Success] HTML 報告已產生: $html_report"
