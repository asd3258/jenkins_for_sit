#!/bin/bash
set -euo pipefail

# --- 宣告變數 ---
BMC_IP=""
BMC_USER=""
BMC_PASS=""
FW_FILE=""

# --- 參數解析迴圈 ---
# $# 代表參數個數，只要還有參數就繼續跑
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --bmc_ip=*) BMC_IP="${1#*=}" ;;
        --bmc_user=*) BMC_USER="${1#*=}" ;;
        --bmc_pass=*) BMC_PASS="${1#*=}" ;;
        --fw_file=*) FW_FILE="${1#*=}" ;;
        --help|-h)
            echo "Usage: $0 --fw_file --bmc_ip --bmc_user --bmc_pass"
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
if [[ -z "$BMC_IP" ]]; then
    echo "[ERROR] BMC_IP (--bmc_ip) is required." >&2
    exit 1
fi

# 1. 檢查網路層(L3 Ping)
if ping -c 1 -W 1 "$BMC_IP" &> /dev/null; then
    # 2. 檢查應用層 (L7), -f: 失敗時回傳錯誤碼 (fail silently)
    if curl -s -k -f --connect-timeout 2 "https://$BMC_IP/redfish/v1/" &> /dev/null; then
        echo "[Info] BMC Redfish 服務正常。"
    else
        echo "[ERROR] BMC Redfish 無法正常連線。"
        exit 1
    fi
else
    echo "[ERROR] BMC Ping不到。"
    exit 1
fi

UPDATE_SVC="https://${BMC_IP}/redfish/v1/UpdateService"
UPLOAD_URI="https://${BMC_IP}/redfish/v1/UpdateService/upload"

if [[ ! -f "${FW_FILE}" ]]; then
  echo "[ERROR] File not found: ${FW_FILE}"
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

SLEEP_SEC=10
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
    echo "[DONE] Update completed. Please do DC (power cycle) to activate the new firmware."
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

