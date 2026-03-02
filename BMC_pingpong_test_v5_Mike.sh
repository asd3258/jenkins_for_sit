#!/bin/bash

OS_BOOT_TIME_OUT=900      # Power On 後等待 OS 開機最大秒數 (SSH timeout)

# 遠端執行指令 (SSH)
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
              echo "[Debug] SSH 連線 $ip 失敗，第 $remote_count/$retries 次重試..." >&2
              sleep "$wait_retry"
          fi
      fi
  done

  echo "[Error] SSH 連線 $ip 失敗，已重試 $retries 次。" >&2
  return 1
}

wait_for_server_online() {
    local ip=$1
    local bmc_ip=$2
    local server_type=$3  # BMC or OS
    local timeout_sec=$4  # 設定最大等待時間(秒)
    local interval=60     # 每幾秒 Ping 一次
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
            [ -n "$last_state" ] && echo "最後狀態: $last_state"
            echo "[ERROR] 等待 $server_type [$ip] 上線超時 ($timeout_sec 秒)！"
            return 1
        fi
        
        # --- BMC檢查邏輯 ---
        if [[ $server_type == "BMC" ]]; then
            # 1. 檢查網路層(L3 Ping)
            if ping -c 1 -W 1 "$ip" &> /dev/null; then
                last_state="[Info] Ping BMC success (L3), waiting for Redfish service (L7)..."
                # 2. 檢查應用層 (L7), -f: 失敗時回傳錯誤碼 (fail silently)
                if curl -s -k -f --connect-timeout 2 "https://$ip/redfish/v1/" &> /dev/null; then
                    echo "[Info] BMC Redfish (L7) 服務正常 (耗時: ${elapsed}s)。"
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
                            echo "[Info] OS Systemd Ready (Status: $boot_status) (耗時: ${elapsed}s)。"
                            return 0
                        else
                            last_state="[Info] SSH is up, but System is still booting (Status: $boot_status)..."
                            #sleep $wait_os_ready
                        fi
                    fi
                else
                    last_state="[Info] OS unreachable (L3) - Power is ON"
                fi
            fi
        fi
        echo "$last_state"
        sleep $interval
    done
}

# === BMC Ping Pong Update Script ===

# === Step 0: Load Configuration ===
# === BMC Ping Pong Configuration === 
# Target BMC IP Address 
BMC_IP="192.168.129.81" 
BMC_USER="" 
BMC_PASS="" 
# Default password used after BMC reset (for password recovery) 
BMC_DEFAULT_PASS="" 

# Number of update cycles to run 
REPEAT_COUNT=100

# Failure behavior (0=disable, 1=enable)
PAUSE_ON_FAIL=0
PACKAGE_ON_FAIL=0

# Image URLs for two versions of BMC firmware (used in ping-pong update) 
BMC_IMAGE_URL1="" 
BMC_IMAGE_URL2=""

# OS ssh (for dmidecode)
OS_IP=""
OS_USER=""
OS_PASS=""
OS_SSH_PORT=22

# dmidecode check
DMIDECODE_FATAL_ON_FAIL=1   # 1=dmidecode FAIL -> exit immediately + package

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --loop=*)
            REPEAT_COUNT="${1#*=}"
            ;;
        --bmc_ip=*)
            BMC_IP="${1#*=}"
            ;;
        --bmc_user=*)
            BMC_USER="${1#*=}"
            ;;
        --bmc_pass=*)
            BMC_PASS="${1#*=}"
            ;;
        --bmc_def=*)
            BMC_DEFAULT_PASS="${1#*=}"
            ;;
        --os_ip=*)
            OS_IP="${1#*=}"
            ;;
        --os_user=*)
            OS_USER="${1#*=}"
            ;;
        --os_pass=*)
            OS_PASS="${1#*=}"
            ;;
        --fw_a_path=*)
            BMC_IMAGE_URL1="${1#*=}"
            ;;
        --fw_b_path=*)
            BMC_IMAGE_URL2="${1#*=}"
            ;;
        # 顯示幫助
        --help|-h)
            echo "Usage: $0 --fw_a_path --fw_b_path [--loop=N] --bmc_ip --bmc_user --bmc_pass --bmc_def --os_ip --os_user --os_pass"
            echo "  --loop=i         : Repeat count (Default: 100)"
            exit 0
            ;;
            
        # 未知參數處理
        *)
            echo "[Error] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    shift
done

# --- 檢查必要參數 ---
if [[ -z "$BMC_IMAGE_URL1" ]] || [[ -z "$BMC_IMAGE_URL2" ]]; then
    echo "[Error] BMC_IMAGE_URL1 (--fw_a_path) and BMC_IMAGE_URL2 (--fw_b_path) are required." >&2
    exit 1
fi

