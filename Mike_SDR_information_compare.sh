#!/bin/bash

# --- 設定區 ---
BMC_USER=""
BMC_PASS=""     # 要設定的新密碼
BMC_IP=""

SDR_SPEC_FILE="sdr_spec.csv"
SDR_REDFISH_LOG="sdr_redfish.log"
SDR_IPMITOOL_LOG="sdr_ipmitool.log"
: > "$SDR_REDFISH_LOG"
: > "$SDR_IPMITOOL_LOG"

# 檢查參數
if [ -z "$BMC_IP" ]; then
    echo "用法: $0 <BMC_IP>"
    exit 1
fi

if [ ! -f "$SDR_SPEC_FILE" ]; then
    echo "錯誤: 找不到 $SDR_SPEC_FILE，請先執行 Mike_parse_sdr_spec.py 產生該檔案。"
    exit 1
fi
# 強制移除 Windows 換行符號 (\r)，避免讀取失敗
sed -i 's/\r//g' "$SDR_SPEC_FILE"

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

# 檢查 Server 健康狀態
check_server_health() {
    local ip=$1
    
    # L3 檢查: Ping
    if ! ping -c 1 -W 1 "$BMC_IP" &> /dev/null; then
        echo "[Fail] Network Unreachable (Ping fail) - $BMC_IP"
        return 1
    fi

    # L7 檢查: 嘗試 Redfish 連線
    # -f: fail silently (回傳非0), -s: silent
    if curl -s -k -f --connect-timeout 2 "https://$BMC_IP/redfish/v1/" &> /dev/null; then
        return 0
    else
        echo "[Fail] BMC Network OK but Service Down (Redfish fail) - $BMC_IP"
        return 2
    fi
}


