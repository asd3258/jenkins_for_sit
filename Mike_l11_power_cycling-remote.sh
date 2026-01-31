#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""
DEFAULT_PASS=""
OS_USER=""
OS_PASS=""

# --- 參數預設值 ---
TEST_MODE=""    # 預設為空dc ac warm
REPEAT_COUNT=2  # 測試圈數
WAIT_OFF=90     # Power Off 後等待秒數
OS_BOOT_TIME_OUT=900      # Power On 後等待 OS 開機最大秒數 (SSH timeout)
THIS_YEAR=$(date '+%Y')   # 當前年度, 用於檢查BMC與OS年時間是否被重置

SERVER_LIST="servers.csv"
EXECUTE_SERVER_LIST="execute_servers.csv"
LOG_ROOT="DC_Check_Logs"
TIME_STAMP=$(date '+%Y%m%d_%H%M')
DAY_STAMP=$(date '+%Y-%m-%d')

# Command
NVME_LIST="nvme list -o json | jq -r '.Devices[] | \"\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)\"' | sort"
# 邏輯說明：
# 1. /^[0-9a-f]{2,4}:/ : 抓取以 PCI Bus ID 開頭的行 (例如 01:00.0 VGA...) -> 用於比對硬體是否掉卡 (Topology)
# 2. /LnkSta:/ : 抓取 Link Status 行 -> 用於比對速度與頻寬
# 3. match(...) : 在 LnkSta 行中，只精確擷取 "Speed ... GT/s" 和 "Width x..." 的部分，丟棄後面浮動的 Training 狀態
LSPCI="lspci -vvv | awk '
        /^[0-9a-f]{2,4}:[0-9a-f]{2}:/ { 
            print $0 
        }
        /LnkSta:/ { 
            if (match($0, /Speed [^,]+, Width [^,]+/)) {
                print "\t" substr($0, RSTART, RLENGTH)
            }
        }
    '"
DECODE_PS="dmidecode -t processor | grep -E 'Socket Designation:|Version:|Core Count:|Thread Count:|Status:'"
DECODE_ME="dmidecode -t memory | grep -E 'Locator:|Size:|Type:|Speed:|Part Number:'"

