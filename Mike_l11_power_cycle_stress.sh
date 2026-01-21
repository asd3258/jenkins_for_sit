#!/bin/bash
set +x

# --- 設定區 ---
BMC_USER="admin"
BMC_PASS="adminadmin"
DEFAULT_PASS="admin"
OS_USER="root"
OS_PASS="abcdef"

# --- 參數預設值 ---
TEST_MODE=""    # 預設為空dc ac warm
REPEAT_COUNT=2  # 測試圈數
WAIT_OFF=90     # Power Off 後等待秒數
OS_BOOT_TIME_OUT=900      # Power On 後等待 OS 開機最大秒數 (SSH timeout)
THIS_YEAR=$(date '+%Y')   # 當前年度, 用於檢查BMC與OS年時間是否被重置

SERVER_LIST="servers.csv"
EXECUTE_SERVER_LIST="execute_servers.csv"
LOG_ROOT="DC_Check_Logs"
time_stamp=$(date '+%Y%m%d_%H%M')

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

wait_for_jobs() {
    local pids_arr=($@)
    echo "[Main] 測試進行中，等待以下 Background PID 完成: ${pids_arr[*]}"
    
    # 直接使用 wait 等待所有子進程
    # Jenkins 會自動處理輸出流，不需要 spinner
    for pid in "${pids_arr[@]}"; do
        if wait "$pid"; then
            echo "[Main] PID $pid 任務完成。"
        else
            echo "[Main] PID $pid 任務失敗 (Exit Code: $?)。"
        fi
    done
}
# 檢查相依套件
check_dependencies() {
    local missing=0
    for cmd in ipmitool sshpass curl jq nc; do
        if ! command -v $cmd &> /dev/null; then
            echo "[Error] 尚未安裝 $cmd"
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        echo "---------------------------------------------------"
        echo "[Fatal] 缺少必要套件。請進入 Jenkins Docker 容器執行安裝："
        echo "docker exec -u 0 -it <container_name> bash"
        echo "apt-get update && apt-get install -y ipmitool sshpass curl jq netcat-openbsd"
        echo "---------------------------------------------------"
        exit 1
    fi
}

# 整理SEVER LIST
parse_server_list() {
    # 定義 IP 的正則表達式 (重複三次 [0-9]. 最後接一個 [0-9])
    local IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

    # 清空之前的執行清單
    : > "$EXECUTE_SERVER_LIST"
    echo "[Info] 開始解析 $SERVER_LIST ..."

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
            main_log "[Add] 加入清單: $NAME,$BMC_IP,$OS_IP"
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
    local interval=30     # 每幾秒 Ping 一次
    local wait_os_ready=30   # SSH成功後等待進入OS畫面時間
    local start_time
    start_time=$(date +%s)
    local last_state
    local current_time
    local elapsed

    log "檢測 $server_type [$ip] 是否上線 (Timeout: ${timeout_sec}s)..."

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
                    log "[Successful] BMC Redfish (L7) 服務正常 (耗時: ${elapsed}s)。"
                    return 0
                fi
            else
                last_state="[Fail] BMC unreachable (L3) Waiting for Ping..."
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
                    if nc -z -w 2 "$ip" 22; then
                        last_state="[Info] OS SSH is up (L7)"
                        # 4. SSH 進去確認 systemd 狀態，running 代表完全開機，degraded 代表開完但有部分服務失敗，starting 代表還在開機中
                        local boot_status
                        boot_status=$(sshpass -p "$OS_PASS" ssh -o StrictHostKeyChecking=no "$OS_USER@$ip" "systemctl is-system-running" 2>/dev/null)
                        if [[ "$boot_status" == "running" ]] || [[ "$boot_status" == "degraded" ]]; then
                            log "[Successful] OS Systemd Ready (Status: $boot_status) (耗時: ${elapsed}s)。"
                            return 0
                        else
                            last_state="[Info] SSH is up, but System is still booting (Status: $boot_status)..."
                            sleep $wait_os_ready
                        fi
                    fi
                else
                    last_state="[Fail] OS unreachable (L3) - Power is ON"
                fi
            else
                last_state="[Fail] OS Power is OFF (L1) System not started yet"
            fi
        fi
        sleep $interval
    done
}

