#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""
BMC_IP=""
RESULT_FILE="result.txt"
HTML_REPORT="summary_report.html"

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
            
        --bmc_ip=*)
            BMC_IP="${1#*=}"
            ;;

        # --- 幫助與錯誤處理 ---
        --help|-h)
            echo "Usage: $0 --bmc_user=USER  --bmc_pass=PASS --bmc_ip=w.x.y.z"
            exit 0
            ;;
            
        *)
            echo "[Fail] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    
    # 移除目前參數 ($1)，繼續處理下一個
    shift 
done


# 檢查 Server 健康狀態
check_server_health() {    
    # L3 檢查: Ping
    if ! ping -c 1 -W 1 "$BMC_IP" &> /dev/null; then
        echo "[Fail] Network Unreachable (Ping fail) - $BMC_IP" | tee -a "$RESULT_FILE"
        return 1
    fi

    # L7 檢查: 嘗試 Redfish 連線
    # -f: fail silently (回傳非0), -s: silent
    if curl -s -k -f --connect-timeout 2 "https://$BMC_IP/redfish/v1/" &> /dev/null; then
        return 0
    else
        echo "[Fail] BMC Network OK but Service Down (Redfish fail) - $BMC_IP" | tee -a "$RESULT_FILE"
        return 2
    fi
}
check_error() {
    local text="$1"
    local i_id="$2"
    # 檢查 Header 異常
    if echo "$text" | grep -q "Unknown FRU header version"; then
        echo "[Skip] ID $i_id 發現異常: $text 。跳過此裝置。" | tee -a "result.txt"
        return 1
    fi

    # 檢查 Handshake / Session 異常
    if echo "$text" | grep -q "Error: Unable to establish"; then
        echo "[Fail] ID $i_id 發現異常: 網路連線或 Session 建立失敗。跳過此裝置。" | tee -a "result.txt"
        return 1
    fi

    return 0
}

wait_for_server_online() {
    local timeout_sec=300  # 設定最大等待時間(秒)
    local interval=60      # 每幾秒 Ping 一次
    local start_time
    start_time=$(date +%s)
    local current_time
    local elapsed

    echo "等待伺服器 ($BMC_IP) 上線中..."

    while true; do
        # --- 計算經過時間 ---
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        # --- 超時檢查 ---
        if [ $elapsed -ge $timeout_sec ]; then
            echo ""
            echo "[Fail] 等待 [$BMC_IP] 上線超時 ($timeout_sec 秒)！" | tee -a "result.txt"
            return 1
        fi
        
        # --- BMC檢查邏輯 ---
        # 1. 檢查網路層(L3 Ping)
        if ping -c 1 -W 1 "$BMC_IP" &> /dev/null; then
            # 2. 檢查應用層 (L7), -f: 失敗時回傳錯誤碼 (fail silently)
            if curl -s -k -f --connect-timeout 2 "https://$BMC_IP/redfish/v1/" &> /dev/null; then
                echo "BMC 已上線。"
                return 0
            fi
        fi

        sleep $interval
    done
}