# --- 函式區 ---
# 用於主程序的 Log，會顯示在螢幕
main_log() {
    echo "[Main] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # 如果有定義 LOG_FILE，則寫入
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}
verify_log() {
    local text
    text="$1"
    if [ -n "${VERIFY_FILE:-}" ]; then
        if [[ "$text" == "[Fail]"* ]]; then
            {
                echo ""
                echo "$text"
                echo "--------------------------------------------------------------"
            } >> "$VERIFY_FILE"
        elif [[ "$text" == "h2"* ]]; then
            {
                echo ""
                echo "$text"
            } >> "$VERIFY_FILE"
        else
            echo "$text" >> "$VERIFY_FILE"
        fi
    fi
    log "$text"
}
#Polling（輪詢
wait_with_spinner() {
    local pids_arr=($@)
    local spinner_start_time
    spinner_start_time=$(date +%s)
    local spinner_current_time
    local spinner_elapsed
    
    # 判斷是否為終端機環境 (Jenkins 回傳 false)
    if [ ! -t 1 ]; then
        wait "${pids_arr[@]}"
        return
    fi

    tput civis 2>/dev/null # 隱藏游標

    while true; do
        local any_running=false
        # 檢查每個 PID 是否存在
        for pid in "${pids_arr[@]}"; do
            # kill -0 不會殺掉進程，只是檢查是否存在
            if kill -0 "$pid" 2>/dev/null; then
                any_running=true
                break
            fi
        done

        if [ "$any_running" = "false" ]; then
            break
        fi
        
        spinner_current_time=$(date +%s)
        spinner_elapsed=$((spinner_current_time - spinner_start_time))
        
        # 修改這裡：
        printf "\r[Main] 測試進行中... (已耗時: %4ds)   " "$spinner_elapsed"
        
        sleep 1
    done
    
    tput cnorm 2>/dev/null # 恢復游標
    echo "" # 換行
}
# 檢查相依套件
check_dependencies() {
    for cmd in ipmitool sshpass curl jq netcat-openbsd; do
        if ! command -v $cmd &> /dev/null; then
            # 判斷是否為終端機環境 (Jenkins 回傳 false)
            # if [ ! -t 1 ]; then
            #     echo "---------------------------------------------------"
            #     echo "[Fatal] 缺少必要套件。請進入 Jenkins Docker 容器執行安裝："
            #     echo "docker exec -u 0 -it <container_name> bash"
            #     echo "apt-get update && apt-get install -y ipmitool sshpass curl jq netcat-openbsd"
            #     echo "---------------------------------------------------"
            #     exit 1
            # else
                # echo "[Info] 檢測未安裝 $cmd，開始自動安裝"
                sudo apt-get update -y -qq
                sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $cmd > /dev/null
            # fi
        fi
    done
}
# 遠端環境相依套件
remote_check_dependencies() {
    local ip=$1
    local remote_cmd='
        export LC_ALL=C  # 使用標準語系避免警告
        export LANG=C
        # 定義套件
        check_list=("ipmitool:ipmitool" "jq:jq" "nvme:nvme-cli")
        
        missing_pkgs=""
        
        for item in "${check_list[@]}"; do
            cmd=${item%%:*}   # 取得冒號前 (指令)
            pkg=${item#*:}    # 取得冒號後 (套件)
            
            if ! command -v "$cmd" &> /dev/null; then
                missing_pkgs="$missing_pkgs $pkg"
            fi
        done

        if [ -n "$missing_pkgs" ]; then
            echo "[Remote] 正在安裝缺失套件:$missing_pkgs"
            sudo apt-get update -y -qq
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing_pkgs
        fi
    '
    if remote_exec "$ip" "$remote_cmd"; then
        log "[Info] 遠端伺服器 [$ip] 相依套件檢查完成。"
    else
        log "[Error] 遠端伺服器 [$ip] 套件安裝失敗，請檢查 sudo 權限或網路。"
        return 1
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
            main_log "[Add] $NAME BMC: $BMC_IP OS: $OS_IP"
        else
            main_log "[Error] $NAME 的 IP 格式錯誤 (BMC: $BMC_IP, OS: $OS_IP)"
        fi
    done < "$SERVER_LIST"
    main_log "[Success] 解析完成，有效清單已儲存至 $EXECUTE_SERVER_LIST"
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
remote_copy() {
    local ip=$1
    local src=$2
    local dest=$3
    local mode=${4:-upload} # 第4參數：預設為 upload，若傳入 "download" 則為下載

    local retries=3       # 設定重試次數
    local wait_retry=5    # 重試間隔秒數
    local copy_count
    
    local scp_src
    local scp_dest
    local action_log

    # --- 判斷上傳或下載 ---
    if [[ "${mode,,}" == "download" ]]; then
        # [下載模式] Remote -> Local src 是遠端路徑，dest 是本地路徑
        scp_src="$OS_USER@$ip:$src"
        scp_dest="$dest"
        action_log="下載 (Remote:$src -> Local:$dest)"
    else
        # [上傳模式] Local -> Remote (預設) src 是本地路徑，dest 是遠端路徑
        scp_src="$src"
        scp_dest="$OS_USER@$ip:$dest"
        action_log="上傳 (Local:$src -> Remote:$dest)"
    fi

    for (( copy_count=1; copy_count<=retries; copy_count++ )); do
        # 執行 SCP
        sshpass -p "$OS_PASS" scp -q -r -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
            "$scp_src" "$scp_dest"
        
        if [ $? -eq 0 ]; then
            return 0
        else
            if [ $copy_count -lt $retries ]; then
                log "[Debug] SCP $action_log 失敗，第 $copy_count/$retries 次重試..." >&2
                sleep "$wait_retry"
            fi
        fi
    done

    log "[Error] SCP $action_log 失敗，已重試 $retries 次。" >&2
    return 1
}

wait_for_server_online() {
    local ip=$1
    local bmc_ip=$2
    local server_type=$3  # BMC or OS
    local timeout_sec=$4  # 設定最大等待時間(秒)
    local interval=60     # 每幾秒 Ping 一次
    local wait_os_ready=30   # SSH成功後等待進入OS畫面時間
    local execute_bmc_reset=240   # 設定execute BMC reset時間(秒)
    local start_time
    start_time=$(date +%s)
    local last_state
    local current_time
    local elapsed

    log "[Info] 檢測 ${server_type}: ${ip} 是否上線 (Timeout: ${timeout_sec}s)..."

    while true; do
        # --- 計算經過時間 ---
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        # --- 超時檢查 ---
        if [ $elapsed -ge $timeout_sec ]; then
            echo "" # 換行
            [ -n "$last_state" ] && log "最後狀態: $last_state"
            log "[ERROR] 等待 $server_type [$ip] 上線超時 ($timeout_sec 秒)！"
            return 1
        fi
        
        # --- BMC檢查邏輯 ---
        if [[ $server_type == "BMC" ]]; then
            # 1. 檢查網路層(L3 Ping)
            if ping -c 1 -W 1 "$ip" &> /dev/null; then
                last_state="[Info] Ping BMC success (L3), waiting for Redfish service (L7)..."
                # 2. 檢查應用層 (L7), -f: 失敗時回傳錯誤碼 (fail silently)
                if curl -s -k -f --connect-timeout 2 "https://$ip/redfish/v1/" &> /dev/null; then
                    log "[Info] BMC Redfish (L7) 服務正常 (耗時: ${elapsed}s)。"
                    return 0
                fi
            else
                last_state="[Info] BMC unreachable (L3) Waiting for Ping..."
            fi
        
        # --- OS檢查邏輯 ---
        else
            # 1. 檢查Power狀態(透過 BMC L7 確認 OS L1)
            local pwr_status
            pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
            if [[ "${pwr_status,,}" == *"is on"* ]]; then
                last_state="[Info] OS Power is ON (L1), waiting for Network..."
                # 2. 檢查網路層(L3 Ping)
                if ping -c 1 -W 1 "$ip" &> /dev/null; then
                    last_state="[Info] Ping OS success (L3), waiting for SSH Port 22 service (L7)..."
                    # 3. 檢查應用層(L7 SSH Port 22), 使用 nc (netcat) 偵測 Port 22, -z: 掃描模式, -w 2: 超時2秒
                    if nc -z -w 2 "$ip" 22  &> /dev/null; then
                        last_state="[Info] OS SSH is up (L7)"
                        # 4. SSH 進去確認 systemd 狀態，running 代表完全開機，degraded 代表開完但有部分服務失敗，starting 代表還在開機中
                        local boot_status
                        boot_status=$(sshpass -p "$OS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$OS_USER@$ip" "systemctl is-system-running" 2>/dev/null)
                        if [[ "$boot_status" == "running" ]] || [[ "$boot_status" == "degraded" ]]; then
                            log "[Info] OS Systemd Ready (Status: $boot_status) (耗時: ${elapsed}s)。"
                            return 0
                        else
                            last_state="[Info] SSH is up, but System is still booting (Status: $boot_status)..."
                            #sleep $wait_os_ready
                        fi
                    fi
                else
                    last_state="[Info] OS unreachable (L3) - Power is ON"
                fi
            else
                # --- Execute BMC reset ---
                if [ $elapsed -ge $execute_bmc_reset ]; then
                    ipmitool -I lanplus -C 17 -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" mc reset cold > /dev/null 2>&1
                    log "[ERROR] 等待 $server_type [$ip] 上線超時 ($execute_bmc_reset 秒), Execute BMC reset !"
                    sleep 240
                    # return 1
                fi
                last_state="[Info] OS Power is OFF (L1) System not started yet"
            fi
        fi
        log "$last_state"
        sleep $interval
    done
}

# 檢查BMC密碼是否被還原為DEFAULT
check_bmc_password_status() {
    local ip="$1"
    local pwr_status
    # 1. 嘗試用 [目前的密碼], &> /dev/null 2>&1 靜默執行, -N 5: 5秒超時, -R 3: 重試3次
    pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
    if [[ "${pwr_status,,}" == *"is"* ]]; then return 0; fi  # 密碼正常，未被還原

    # 2. 嘗試用 [預設密碼]
    pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$ip" -U "$BMC_USER" -P "$DEFAULT_PASS" power status 2>/dev/null)
    if [[ "${pwr_status,,}" == *"is"* ]]; then
        verify_log "[Warn] BMC ($ip) 密碼已被還原為 DEFAULT ($DEFAULT_PASS)！"
        return 1
    fi
    
    # 3. 如果兩者都失敗
    verify_log "[Error] BMC ($ip) 兩組密碼都無法連線($BMC_PASS)($DEFAULT_PASS)-確認是否為網路中斷或密碼錯誤。"
    return 2
}
check_and_turn_power_on() {
    local bmc_ip="$1"
    # 檢查當前電源狀態
    local pwr_status
    pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>&1)
    # 檢查 ipmitool 是否執行成功 ($? 為 0 表示成功)
    if [ $? -ne 0 ]; then
        main_log "[Error] 無法連線至 BMC 或指令執行失敗: $pwr_status"
        return 1
    fi
    if [[ "${pwr_status,,}" == *"is off"* ]]; then
        log "[Info] 偵測到目前為 Power Off 狀態，正在執行 Power On..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power on > /dev/null 2>&1
        sleep "$WAIT_OFF"
    else
        log "[Info] 目前電源狀態正常: $pwr_status"
    fi
}
# 抓取 Version
get_version_with_redfish() {
    local ip=$1
    curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip/redfish/v1/UpdateService/FirmwareInventory" | \
    jq -r '.Members[]."@odata.id"' | \
    xargs -I {} curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip{}" | \
    jq -r '"\(.Id) : \(.Version)"'
}

#OS Systemd Services
check_system_services() {
    local ip=$1
    local failed_services
    failed_services=$(remote_exec "$ip" "systemctl list-units --state=failed --no-legend --plain | wc -l")
    if [ "$failed_services" -gt 0 ]; then
        verify_log "[Fail] 發現 $failed_services 個系統服務啟動失敗！"
        remote_exec "$ip" "systemctl list-units --state=failed" >> "$VERIFY_FILE"
    else
        log "[Pass] OS Systemd Services Check OK"
    fi
}

golden_file() {
    local remote_dir=$1
    local bmc_ip=$2
    local os_ip=$3
    local server_dir=$4

    # 遠端安裝測試工具
    remote_check_dependencies "$os_ip"

    verify_log "h2 =========== Golden ==========="

    local local_decode="${remote_dir}/golden_decode.log"
    remote_exec "$os_ip" "dmidecode > $local_decode"
    if remote_exec "$os_ip" "grep -qi 'filled' '$local_decode'"; then
        verify_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
        main_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
        ((round_fail++))
    else
        log "[Pass] dmidecode Check OK"
    fi

    # OS Systemd Services
    check_system_services "$os_ip"
    
    # 1. Lspci
    remote_exec "$os_ip" "$LSPCI > ${remote_dir}/golden_lspci.log"
    
    # 2. Firmware Version
    get_version_with_redfish "$bmc_ip" > "${server_dir}/golden_firmware_version.log"

    # 3. dmidecode -t 4 (processor)
    remote_exec "$os_ip" "$DECODE_PS > ${remote_dir}/golden_decode_processor.log"

    # 4. dmidecode -t memory
    remote_exec "$os_ip" "$DECODE_ME > ${remote_dir}/golden_decode_memory.log"
    
    # 5. lscpu
    remote_exec "$os_ip" "lscpu > ${remote_dir}/golden_lscpu.log"

    # 6. Sensor Readings
    remote_exec "$os_ip" "ipmitool sdr list > ${remote_dir}/golden_sdr.log"
    remote_exec "$os_ip" "awk -F | '{print $1, $3}' ${remote_dir}/golden_sdr.log > ${remote_dir}/golden_sdr_remove_value.log"   # 去除數值
    # 檢查最後一個欄位 ($NF)，如果不是 ok 也不是 ns，就寫入
    # ok：正常。
    # ns (No Reading/Sensor disabled)：讀不到數值（有時是正常的，取決於配置）。
    # nc (Non-Critical)：輕微異常（警告）。
    # cr (Critical)：嚴重異常。
    # nr (Non-Recoverable)：不可恢復的錯誤。
    remote_exec "$os_ip" "awk '\$NF == nc || \$NF == cr || \$NF == nr' ${remote_dir}/golden_sdr_remove_value.log > ${remote_dir}/golden_sdr_ng_item.log"
    # 判斷結果 -s 表示檔案存在且大小 > 0 (代表有抓到錯誤)
    if remote_exec "$os_ip" "[ -f '${remote_dir}/golden_sdr_ng_item.log' ]"; then
        verify_log "[Fail] SDR Check Failed! Critical sensors found!"
        remote_exec "$os_ip" "awk '\$NF == nc || \$NF == cr || \$NF == nr' ${remote_dir}/golden_sdr_remove_value.log" >> "$VERIFY_FILE"
    else
        log "[Pass] SDR Check Pass!"
    fi

    # 7. nvme list
    remote_exec "$os_ip" "$NVME_LIST > ${remote_dir}/golden_nvme_list.log"
    #root@ubuntu-server:~# nvme list -o json | jq -r '.Devices[] | "\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)"' | sort
    #S666NE0RB01523 | SAMSUNG MZ1L21T9HCLS-00A07 | GDC7202Q | 1920383410176

    # 8. FRU
    remote_exec "$os_ip" "ipmitool fru print 2>/dev/null > ${remote_dir}/golden_fru.log"

    # 清除SEL & Dmesg
    sleep 1
    ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
    sleep 1
    remote_exec "$os_ip" "sudo dmesg -C" > /dev/null
    sleep 1

    # 11. lshw
    # remote_dir="${server_dir}/11--lshw"
    # mkdir -p "${remote_dir}"
    # remote_exec "$os_ip" "lshw" > "${remote_dir}/golden_lshw.log"
}
insert_into_log() {
    local current_count=$1
    local os_ip=$2
    local remote_path=$3
    local report_file=$4

    # 產生一個暫存檔名 (使用 $$ 加入 PID 避免衝突)
    local temp_local_file="/tmp/log_${os_ip}_$$.tmp"

    # 先寫入標題
    {
        echo "h2 ============= $current_count ============="
        echo ""
    } >> "$report_file"

    # 使用通用的 remote_copy 進行 [下載]
    # 參數順序: IP, 遠端路徑(來源), 本地路徑(目的), 模式
    if remote_copy "$os_ip" "$remote_path" "$temp_local_file" "download"; then
        # 下載成功，檢查檔案是否有內容 (-s 檔案存在且大於0)
        if [ -s "$temp_local_file" ]; then
            cat "$temp_local_file" >> "$report_file"
        else
            echo "[Warn] 遠端 Log 檔案為空: $remote_path" >> "$report_file"
        fi
        rm -f "$temp_local_file" # 清除暫存檔
    else
        # 下載失敗 (remote_copy 內部已經有 retry 了，這裡只要記錄最終失敗)
        echo "[Error] 無法讀取遠端 Log (下載失敗): $remote_path" >> "$report_file"
    fi
}

# 單台 Server 測試流程
run_server_test() {
    local name=$1
    local bmc_ip=$2
    local os_ip=$3
    local current_count=$4
    local round_fail=0

    # 定義local 的 Log 目錄
    local server_dir="${LOG_ROOT}_${TIME_STAMP}/${bmc_ip}"
    mkdir -p "$server_dir"
    local shm_dir="/dev/shm/${LOG_ROOT}_${bmc_ip}"
    rm -rf "$shm_dir"
    mkdir -p "$shm_dir"

    # [Remote] 遠端受測機 - 永久儲存區 (用於存放 Golden 和 Fail Logs)
    local remote_dir="/root/${LOG_ROOT}_${TIME_STAMP}/${bmc_ip}"
    # [Remote] 遠端受測機 - RAM Disk 暫存區
    local remote_shm_dir="/dev/shm/${LOG_ROOT}_${bmc_ip}"

    local LOG_FILE="${server_dir}/run.log"
    local VERIFY_FILE="${server_dir}/run_verify.log"
    local SUMMARY_REPORT="${server_dir}/summary_report.txt"

    # 初始化
    local status_file="${server_dir}/${current_count}_round_status.log"
    echo "FAIL" > "$status_file"

    log "----------------------------------------"
    log "Round $current_count / $REPEAT_COUNT"

    # a. 檢查BMC啟動
    if ! wait_for_server_online "$bmc_ip" "$bmc_ip" "BMC" "$OS_BOOT_TIME_OUT"; then
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # b.檢查BMC密碼
    check_bmc_password_status "$bmc_ip"
    local pw_status=$?
    if [ $pw_status -eq 1 ]; then
        ((round_fail+=1))
        log "嘗試恢復 BMC 密碼..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$DEFAULT_PASS" user set password 2 "$BMC_PASS" > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            verify_log "[Fail] BMC ($ip) DEFAULT密碼修改失敗！"
            log "[Skip] 本次跳過此Server。"
            return 1
        fi
    elif [ $pw_status -eq 2 ]; then
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # c. 檢查並開啟電源
    check_and_turn_power_on "$bmc_ip"

    # d. 檢查OS啟動
    if ! wait_for_server_online "$os_ip" "$bmc_ip" "OS" "$OS_BOOT_TIME_OUT"; then
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # [Remote] 建立資料夾
    remote_exec "$os_ip" "mkdir -p $remote_dir"
    remote_exec "$os_ip" "mkdir -p $remote_shm_dir"

    # 撈取GOLDEN資料
    local j
    for (( j=1; j<=3; j++ )); do
        if remote_exec "$os_ip" "[ -d '${remote_dir}' ]"; then
            break  #遠端資料夾存在
        else
            golden_file "$remote_dir" "$bmc_ip" "$os_ip" "$server_dir"
        fi
    done

    verify_log "h2 ============= $current_count ============="

    # --- Power Action Execution ---
    local pwr_status
    local j
    if [[ "$TEST_MODE" == "DC" ]]; then
        log "[Exec] DC Power OFF..."
        for (( j=1; j<=2; j++ )); do
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power off > /dev/null 2>&1
            sleep "$WAIT_OFF"
            pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
            if [[ "${pwr_status,,}" != *"is off"* ]]; then
                if [ $j -eq 1 ]; then
                    log "[Warn] 關機失敗，重試..."
                else
                    log "[Error] 關機失敗，跳過此 Server。"
                    return 1
                fi
            else
                break
            fi
        done

        log "[Exec] IPMI Power ON..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power on > /dev/null 2>&1
        
    elif [[ "$TEST_MODE" == "AC" ]]; then
        log "[Exec] AUX Power Cycle..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" raw 0x06 0x05 0x73 0x75 0x70 0x65 0x72 0x75 0x73 0x65 0x72 > /dev/null 2>&1
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" raw 0x6 0x52 19 0x40 0 6 0x57 > /dev/null 2>&1
        sleep "$WAIT_OFF"

        # 檢查BMC啟動
        if ! wait_for_server_online "$bmc_ip" "$bmc_ip" "BMC" "$OS_BOOT_TIME_OUT"; then
            log "[Skip] 本次跳過此Server。"
            return 1
        fi
        # 檢查並開啟電源
        check_and_turn_power_on "$bmc_ip"
    
    elif [[ "$TEST_MODE" == "WARM" ]]; then
        log "[Exec] OS Warm Boot (SSH Reboot)..."
        # 使用 nohup 避免 SSH 斷線造成 script 報錯
        local cmd_ret=1
        for (( j=1; j<=3; j++ )); do
            sshpass -p "$OS_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                "$OS_USER@$os_ip" "nohup bash -c 'sleep 1; reboot' > /dev/null 2>&1 &"
            if [ $? -eq 0 ]; then
                log "[Info] Reboot 指令發送成功"
                cmd_ret=0
                break
            else
                log "[Warn] Reboot 指令發送失敗 (SSH連線問題?)，第 $j 次重試..."
                sleep 5
            fi
        done
        
        if [ $cmd_ret -ne 0 ]; then
             log "[Error] 無法透過 SSH 執行 Reboot，跳過此 Server。"
             return 1
        fi
    else
        main_log "參數${TEST_MODE}錯誤，非dc ac warm"
        exit 1
    fi

    # 等待開機
    log "[Info] 等待 240 秒讓系統重啟..."
    sleep 240

    # 4. 檢查OS啟動
    if ! wait_for_server_online "$os_ip" "$bmc_ip" "OS" "$OS_BOOT_TIME_OUT"; then
        log "[Fail] Round $current_count OS Boot Timeout."
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # 驗證 (Health Check)
    log "=== 執行 Health Check ,Round $current_count ==="

    # OS Systemd Services
    check_system_services "$os_ip"
    
    # 0. dmidecode Verify
    local remote_shm_path="${remote_shm_dir}/decode.log"
    remote_exec "$os_ip" "dmidecode > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi 'filled' '$remote_shm_path'"; then
        verify_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/00_decode.log"
        ((round_fail++))
    else
        log "[Pass] dmidecode Check OK"
    fi

    # 1. Lspci Verify
    local remote_shm_path="${remote_shm_dir}/lspci.log"
    remote_exec "$os_ip" "$LSPCI > ${remote_shm_path}"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_lspci.log' '$remote_shm_path'"; then
        verify_log "[Fail] Lspci Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_lspci.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/01_lspci.log"
        ((round_fail++))
    else
        log "[Pass] dmidecode Check OK"
    fi

    # 2. Firmware Verify  server_dir
    get_version_with_redfish "$bmc_ip" > "${shm_dir}/firmware_version.log"
    if diff -q "${server_dir}/golden_firmware_version.log" "${shm_dir}/firmware_version.log" > /dev/null; then
        log "[Pass] Firmware Version Check OK"
    else
        verify_log "[Fail] Firmware Version Mismatch!"
        diff -u "${server_dir}/golden_firmware_version.log" "${shm_dir}/firmware_version.log" >> "$VERIFY_FILE"
        {
            echo "h2 ============= $current_count ============="
            echo ""
            cat "${shm_dir}/firmware_version.log"
        } >> "${server_dir}/02_firmware_version.log"
        ((round_fail++))
    fi

    # 3. dmidecode -t 4 (processor)
    local remote_shm_path="${remote_shm_dir}/decode_processor.log"
    remote_exec "$os_ip" "$DECODE_PS > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_decode_processor.log' '$remote_shm_path'"; then
        log "[Pass] dmidecode processor Check OK"
    else
        verify_log "[Fail] dmidecode processor Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_decode_processor.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/03_decode_processor.log"
        ((round_fail++))
    fi

    # 4. dmidecode -t memory
    local remote_shm_path="${remote_shm_dir}/decode_memory.log"
    remote_exec "$os_ip" "$DECODE_ME > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_decode_memory.log' '$remote_shm_path'"; then
        log "[Pass] dmidecode memory Check OK"
    else
        verify_log "[Fail] dmidecode memory Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_decode_memory.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/04_decode_memory.log"
        ((round_fail++))
    fi

    # 5. lscpu
    local remote_shm_path="${remote_shm_dir}/lscpu.log"
    remote_exec "$os_ip" "lscpu > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_lscpu.log' '$remote_shm_path'"; then
        log "[Pass] lscpu Check OK"
    else
        verify_log "[Fail] lscpu Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_lscpu.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/05_lscpu.log"
        ((round_fail++))
    fi

    # 6. Sensor Readings
    local remote_shm_path="${remote_shm_dir}/sdr.log"
    remote_exec "$os_ip" "ipmitool sdr list 2>/dev/null > $remote_shm_path"
    remote_exec "$os_ip" "awk -F | '{print $1, $3}' ${remote_shm_dir}/sdr.log > ${remote_shm_dir}/sdr_remove_value.log"   # 去除數值
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_sdr_remove_value.log' '${remote_shm_dir}/sdr_remove_value.log'"; then
        log "[Pass] SDR Check OK"
    else
        verify_log "[Fail] SDR Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_sdr_remove_value.log' '${remote_shm_dir}/sdr_remove_value.log'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/06_sdr.log"
        ((round_fail++))
    fi

    # 7. nvme list
    local remote_shm_path="${remote_shm_dir}/nvme_list.log"
    remote_exec "$os_ip" "$NVME_LIST > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_nvme_list.log' '$remote_shm_path'"; then
        log "[Pass] nvme list Check OK"
    else
        verify_log "[Fail] nvme list Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_nvme_list.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/07_nvme_list.log"
        ((round_fail++))
    fi

    # 8. FRU Verify
    local remote_shm_path="${remote_shm_dir}/fru.log"
    remote_exec "$os_ip" "ipmitool fru print 2>/dev/null > $remote_shm_path"
    if remote_exec "$os_ip" "grep -qi '${remote_dir}/golden_fru.log' '$remote_shm_path'"; then
        log "[Pass] FRU Check OK"
    else
        verify_log "[Fail] FRU Mismatch!"
        remote_exec "$os_ip" "grep -u '${remote_dir}/golden_fru.log' '$remote_shm_path'" >> "$VERIFY_FILE"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/08_fru.log"
        ((round_fail++))
    fi

    # === SEL Check ===
    local remote_shm_path="${remote_shm_dir}/sel.log"
    remote_exec "$os_ip" "ipmitool sel elist > $remote_shm_path"
    # EXCLUDE_KEYS: 白名單 (需根據 Server 型號微調)
    #   - "Log area cleared": 腳本最後會清 Log，下一輪可能會抓到這行
    #   - "Initiated by power up": 正常的開機程序
    #   - "Power Supply .* AC lost": 預期的斷電
    #   - "Power Unit.*Power off/down": 預期的斷電
    local ERROR_KEYS="fail|error|critical|uncorrectable|non-recoverable|corrupt"
    local EXCLUDE_KEYS="Log area cleared|System Boot Initiated|Event Logging Disabled|AC lost|Power Supply .* Deasserted|Power Unit.*Power off/down"
    # grep -iE 抓取錯誤 -> grep -vE 排除白名單 -> wc -l 計算行數
    local error_count=$(remote_exec "$os_ip" "grep -iE '$ERROR_KEYS' '$remote_shm_path' | grep -vE '$EXCLUDE_KEYS' | wc -l")
    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] SEL check found $error_count errors."
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/09_sel.log"
        #((round_fail+=1))
    else
        log "[Pass] SEL Check OK"
    fi
    ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
    sleep 1

    # === Dmesg Check ===
    local remote_shm_path="${remote_shm_dir}/dmesg.log"
    remote_exec "$os_ip" "dmesg -T > $remote_shm_path"  # -T 時間, -x 顯示等級
    local ERROR_KEYS="fail|error|critical|Call Trace|Kernel panic|Oops|soft lockup|hung_task|MCE" #|warn|Hardware Error|I/O error|EXT4-fs error|critical target error
    local EXCLUDE_KEYS=".*ERST.*initialized.*" #ACPI|ERST|firmware|integrity: Problem loading X.509 certificate"
    local error_count=$(remote_exec "$os_ip" "grep -iE '$ERROR_KEYS' '$remote_shm_path' | grep -vE '$EXCLUDE_KEYS' | wc -l")
    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] Dmesg found $error_count errors"
        insert_into_log "$current_count" "$os_ip" "$remote_shm_path" "${server_dir}/10_dmesg.log"
        #((round_fail+=1))
    else
        log "[Pass] Dmesg Check OK!"
    fi
    remote_exec "$os_ip" "sudo dmesg -C" > /dev/null
    sleep 1

    # BMC Time
    local current_bmc_time
    if current_bmc_time=$(remote_exec "$os_ip" "ipmitool sel time get"); then							  
        local bmc_year=$(echo "$current_bmc_time" | awk -F "/" '{print $3}' | awk '{print $1}')  #2026
        # 如果年份是 2 位數 (例如 26)，自動補全為 2026
        if [ ${#bmc_year} -eq 2 ]; then
            bmc_year="20${bmc_year}"
        fi
        if [ "$bmc_year" -lt "$THIS_YEAR" ]; then
            verify_log "[Fail] BMC Time is incorrect! Year: $bmc_year"
        else
            log "[Pass] BMC Time is valid! Year: $bmc_year"
        fi
    else
        verify_log "[Fail] BMC Time is Empty!"
    fi

    # OS Time
    local os_year=$(remote_exec "$os_ip" "date '+%Y'")
    if [ "$os_year" -lt "$THIS_YEAR" ]; then
        verify_log "[Fail] OS System Time is incorrect! Year: $os_year ,Year: $os_year"
    else
        log "[Pass] OS System Time is valid! Year: $os_year"
    fi
    
    # 寫入報告 echo "h2 ============= $current_count ============="
    {
        cat "$VERIFY_FILE"
        echo ""
    } >> "$SUMMARY_REPORT"

    # 清空
    :> "$VERIFY_FILE"

    if [ $round_fail -eq 0 ]; then
        log "Round $current_count Result: PASS"
        echo "PASS" > "$status_file"
        return 0
    else
        log "Round $current_count Result: FAIL"
        return 1
    fi
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

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        # --- 原有參數解析 ---
        # 解析 --item=xxx
        --item=*)
            TEST_MODE="${1#*=}" # 刪除 "=" 左邊字串，保留右邊的值
            TEST_MODE="${TEST_MODE^^}" # 轉大寫
            LOG_ROOT="${TEST_MODE}_Check_Logs"
            ;;
        
        # 解析 --loop=xxx
        --loop=*)
            REPEAT_COUNT="${1#*=}"
            ;;

        # --- 新增參數解析 (SIT/Jenkins 傳入) ---
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

        # 解析 --os_user=xxx
        --os_user=*)
            OS_USER="${1#*=}"
            ;;

        # 解析 --os_pass=xxx
        --os_pass=*)
            OS_PASS="${1#*=}"
            ;;

        # --- 幫助與錯誤處理 ---
        --help|-h)
            echo "Usage: $0 --item={DC|AC|WARM} --loop=N --bmc_user=USER  --bmc_def=DefPASS --bmc_pass=PASS --os_user=USER --os_pass=PASS"
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
# --- 檢查必要參數 ---
if [[ -z "$TEST_MODE" ]]; then
    echo "[Error] You must specify a test mode using --item."
    echo "Usage: $0 --item={dc|ac|warm}"
    exit 1
