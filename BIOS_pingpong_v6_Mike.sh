#!/bin/bash
set -euo pipefail
export LC_ALL=C

# =========================
# ONLY YOU ALLOW TO CHANGE
# =========================
BMC_USER=""
BMC_PASS=""
BMC_IP=""

# Slot A / Slot B firmware package (ping-pong)
FW_A=""
FW_B=""
FW_A_PATH=""
FW_B_PATH=""
REPEAT_COUNT=100
# =========================

# =========================
# DC + HOST VERIFY
# =========================
OS_IP=""
OS_USER=""
OS_PASS=""

TASK_TIMEOUT=3600
TASK_INTERVAL=20
TASK_NA_LIMIT=12   # consecutive N/A parse miss limit; 12*20s=240s

HOST_PING_DOWN_TIMEOUT=240
HOST_PING_TIMEOUT=1200
SSH_TIMEOUT=1200
SSH_CONNECT_TIMEOUT=5

OS_STABLE_WAIT_SEC=300   # 5 minutes wait AFTER OS is reachable, before next cycle
# =========================

# =========================
# Auto pack on exit (PASS/FAIL/STOP/CTRL+C)
# =========================
OUTDIR=""         # set in main() (global)
START_TS="$(date +%Y%m%d_%H%M%S)"
ARCHIVE_PATH=""
TASK_LIVE_LOG=""  # set in main() (global)

# Context for live logging (avoid set -u unbound)
CURRENT_CYCLE="N/A"
CURRENT_SLOT="N/A"
CURRENT_TASK_ID="N/A"

finalize_and_pack() {
  local exit_rc="$1"
  set +e

  if [[ -n "${OUTDIR:-}" && -d "${OUTDIR:-}" ]]; then
    local tar_name
    tar_name="$(basename "$OUTDIR").tar.gz"
    ARCHIVE_PATH="$(dirname "$OUTDIR")/$tar_name"

    echo "[$(date '+%F %T')] [INFO] Packing results: $ARCHIVE_PATH"
    tar -czf "$ARCHIVE_PATH" "$OUTDIR" 2>/dev/null
    echo "[$(date '+%F %T')] [INFO] Pack done. exit_rc=$exit_rc"
  else
    echo "[$(date '+%F %T')] [WARN] OUTDIR not ready, skip pack. exit_rc=$exit_rc"
  fi
}

on_exit() {
  local rc=$?
  finalize_and_pack "$rc"
  exit "$rc"
}

trap on_exit EXIT
trap 'echo "[$(date "+%F %T")] [WARN] Interrupted"; exit 130' INT TERM
# =========================

ts() { date +"%F %T"; }
log() { echo "[$(ts)] $*"; }
fail() { echo "[$(ts)] [FAIL] $*" >&2; exit 1; }

# ---- live task log helper ----
live_task_log() {
  # usage: live_task_log "text..."
  local msg="$*"
  [[ -n "${TASK_LIVE_LOG:-}" ]] || return 0
  echo "[$(ts)][C${CURRENT_CYCLE}][S${CURRENT_SLOT}][T${CURRENT_TASK_ID}] $msg" >> "$TASK_LIVE_LOG"
}
# -----------------------------

extract_bios_ver_from_fw() {
  local fw="$1"
  local base
  base="$(basename "$fw")"
  echo "$base" | sed -n 's/.*-\([0-9][0-9][0-9][0-9]\)\.fwpkg$/\1/p'
}

normalize_ver() {
  # 0302 / 03.02 / 3.02 -> 03.02
  local v="$1"
  v="$(echo "$v" | tr -d '\r\n ')"
  v="${v//./}"
  [[ "$v" =~ ^[0-9]{4}$ ]] || { echo "$1"; return 0; }
  echo "${v:0:2}.${v:2:2}"
}

