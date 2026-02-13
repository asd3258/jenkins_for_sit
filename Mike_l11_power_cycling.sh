#!/bin/bash
# Mike_l11_power_cycling-v0213-01.sh

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""        # 一般密碼
DEFAULT_PASS=""    # 預設密碼
OS_USER=""
OS_PASS=""

# --- 參數預設值 ---
TEST_MODE=""    # 預設為空dc soft ac warm
REPEAT_COUNT=2  # 測試圈數
WAIT_OFF=60     # Power Off 後等待秒數
OS_BOOT_TIME_OUT=900      # Power On 後等待 OS 開機最大秒數 (SSH timeout)
THIS_YEAR=$(date '+%Y')   # 當前年度, 用於檢查BMC與OS年時間是否被重置

SERVER_LIST="servers.csv"
EXECUTE_SERVER_LIST="execute_servers.csv"
LOG_ROOT="DC_Check_Logs"
TIME_STAMP=$(date '+%Y%m%d_%H%M')

# Command
NVME_LIST="nvme list -o json | jq -r '.Devices[] | \"\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)\"' | sort"

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
    # 使用標準語系避免 grep 或 awk 處理時出現語系警告
    export LC_ALL=C
    export LANG=C
    # 定義套件清單 (格式: "檢查指令:安裝套件名稱")
    declare -a check_list=(
        # --- 基礎工具 ---
        "ipmitool:ipmitool"
        "jq:jq"
        "sshpass:sshpass"
        "curl:curl"
        "nc:netcat-openbsd"
    )
    
    missing_pkgs=""
    
    for item in "${check_list[@]}"; do
        cmd="${item%%:*}"   # 取得冒號前 (指令)
        pkg="${item#*:}"    # 取得冒號後 (套件)
        
        # 使用 command -v 檢查指令是否存在
        if ! command -v "$cmd" &> /dev/null; then
            missing_pkgs="$missing_pkgs $pkg"
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        echo "--------------------------------------------------"
        echo "偵測到缺失套件，準備安裝:$missing_pkgs"
        echo "--------------------------------------------------"
        
        # 更新 apt 快取
        sudo apt-get update -y -qq
        
        # 安裝套件, 靜默安裝可以加 > /dev/null
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing_pkgs > /dev/null
        
        if [ $? -eq 0 ]; then
            echo "所有套件安裝完成。"
        else
            echo "安裝過程中發生錯誤，請檢查網路或套件名稱。"
            exit 1
        fi
    fi
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
                        boot_status=$(sshpass -p "$OS_PASS" ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$OS_USER@$ip" "systemctl is-system-running" 2>/dev/null)
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

#收集與過濾 LSPCI
get_filtered_lspci() {
    local ip=$1
    local output_file=$2
    # 邏輯說明：
    # 1. /^[0-9a-f]{2,4}:/ : 抓取以 PCI Bus ID 開頭的行 (例如 01:00.0 VGA...) -> 用於比對硬體是否掉卡 (Topology)
    # 2. /LnkSta:/ : 抓取 Link Status 行 -> 用於比對速度與頻寬
    # 3. match(...) : 在 LnkSta 行中，只精確擷取 "Speed ... GT/s" 和 "Width x..." 的部分，丟棄後面浮動的 Training 狀態
    
    remote_exec "$ip" "lspci -vvv" | awk '
        /^[0-9a-f]{2,4}:[0-9a-f]{2}:/ { 
            print $0 
        }
        /LnkSta:/ { 
            if (match($0, /Speed [^,]+, Width [^,]+/)) {
                print "\t" substr($0, RSTART, RLENGTH)
            }
        }
    ' > "$output_file"
}
# 抓取 Version
get_version_with_redfish() {
    local ip=$1
    local output_file=$2
    curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip/redfish/v1/UpdateService/FirmwareInventory" | \
    jq -r '.Members[]."@odata.id"' | \
    xargs -I {} curl -u "$BMC_USER:$BMC_PASS" -k -s "https://$ip{}" | \
    jq -r '"\(.Id) : \(.Version)"' > "$output_file"
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
    local server_dir=$1
    local bmc_ip=$2
    local os_ip=$3
    local path
    # --- Golden Sample 建立 ---
    if [ ! -d "${server_dir}/10--dmesg" ]; then

        # 遠端安裝測試工具
        remote_check_dependencies "$os_ip"

        verify_log "h2 =========== Golden ==========="

        local path="${server_dir}/00--dmidecode"
        mkdir -p "${path}"
        local local_decode="${path}/golden_decode.log"
        remote_exec "$os_ip" "dmidecode" > "$local_decode"
        if grep -qi "filled" "$local_decode"; then
            verify_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
            main_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
            ((round_fail++))
        else
            log "[Pass] dmidecode Check OK"
        fi

        # 0. OS Systemd Services
        check_system_services "$os_ip"
        
        # 1. Lspci
        path="${server_dir}/01--lspci"
        mkdir -p "${path}"
        get_filtered_lspci "$os_ip" "${path}/golden_lspci.log"
        
        # 2. Firmware Version
        path="${server_dir}/02--fw_ver"
        mkdir -p "${path}"
        get_version_with_redfish "$bmc_ip" "${path}/golden_firmware_version.log"

        # 3. dmidecode -t 4 (processor)
        path="${server_dir}/03--decode_processor"
        mkdir -p "${path}"
        remote_exec "$os_ip" "dmidecode -t processor | grep -E 'Socket Designation:|Version:|Core Count:|Thread Count:|Status:'" \
        > "${path}/golden_decode_processor.log"

        # 4. dmidecode -t memory
        path="${server_dir}/04--decode_memory"
        mkdir -p "${path}"
        remote_exec "$os_ip" "dmidecode -t memory | grep -E 'Locator:|Size:|Type:|Speed:|Part Number:'" \
        > "${path}/golden_decode_memory.log"
        
        # 5. lscpu
        path="${server_dir}/05--lscpu"
        mkdir -p "${path}"
        remote_exec "$os_ip" "lscpu" > "${path}/golden_lscpu.log"

        # 6. Sensor Readings
        path="${server_dir}/06--sdr"
        mkdir -p "${path}"
        remote_exec "$os_ip" "ipmitool sdr list" > "${path}/golden_sdr.log"
        # 去除數值
        local local_golden_sdr_remove_value="${path}/golden_sdr_remove_value.log"
        awk -F "|" '{print $1, $3}' "${path}/golden_sdr.log" > "$local_golden_sdr_remove_value"
        # 檢查最後一個欄位 ($NF)，如果不是 ok 也不是 ns，就寫入
        # ok：正常。
        # ns (No Reading/Sensor disabled)：讀不到數值（有時是正常的，取決於配置）。
        # nc (Non-Critical)：輕微異常（警告）。
        # cr (Critical)：嚴重異常。
        # nr (Non-Recoverable)：不可恢復的錯誤。
        local local_golden_sdr_ng_item="${path}/golden_sdr_ng_item.log"
        awk '$NF == "nc" || $NF == "cr" || $NF == "nr"' "$local_golden_sdr_remove_value" > "$local_golden_sdr_ng_item"
        # 判斷結果 -s 表示檔案存在且大小 > 0 (代表有抓到錯誤)
        if [ -s "$local_golden_sdr_ng_item" ]; then
            verify_log "[Fail] SDR Check Failed! Critical sensors found!"
            cat "$local_golden_sdr_ng_item" >> "$VERIFY_FILE"
        else
            log "[Pass] SDR Check Pass!"
        fi

        # 7. nvme list
        path="${server_dir}/07--nvme_list"
        mkdir -p "${path}"
        remote_exec "$os_ip" "$NVME_LIST" > "${path}/golden_nvme_list.log"
        #root@ubuntu-server:~# nvme list -o json | jq -r '.Devices[] | "\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)"' | sort
        #S666NE0RB01523 | SAMSUNG MZ1L21T9HCLS-00A07 | GDC7202Q | 1920383410176

        # 8. FRU
        path="${server_dir}/08--fru"
        mkdir -p "${path}"
        remote_exec "$os_ip" "ipmitool fru print 2>/dev/null" > "${path}/golden_fru.log"

        # 清除SEL & Dmesg
        mkdir -p "${server_dir}/09--sel"
        mkdir -p "${server_dir}/10--dmesg"

        sleep 1
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
        sleep 1
        remote_exec "$os_ip" "dmesg -C" > /dev/null
        sleep 1
    fi
}


# 單台 Server 測試流程
run_server_test() {
    local name=$1
    local bmc_ip=$2
    local os_ip=$3
    local current_count=$4
    local round_fail=0

    # 定義每個 Server 的 Log 目錄
    local server_dir="${LOG_ROOT}_${TIME_STAMP}/${bmc_ip}"
    mkdir -p "$server_dir"

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

    # c. 檢查當前電源狀態
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
        # 等待5min
        sleep 300
    else
        log "[Info] 目前電源狀態正常: $pwr_status"
    fi

    # d. 檢查OS啟動
    if ! wait_for_server_online "$os_ip" "$bmc_ip" "OS" "$OS_BOOT_TIME_OUT"; then
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # 定義 受測端Server 的 Log 目錄
    #local remote_dir="/root/${LOG_ROOT}_${TIME_STAMP}/${bmc_ip}"
    #remote_exec "$os_ip" "mkdir -p $remote_dir"

    local j
    for (( j=1; j<=5; j++ )); do
        if [ ! -d "${server_dir}/10--dmesg" ]; then
            golden_file "$server_dir" "$bmc_ip" "$os_ip"
            sleep 1
        else
            break
        fi
    done

    verify_log "h2 ============= $current_count ============="

    # --- Power Action Execution ---
    local status
    local action_cmd=""
    local action_desc=""
    local poll_timeout=0
    local retry_limit=1
    local is_off=false
    local j

    if [[ "$TEST_MODE" == "DC" ]]; then
        action_desc="DC Power OFF (Force)"
        action_cmd="power off"
        poll_timeout=90      # 等待 OS 關機
        retry_limit=2        # 重試指令
    elif [[ "$TEST_MODE" == "SOFT" ]]; then
        action_desc="SOFT Power OFF (Graceful)"
        action_cmd="chassis power soft"
        poll_timeout=300     # 等待 OS 關機
        retry_limit=1
    fi

    if [[ "$TEST_MODE" == "DC" || "$TEST_MODE" == "SOFT" ]]; then
        log "[Exec] $action_desc..."

        local attempt
        for (( attempt=1; attempt<=retry_limit; attempt++ )); do
            
            # 發送關機指令
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" $action_cmd > /dev/null 2>&1
            
            # 進入 Polling 檢查
            local elapsed=0
            is_off=false
            
            while [ $elapsed -lt $poll_timeout ]; do
                status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
                
                if [[ "${status,,}" == *"is off"* ]]; then
                    is_off=true
                    break # 跳出 Polling 迴圈
                fi
                
                sleep 10
                ((elapsed+=10))

                if (( elapsed % 20 == 0 )); then 
                    log "[Wait] 等待電源關閉中... ($elapsed / $poll_timeout s)" 
                fi
            done

            if [ "$is_off" = true ]; then
                log "[Info] 系統已確認關機 (耗時: ${elapsed}s)。"
                break # 成功關機，跳出 Retry 迴圈
            else
                log "[Warn] 第 $attempt 次關機嘗試超時 (Status: $status)。"
                if [ $attempt -lt $retry_limit ]; then
                    log "[Retry] 重新發送關機指令..."
                fi
            fi
        done

        if [ "$is_off" = true ]; then
            log "[Info] 等待 ${WAIT_OFF}s 後執行開機..."
            sleep "$WAIT_OFF"
            
            log "[Exec] IPMI Power ON..."
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power on > /dev/null 2>&1
        else
            log "[Error] $action_desc 失敗，超過最大等待時間或重試次數。跳過此 Server。"
            return 1
        fi

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
    
    elif [[ "$TEST_MODE" == "WARM" ]]; then
        log "[Exec] OS Warm Boot (SSH Reboot)..."
        # 使用 nohup 避免 SSH 斷線造成 script 報錯
        local cmd_ret=1
        for (( j=1; j<=3; j++ )); do
            sshpass -p "$OS_PASS" ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \
                "$OS_USER@$os_ip" "nohup reboot > /dev/null 2>&1 &"
            sleep 1
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

    # 0. OS Systemd Services
    check_system_services "$os_ip"

    local path="${server_dir}/00--dmidecode"
    mkdir -p "${path}"
    local local_decode="${path}/${current_count}_decode.log"

    remote_exec "$os_ip" "dmidecode" > "$local_decode"
    if grep -qi "filled" "$local_decode"; then
        verify_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
        main_log "[Fail] dmidecode Found [To be filled by O.E.M.]"
        ((round_fail++))
    else
        log "[Pass] dmidecode Check OK"
    fi

    # 1. Lspci Verify
    local path="${server_dir}/01--lspci"
    local local_lspci="${path}/${current_count}_lspci.log"
    get_filtered_lspci "$os_ip" "$local_lspci"
    if diff -q "${path}/golden_lspci.log" "$local_lspci" > /dev/null; then
        log "[Pass] Lspci Check OK"
    else
        verify_log "[Fail] Lspci Mismatch!"
        diff -u "${path}/golden_lspci.log" "$local_lspci" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 2. Firmware Verify
    local path="${server_dir}/02--fw_ver"
    local current_firmware="${path}/${current_count}_firmware_version.log"
    get_version_with_redfish "$bmc_ip" "$current_firmware"
    if diff -q "${path}/golden_firmware_version.log" "$current_firmware" > /dev/null; then
        log "[Pass] Firmware Version Check OK"
    else
        verify_log "[Fail] Firmware Version Mismatch!"
        diff -u "${path}/golden_firmware_version.log" "$current_firmware" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 3. dmidecode -t 4 (processor)4
    local path="${server_dir}/03--decode_processor"
    local current_decode_processor="${path}/${current_count}_decode_processor.log"
    remote_exec "$os_ip" "dmidecode -t processor | grep -iE 'Socket Designation:|Version:|Core Count:|Thread Count:|Status:'" > "$current_decode_processor"
    if diff -q "${path}/golden_decode_processor.log" "$current_decode_processor" > /dev/null; then
        log "[Pass] dmidecode processor Check OK"
    else
        verify_log "[Fail] dmidecode processor Mismatch!"
        diff -u "${path}/golden_decode_processor.log" "$current_decode_processor" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 4. dmidecode -t memory
    local path="${server_dir}/04--decode_memory"
    local current_decode_memory="${path}/${current_count}_decode_memory.log"
    remote_exec "$os_ip" "dmidecode -t memory | grep -iE 'Locator:|Size:|Type:|Speed:|Part Number:'" > "$current_decode_memory"
    if diff -q "${path}/golden_decode_memory.log" "$current_decode_memory" > /dev/null; then
        log "[Pass] dmidecode memory Check OK"
    else
        verify_log "[Fail] dmidecode memory Mismatch!"
        diff -u "${path}/golden_decode_memory.log" "$current_decode_memory" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 5. lscpu
    local path="${server_dir}/05--lscpu"
    local current_lscpu="${path}/${current_count}_lscpu.log"
    remote_exec "$os_ip" "lscpu" > "$current_lscpu"
    if diff -q "${path}/golden_lscpu.log" "$current_lscpu" > /dev/null; then
        log "[Pass] lscpu Check OK"
    else
        verify_log "[Fail] lscpu Mismatch!"
        diff -u "${path}/golden_lscpu.log" "$current_lscpu" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 6. Sensor Readings
    local path="${server_dir}/06--sdr"
    local current_sdr="${path}/${current_count}_sdr.log"
    remote_exec "$os_ip" "ipmitool sdr list 2>/dev/null" > "$current_sdr"
    # 去除數值
    local current_sdr_remove_value="${path}/${current_count}_sdr_remove_value.log"
    awk -F "|" '{print $1, $3}' "${current_sdr}" > "$current_sdr_remove_value"
    if diff -q "${path}/golden_sdr_remove_value.log" "$current_sdr_remove_value" > /dev/null; then
        log "[Pass] SDR is same golden_sdr_remove_value.log"
    else
        verify_log "[Fail] SDR Mismatch!"
        diff -u "${path}/golden_sdr_remove_value.log" "$current_sdr_remove_value" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 7. nvme list
    local path="${server_dir}/07--nvme_list"
    local current_nvme_list="${path}/${current_count}_nvme_list.log"
    remote_exec "$os_ip" "$NVME_LIST" > "$current_nvme_list"
    if diff -q "${path}/golden_nvme_list.log" "$current_nvme_list" > /dev/null; then
        log "[Pass] nvme list Check OK"
    else
        verify_log "[Fail] nvme list Mismatch!"
        diff -u "${path}/golden_nvme_list.log" "$current_nvme_list" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 8. FRU Verify
    local path="${server_dir}/08--fru"
    local current_fru="${path}/${current_count}_fru.log"
    remote_exec "$os_ip" "ipmitool fru print 2>/dev/null" > "$current_fru"
    if diff -q "${path}/golden_fru.log" "$current_fru" > /dev/null; then
        log "[Pass] FRU Check OK"
    else
        verify_log "[Fail] FRU Mismatch!"
        diff -u "${path}/golden_fru.log" "$current_fru" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # === SEL Check ===
    local path="${server_dir}/09--sel"
    local local_sel="${path}/${current_count}_sel.log"
    # 1. 抓取 Log 存到本地
    remote_exec "$os_ip" "ipmitool sel elist" > "$local_sel"

    # 2. 定義關鍵字
    # EXCLUDE_KEYS: 白名單 (需根據 Server 型號微調)
    #   - "Log area cleared": 腳本最後會清 Log，下一輪可能會抓到這行
    #   - "Initiated by power up": 正常的開機程序
    #   - "Power Supply .* AC lost": 預期的斷電
    #   - "Power Unit.*Power off/down": 預期的斷電
    ERROR_KEYS="fail|error|critical|uncorrectable|non-recoverable|corrupt"
    EXCLUDE_KEYS="Log area cleared|System Boot Initiated|Event Logging Disabled|AC lost|Power Supply .* Deasserted|Power Unit.*Power off/down"

    # 3. 檢查邏輯
    # grep -iE 抓取錯誤 -> grep -vE 排除白名單 -> wc -l 計算行數
    local error_count=$(grep -iE "$ERROR_KEYS" "$local_sel" | grep -vE "$EXCLUDE_KEYS" | wc -l)
    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] SEL check found $error_count errors."
        #grep -iE "$ERROR_KEYS" "$local_sel" | grep -vE "$EXCLUDE_KEYS" >> "$VERIFY_FILE"
        #((round_fail+=1))
    else
        log "[Pass] SEL Check OK"
    fi
    # 4. 清除 SEL
    ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
    sleep 1
    # -------------------

    # === Dmesg Check ===
    local path="${server_dir}/10--dmesg"
    local local_dmesg="${path}/${current_count}_dmesg.log"
    # 1. 抓取 Log, -T 時間, -x 顯示等級
    remote_exec "$os_ip" "dmesg -T" > "$local_dmesg"

    # 2. 定義關鍵字
    FATAL_KEYS="fail|error|critical|Call Trace|Kernel panic|Oops|soft lockup|hung_task|MCE" #|warn|Hardware Error|I/O error|EXT4-fs error|critical target error
    EXCLUDE_KEYS=".*ERST.*initialized.*" #ACPI|ERST|firmware|integrity: Problem loading X.509 certificate"

    local error_count=$(grep -iE "$FATAL_KEYS" "$local_dmesg" | grep -vE "$EXCLUDE_KEYS" | wc -l)

    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] Dmesg found $error_count errors"
        #grep -iE "$FATAL_KEYS" "$local_dmesg" | grep -vE "$EXCLUDE_KEYS" >> "$VERIFY_FILE"
        #((round_fail+=1))
    else
        log "[Pass] Dmesg Check OK!"
    fi
    
    # # 3. 清除 Dmesg
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

    # 延遲一段時間
    sleep 3
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
        --item=*)
            TEST_MODE="${1#*=}"
            TEST_MODE="${TEST_MODE^^}" # 轉大寫
            LOG_ROOT="${TEST_MODE}_Check_Logs"
            ;;
        --loop=*)
            REPEAT_COUNT="${1#*=}"
            ;;
        --bmc_user=*)
            BMC_USER="${1#*=}"
            ;;
        --bmc_def=*)
            DEFAULT_PASS="${1#*=}"
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
        # 顯示幫助
        --help|-h)
            echo "Usage: $0 --item={dc|ac|warm} [--loop=N] --bmc_user=USER  --bmc_def=DefPASS --bmc_pass=PASS --os_user=USER --os_pass=PASS"
            echo "  --item=dc   : Force Shutdown Power Cycle (IPMI Power Off -> On)"
            echo "  --item=soft : Graceful Shutdown Power Cycle (IPMI Soft Off -> On)"
            echo "  --item=ac   : AC Power Cycle (AUX command power Cycle)"
            echo "  --item=warm : Warm Boot (SSH Reboot)"
            echo "  --loop=N    : Repeat count (Default: 2)"
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
    echo "Usage: $0 --item={dc|soft|ac|warm}"
    exit 1
fi

# 再次確認輸入的值是否合法
if [[ ! "$TEST_MODE" =~ ^(DC|SOFT|AC|WARM)$ ]]; then
    echo "[Error] Invalid mode: $TEST_MODE. Supported modes: dc, soft, ac, warm"
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
