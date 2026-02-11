import os
import sys
import pandas as pd

def main():
    if len(sys.argv) < 2:
        print("用法: python script.py <input_file.xlsx>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = "sdr_spec.csv"
    
    # 檢查輸入檔是否存在
    if not os.path.exists(input_file):
        print(f"[Error] 找不到輸入檔案: {input_file}")
        sys.exit(1)
   
    xls = pd.ExcelFile(input_file)
    target_sheet_name = None

    for sheet in xls.sheet_names:
        try:
            check_df = pd.read_excel(xls, sheet_name=sheet, header=None, nrows=1, usecols="A")
            if not check_df.empty:
                a1_value = str(check_df.iloc[0,0]).strip().lower()
                if "sensor" in a1_value and "name" in a1_value:
                    target_sheet_name = sheet
                    break
        except Exception as e:
            print(f"讀取 Sheet '{sheet}' 時發生錯誤: {e}")
            continue

    if target_sheet_name is None:
        print("Excel檔案內沒有任何 Sheet 的 A1 儲存格有 'Sensor Name' 字串")
        sys.exit(1)
    
    df = pd.read_excel(xls, sheet_name=target_sheet_name)

    if not df.empty:
        
        new_columns = list(df.columns)
        drop_columns = []
        if 'Project Selected' in df.columns:
            #filtered_data = df[df['Project Selected'].isin(['Y', 'N', ''])].copy()
            filtered_data = df[df['Project Selected'].fillna('').astype(str).str.strip().isin(['Y', 'N', ''])].copy()
        else:
            print("警告: 找不到 'Project Selected' 欄位，跳過篩選步驟。")
            filtered_data = df.copy()

        for i in range(len(filtered_data.columns)):
            row1_value = str(filtered_data.columns[i]).strip().lower()
            row2_value = str(filtered_data.iloc[0, i]).strip().lower()
            
            if "sensor" in row1_value and "name" in row1_value:
                new_columns[i] = "Sensor_Name"
            elif "sensor" in row1_value and "number" in row1_value:
                new_columns[i] = "Sensor_Number"
            elif "project" in row1_value and "selected" in row1_value:
                new_columns[i] = "Project_Selected"
            elif "lnr" == row1_value or "lnr" == row2_value:
                new_columns[i] = "LNR"
            elif "lc" == row1_value or "lc" == row2_value:
                new_columns[i] = "LC"
            elif "lnc" == row1_value or "lnc" == row2_value:
                new_columns[i] = "LNC"
            elif "unc" == row1_value or "unc" == row2_value:
                new_columns[i] = "UNC"
            elif "uc" == row1_value or "uc" == row2_value:
                new_columns[i] = "UC"
            elif "unr" == row1_value or "unr" == row2_value:
                new_columns[i] = "UNR"
            elif "sensor" in row1_value and "type" in row1_value and "code" in row1_value:
                new_columns[i] = "Sensor_Type_Code"
            elif "sensor" in row1_value and "unit" in row1_value and "type" in row1_value:
                new_columns[i] = "Sensor_Unit_Type"
            elif "redfish" == row1_value:
                new_columns[i] = "Redfish"
            else:
                drop_columns.append(filtered_data.columns[i])

        filtered_data.columns = new_columns
        filtered_data = filtered_data.drop(columns=drop_columns, errors='ignore')

        if 'Project_Selected' in filtered_data.columns:
            filtered_data = filtered_data[filtered_data['Project_Selected'] == 'Y'].copy()

        # ---------------------------------------------------------
        # 清洗資料邏輯
        # 1. 轉字串 -> 切割行 -> 取前兩行 -> 合併
        # 2. 依據逗號 ',' 切割，只取第0個元素
        # ---------------------------------------------------------
        def clean_cell_content(val):
            if pd.isna(val):
                return ""
            # 1. 轉字串並切割行 (支援 \r\n, \n)
            lines = str(val).splitlines()
            
            # 2. 只保留前兩行
            top_lines = lines[:2]
            
            # 3. 合併為單行，中間用空格隔開
            combined_text = " ".join(top_lines)
            
            # 4. 依據逗號切割，只取第一部分
            final_text = combined_text.split(',')[0]
            
            # 5. 清除無效資料
            if "[Event Data1]" in final_text:
                 final_text = ""
            return final_text.strip()
        
        filtered_data = filtered_data.map(clean_cell_content)
        # ---------------------------------------------------------

    filtered_data.to_csv(output_file, index=False, encoding='utf-8', lineterminator='\n')
    print(f"處理完成，輸出至: {output_file}")

if __name__ == "__main__":
    main()