# 檢查BMC密碼是否被還原為DEFAULT
check_bmc_password_status() {
    local ip="$1"

    # 1. 嘗試用 [目前的密碼], &> /dev/null 靜默執行, -N 5: 5秒超時, -R 3: 重試3次
    ipmitool -I lanplus -N 5 -R 3 -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" power status &> /dev/null
    sleep 0.5
    # 密碼正常，未被還原
    if [ $? -eq 0 ]; then return 0; fi

    # 2. 嘗試用 [預設密碼]
    ipmitool -I lanplus -N 5 -R 3 -H "$ip" -U "$BMC_USER" -P "$DEFAULT_PASS" power status &> /dev/null
    sleep 2
    if [ $? -eq 0 ]; then
        verify_log "[Warning] BMC ($ip) 密碼已被還原為 DEFAULT ($DEFAULT_PASS)！"
        return 1
    fi

    # 3. 如果兩者都失敗
    verify_log "[Error] BMC ($ip) 兩組密碼都無法連線($BMC_PASS)($DEFAULT_PASS)-確認是否為網路中斷或密碼錯誤。"
    return 2
}

# 收集 NVIDIA GPU 資訊
get_gpu_info() {
    local ip=$1
    local output_file=$2
    
    # 檢查是否安裝 nvidia-smi
    remote_exec "$ip" "command -v nvidia-smi >/dev/null 2>&1"
    if [ $? -eq 0 ]; then
        # 抓取摘要資訊 (Driver, CUDA, VBIOS, GPU Count)
        remote_exec "$ip" "nvidia-smi --query-gpu=gpu_name,vbios_version,driver_version --format=csv,noheader" > "$output_file"
        
        # 額外紀錄 GPU 數量
        local count
        count=$(wc -l < "$output_file")
        echo "Attached GPUs: $count" >> "$output_file"
        
        # 紀錄 CUDA 版本 (從 nvidia-smi 輸出第一行抓)
        remote_exec "$ip" "nvidia-smi | grep 'CUDA Version' | awk -F'CUDA Version: ' '{print \$2}' | awk '{print \$1}'" >> "$output_file"
    else
        echo "No NVIDIA GPU found or driver not installed" > "$output_file"
    fi
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

    # 使用 sed 過濾掉常見的變動欄位
    # 1. 過濾 IRQ 數字 (IRQ 123 -> IRQ xxx)
    # 2. 過濾 Latency (Latency=0 -> Latency=x)
    # 3. 過濾 HeaderLog, LnkSta (Link Status 會浮動)
    # 2. 過濾 ErrorSrc (錯誤源計數)
    # 3. 過濾 LnkSta2 (電氣訊號參數)
    # 4. 過濾 DpcCtl/DpcCap (DPC 控制狀態)
    # 5. 過濾 LnkCtl2 (因為 LnkSta2 變了，通常 LnkCtl2 也會有些微變動)
    # 6. Secondary status: Bridge 的狀態位元會浮動
    # 7. CEMsk / UEMsk / UESvrt: AER 錯誤遮罩設定，易受 Driver 載入順序影響
    # 8. DevCtl / DevSta: 裝置控制與狀態 (包含 Error Reporting Enable)
    # 9. Power Management Status (Status: D0/D3): 電源狀態會隨負載變動
    
    # remote_exec "$ip" "lspci -vvv" | sed \
    #     -e 's/IRQ [0-9]\+/IRQ xxx/g' \
    #     -e 's/Latency[:=] [0-9]\+/Latency: x/g' \
    #     -e 's/Physical Slot: [0-9]\+/Physical Slot: x/g' \
    #     -e 's/Capabilities: \[[0-9a-f]\+\]/Capabilities: [xx]/g' \
    #     -e '/HeaderLog:/d' \
    #     -e '/UESta:/d' \
    #     -e '/CESta:/d' \
    #     -e '/DevSta:/d' \
    #     -e '/IOMMU group:/d' \
    #     -e '/ErrorSrc:/d' \
    #     -e '/LnkSta2:/d' \
    #     -e '/LnkCtl2:/d' \
    #     -e '/DpcCtl:/d' \
    #     -e '/DpcCap:/d' \
    #     -e '/DpcSta:/d' \
    #     -e '/Secondary status:/d' \
    #     -e '/CEMsk:/d' \
    #     -e '/UEMsk:/d' \
    #     -e '/UESvrt:/d' \
    #     -e '/DevCtl:/d' \
    #     -e '/Status: D[0-3]/d' \
    #     -e 's/\(LnkSta: Speed [^,]\+, Width [^,]\+\).*/\1/g' \
    #     > "$output_file"
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


# 單台 Server 測試流程
run_server_test() {
    local name=$1
    local bmc_ip=$2
    local os_ip=$3
    local current_count=$4
    local round_fail=0

    # 定義每個 Server 的 Log 目錄
    local server_dir="${LOG_ROOT}_${time_stamp}/${bmc_ip}"
    mkdir -p "$server_dir"

    # Export 全域變數給 log() 使用
    export LOG_FILE="${server_dir}/run.log"
    export VERIFY_FILE="${server_dir}/run_verify.log"
    local SUMMARY_REPORT="${server_dir}/summary_report.txt"

    local status_file="${server_dir}/${current_count}_round_status.log"
    # 初始化
    echo "FAIL" > "$status_file"

    # 定義 受測端Server 的 Log 目錄
    local remote_dir="/root/${LOG_ROOT}_${time_stamp}/${bmc_ip}"
    remote_exec "$os_ip" "mkdir -p $remote_dir"

    # Command
    local NVME_LIST="nvme list -o json | jq -r '.Devices[] | \"\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)\"' | sort"

    log "----------------------------------------"
    log "Round $current_count / $REPEAT_COUNT"
    log "========== 開始測試 Server: $name (BMC: $bmc_ip, OS: $os_ip) =========="
    
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
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$DEFAULT_PASS" user set password 2 "$BMC_PASS" > /dev/null
        if [ $? -ne 0 ]; then
            verify_log "[Error] BMC ($ip) DEFAULT密碼修改失敗！"
            log "[Skip] 本次跳過此Server。"
            return 1
        fi
    elif [ $pw_status -eq 2 ]; then
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # c. 檢查當前電源狀態
    local pwr_status
    pwr_status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
    if [[ "${pwr_status,,}" == *"is off"* ]]; then
        log "[Info] 偵測到目前為 Power Off 狀態，正在執行 Power On..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power on > /dev/null
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

    # --- Golden Sample 建立 (只在 Round 1) ---
    if [[ "$current_count" -eq 1 ]]; then
        verify_log "h2 =========== Golden ==========="
        # 1. OS Systemd Services
        check_system_services "$os_ip"

        # 2. Lspci
        get_filtered_lspci "$os_ip" "${server_dir}/golden_lspci.log"

        # 3. GPU Info
        # get_gpu_info "$os_ip" "${server_dir}/golden_gpu.log"
        
        # 4. Firmware Version
        get_version_with_redfish "$bmc_ip" "${server_dir}/golden_firmware_version.log"

        # 5. dmidecode -t 4 (processor)
        remote_exec "$os_ip" "dmidecode -t processor" > "${server_dir}/golden_dcode_processor.log"

        # 6. dmidecode -t memory
        # remote_exec "$os_ip" "dmidecode -t memory | grep 'Size:' | sort" > "${server_dir}/golden_dcode_memory.log"
        remote_exec "$os_ip" "dmidecode -t memory" > "${server_dir}/golden_dcode_memory.log"
        
        # 7. lscpu
        remote_exec "$os_ip" "lscpu" > "${server_dir}/golden_lscpu.log"

        # 8. Sensor Readings
        remote_exec "$os_ip" "ipmitool sdr list" > "${server_dir}/golden_sdr.log"
        # 去除數值
        local local_golden_sdr_remove_value="${server_dir}/golden_sdr_remove_value.log"
        awk -F "|" '{print $1, $3}' "${server_dir}/golden_sdr.log" > "$local_golden_sdr_remove_value"
        # 檢查最後一個欄位 ($NF)，如果不是 ok 也不是 ns，就寫入
        # ok：正常。
        # ns (No Reading/Sensor disabled)：讀不到數值（有時是正常的，取決於配置）。
        # nc (Non-Critical)：輕微異常（警告）。
        # cr (Critical)：嚴重異常。
        # nr (Non-Recoverable)：不可恢復的錯誤。
        local local_golden_sdr_ng_item="${server_dir}/golden_sdr_ng_item.log"
        awk '$NF == "nc" || $NF == "cr" || $NF == "nr"' "$local_golden_sdr_remove_value" > "$local_golden_sdr_ng_item"
        # 判斷結果 -s 表示檔案存在且大小 > 0 (代表有抓到錯誤)
        if [ -s "$local_golden_sdr_ng_item" ]; then
            verify_log "[Fail] SDR Check Failed! Critical sensors found!"
            cat "$local_golden_sdr_ng_item" >> "$VERIFY_FILE"
        else
            log "[Pass] SDR Check Pass!"
        fi

        # 9. nvme list
        remote_exec "$os_ip" "$NVME_LIST" > "${server_dir}/golden_nvme_list.log"
        #root@ubuntu-server:~# nvme list -o json | jq -r '.Devices[] | "\(.SerialNumber) | \(.ModelNumber) | \(.Firmware) | \(.PhysicalSize)"' | sort
        #S666NE0RB01523 | SAMSUNG MZ1L21T9HCLS-00A07 | GDC7202Q | 1920383410176
        #S6RMNC0WA00324 | SAMSUNG MZTL23T8HCLS-00A07 | GDC6302Q | 3840755982336

        # 10. FRU
        remote_exec "$os_ip" "ipmitool fru print 2>/dev/null" > "${server_dir}/golden_fru.log"
        
        # 11. lshw
        # remote_exec "$os_ip" "lshw" > "${server_dir}/golden_lshw.log"

        # --- 清除 ---
        # SEL & Dmesg
        sleep 3
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
        sleep 3
        remote_exec "$os_ip" "dmesg -C" > /dev/null
        sleep 3
    fi

    verify_log "h2 ============= $current_count ============="

    # --- Power Action Execution ---
    local status
    local j
    if [[ "$TEST_MODE" == "dc" ]]; then
        log "執行 DC Power OFF..."
        for (( j=1; j<=2; j++ )); do
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power off > /dev/null
            sleep "$WAIT_OFF"
            status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
            if [[ "${status,,}" != *"is off"* ]]; then
                if [ $j -eq 1 ]; then
                    log "[Warning] 關機失敗，重試..."
                else
                    log "[Error] 關機失敗，跳過此 Server。"
                    return 1
                fi
            else
                break
            fi
        done

        log "執行 IPMI Power ON..."
        ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power on > /dev/null
        
        # DC On 後等待開機
        log "等待 300 秒讓系統重啟..."
        sleep 300

    elif [[ "$TEST_MODE" == "ac" ]]; then
        log "執行 AUX Power Cycle..."
        for (( j=1; j<=2; j++ )); do
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" raw 0x06 0x05 0x73 0x75 0x70 0x65 0x72 0x75 0x73 0x65 0x72 > /dev/null
            ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" raw 0x6 0x52 19 0x40 0 6 0x57 > /dev/null
            sleep "$WAIT_OFF" 
            status=$(ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" power status 2>/dev/null)
            if [[ "${status,,}" != *"is off"* ]]; then
                if [ $j -eq 1 ]; then
                    log "[Warning] AC AUX關機失敗，重試..."
                else
                    log "[Error] AC AUX關機失敗，跳過此 Server。"
                    return 1
                fi
            else
                break
            fi
        done
        # AC斷電重啟
        log "等待 480 秒讓系統重啟..."
        sleep 480
    elif [[ "$TEST_MODE" == "warm" ]]; then
        log "執行 OS Warm Boot (SSH Reboot)..."
        # 使用 nohup 避免 SSH 斷線造成 script 報錯
        local cmd_ret=1
        for (( j=1; j<=3; j++ )); do
            sshpass -p "$OS_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                "$OS_USER@$os_ip" "nohup reboot > /dev/null 2>&1 &"
            sleep 1
            if [ $? -eq 0 ]; then
                log "[Info] Reboot 指令發送成功"
                cmd_ret=0
                break
            else
                log "[Warning] Reboot 指令發送失敗 (SSH連線問題?)，第 $j 次重試..."
                sleep 5
            fi
        done
        
        if [ $cmd_ret -ne 0 ]; then
             log "[Error] 無法透過 SSH 執行 Reboot，跳過此 Server。"
             return 1
        fi
        log "等待 180 秒讓系統重啟..."
        sleep 180
    else
        main_log "參數${TEST_MODE}錯誤，非dc ac warm"
        exit 1
    fi

    # 4. 檢查OS啟動
    if ! wait_for_server_online "$os_ip" "$bmc_ip" "OS" "$OS_BOOT_TIME_OUT"; then
        log "[Fail] Round $current_count OS Boot Timeout."
        log "[Skip] 本次跳過此Server。"
        return 1
    fi

    # 驗證 (Health Check)
    log "=== 執行 Health Check ,Round $current_count ==="

    # 1. OS Systemd Services
    check_system_services "$os_ip"

    # 2. Lspci Verify (過濾版)
    local local_lspci="${server_dir}/${current_count}_lspci.log"
    get_filtered_lspci "$os_ip" "$local_lspci"
    if diff -q "${server_dir}/golden_lspci.log" "$local_lspci" > /dev/null; then
        log "[Pass] Lspci Check OK"
    else
        verify_log "[Fail] Lspci Mismatch!"
        diff -u "${server_dir}/golden_lspci.log" "$local_lspci" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 3. GPU Verify
    # local current_gpu="${server_dir}/${current_count}_gpu.log"
    # get_gpu_info "$os_ip" "$current_gpu"
    # if diff -q "$server_dir/golden_gpu.log" "$current_gpu" > /dev/null; then
    #     log "[Pass] GPU Info Check OK"
    # else
    #     verify_log "[Fail] GPU Info Mismatch!"
    #     diff -u "$server_dir/golden_gpu.log" "$current_gpu" >> "$VERIFY_FILE"
    #     ((round_fail+=1))
    # fi

    # 4. Firmware Verify
    local current_firmware="${server_dir}/${current_count}_firmware_version.log"
    get_version_with_redfish "$bmc_ip" "$current_firmware"
    if diff -q "$server_dir/golden_firmware_version.log" "$current_firmware" > /dev/null; then
        log "[Pass] Firmware Version Check OK"
    else
        verify_log "[Fail] Firmware Version Mismatch!"
        diff -u "$server_dir/golden_firmware_version.log" "$current_firmware" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 5. dmidecode -t 4 (processor)
    local current_dcode_processor="${server_dir}/${current_count}_dcode_processor.log"
    remote_exec "$os_ip" "dmidecode -t processor" > "$current_dcode_processor"
    if diff -q "$server_dir/golden_dcode_processor.log" "$current_dcode_processor" > /dev/null; then
        log "[Pass] dmidecode processor Check OK"
    else
        verify_log "[Fail] dmidecode processor Mismatch!"
        diff -u "$server_dir/golden_dcode_processor.log" "$current_dcode_processor" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 6. dmidecode -t memory
    local current_dcode_memory="${server_dir}/${current_count}_dcode_memory.log"
    remote_exec "$os_ip" "dmidecode -t memory" > "$current_dcode_memory"
    if diff -q "$server_dir/golden_dcode_memory.log" "$current_dcode_memory" > /dev/null; then
        log "[Pass] dmidecode memory Check OK"
    else
        verify_log "[Fail] dmidecode memory Mismatch!"
        diff -u "$server_dir/golden_dcode_memory.log" "$current_dcode_memory" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 7. lscpu
    local current_lscpu="${server_dir}/${current_count}_lscpu.log"
    remote_exec "$os_ip" "lscpu" > "$current_lscpu"
    if diff -q "$server_dir/golden_lscpu.log" "$current_lscpu" > /dev/null; then
        log "[Pass] lscpu Check OK"
    else
        verify_log "[Fail] lscpu Mismatch!"
        diff -u "$server_dir/golden_lscpu.log" "$current_lscpu" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 8. Sensor Readings
    local current_sdr="${server_dir}/${current_count}_sdr.log"
    remote_exec "$os_ip" "ipmitool sdr list" > "$current_sdr"
    # 去除數值
    local current_sdr_remove_value="${server_dir}/${current_count}_sdr_remove_value.log"
    awk -F "|" '{print $1, $3}' "${current_sdr}" > "$current_sdr_remove_value"
    if diff -q "$server_dir/golden_sdr_remove_value.log" "$current_sdr_remove_value" > /dev/null; then
        log "[Pass] SDR is same golden_sdr_remove_value.log"
    else
        verify_log "[Fail] SDR Mismatch!"
        diff -u "$server_dir/golden_sdr_remove_value.log" "$current_sdr_remove_value" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 9. nvme list
    local current_nvme_list="${server_dir}/${current_count}_nvme_list.log"
    remote_exec "$os_ip" "$NVME_LIST" > "$current_nvme_list"
    if diff -q "$server_dir/golden_nvme_list.log" "$current_nvme_list" > /dev/null; then
        log "[Pass] nvme list Check OK"
    else
        verify_log "[Fail] nvme list Mismatch!"
        diff -u "$server_dir/golden_nvme_list.log" "$current_nvme_list" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 10. FRU Verify
    local current_fru="${server_dir}/${current_count}_fru.log"
    remote_exec "$os_ip" "ipmitool fru print 2>/dev/null" > "$current_fru"
    if diff -q "$server_dir/golden_fru.log" "$current_fru" > /dev/null; then
        log "[Pass] FRU Check OK"
    else
        verify_log "[Fail] FRU Mismatch!"
        diff -u "$server_dir/golden_fru.log" "$current_fru" >> "$VERIFY_FILE"
        ((round_fail+=1))
    fi

    # 11. lshw
    # local current_lshw="${server_dir}/${current_count}_lshw.log"
    # remote_exec "$os_ip" "lshw" > "$current_lshw"
    # if diff -q "$server_dir/golden_lshw.log" "$current_lshw" > /dev/null; then
    #     log "[Pass] lshw Check OK"
    # else
    #     verify_log "[Fail] lshw Mismatch!"
    #     diff -u "$server_dir/golden_lshw.log" "$current_lshw" >> "$VERIFY_FILE"
    #     ((round_fail+=1))
    # fi

    # === SEL Check ===
    local local_sel="${server_dir}/${current_count}_sel.log"
    # 1. 抓取 Log 存到本地
    remote_exec "$os_ip" "ipmitool sel elist" > "$local_sel"

    # 2. 定義關鍵字
    # EXCLUDE_KEYS: 白名單 (需根據 Server 型號微調)
    #   - "Log area cleared": 腳本最後會清 Log，下一輪可能會抓到這行
    #   - "Initiated by power up": 正常的開機程序
    #   - "Power Supply .* AC lost": 預期的斷電
    ERROR_KEYS="fail|error|critical|uncorrectable|non-recoverable|corrupt|asserted"
    EXCLUDE_KEYS="Log area cleared|System Boot Initiated|Event Logging Disabled|AC lost|Power Supply .* Deasserted"

    # 3. 檢查邏輯
    # grep -iE 抓取錯誤 -> grep -vE 排除白名單 -> wc -l 計算行數
    error_count=$(grep -iE "$ERROR_KEYS" "$local_sel" | grep -vE "$EXCLUDE_KEYS" | wc -l)
    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] SEL check found $error_count errors."
        grep -iE "$ERROR_KEYS" "$local_sel" | grep -vE "$EXCLUDE_KEYS" >> "$VERIFY_FILE"
        ((round_fail+=1))
    else
        log "[Pass] SEL Check OK"
    fi

    # 4. 清除 SEL
    sleep 1
    ipmitool -I lanplus -N 5 -R 3 -H "$bmc_ip" -U "$BMC_USER" -P "$BMC_PASS" sel clear > /dev/null 2>&1
    sleep 1
    # -------------------


    # === Dmesg Check ===
    local local_dmesg="${server_dir}/${current_count}_dmesg.log"

    # 1. 抓取 Log, -T 時間, -x 顯示等級
    remote_exec "$os_ip" "dmesg -T -x" > "$local_dmesg"

    # 2. 定義關鍵字
    FATAL_KEYS="fail|error|critical|Call Trace|Kernel panic|Oops|soft lockup|hung_task|MCE" #|warn|Hardware Error|I/O error|EXT4-fs error|critical target error
    EXCLUDE_KEYS="Error Record Serialization Table (ERST) support is initialized" #ACPI|ERST|firmware|integrity: Problem loading X.509 certificate"

    # 3. 執行檢查
    # grep -iE 抓取錯誤 -> grep -vE 排除白名單 -> wc -l 計算行數
    error_count=$(grep -iE "$FATAL_KEYS" "$local_dmesg" | grep -vE "$EXCLUDE_KEYS" | wc -l)

    if [ "$error_count" -gt 0 ]; then
        verify_log "[Fail] Dmesg found $error_count errors"
        grep -iE "$FATAL_KEYS" "$local_dmesg" | grep -vE "$EXCLUDE_KEYS" >> "$VERIFY_FILE"
        ((round_fail+=1))
    else
        # 這裡可以做一個 "Soft Check"，只檢查 warn 但不計入 fail，僅供參考
        warn_count=$(grep -i "warn" "$local_dmesg" | wc -l)
        log "[Pass] Dmesg Check OK (Warnings: $warn_count)"
    fi

    # 3. 清除 Dmesg
    sleep 1
    remote_exec "$os_ip" "sudo dmesg -C" > /dev/null
    sleep 1
    # -------------------

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
            echo "(ipmitool sel time get) Command Result:$bmc_time" >> "$VERIFY_FILE"
        else
            log "[Pass] BMC Time is valid! Year: $bmc_time"
        fi
    else
        verify_log "[Fail] BMC Time is Empty!"
    fi

    # OS Time
    # local current_os_time="${server_dir}/${current_count}_os_time.log"
    # remote_exec "$os_ip" "date '+%Y-%m-%d %H:%M:%S'" > "${current_os_time}"
    local os_year=$(remote_exec "$os_ip" "date '+%Y'")
    if [ "$os_year" -lt "$THIS_YEAR" ]; then
        verify_log "[Fail] OS System Time is incorrect! Year: $os_year ,Year: $os_year"
    else
        log "[Pass] OS System Time is valid! Year: $os_year"
    fi

    # 延遲一段時間
    sleep 10
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

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        # 解析 --item=xxx
        --item=*)
            # "${1#*=}" 意思是刪除 "=" 左邊(包含=)的字串，只保留右邊的值
            TEST_MODE="${1#*=}"
            # 轉小寫 (避免輸入 DC, Dc, dc 造成誤判)
            TEST_MODE="${TEST_MODE,,}"
            LOG_ROOT="${TEST_MODE}_Check_Logs"
            shift # 移除目前處理完的參數 ($1)，原本的 $2 變成 $1
            ;;
        
        # 解析 --loop=xxx
        --loop=*)
            REPEAT_COUNT="${1#*=}"
            shift
            ;;
            
        # 顯示幫助
        --help|-h)
            echo "Usage: $0 --item={dc|ac|warm} [--loop=N]"
            echo "  --item=dc   : Run DC Power Cycle (Power Off -> Wait -> Power On)"
            echo "  --item=ac   : Run AC Power Cycle (Chassis Power Cycle)"
            echo "  --item=warm : Run Warm Boot (SSH Reboot)"
            echo "  --loop=N    : Repeat count (Default: 2)"
            exit 0
            ;;
            
        # 未知參數處理
        *)
            echo "[Error] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