if [[ -z "$BMC_IP" ]] || [[ -z "$OS_IP" ]]; then
    echo "[Error] BMC_IP and OS_IP (--os_ip) are required." >&2
    exit 1
fi

LOG_FILE="bmc_pingpong_log_$BMC_IP.txt"
SEL_LOG_FILE="sel_log_collection_$BMC_IP.txt"
BMC_IMAGE_URLS=($BMC_IMAGE_URL1 $BMC_IMAGE_URL2)

# === Step 0.0: Clean Previous Per-IP Log Files ===
LOG_PREFIXES=("golden_fru" "golden_lan" "golden_user" "test_fru" "test_lan" "test_user" "sel")
for prefix in "${LOG_PREFIXES[@]}"; do
  target_file="${prefix}_${BMC_IP}.log"
  if [ -f "$target_file" ]; then
    echo "[INFO] Removing old $target_file"
    rm -f "$target_file"
  fi
done

if [ -f "$SEL_LOG_FILE" ]; then
  echo "[INFO] Removing old SEL log collection file: $SEL_LOG_FILE"
  rm -f "$SEL_LOG_FILE"
fi

if [ -f "$LOG_FILE" ]; then
  echo "[INFO] Removing old log file: $LOG_FILE"
  rm -f "$LOG_FILE"
fi

SUCCESS_COUNT=0
FAILURE_COUNT=0
FAILED_CYCLES=()

# === Step 0.2: Print Summary Placeholder First ===
echo "=== Ping Pong Test Summary ===" > "$LOG_FILE"
echo "Successful updates: $SUCCESS_COUNT" >> "$LOG_FILE"
echo "Failed updates: $FAILURE_COUNT" >> "$LOG_FILE"
echo "Failed cycles: ${FAILED_CYCLES[*]:-None}" >> "$LOG_FILE"
echo -e "\n=== BMC Ping Pong Test Log ===" >> "$LOG_FILE"

# === Step 1: Backup BMC Configurations ===
for type in fru lan; do
  echo "Backing up BMC $type configuration..." | tee -a "$LOG_FILE"
  ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS $type print > golden_${type}_$BMC_IP.log
  sleep 1
  echo
  echo "[INFO] Saved golden_${type}_$BMC_IP.log" | tee -a "$LOG_FILE"
done

echo "Backing up BMC user configuration..." | tee -a "$LOG_FILE"
ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS user list > golden_user_$BMC_IP.log
sleep 1

Check_redfish_service_ready() {
  redfishcmd="redfishtool raw -r $BMC_IP -u $BMC_USER -p $BMC_PASS -S Always "
  echo "Check redfish service is ready"
  while true; do
    $redfishcmd GET /redfish/v1/Chassis/ 2>/dev/null
    if [ "$?" == 0 ]; then
      echo
      echo "Redfish Service is OK."
      break
    else
      sleep 2
      echo -n -e "."
    fi
  done
  echo
}

