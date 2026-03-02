#!/bin/bash
set -euo pipefail



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

    echo "[Info] 檢測 ${server_type}: ${ip} 是否上線 (Timeout: ${timeout_sec}s)..."

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


# --- 宣告變數 ---
BMC_IP=""
BMC_USER=""
BMC_PASS=""

OS_IP=""
OS_USER=""
OS_PASS=""

FW_FILE=""
OS_BOOT_TIME_OUT=900      # Power On 後等待 OS 開機最大秒數 (SSH timeout)

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --bmc_ip=*) BMC_IP="${1#*=}" ;;
        --bmc_user=*) BMC_USER="${1#*=}" ;;
        --bmc_pass=*) BMC_PASS="${1#*=}" ;;
        --os_ip=*) OS_IP="${1#*=}" ;;
        --os_user=*) OS_USER="${1#*=}" ;;
        --os_pass=*) OS_PASS="${1#*=}" ;;
        --fw_file=*) FW_FILE="${1#*=}" ;;
        --help|-h)
            echo "Usage: $0 --fw_file --bmc_ip --bmc_user --bmc_pass --os_ip --os_user --os_pass"
            exit 0
            ;;
        *)
            echo "[Error] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    shift
done

# --- 檢查必要參數 ---
if [[ -z "$BMC_IP" ]] || [[ -z "$OS_IP" ]]; then
    echo "[Error] BMC_IP (--bmc_ip) and OS_IP (--os_ip) are required." >&2
    exit 1
fi

if [[ -z "$FW_FILE" ]] || [[ ! -f "${FW_FILE}" ]]; then
  echo "[ERROR] Firmware file not specified or not found: ${FW_FILE:-<empty>}"
  exit 1
fi

UPDATE_SVC="https://${BMC_IP}/redfish/v1/UpdateService"
UPLOAD_URI="https://${BMC_IP}/redfish/v1/UpdateService/upload"

# 檢查BMC啟動
if ! wait_for_server_online "$BMC_IP" "$BMC_IP" "BMC" "$OS_BOOT_TIME_OUT"; then
    echo "[ERROR] BMC未啟動。"
    exit 1
fi

echo "[INFO] Get ETag from UpdateService..."
ETAG=$(
  curl -k -s -D - -o /dev/null -u "${BMC_USER}:${BMC_PASS}" "${UPDATE_SVC}" \
  | awk 'BEGIN{IGNORECASE=1} $1=="ETag:"{print $2}' \
  | tr -d '\r"'
)

if [[ -z "${ETAG}" ]]; then
  echo "[ERROR] Failed to get ETag from ${UPDATE_SVC}"
  exit 1
fi
echo "[INFO] ETag=${ETAG}"

echo "[INFO] PATCH ForceUpdate=true ..."
curl --http1.0 -k -s -X PATCH -u "${BMC_USER}:${BMC_PASS}" "${UPDATE_SVC}" \
  -H 'Content-Type: application/json' \
  -H "If-Match: \"${ETAG}\"" \
  -d '{"HttpPushUriOptions":{"ForceUpdate":true}}' > /dev/null

echo "[INFO] Uploading firmware: ${FW_FILE}"
RESP=$(
  curl --http1.0 -k -s -u "${BMC_USER}:${BMC_PASS}" -X POST "${UPLOAD_URI}" \
    -F 'UpdateParameters={"Targets":[]};type=application/json' \
    -F 'OemParameters={"ImageType":"PLDM","Platform":"HGX"};type=application/json' \
    -F "UpdateFile=@${FW_FILE}"
)

TASK_MONITOR=$(echo "${RESP}" | jq -r '.TaskMonitor // empty')
TASK_URI=$(echo "${RESP}" | jq -r '."@odata.id" // empty')

if [[ -z "${TASK_URI}" ]]; then
  echo "[ERROR] No @odata.id (Task URI) returned!"
  echo "${RESP}" | jq .
  exit 1
fi

echo "[INFO] Task URI = ${TASK_URI}"
[[ -n "${TASK_MONITOR}" ]] && echo "[INFO] TaskMonitor = ${TASK_MONITOR}"

poll_json() {
  local url="$1"
  local out http body

  out=$(curl -k -s -u "${BMC_USER}:${BMC_PASS}" -w $'\n%{http_code}' "https://${BMC_IP}${url}" || true)
  http=$(echo "$out" | tail -n1)
  body=$(echo "$out" | sed '$d')

  if [[ "$http" != "200" && "$http" != "201" && "$http" != "202" ]]; then
    return 1
  fi
  echo "$body" | jq -e . >/dev/null 2>&1 || return 1

  echo "$body"
  return 0
}

SLEEP_SEC=30
MISS=0
MISS_LIMIT=60   # ~10 min

echo "[INFO] Polling task progress..."
while true; do
  SRC="TaskMonitor"
  TASK_RAW=""

  if [[ -n "${TASK_MONITOR}" ]] && TASK_RAW=$(poll_json "${TASK_MONITOR}"); then
    :
  else
    SRC="Tasks"
    if TASK_RAW=$(poll_json "${TASK_URI}"); then
      :
    else
      MISS=$((MISS+1))
      echo "[WARN] Cannot read task yet (miss ${MISS}/${MISS_LIMIT})"
      if (( MISS >= MISS_LIMIT )); then
        echo "[ERROR] Too many misses; treat as failure."
        exit 1
      fi
      sleep "${SLEEP_SEC}"
      continue
    fi
  fi

  MISS=0

  STATE=$(echo "${TASK_RAW}" | jq -r '.TaskState // "Unknown"')
  STATUS=$(echo "${TASK_RAW}" | jq -r '.TaskStatus // "Unknown"')
  PCT=$(echo "${TASK_RAW}" | jq -r '.PercentComplete // "N/A"')

  echo "[TASK][${SRC}] State=${STATE} Status=${STATUS} Progress=${PCT}%"

  if [[ "${SRC}" == "Tasks" && "${STATE}" == "Completed" && "${STATUS}" == "OK" && "${PCT}" == "100" ]]; then
    echo "[INFO] FW Update completed. The system will reboot shortly to apply the firmware."
    curl -sku "${BMC_USER}:${BMC_PASS}" -H 'Content-Type: application/json' -X POST https://${BMC_IP}/redfish/v1/Systems/System_0/Actions/ComputerSystem.Reset -d '{"ResetType":"PowerCycle"}'
    echo ""
    echo "[INFO] Sleep 360s"
    sleep 360
    # 檢查OS啟動
    if ! wait_for_server_online "$OS_IP" "$BMC_IP" "OS" "$OS_BOOT_TIME_OUT"; then
      echo "[ERROR] 未進入OS內，請手動確認機台狀況。"
      exit 1
    else
      echo "[DONE] System reboot completed."
      exit 0
    fi
    break
  fi

  case "${STATE}" in
    Exception|Killed|Cancelled)
      echo "[ERROR] Firmware update failed!"
      exit 1
      ;;
  esac

  sleep "${SLEEP_SEC}"
done

