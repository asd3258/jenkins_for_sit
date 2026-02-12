#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""
BMC_IP=""

# --- 參數解析迴圈 ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --bmc_user=*) BMC_USER="${1#*=}" ;;
        --bmc_pass=*) BMC_PASS="${1#*=}" ;;
        --bmc_ip=*)   BMC_IP="${1#*=}"   ;;
        --help|-h)
            echo "Usage: $0 --bmc_user=USER --bmc_pass=PASS --bmc_ip=IP"
            exit 0
            ;;
        *)
            echo "[Error] Unknown parameter: $1"
            exit 1
            ;;
    esac
    shift 
done

# --- 核心功能區 ---

# 函式：安裝並編譯最新版 ipmitool (解決 Segfault 的唯一真理)
install_new_ipmitool() {
    if [ -f "/usr/local/bin/ipmitool" ]; then
        # 簡單檢查版本 (如果已經是手動編譯的就不重做)
        if /usr/local/bin/ipmitool -V | grep -q "version 1.8.19"; then
            return 0
        fi
    fi

    echo ">>> 檢測到 ipmitool 可能過舊，正在下載並編譯最新版 (約需 1 分鐘)..."
    
    # 1. 安裝編譯依賴 (安靜模式)
    apt-get update -qq >/dev/null
    apt-get install -y -qq git build-essential autoconf automake libtool libssl-dev >/dev/null

    # 2. 下載與編譯
    cd /tmp
    rm -rf ipmitool_src
    git clone --depth 1 https://github.com/ipmitool/ipmitool.git ipmitool_src >/dev/null 2>&1
    cd ipmitool_src
    
    ./bootstrap >/dev/null 2>&1
    ./configure --prefix=/usr/local >/dev/null 2>&1
    make -j$(nproc) >/dev/null 2>&1
    make install >/dev/null 2>&1
    
    echo ">>> ipmitool 更新完成！版本："
    /usr/local/bin/ipmitool -V
    cd - >/dev/null
}

__main__() {
    # 檢查必要參數
    if [ -z "$BMC_IP" ] || [ -z "$BMC_USER" ] || [ -z "$BMC_PASS" ]; then
        echo "[Error] 缺少必要參數。請使用 --help 查看用法。"
        return 1
    fi

    # 確保使用我們編譯的 ipmitool (如果有的話)
    IPMITOOL_CMD="ipmitool"
    if [ -x "/usr/local/bin/ipmitool" ]; then
        IPMITOOL_CMD="/usr/local/bin/ipmitool"
    fi

    local ip="$BMC_IP"
    : > result.txt

    echo "正在連接 $ip 獲取 FRU 列表..."
    $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print > fru_all.log 2>&1
    
    fru_ids=$(grep -oP 'ID \K[0-9]+' fru_all.log)
    
    if [ -z "$fru_ids" ]; then
        echo "[Error] 未找到 FRU ID，嘗試切換加密演算法重試..."
        # 備援：不加 -C 17 再試一次
        $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus fru print > fru_all.log 2>&1
        fru_ids=$(grep -oP 'ID \K[0-9]+' fru_all.log)
        if [ -z "$fru_ids" ]; then
            echo "[Error] 仍無法連線，請檢查網路或帳密。"
            cat fru_all.log
            return 1
        fi
    fi

    echo "檢測到的 ID: $fru_ids"
    echo "----------------------------------------"

    for id in $fru_ids; do
        echo "正在處理 FRU ID: $id ..."

        # 讀取
        $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru read "$id" "fru${id}.bin" >/dev/null 2>&1
        
        if [ ! -s "fru${id}.bin" ]; then
            echo "[Error] 讀取 FRU $id 失敗或文件為空。" | tee -a "result.txt"
            continue
        fi

        # 嘗試寫入
        echo "正在寫入 FRU $id (Size: $(stat -c%s "fru${id}.bin") bytes)..."
        
        # 第一次嘗試寫入
        if ! $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru write "$id" "fru${id}.bin"; then
            
            # 捕捉錯誤代碼 $?
            err_code=$?
            echo "[Warning] 寫入失敗 (Code: $err_code)。"

            # 如果是 Segfault (139) 或其他錯誤，執行自動修復 (編譯新版)
            if [ "$err_code" -eq 139 ] || [ "$err_code" -eq 1 ]; then
                echo ">>> 偵測到 ipmitool 異常 (Segfault/Fail)，嘗試自動升級修復..."
                install_new_ipmitool
                IPMITOOL_CMD="/usr/local/bin/ipmitool" # 切換到新版指令
                
                echo ">>> 使用新版 ipmitool 重試寫入..."
                sleep 2
                if ! $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru write "$id" "fru${id}.bin"; then
                     echo "[Fail] 重試後仍然失敗 (ID $id)。" | tee -a "result.txt"
                     continue
                fi
            else
                echo "[Fail] 寫入失敗 (ID $id)。" | tee -a "result.txt"
                continue
            fi
        fi
        
        echo "[Success] 寫入成功 (ID $id)。"
        sleep 5 

        # 驗證
        $IPMITOOL_CMD -H "$ip" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 fru print "$id" > "fru${id}_after.log" 2>&1
        
        # 比對略... (您原有的邏輯)
        echo "----------------------------------------"
    done
}

# --- 執行 ---
__main__
