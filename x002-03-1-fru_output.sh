#!/bin/bash

# ==============================================================================
# 功    能: 產生個別的 FRU log (fru_0.log, fru_1.log...)
# ==============================================================================

# 設置腳本在遇到錯誤時立即退出 (set -e)
# 注意：在迴圈中測試 FRU ID 時，我們會用 if 條件句來避免因找不到 ID 而導致腳本中斷
set -e
set -o pipefail

# ------------------------------------------------------
# 變數設定
# ------------------------------------------------------
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
echo "腳本所在的絕對路徑是: $SCRIPT_DIR"

BMC_IP=$1
USER="admin"
PASSWD="adminadmin"
LOG_DIR="$SCRIPT_DIR/fru_log"
# 設定要掃描的 FRU ID 範圍 (例如 0~50)
MAX_FRU_SCAN=50

# 建立資料夾
mkdir -p "$LOG_DIR"

# 核心簡化：根據是否有輸入參數，決定基礎指令 (IPMI_CMD)
if [ -n "$1" ]; then
    BMC_IP=$1
    echo "Mode: Remote (IP: $BMC_IP)"
    IPMI_CMD="ipmitool -H $BMC_IP -U admin -P adminadmin -I lanplus"
else
    echo "Mode: Local (In-Band)"
    IPMI_CMD="ipmitool"
fi

echo "正在掃描並輸出 FRU IDs (0-"$MAX_FRU_SCAN") 至 $LOG_DIR ..."

# ------------------------------------------------------
# 主程式：迴圈掃描 FRU ID
# ------------------------------------------------------
for (( id=0; id<=MAX_FRU_SCAN; id++ )); do

    if [ -n "$1" ]; then
        FRU_NAME="OOB_fru_${id}.log"
    else
        FRU_NAME="INB_fru_${id}.log"
    fi
    OUTPUT_FILE="${LOG_DIR}/${FRU_NAME}"
    
    # 2>/dev/null: 將錯誤訊息隱藏，避免畫面上出現一堆 "Device not present"
    # 使用 if 判斷，這樣即使 ipmitool 返回錯誤代碼，也不會觸發 set -e 導致腳本結束
    if $IPMI_CMD fru print "$id" > "$OUTPUT_FILE" 2>&1; then
        
        # 驗證檔案：1. 檔案大小 > 0 且 2. 不包含錯誤關鍵字
        if [ -s "$OUTPUT_FILE" ] && ! grep -qE "Device not present|Invalid|Error" "$OUTPUT_FILE"; then
            echo "[V] Saved: ${FRU_NAME}"
        else
            rm -f "$OUTPUT_FILE"
        fi
    else
        # 指令回傳失敗 (Exit Code != 0) 則刪除空檔
        rm -f "$OUTPUT_FILE"
    fi
done

echo "------------------------------------------------------"
echo "作業完成。所有存在的 FRU Log 已儲存於 $LOG_DIR"