__main__() {

    : > "$RESULT_FILE"  # 清空

    echo "正在連接 $BMC_IP 獲取 FRU 列表..."

    # 獲取所有 FRU 資訊
    ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print > fru_all.log 2>&1
    
    id="4"
    echo "開始輸出與寫入 ID:$id"    
    echo "----------------------------------------"

    # 1. 記錄寫入前的狀態
    if ! ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print "$id" > "fru${id}_before.log" 2>&1; then
        echo "[Fail] ID $id fru print輸出失敗 (ID $id)" | tee -a "$RESULT_FILE"
        cat "fru${id}_before.log" | tee -a "$RESULT_FILE"
        return 1
    fi

    # 檢查 Header Handshake
    fru_text=$(cat "fru${id}_before.log")
    check_error "$fru_text" "$id"
    if [ $? -ne 0 ]; then return 1; fi

    # BMC MFG Mode
    ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 raw 0x06 0x05 0x73 0x75 0x70 0x65 0x72 0x75 0x73 0x65 0x72
    # 解鎖OEM cmd, enable fru write
    # ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 raw 0x30 0x17 0x01
    ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 raw 0x30 0x17 1
    
    # 2. 讀取 bin 檔
    read_fru=$(ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru read "$id" "fru${id}.bin" 2>&1)
    
    check_error "$read_fru" "$id"
    if [ $? -ne 0 ]; then
        echo "[Fail] ID $id fru read 失敗。" | tee -a "$RESULT_FILE"
        echo "$read_fru" | tee -a "$RESULT_FILE"
        return 1
    fi
    # 檢查檔案是否存在且大小大於 0
    if [ ! -s "fru${id}.bin" ]; then
        echo "[Fail] ID $id 找不到 fru${id}.bin 或檔案為空，跳過寫入。"  | tee -a "$RESULT_FILE"
        return 1
    fi

    sleep 2

    # 3. 寫入 bin 檔
    write_fru=$(ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru write "$id" "fru${id}.bin" 2>&1)
    check_error "$write_fru" "$id"

    if echo "$write_fru" | grep -q "Error"; then
        echo "[Fail] ID $id fru write 失敗。" | tee -a "$RESULT_FILE"
        echo "$write_fru" | tee -a "$RESULT_FILE"
        return 1
    fi
        
    # 寫入後等待 BMC 刷新緩存
    sleep 5 

    echo "執行 BMC reset 並等待 180 秒..."
    ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 mc reset cold
    sleep 180

    wait_for_server_online
    if [ $? -ne 0 ]; then
        echo "[Fail] BMC 重啟後無法連線，停止後續驗證。" | tee -a "$RESULT_FILE"
        return 1
    fi

    # 4. 記錄寫入後的狀態
    if ! ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print "$id" > "fru${id}_after.log" 2>&1; then
        echo "[Fail] ID $id fru print輸出失敗 (ID $id)" | tee -a "$RESULT_FILE"
        cat "fru${id}_after.log" | tee -a "$RESULT_FILE"
        return 1
    fi

    # 檢查 Header Handshake
    fru_text=$(cat "fru${id}_after.log")
    check_error "$fru_text" "$id"
    if [ $? -ne 0 ]; then return 1; fi

    # 5. 比對差異
    if diff -q "fru${id}_before.log" "fru${id}_after.log" > /dev/null; then
        echo "[Pass] FRU Check OK (ID $id)" | tee -a "result.txt"
    else
        echo "[Fail] FRU Mismatch (ID $id)" | tee -a "result.txt"
        # 將詳細差異附加到結果檔
        echo "--- Diff for ID $id ---" >> "result.txt"
        diff -u "fru${id}_before.log" "fru${id}_after.log" >> "result.txt"
    fi

}

# 檢查BMC連線
if ! check_server_health "$BMC_IP"; then
    exit 1
fi
# --- 執行 ---
__main__


# --- 產生 HTML 報告 ---
echo "正在產生 HTML 報告..."

# 寫入 HTML 檔頭與 CSS 樣式
cat <<EOF > "$HTML_REPORT"
<!DOCTYPE html>
<html>
<head>
<style>
    body {
        font-family: Consolas, "Courier New", monospace;
        padding: 20px;
        background-color: #f4f4f9;
    }
    h2 { color: #333; border-bottom: 2px solid #666; padding-bottom: 10px; }
    .log-box {
        background: #fff;
        padding: 15px;
        border: 1px solid #ddd;
        border-radius: 4px;
        box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        white-space: pre-wrap;
        font-size: 14px;
        color: #333;
    }
    .pass { color: #009879; font-weight: bold; }
    .fail { color: #d63031; font-weight: bold; }
    .skip { color: #e17055; font-weight: bold; }
</style>
</head>
<body>
<h2>FRU Info Import</h2>
<p>BMC IP:$BMC_IP, Generated time: $(date '+%Y-%m-%d %H:%M:%S')</p>
<div class="log-box">
EOF

# 2. 處理內容並寫入
if [ -f "$RESULT_FILE" ]; then
    sed -e 's/$/<br>/' \
        -e 's/\[Pass\]/<span class="pass">[Pass]<\/span>/g' \
        -e 's/\[Fail\]/<span class="fail">[Fail]<\/span>/g' \
        -e 's/\[Skip\]/<span class="skip">[Skip]<\/span>/g' \
        "$RESULT_FILE" >> "$HTML_REPORT"
else
    echo "No result file found." >> "$HTML_REPORT"
fi

# 寫入 HTML 結尾
cat <<EOF >> "$HTML_REPORT"
</div>
</body>
</html>
EOF

echo "[Success] HTML 報告已產生: $HTML_REPORT"