fi

# 再次確認輸入的值是否合法
if [[ ! "$TEST_MODE" =~ ^(DC|AC|WARM)$ ]]; then
    echo "[Error] Invalid mode: $TEST_MODE. Supported modes: dc, ac, warm"
    exit 1
fi

# if [[ "$TEST_MODE" == "AC" ]]; then WAIT_OFF=180; fi

main_log "[Config] Mode: $TEST_MODE, Loop: $REPEAT_COUNT, DC Off等待時間 = $WAIT_OFF, 等待OS重啟時間 = $OS_BOOT_TIME_OUT"

# 檢查相依套件
check_dependencies

# 整理SEVER LIST
parse_server_list

for (( i=1; i<=REPEAT_COUNT; i++)); do
    
    echo ""
    main_log "====== Cycle $i / $REPEAT_COUNT ======"
    
    # 設定Watchdog超時時間20min
    CYCLE_TIMEOUT=1200
    
    # 1. 觸發所有任務
    PID_LIST=""
    SERVER_NAMES=""
    row_count=1
    row_total=$(wc -l < "$EXECUTE_SERVER_LIST")
    while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
        main_log "[$row_count/$row_total] $NAME BMC: $BMC_IP OS: $OS_IP"
        ((row_count++))
        # Watchdog 模式呼叫, 參數順序: 1.時間  2.Server名稱  3.原本的函式  4...原本的參數
        run_with_watchdog "$CYCLE_TIMEOUT" "$NAME" \
            run_server_test "$NAME" "$BMC_IP" "$OS_IP" "$i" &
        pid=$!
        PID_LIST="$PID_LIST $pid"
        SERVER_NAMES="$SERVER_NAMES $NAME"
    done < "$EXECUTE_SERVER_LIST"

    # 2. 等待所有任務完成
    # wait $PID_LIST
    wait_with_spinner $PID_LIST
    
    # 3. 檢查結果 (讀取 status 檔案)
    while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
        status_file="${LOG_ROOT}_${TIME_STAMP}/${BMC_IP}/${i}_round_status.log"
        if [ -f "$status_file" ]; then
            result=$(cat "$status_file")
            main_log "Server: $NAME, Result: $result"
        else
            main_log "Server: $NAME, Result: UNKNOWN (Log missing)"
        fi
        rm $status_file
    done < "$EXECUTE_SERVER_LIST"
done

