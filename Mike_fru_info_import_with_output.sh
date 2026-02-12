#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""
BMC_IP=""

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
            echo "[Error] Unknown parameter: $1"
            echo "Try '$0 --help' for more information."
            exit 1
            ;;
    esac
    
    # 移除目前參數 ($1)，繼續處理下一個
    shift 
done

__main__() {

    local ip="$1"
    : > result.txt  # 清空或建立結果檔

    echo "正在連接 $ip 獲取 FRU 列表..."
    # 獲取所有 FRU 資訊 (建議這裡也加上 2>&1 以便 Debug)
    ipmitool -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print > fru_all.log 2>&1
    
    # 提取 ID (使用 grep -P 正則)
    fru_ids=$(grep -oP 'ID \K[0-9]+' fru_all.log)
    
    # 檢查是否獲取到 ID
    if [ -z "$fru_ids" ]; then
        echo "[Error] 未找到任何 FRU ID，請檢查連線或密碼。"
        return 1
    fi

    echo "檢測到的 ID: $fru_ids"
    echo "----------------------------------------"

    for id in $fru_ids; do
        echo "正在處理 FRU ID: $id ..."

        # 1. 記錄寫入前的狀態 (包含 stderr)
        ipmitool -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print "$id" > "fru${id}_before.log" 2>&1

        # 檢查 Header 異常
        if grep -q "Unknown FRU header version 0x00" "fru${id}_before.log"; then
            echo "[Skip] 發現異常: Unknown FRU header version 0x00 (ID $id)。跳過此裝置。" | tee -a "result.txt"
            echo "----------------------------------------"
            continue
        fi

        # 2. 讀取 bin 檔
        ipmitool -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru read "$id" "fru${id}.bin"

        # 檢查檔案是否存在且不為空
        if [ ! -s "fru${id}.bin" ]; then
            echo "[Error] 讀取 FRU $id 失敗或文件為空，跳過寫入。"  | tee -a "result.txt"
            echo "----------------------------------------"
            continue
        fi

        sleep 2

        # 3. 寫入 bin 檔
        echo "正在寫入 FRU $id..."
        if ! ipmitool -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru write "$id" "fru${id}.bin"; then
            echo "[Fail] ipmitool 執行異常 (ID $id)，可能是 Segmentation fault 或連線中斷" | tee -a "result.txt"
            echo "----------------------------------------"
            continue
        fi
        
        # 寫入後等待 BMC 刷新緩存
        sleep 5 

        # 4. 記錄寫入後的狀態
        if ! ipmitool -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print "$id" > "fru${id}_after.log" 2>&1; then
            echo "[Fail] 寫入後讀取失敗 (ID $id)" | tee -a "result.txt"
            echo "----------------------------------------"
            continue
        fi

        # 5. 比對差異
        if diff -q "fru${id}_before.log" "fru${id}_after.log" > /dev/null; then
            echo "[Pass] FRU Check OK (ID $id)" | tee -a "result.txt"
        else
            echo "[Fail] FRU Mismatch (ID $id)" | tee -a "result.txt"
            # 將詳細差異附加到結果檔
            echo "--- Diff for ID $id ---" >> "result.txt"
            diff -u "fru${id}_before.log" "fru${id}_after.log" >> "result.txt"
        fi
        echo "----------------------------------------"
    done
}

# --- 執行 ---
__main__ "$BMC_IP"