done

# --- 檢查必要參數 ---
if [[ -z "$TEST_MODE" ]]; then
    echo "[Error] You must specify a test mode using --item."
    echo "Usage: $0 --item={dc|ac|warm}"
    exit 1
fi

# 再次確認輸入的值是否合法
if [[ ! "$TEST_MODE" =~ ^(dc|ac|warm)$ ]]; then
    echo "[Error] Invalid mode: $TEST_MODE. Supported modes: dc, ac, warm"
    exit 1
fi

main_log "[Config] Test Mode: $TEST_MODE, Loop: $REPEAT_COUNT, DC Off等待時間 = $WAIT_OFF, 等待OS重啟時間 = $OS_BOOT_TIME_OUT"

# 檢查相依套件
check_dependencies

# 整理SEVER LIST
parse_server_list

for (( i=1; i<=REPEAT_COUNT; i++)); do
    main_log "=== 開始 Cycle $i / $REPEAT_COUNT (併發測試) ==="

    # 設定Watchdog超時時間20min
    CYCLE_TIMEOUT=1200
    
    # 1. 觸發所有任務
    PID_LIST=""
    SERVER_NAMES=""
    while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
        main_log "[$i/$REPEAT_COUNT] DUT: $NAME BMC: $BMC_IP OS: $OS_IP"
        # Watchdog 模式呼叫, 參數順序: 1.時間  2.Server名稱  3.原本的函式  4...原本的參數
        run_with_watchdog "$CYCLE_TIMEOUT" "$NAME" \
            run_server_test "$NAME" "$BMC_IP" "$OS_IP" "$i" &
        pid=$!
        PID_LIST="$PID_LIST $pid"
        SERVER_NAMES="$SERVER_NAMES $NAME"
    done < "$EXECUTE_SERVER_LIST"

    # 2. 等待所有任務完成
    main_log "已觸發所有 Server，等待測試完成..."
    
    # wait $PID_LIST
    wait_for_jobs $PID_LIST
    
    # 3. 檢查結果 (讀取 status 檔案)
    while IFS=, read -r NAME BMC_IP OS_IP || [ -n "$NAME" ]; do
        status_file="${LOG_ROOT}_${time_stamp}/${BMC_IP}/${i}_round_status.log"
        if [ -f "$status_file" ]; then
            result=$(cat "$status_file")
            main_log "Server: $NAME, Result: $result"
        else
            main_log "Server: $NAME, Result: UNKNOWN (Log missing)"
        fi
    done < "$EXECUTE_SERVER_LIST"

    main_log "=== Cycle $i 結束 ==="
    echo ""
done