compare_number() {
    local expected="$1"
    local actual="$2"
    if [[ $expected =~ ^-?[0-9]+(\.[0-9]+)?$ && $actual =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        expected=$(echo "$expected" | awk '{print $1 + 0}')
        actual=$(echo "$actual" | awk '{print $1 + 0}')
        if [ "$expected" == "$actual" ]; then
            return 0
        else
            return 1
        fi
    fi
    if [[ ! $expected =~ ^-?[0-9]+(\.[0-9]+)?$ && $actual =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then return 1; fi
    if [[ $expected =~ ^-?[0-9]+(\.[0-9]+)?$ && ! $actual =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then return 1; fi
    return 0
}

compare_string() {
    local expected="$1"
    local actual="$2"
    if [[ "$actual" == "Cel" || "$actual" == "degrees C" ]]; then
        actual="Degree C"
    elif [[ "$actual" == "V" ]]; then
        actual="Volts"
    fi
    if [[ "${expected,,}" == "${actual,,}" ]] ; then return 0; fi
    if [[ "$expected" == "" && "${actual,,}" == "0h" ]]; then
        return 0
    elif [[ "$expected" == "" && "${actual^^}" == "N/A" ]]; then
        return 0
    fi
    if [[ "${expected,,}" == *"${actual,,}"* ]]; then return 0; fi
    if [[ "${expected^^}" == "N/A" ]]; then  return 0; fi

    return 1
}

# 1. 檢查BMC連線
if ! check_server_health "$BMC_IP"; then
    exit 1
fi

head_orig="Sensor_Name,Sensor_Number,LNR,LC,LNC,UNC,UC,UNR,Code,Type,Unit"
head_redfish="red_Name,red_Status,red_LNR,red_LC,red_LNC,red_UNC,red_UC,red_UNR,red_Type,red_Unit"
head_ipmi="ipmi_Status,ipmi_LNR,ipmi_LC,ipmi_LNC,ipmi_UNC,ipmi_UC,ipmi_UNR,ipmi_Code,ipmi_Type,ipmi_Unit"

echo "$head_orig","$head_ipmi",Redfish_URL,"$head_redfish" > SDR_comparison_result.txt

# 2. 查詢SDR規格
while IFS=, read -r Sensor_Name Sensor_Number Project_Selected LNR LC LNC UNC UC UNR Sensor_Type_Code Sensor_Unit_Type Redfish; do
    
    # 跳過空行
    [[ -z "$Sensor_Name" ]] && continue
    [[ "$Sensor_Name" == "Sensor_Name" ]] && continue

    echo "正在檢查: $Sensor_Name ..."

    unset redfish_data ipmi_data red_Status ipmi_Status

    if [[ "$Sensor_Type_Code" == "N/A" ]]; then
        Code="N/A"
        Type="N/A"
    else
        Code=$(echo "$Sensor_Type_Code" | awk '{print $1}')
        Type=$(echo "$Sensor_Type_Code" | awk -F '(' '{print $2}' | sed 's/)//g')
    fi

    if [[ "$Sensor_Unit_Type" == "N/A" ]]; then
        Unit="N/A"
    else
        Unit=$(echo "$Sensor_Unit_Type" | sed "s/.*(//; s/.*\///; s/)//g; s/^[ \t]*//")
    fi

    orig_data="$Sensor_Name,$Sensor_Number,$LNR,$LC,$LNC,$UNC,$UC,$UNR,$Code,$Type,$Unit"
    
    # Redfish 查詢
    if [[ "$Redfish" != /* ]]; then Redfish="/$Redfish"; fi

    redfish_sdr=$(curl -s -k -f -u "$BMC_USER:$BMC_PASS" "https://$BMC_IP$Redfish" 2>/dev/null)
    {
        echo "curl -s -k -f -u "$BMC_USER:$BMC_PASS" https://$BMC_IP$Redfish 2>/dev/null"
        echo "$redfish_sdr"
        echo ""
    } >> $SDR_REDFISH_LOG

    if [ -z "$redfish_sdr" ] || ! echo "$redfish_sdr" | jq -e . >/dev/null 2>&1; then
        red_Name="Not Found"
        red_Status="Fail"
        redfish_data="$red_Name,$red_Status,-,-,-,-,-,-,-,-"
    else
        red_Status="Pass"
        red_Name=$(echo "$redfish_sdr" | jq -r '.Name // "N/A"')
        if [[ "$Sensor_Name" != "$red_Name" ]]; then red_Name="mismatch:$red_Name"; red_Status="Fail"; fi

        red_LNR=$(echo "$redfish_sdr" | jq -r '.Thresholds.LowerFatal.Reading // "N/A"')
        if ! compare_number "$LNR" "$red_LNR"; then red_LNR="mismatch:$red_LNR"; red_Status="Fail"; fi

        red_LC=$(echo "$redfish_sdr" | jq -r '.Thresholds.LowerCritical.Reading // "N/A"')
        if ! compare_number "$LC" "$red_LC"; then red_LC="mismatch:$red_LC"; red_Status="Fail"; fi

        red_LNC=$(echo "$redfish_sdr" | jq -r '.Thresholds.LowerCaution.Reading // "N/A"')
        if ! compare_number "$LNC" "$red_LNC"; then red_LNC="mismatch:$red_LNC"; red_Status="Fail"; fi

        red_UNC=$(echo "$redfish_sdr" | jq -r '.Thresholds.UpperCaution.Reading // "N/A"')
        if ! compare_number "$UNC" "$red_UNC"; then red_UNC="mismatch:$red_UNC"; red_Status="Fail"; fi

        red_UC=$(echo "$redfish_sdr" | jq -r '.Thresholds.UpperCritical.Reading // "N/A"')
        if ! compare_number "$UC" "$red_UC"; then red_UC="mismatch:$red_UC"; red_Status="Fail"; fi

        red_UNR=$(echo "$redfish_sdr" | jq -r '.Thresholds.UpperFatal.Reading // "N/A"')
        if ! compare_number "$UNR" "$red_UNR"; then red_UNR="mismatch:$red_UNR"; red_Status="Fail"; fi

        red_Type=$(echo "$redfish_sdr" | jq -r '.PhysicalContext // "N/A"')
        if ! compare_string "$Type" "$red_Type"; then
            red_Type=$(echo "$redfish_sdr" | jq -r '.ReadingType // "N/A"')
            if ! compare_string "$Type" "$red_Type"; then red_Type="mismatch:$red_Type"; red_Status="Fail"; fi
        fi

        red_Unit=$(echo "$redfish_sdr" | jq -r '.ReadingUnits // "N/A"')
        if ! compare_string "$Unit" "$red_Unit"; then red_Unit="mismatch:$red_Unit"; red_Status="Fail"; fi

        redfish_data="$red_Name,$red_Status,$red_LNR,$red_LC,$red_LNC,$red_UNC,$red_UC,$red_UNR,$red_Type,$red_Unit"
    fi

    # IPMI 查詢
    ipmi_sdr=$(ipmitool -H "$BMC_IP" -U "$BMC_USER" -P "$BMC_PASS" -I lanplus -C 17 sdr get "$Sensor_Name")
    
    {
        echo "ipmitool -H $BMC_IP -U $BMC_USER -P $BMC_PASS -I lanplus -C 17 sdr get $Sensor_Name"
        echo "$ipmi_sdr"
        echo ""
    } >> $SDR_IPMITOOL_LOG

    if [ $? -ne 0 ]; then
        ipmi_Status="Fail:Not Found"
        ipmi_data="$ipmi_Status,-,-,-,-,-,-,-,-,-"
    else
        ipmi_Status="Pass"
        ipmi_number=$(echo "$ipmi_sdr" | grep -iE "Sensor ID" | awk '{print $NF}' | sed 's/(//' | sed 's/)//')
        if ! compare_number "$Sensor_Number" "$ipmi_number"; then ipmi_number="mismatch:$ipmi_number"; ipmi_Status="Fail"; fi

        ipmi_LNR=$(echo "$ipmi_sdr" | grep -iE "Lower non-recoverable" | awk '{print $NF}')
        if ! compare_number "$LNR" "$ipmi_LNR"; then ipmi_LNR="mismatch:$ipmi_LNR"; ipmi_Status="Fail"; fi

        ipmi_LC=$(echo "$ipmi_sdr" | grep -iE "Lower critical" | awk '{print $NF}')
        if ! compare_number "$LC" "$ipmi_LC"; then ipmi_LC="mismatch:$ipmi_LC"; ipmi_Status="Fail"; fi
        
        ipmi_LNC=$(echo "$ipmi_sdr" | grep -iE "Lower non-critical" | awk '{print $NF}')
        if ! compare_number "$LNC" "$ipmi_LNC"; then ipmi_LNC="mismatch:$ipmi_LNC"; ipmi_Status="Fail"; fi

        ipmi_UNC=$(echo "$ipmi_sdr" | grep -iE "Upper non-critical" | awk '{print $NF}')
        if ! compare_number "$UNC" "$ipmi_UNC"; then ipmi_UNC="mismatch:$ipmi_UNC"; ipmi_Status="Fail"; fi

        ipmi_UC=$(echo "$ipmi_sdr" | grep -iE "Upper critical" | awk '{print $NF}')
        if ! compare_number "$UC" "$ipmi_UC"; then ipmi_UC="mismatch:$ipmi_UC"; ipmi_Status="Fail"; fi

        ipmi_UNR=$(echo "$ipmi_sdr" | grep -iE "Upper non-recoverable" | awk '{print $NF}')
        if ! compare_number "$UNR" "$ipmi_UNR"; then ipmi_UNR="mismatch:$ipmi_UNR"; ipmi_Status="Fail"; fi
        
        ipmi_Code=$(echo "$ipmi_sdr" | grep -iE "Sensor Type" | awk -F ':' '{print $2}' | awk -F '(' '{print $2}' | sed 's/)//g')
        if [[ "$Code" != "$ipmi_Code" ]]; then ipmi_Code="mismatch:$ipmi_Code"; ipmi_Status="Fail"; fi

        ipmi_Type=$(echo "$ipmi_sdr" | grep -iE "Sensor Type" | awk -F ':' '{print $2}' | awk '{print $1}')
        if ! compare_string "$Type" "$ipmi_Type"; then ipmi_Type="mismatch:$ipmi_Type"; ipmi_Status="Fail"; fi
        
        ipmi_Unit=$(echo "$ipmi_sdr" | grep -iE "Sensor Reading" | sed -E 's/.*:[[:space:]]*//; s/.*\)[[:space:]]*//')
        if ! compare_string "$Unit" "$ipmi_Unit"; then ipmi_Unit="mismatch:$ipmi_Unit"; ipmi_Status="Fail"; fi
        
        ipmi_data="$ipmi_Status,$ipmi_LNR,$ipmi_LC,$ipmi_LNC,$ipmi_UNC,$ipmi_UC,$ipmi_UNR,$ipmi_Code,$ipmi_Type,$ipmi_Unit"

    fi

    echo "$orig_data,$ipmi_data,$Redfish,$redfish_data" >> SDR_comparison_result.txt

done < "$SDR_SPEC_FILE"


# 3. 產生 HTML 報告 (Convert to HTML)
html_report="summary_report.html"
comparison_result="SDR_comparison_result.txt"

# 寫入 HTML 檔頭與 CSS 樣式
cat <<EOF > "$html_report"
<!DOCTYPE html>
<html>
<head>
<style>
    :root {
        --primary-color: #009879;
        --row-even: #f3f3f3;
        --row-even-sticky: #e8e8e8; /* 偶數列第一欄顏色 */
        --row-hover: #e0fcf0;
        --sticky-bg: #f1f1f1;       /* 奇數列第一欄顏色 */
        --lighter-red: #ff8080;
        --lighter-blue: #4d94ff;
    }
    .table-container {max-height: 85vh;overflow: auto;border: 1px solid #ccc;max-width: 100%;}
    table {border-collapse: collapse;width: auto;min-width: 600px;box-shadow: 0 0 20px rgba(0,0,0,0.1);}
    th, td {border: 1px solid #dddddd;text-align: left;padding: 8px;}
    th {position: sticky;top: 0;background-color: var(--primary-color);color: white;z-index: 2;}       /* 標題固定 (Top) */
    td:first-child {position: sticky; left: 0;z-index: 1;background-color: var(--sticky-bg);}            /* 第一欄固定 (Left) */
    th:first-child {position: sticky;left: 0;top: 0;z-index: 3;background-color: var(--primary-color);}  /* 左上角交集格 */
    tr:nth-child(even) {background-color: var(--row-even);}                        /* 偶數列背景 */
    tr:nth-child(even) td:first-child {background-color: var(--row-even-sticky);}  /* 偶數列的第一欄背景覆蓋 */
    tr:hover td {background-color: var(--row-hover) !important;}                   /* Hover 懸停效果 */
    .error { color: red; font-weight: bold; }
    .pass { color: green; font-weight: bold; }
    body { font-family: Arial, sans-serif; margin: 20px; }
    h2 { color: #333; }
    .redfish { background-color: var(--lighter-red);}
    .ipmitool { background-color: var(--lighter-blue);}
</style>
</head>
<body>
<h2>SDR Check Report</h2>
<p>BMC IP:$BMC_IP, Generated time: $(date '+%Y-%m-%d %H:%M:%S')</p>
<table>
EOF


# 使用 awk 解析 txt 並轉換為 HTML 表格列
# -F ','  : 指定分隔符號為 ,
# !/^-/   : 忽略純分隔線 (例如 -------)
# gsub    : 去除前後空白
awk -F ',' '
    {
        print "<tr>"

        # 處理原始資料欄位
        for(i=1; i<=NF; i++) {
            # 去除欄位前後空白
            gsub(/^ +| +$/, "", $i)
            
            # 第一行使用 <th> (標題)，其他行使用 <td> (內容)
            tag = (NR==1) ? "th" : "td"
            
            # 設定樣式 class
            if ( NR==1 && $i ~ /red_|Redfish_/ ) {
                class = "class=\"redfish\""
            } else if ( NR==1 && $i ~ /ipmi_/ ) {
                class = "class=\"ipmitool\""
            # 再判斷內容是否有錯誤訊息
            } else if ( $i ~ /Fail/ || $i ~ /mismatch/ || $i ~ /Not Found/ ) {
                class = "class=\"error\""
            } else if ( $i == "Pass" ) {
                class = "class=\"pass\""
            } else {
                class = ""
            }
            
            printf "<%s %s>%s</%s>\n", tag, class, $i, tag
        }
        
        row_idx++
        # 處理第一欄：行號/標題
        tag = (NR==1) ? "th" : "td"
        # 如果是第一行則顯示 "No."，否則顯示行號數值
        cell_value = (NR==1) ? "No." : (row_idx - 1)
        printf "<%s>%s</%s>\n", tag, cell_value, tag

        print "</tr>"
    }
' "$comparison_result" >> "$html_report"

# 寫入 HTML 結尾
cat <<EOF >> "$html_report"
</table>
</body>
</html>
EOF

echo "[Success] HTML 報告已產生: $html_report"