extract_task_uri_from_upload_output() {
  local out="$1"
  echo "$out" | sed -n 's/.*"@odata.id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

extract_taskmonitor_uri_from_upload_output() {
  local out="$1"
  echo "$out" | sed -n 's/.*"TaskMonitor"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

task_id_from_task_uri() {
  # /redfish/v1/TaskService/Tasks/31 -> 31
  local uri="$1"
  echo "$uri" | sed -n 's#.*/Tasks/\([0-9]\+\).*#\1#p'
}

dump_task_by_id() {
  local task_id="$1"
  local outdir="${2:-$OUTDIR}"
  [[ -n "$task_id" ]] || return 1

  local url="https://$BMC_IP/redfish/v1/TaskService/Tasks/$task_id"
  log "[INFO] Dump Task: $url"
  live_task_log "DumpTask url=$url"

  curl -k -sS -u "$BMC_USER:$BMC_PASS" "$url" > "${outdir}/task_${task_id}.json" || return 1
  jq . "${outdir}/task_${task_id}.json" > "${outdir}/task_${task_id}.pretty.json" 2>/dev/null || true
  return 0
}

wait_host_ping() {
  log "[INFO] Waiting HOST ping UP: $OS_IP (timeout ${HOST_PING_TIMEOUT}s)"
  local start now
  start=$(date +%s)
  while true; do
    if ping -c 1 -W 1 "$OS_IP" >/dev/null 2>&1; then
      log "[PASS] HOST ping is UP"
      return 0
    fi
    now=$(date +%s)
    (( now - start >= HOST_PING_TIMEOUT )) && fail "HOST ping timeout"
    sleep 2
  done
}

wait_host_ping_down() {
  local ip="$1"
  local timeout="${2:-240}"

  log "[INFO] Waiting HOST ping DOWN: $ip (timeout ${timeout}s)..."
  local start now
  start=$(date +%s)

  while true; do
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      : # still up
    else
      log "[PASS] HOST ping is DOWN: $ip"
      return 0
    fi

    now=$(date +%s)
    (( now - start >= timeout )) && return 1
    sleep 2
  done
}

dc_forceoff_on() {
  # log "[INFO] DC: ForceOff -> On"

  # curl --http1.0 -k -X POST -u $BMC_USER:$BMC_PASS \
  #   -H "Content-Type: application/json" \
  #   https://$BMC_IP/redfish/v1/Systems/System_0/Actions/ComputerSystem.Reset \
  #   -d '{"ResetType":"ForceOff"}' | jq .

  # sleep 10

  # curl --http1.0 -k -X POST -u $BMC_USER:$BMC_PASS \
  #   -H "Content-Type: application/json" \
  #   https://$BMC_IP/redfish/v1/Systems/System_0/Actions/ComputerSystem.Reset \
  #   -d '{"ResetType":"On"}' | jq .

  # ======================== Mike ========================
  log "[INFO] DC: GracefulRestart"

  curl -X POST -sS -k -u admin:adminadmin \
  -H "Content-Type: application/json" \
  https://$BMC_IP/redfish/v1/Systems/System_0/Actions/ComputerSystem.Reset \
  -d '{"ResetType":"GracefulRestart"}' | jq .

  sleep 300
  # ======================================================
}

wait_ssh_password_login() {
  log "[INFO] Waiting SSH password login: ${OS_USER}@${OS_IP} (timeout ${SSH_TIMEOUT}s)"
  export SSHPASS="$OS_PASS"

  local start now
  start=$(date +%s)

  while true; do
    if sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
      "$OS_USER@$OS_IP" \
      'echo LOGIN_OK' 2>/dev/null | grep -q LOGIN_OK; then
      log "[PASS] SSH password login confirmed"
      return 0
    fi
    now=$(date +%s)
    (( now - start >= SSH_TIMEOUT )) && fail "SSH password login timeout"
    sleep 5
  done
}

verify_os_proof() {
  log "[INFO] OS proof (whoami/uname/uptime/systemd)..."
  export SSHPASS="$OS_PASS"
  sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    "$OS_USER@$OS_IP" \
    'whoami; uname -s; uptime -p; systemctl is-system-running || true' \
    | sed 's/^/[OS] /'
  log "[PASS] OS proof collected"
}

get_os_bios_version_raw() {
  export SSHPASS="$OS_PASS"
  sshpass -e ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
    "$OS_USER@$OS_IP" \
    "dmidecode -t 0 | awk -F': ' '/Version:/ {print \$2; exit}'" \
    2>/dev/null || true
}

precheck_bios_version_or_exit() {
  # If current BIOS already equals target -> STOP whole script (per your rule)
  local target_raw="$1"
  local target_norm current_raw current_norm

  log "[INFO] Pre-check BIOS version before update..."
  current_raw="$(get_os_bios_version_raw | tr -d '\r')"

  if [[ -z "$current_raw" ]]; then
    log "[WARN] Cannot read current BIOS version from OS (skip pre-check)"
    live_task_log "Precheck skip (cannot read BIOS version)"
    return 0
  fi

  target_norm="$(normalize_ver "$target_raw")"
  current_norm="$(normalize_ver "$current_raw")"

  log "[INFO] Current BIOS Version = $current_norm (raw=$current_raw)"
  log "[INFO] Target  BIOS Version = $target_norm (raw=$target_raw)"

  if [[ "$current_norm" == "$target_norm" ]]; then
    log "[STOP] BIOS already at target version ($target_norm)"
    log "[STOP] Please confirm version, skip redundant flashing."
    live_task_log "STOP (already at target BIOS $target_norm)"
    exit 0
  fi
}

verify_bios_version_after_update() {
  local target_raw="$1"
  local target_norm current_raw current_norm

  target_norm="$(normalize_ver "$target_raw")"
  current_raw="$(get_os_bios_version_raw | tr -d '\r')"
  current_norm="$(normalize_ver "$current_raw")"

  log "[INFO] Post-check BIOS version..."
  log "[INFO] Expect BIOS Version = $target_norm"
  log "[INFO] Actual BIOS Version = $current_norm (raw=$current_raw)"

  if [[ "$current_norm" == "$target_norm" ]]; then
    log "[PASS] BIOS version match"
    return 0
  fi

  log "[FAIL] BIOS version mismatch (expect=$target_norm actual=$current_norm)"
  return 1
}

wait_os_stable_before_next_cycle() {
  local total="${1:-300}"

  # TTY -> single line dynamic; Non-TTY (pipe/tee) -> clean logs
  if [[ -t 1 ]]; then
    log "[INFO] OS is reachable. Waiting ${total}s before next cycle..."
    local start now elapsed remain
    start=$(date +%s)
    while true; do
      now=$(date +%s)
      elapsed=$(( now - start ))
      remain=$(( total - elapsed ))
      (( remain <= 0 )) && break
      printf "\r[INFO] Next cycle in %3ds..." "$remain"
      sleep 1
    done
    printf "\r[PASS] Wait done. Continue next cycle.           \n"
  else
    log "[INFO] OS is reachable. Waiting ${total}s before next cycle..."
    sleep "$total"
    log "[PASS] Wait done. Continue next cycle."
  fi
}

poll_task() {
  local uri="$1"
  local timeout="${2:-$TASK_TIMEOUT}"
  local interval="${3:-$TASK_INTERVAL}"
  local outdir="${4:-.}"

  [[ -n "$uri" ]] || fail "Empty task uri"
  log "[INFO] Polling: https://$BMC_IP${uri} (timeout ${timeout}s interval ${interval}s)"
  live_task_log "Poll start uri=$uri timeout=${timeout}s interval=${interval}s"

  local start now
  start=$(date +%s)

  local miss=0

  while true; do
    local raw http_code curl_rc
    curl_rc=0

    raw="$(curl -k -sS -u "$BMC_USER:$BMC_PASS" -w $'\nHTTP_CODE:%{http_code}\n' "https://$BMC_IP${uri}" 2>&1)" || curl_rc=$?
    http_code="$(echo "$raw" | sed -n 's/^HTTP_CODE:\([0-9][0-9][0-9]\)$/\1/p' | tail -n1)"
    raw="$(echo "$raw" | sed '/^HTTP_CODE:/d')"

    if [[ "${http_code:-}" == "404" ]]; then
      miss=$((miss+1))
      log "[WARN] Task URI returns 404 (miss ${miss}/${TASK_NA_LIMIT})"
      live_task_log "WARN 404 miss=${miss}/${TASK_NA_LIMIT}"
      [[ -d "$outdir" ]] && printf "%s\n" "$raw" > "${outdir}/task_poll_raw_last.txt" 2>/dev/null || true
      return 2
    fi

    local state status pct
    state="$(echo "$raw" | sed -n 's/.*"TaskState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    status="$(echo "$raw" | sed -n 's/.*"TaskStatus"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    pct="$(echo "$raw" | sed -n 's/.*"PercentComplete"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)"
    [[ -n "$pct" ]] || pct="N/A"

    if [[ -z "$state" && -z "$status" ]]; then
      miss=$((miss+1))
      log "[WARN] Cannot read task yet (miss ${miss}/${TASK_NA_LIMIT}) (curl_rc=$curl_rc http=${http_code:-N/A})"
      live_task_log "WARN N/A miss=${miss}/${TASK_NA_LIMIT} curl_rc=$curl_rc http=${http_code:-N/A}"
      [[ -d "$outdir" ]] && printf "%s\n" "$raw" > "${outdir}/task_poll_raw_last.txt" 2>/dev/null || true

      if (( miss >= TASK_NA_LIMIT )); then
        log "[FAIL] Task poll invalid too many consecutive times."
        live_task_log "FAIL too many N/A parses"
        return 1
      fi

      now=$(date +%s)
      (( now - start >= timeout )) && fail "Task timeout (${timeout}s)"
      sleep "$interval"
      continue
    fi

    miss=0
    local line="[TASK] State=${state:-N/A} Status=${status:-N/A} Progress=${pct}%"
    log "$line"
    live_task_log "$line"

    if [[ "${state:-}" == "Exception" || "${status:-}" == "Critical" ]]; then
      [[ -d "$outdir" ]] && {
        printf "%s\n" "$raw" > "${outdir}/task_failed_raw.txt" 2>/dev/null || true
        echo "$raw" | jq . > "${outdir}/task_failed.json" 2>/dev/null || true
      }
      live_task_log "TASK_FAIL state=${state:-} status=${status:-}"
      return 1
    fi

    if [[ "${state:-}" == "Completed" && "${status:-}" == "OK" ]]; then
      live_task_log "TASK_DONE Completed/OK"
      return 0
    fi

    if [[ "${state:-}" == "Completed" && "${status:-}" != "OK" ]]; then
      [[ -d "$outdir" ]] && {
        printf "%s\n" "$raw" > "${outdir}/task_completed_not_ok_raw.txt" 2>/dev/null || true
        echo "$raw" | jq . > "${outdir}/task_completed_not_ok.json" 2>/dev/null || true
      }
      live_task_log "TASK_DONE Completed but Status!=OK (status=${status:-})"
      return 1
    fi

    now=$(date +%s)
    (( now - start >= timeout )) && fail "Task timeout (${timeout}s)"
    sleep "$interval"
  done
}

poll_with_fallback_and_dump() {
  local upload_out="$1"
  local cycle_dir="$2"

  local task_uri taskmon_uri poll_uri task_id
  task_uri="$(extract_task_uri_from_upload_output "$upload_out")"
  taskmon_uri="$(extract_taskmonitor_uri_from_upload_output "$upload_out")"
  task_id="$(task_id_from_task_uri "$task_uri")"

  # Set live context
  CURRENT_TASK_ID="${task_id:-N/A}"

  # Dump task detail once we know id
  if [[ -n "$task_id" ]]; then
    dump_task_by_id "$task_id" "$cycle_dir" || log "[WARN] dump_task_by_id failed (task_id=$task_id)"
  else
    log "[WARN] Cannot parse task id from @odata.id"
    live_task_log "WARN cannot parse task_id"
  fi

  if [[ -n "$taskmon_uri" ]]; then
    poll_uri="$taskmon_uri"
    log "[INFO] TaskMonitor URI: $taskmon_uri (preferred)"
  elif [[ -n "$task_uri" ]]; then
    poll_uri="$task_uri"
    log "[INFO] Task URI: $task_uri"
  else
    log "[WARN] Cannot find Task URI/TaskMonitor in upload response"
    live_task_log "FAIL cannot find Task URI/TaskMonitor"
    return 1
  fi

  set +e
  poll_task "$poll_uri" "$TASK_TIMEOUT" "$TASK_INTERVAL" "$cycle_dir" | tee -a "${cycle_dir}/task_poll.log"
  local rc=${PIPESTATUS[0]}
  set -e

  if [[ $rc -eq 2 ]]; then
    if [[ "$poll_uri" == "$taskmon_uri" && -n "${task_uri:-}" ]]; then
      log "[INFO] TaskMonitor 404 -> fallback to Task URI: $task_uri"
      live_task_log "Fallback TaskMonitor->TaskURI"
      poll_uri="$task_uri"
    elif [[ "$poll_uri" == "$task_uri" && -n "${taskmon_uri:-}" ]]; then
      log "[INFO] Task URI 404 -> fallback to TaskMonitor URI: $taskmon_uri"
      live_task_log "Fallback TaskURI->TaskMonitor"
      poll_uri="$taskmon_uri"
    fi

    set +e
    poll_task "$poll_uri" "$TASK_TIMEOUT" "$TASK_INTERVAL" "$cycle_dir" | tee -a "${cycle_dir}/task_poll.log"
    rc=${PIPESTATUS[0]}
    set -e
  fi

  # If failed and we know task_id, dump again (Messages may update at end)
  if [[ $rc -ne 0 && -n "${task_id:-}" ]]; then
    dump_task_by_id "$task_id" "$cycle_dir" || true
  fi

  return $rc
}

main() {
  # OUTDIR="result_pingpong_${START_TS}"
  OUTDIR="result_pingpong_${BMC_IP}_${START_TS}"
  mkdir -p "$OUTDIR"

  TASK_LIVE_LOG="${OUTDIR}/task_live.log"
  touch "$TASK_LIVE_LOG"
  echo "[$(ts)] [INFO] task_live.log started" >> "$TASK_LIVE_LOG"

  local SUMMARY
  SUMMARY="${OUTDIR}/summary_${START_TS}.csv"
  echo "cycle,slot,target_raw,target_norm,fw,upload_http,task,dc,host_down,host_up,ssh_login,os_proof,postcheck,wait_5min,result" > "$SUMMARY"

  for ((c=1;c<=REPEAT_COUNT;c++)); do
    local FW_FILE SLOT TARGET_RAW TARGET_NORM
    local postcheck="N/A"
    local wait5="N/A"
    local s_task="PASS" s_dc="PASS" s_down="PASS" s_up="PASS" s_ssh="PASS" s_os="PASS"
    local result="PASS"
    local cycle_dir="${OUTDIR}/cycle_$(printf "%03d" "$c")"
    mkdir -p "$cycle_dir"

    if (( c % 2 == 1 )); then
      FW_FILE="$FW_A"; SLOT="A"
    else
      FW_FILE="$FW_B"; SLOT="B"
    fi

    TARGET_RAW="$(extract_bios_ver_from_fw "$FW_FILE")"
    [[ -n "$TARGET_RAW" ]] || TARGET_RAW="UNKNOWN"
    TARGET_NORM="$(normalize_ver "$TARGET_RAW")"

    # Set live context for this cycle
    CURRENT_CYCLE="$c"
    CURRENT_SLOT="$SLOT"
    CURRENT_TASK_ID="N/A"
    live_task_log "===== Cycle start fw=$FW_FILE target=$TARGET_NORM(raw=$TARGET_RAW) ====="

    log "===== Cycle $c (Slot $SLOT) FW=$FW_FILE ====="
    log "[INFO] Target BIOS Version = $TARGET_NORM (raw=$TARGET_RAW from filename)"

    # Pre-check (per your rule: if equals -> STOP whole script)
    wait_host_ping
    wait_ssh_password_login
    precheck_bios_version_or_exit "$TARGET_RAW"

    # ======================== Mike ========================
    # Get all Task
    TASK_URLS=$(curl -sS -k -u admin:adminadmin https://${BMC_IP}/redfish/v1/TaskService/Tasks | jq -r '.Members[]."@odata.id"')

    # Delete Task
    for task in $TASK_URLS; do
        echo "正在刪除: $task"
        curl -X DELETE -sS -k -u admin:adminadmin "https://${BMC_IP}$task"
    done
    # ======================================================

    # ===== YOUR CORE UPDATE (DO NOT MODIFY) =====
    ETAG=$(curl -k -s -I -u $BMC_USER:$BMC_PASS \
        https://$BMC_IP/redfish/v1/UpdateService | \
        grep -i ETag | awk '{print $2}' | tr -d '\r"') && \
        curl --http1.0 -k -i -X PATCH -u $BMC_USER:$BMC_PASS \
        https://$BMC_IP/redfish/v1/UpdateService \
        -d '{"HttpPushUriOptions": {"ForceUpdate": true}}' \
        --header 'Content-Type: application/json' \
        --header "If-Match: \"$ETAG\""

    UPLOAD_OUT="$(
    curl --http1.0 -k -u $BMC_USER:$BMC_PASS -X POST https://$BMC_IP/redfish/v1/UpdateService/upload  \
        -F 'UpdateParameters={"Targets":[]};type=application/json'  \
        -F 'OemParameters={"ImageType": "PLDM", "Platform": "HGX"};type=application/json'  \
        -F "UpdateFile=@${FW_FILE}" \
        -w "\nHTTP Status: %{http_code}\n"
    )"
    echo "$UPLOAD_OUT" | tee "${cycle_dir}/upload_output.log"
    # ===========================================

    local UPLOAD_HTTP
    UPLOAD_HTTP="$(echo "$UPLOAD_OUT" | sed -n 's/.*HTTP Status:[[:space:]]*\([0-9][0-9][0-9]\).*/\1/p' | tail -n1)"
    [[ -n "$UPLOAD_HTTP" ]] || UPLOAD_HTTP="N/A"
    live_task_log "Upload HTTP=$UPLOAD_HTTP"

    : > "${cycle_dir}/task_poll.log"
    if ! poll_with_fallback_and_dump "$UPLOAD_OUT" "$cycle_dir"; then
      s_task="FAIL"; result="FAIL"
      live_task_log "Task FAIL -> stop script"
    fi

    # DC only AFTER task completed OK
    if [[ "$result" == "PASS" ]]; then
      if ! dc_forceoff_on | tee "${cycle_dir}/dc.log"; then
        s_dc="FAIL"; result="FAIL"
        live_task_log "DC FAIL"
      fi
    fi

    # Expect down after ForceOff
    if [[ "$result" == "PASS" ]]; then
      if ! wait_host_ping_down "$OS_IP" "$HOST_PING_DOWN_TIMEOUT"; then
        s_down="FAIL"; result="FAIL"
        live_task_log "HOST DOWN timeout after DC"
      fi
    fi

    # Host verify (UP + password ssh + proof)
    if [[ "$result" == "PASS" ]]; then
      if ! wait_host_ping; then s_up="FAIL"; result="FAIL"; live_task_log "HOST UP timeout"; fi
    fi
    if [[ "$result" == "PASS" ]]; then
      if ! wait_ssh_password_login; then s_ssh="FAIL"; result="FAIL"; live_task_log "SSH login timeout"; fi
    fi
    if [[ "$result" == "PASS" ]]; then
      if ! verify_os_proof | tee "${cycle_dir}/os_proof.log"; then s_os="FAIL"; result="FAIL"; live_task_log "OS proof FAIL"; fi
    fi

    # Post-check BIOS version
    if [[ "$result" == "PASS" ]]; then
      if verify_bios_version_after_update "$TARGET_RAW" | tee "${cycle_dir}/bios_version_check.log"; then
        postcheck="PASS"
        live_task_log "BIOS post-check PASS"
      else
        postcheck="FAIL"
        result="FAIL"
        live_task_log "BIOS post-check FAIL"
      fi
    fi

    # Wait 5 minutes before next cycle (only when PASS and OS reachable)
    if [[ "$result" == "PASS" ]]; then
      wait5="PASS"
      live_task_log "Wait ${OS_STABLE_WAIT_SEC}s before next cycle"
      wait_os_stable_before_next_cycle "$OS_STABLE_WAIT_SEC" | tee "${cycle_dir}/os_stable_wait.log"
      live_task_log "Wait done"
    fi

    echo "$c,$SLOT,$TARGET_RAW,$TARGET_NORM,$FW_FILE,$UPLOAD_HTTP,$s_task,$s_dc,$s_down,$s_up,$s_ssh,$s_os,$postcheck,$wait5,$result" >> "$SUMMARY"
    log "[RESULT] Cycle $c: $result (TASK=$s_task DC=$s_dc DOWN=$s_down UP=$s_up SSH=$s_ssh OS=$s_os POST=$postcheck WAIT5=$wait5)"
    live_task_log "[RESULT] $result"

    [[ "$result" == "PASS" ]] || fail "Stop at cycle $c. Summary: $SUMMARY"
  done

  log "===== DONE ====="
  log "Summary file: $SUMMARY"
  log "Result dir  : $OUTDIR"
  live_task_log "===== DONE ====="
}

# ==============================
# 主程式 (Main)
# ==============================
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
        --os_ip=*)
            OS_IP="${1#*=}"
            ;;
        --os_user=*)
            OS_USER="${1#*=}"
            ;;
        --os_pass=*)
            OS_PASS="${1#*=}"
            ;;
        --fw_a=*)
            FW_A="${1#*=}"
            ;;
        --fw_b=*)
            FW_B="${1#*=}"
            ;;
        # 顯示幫助
        --help|-h)
            echo "Usage: $0 --fw_a --fw_b [--loop=N] --bmc_ip --bmc_user --bmc_pass --os_ip --os_user --os_pass"
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
if [[ ! -f "$FW_A" ]]; then
    echo "[Error] FW_A 檔案不存在於當前目錄: $FW_A" >&2
    exit 1
fi

if [[ ! -f "$FW_B" ]]; then
    echo "[Error] FW_B 檔案不存在於當前目錄: $FW_B" >&2
    exit 1
fi

if [[ -z "$BMC_IP" ]] || [[ -z "$OS_IP" ]]; then
    echo "[Error] BMC_IP and OS_IP (--os_ip) are required." >&2
    exit 1
fi

main