for ((cycle=1; cycle<=REPEAT_COUNT; cycle++)); do
  echo
  echo "================== BMC Ping Pong Cycle $cycle ==================" | tee -a "$LOG_FILE"

  index=$(((cycle + 1) % 2))
  BMC_IMAGE_URL="${BMC_IMAGE_URLS[$index]}"

  # === Step 2: Check Current BMC Version ===
  echo "[INFO] Checking current BMC version before update..." | tee -a "$LOG_FILE"
  version_json=$(redfishtool raw -r $BMC_IP -u $BMC_USER -p $BMC_PASS -S Always GET /redfish/v1/UpdateService/FirmwareInventory/BMC)
  BMC_VERSION_BEFORE=$(echo "$version_json" | grep '"Version"' | awk -F '"' '{print $4}')
  echo "BMC version before update: $BMC_VERSION_BEFORE" | tee -a "$LOG_FILE"

  # === Step 3: Clear SEL ===
  echo "[INFO] Clearing BMC SEL log..." | tee -a "$LOG_FILE"
  ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS sel clear

  # === Step 4: Update BMC Firmware ===
  echo "Cycle $cycle: Updating BMC firmware via Redfish ($BMC_IMAGE_URL)..." | tee -a "$LOG_FILE"
  UPDATE_RESPONSE=$(curl -k -u $BMC_USER:$BMC_PASS -X POST -H "Content-Type: application/json" -d '{"TransferProtocol":"HTTP", "ImageURI":"'$BMC_IMAGE_URL'"}' https://$BMC_IP/redfish/v1/UpdateService/Actions/SimpleUpdate 2>/dev/null)
  echo "[RESPONSE] Update response: $UPDATE_RESPONSE" | tee -a "$LOG_FILE"

  TASK_ID=$(echo "$UPDATE_RESPONSE" | grep -o '/redfish/v1/TaskService/Tasks/[0-9]*' | awk -F '/' '{print $NF}')
  if [ -z "$TASK_ID" ]; then
    echo "[WARN] No Task ID found in response. Assuming immediate reboot will happen." | tee -a "$LOG_FILE"
  else
    echo "[INFO] Detected Task ID: $TASK_ID" | tee -a "$LOG_FILE"
  fi

  # === Step 5: Wait for BMC Reboot ===
  echo "[INFO] Waiting for BMC to reboot (420 seconds)..." | tee -a "$LOG_FILE"
  sleep 420

  # === Step 6: Change BMC Default Password ===
  echo "[INFO] Changing BMC default password if needed..." | tee -a "$LOG_FILE"
  ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_DEFAULT_PASS user set password 2 $BMC_PASS

  # === Step 7: Power Cycle ===
  echo "[INFO] Executing power cycle after BMC update..." | tee -a "$LOG_FILE"
  ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS chassis power cycle
  echo "[INFO] Waiting 400 seconds for system to come back after power cycle..." | tee -a "$LOG_FILE"
  sleep 400

  echo "[INFO] Checking if system is powered on..." | tee -a "$LOG_FILE"
  power_status=$(ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS chassis power status)
  echo "Current Power Status: $power_status" | tee -a "$LOG_FILE"

  if [[ "$power_status" != *"on"* ]]; then
    echo "[ERROR] System is not powered on after power cycle." | tee -a "$LOG_FILE"
    FAILURE_COUNT=$((FAILURE_COUNT+1))
    FAILED_CYCLES+=($cycle)
    continue
  fi

  # 檢查OS啟動
  if ! wait_for_server_online "$OS_IP" "$BMC_IP" "OS" "$OS_BOOT_TIME_OUT"; then
    log "[Skip] 本次跳過此Server。"
    exit 1
  fi

  local_decode="decode_${BMC_IP}.log"
  remote_exec "$OS_IP" "dmidecode" > "$local_decode"
  if grep -qi "filled" "$local_decode"; then
    echo "[Fail] dmidecode Found [To be filled by O.E.M.]"
    cp "$local_decode" "decode_${BMC_IP}_${cycle}.log"
  else
    echo "[Pass] dmidecode not found [To be filled by O.E.M.]"
  fi
  
  # === Step 8: Wait Redfish Ready ===
  Check_redfish_service_ready
  # === Step 9: Check Config Consistency ===
  for type in lan fru user; do
    echo "[CHECK] Verifying $type config..." | tee -a "$LOG_FILE"
    if [ "$type" == "user" ]; then
      ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS user list > test_${type}_$BMC_IP.log
    else
      ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS $type print > test_${type}_$BMC_IP.log
    fi
    diff golden_${type}_$BMC_IP.log test_${type}_$BMC_IP.log > /dev/null
    if [ $? -eq 0 ]; then
      echo "[PASS] $type config match." | tee -a "$LOG_FILE"
    else
      echo "[FAIL] $type config mismatch." | tee -a "$LOG_FILE"
    fi
  done

  # === Step 10: Collect SEL Log ===
  echo "[INFO] Collecting SEL log after boot..." | tee -a "$LOG_FILE"
  ipmitool -I lanplus -H $BMC_IP -U $BMC_USER -P $BMC_PASS sel elist >> "$SEL_LOG_FILE"
  echo "--- End of SEL for Cycle $cycle ---" >> "$SEL_LOG_FILE"

  # === Step 11: Check BMC Version After ===
  version_json=$(redfishtool raw -r $BMC_IP -u $BMC_USER -p $BMC_PASS -S Always GET /redfish/v1/UpdateService/FirmwareInventory/BMC)
  BMC_VERSION_AFTER=$(echo "$version_json" | grep '"Version"' | awk -F '"' '{print $4}')
  echo "Cycle $cycle: BMC Version changed $BMC_VERSION_BEFORE -> $BMC_VERSION_AFTER" | tee -a "$LOG_FILE"

  if [ "$BMC_VERSION_BEFORE" != "$BMC_VERSION_AFTER" ]; then
    echo "Cycle $cycle update passed." | tee -a "$LOG_FILE"
    SUCCESS_COUNT=$((SUCCESS_COUNT+1))
  else
    echo "Cycle $cycle update failed." | tee -a "$LOG_FILE"
    FAILURE_COUNT=$((FAILURE_COUNT+1))
    FAILED_CYCLES+=($cycle)
  fi

done

# === Step 12: Final Summary Rewrite ===
sed -i "1s/.*/=== Ping Pong Test Summary ===\nSuccessful updates: $SUCCESS_COUNT\nFailed updates: $FAILURE_COUNT\nFailed cycles: ${FAILED_CYCLES[*]:-None}\n\n=== BMC Ping Pong Test Log ===/" "$LOG_FILE"




