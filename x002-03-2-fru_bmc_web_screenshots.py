import time
import os
import sys
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait, Select
from selenium.webdriver.support import expected_conditions as EC

# ==============================================================================
# SIT 自動化測試腳本
# 功能: 登入 BMC -> 切換 FRU 頁面 -> 遍歷所有 FRU ID -> 長截圖與抓文字
# 環境: Docker (Jenkins) / Ubuntu / Chromium
# ==============================================================================

# --- 設定區 ---
if len(sys.argv) > 1:
    BMC_IP = sys.argv[1]
    print(f"[*] 接收到 Jenkins 參數 IP: {BMC_IP}")
else:
    exit("[Error] 請提供 BMC IP 作為參數！")
TARGET_URL = f"https://{BMC_IP}/#login"
FRU_URL = f"https://{BMC_IP}/#fru"
USERNAME = "admin"
PASSWORD = "adminadmin"

# --- 截圖儲存目錄 (支援 Jenkins Workspace) ---
# 使用 Docker 內部的路徑，或者當前目錄
# SAVE_DIR = os.path.join(os.getcwd(), f"fru_data_{BMC_IP.replace('.', '-')}")

SAVE_DIR=f"{os.getcwd()}/fru_log"
if not os.path.exists(SAVE_DIR):
    os.makedirs(SAVE_DIR)

print(f"[*] 測試報告儲存路徑: {SAVE_DIR}")

# --- 初始化 Chrome (Docker 環境專用設定) ---
chrome_options = Options()
# 關鍵：SIT Server 無桌面環境，必須 Headless
chrome_options.add_argument("--headless") 
chrome_options.add_argument("--no-sandbox") # Docker 內必須加
chrome_options.add_argument("--disable-dev-shm-usage") # 避免記憶體崩潰
chrome_options.add_argument("--window-size=1920,1080")
chrome_options.add_argument("--ignore-certificate-errors") # 忽略 BMC 的 HTTPS 憑證警告
chrome_options.add_argument("--allow-insecure-localhost")

# 指定 Docker 內建的 Chromedriver 路徑
service = Service("/usr/bin/chromedriver")

print("[*] 正在啟動 Chrome Driver...")
driver = webdriver.Chrome(service=service, options=chrome_options)

# --- 定義長截圖函式 ---
def capture_full_page(driver, filename):
    """
    技巧：在 Headless 模式下，將視窗高度設為網頁總高度，即可完成長截圖
    """
    try:
        # 1. 取得網頁實際內容高度
        total_height = driver.execute_script("return document.body.parentNode.scrollHeight")
        total_width = driver.execute_script("return document.body.parentNode.scrollWidth")
        
        # 2. 調整視窗大小 (寬度固定 1920，高度隨內容變動)
        driver.set_window_size(max(1920, total_width), total_height + 100)
        time.sleep(0.5) # 等待渲染
        
        # 3. 截圖
        driver.save_screenshot(filename)
        print(f"    -> 已儲存截圖: {os.path.basename(filename)} (H:{total_height}px)")
        
    except Exception as e:
        print(f"    -> 截圖失敗: {e}")

try:

    # ==========================
    # 1. 登入流程 (SIT 優化版)
    # ==========================
    driver.get(TARGET_URL)
    wait = WebDriverWait(driver, 30) # 延長等待
    print(f"[*] 已連線至: {TARGET_URL}")

    # 輸入帳密
    user_input = wait.until(EC.presence_of_element_located((By.ID, "userid")))
    user_input.clear()
    user_input.send_keys(USERNAME)
    
    pass_input = driver.find_element(By.ID, "password")
    pass_input.clear()
    pass_input.send_keys(PASSWORD)

    print("[*] 點擊登入按鈕...")
    try:
        login_btn = wait.until(EC.element_to_be_clickable((By.ID, "btn-login")))
        login_btn.click()
    except:
        driver.find_element(By.XPATH, "//button[contains(@id, 'login')]").click()

    # --- [關鍵修改 1] 確保真的登入成功 ---
    print("[*] 正在驗證登入結果...")
    try:
        # 等待「登出按鈕」或「Dashboard 元素」出現，證明 Session 建立成功
        # 這裡假設登入後會有 logout 或 user 相關的圖示/按鈕
        # 如果您不知道登入後有什麼 ID，請先用 print(driver.page_source) 抓下來看
        wait.until(EC.presence_of_element_located((By.XPATH, "//*[contains(@id, 'logout') or contains(@class, 'user') or contains(text(), 'Logout')]")))
        print("[OK] 登入驗證成功！")
    except:
        print("[Error] 登入驗證超時！可能還停留在登入頁面或帳密錯誤。")
        # 拍張照看看發生什麼事
        driver.save_screenshot(os.path.join(SAVE_DIR, "login_failed_debug.png"))
        raise Exception("Login Failed")

    # ==========================
    # 2. 轉跳 FRU 頁面
    # ==========================
    # 建議：登入成功後，與其強制跳轉 URL，不如模擬點擊 Menu (這樣比較像真人，也比較不容易掉 Session)
    # 但為了相容您的寫法，我們先保留 get(URL)，但要加強檢查
    
    print("[*] 準備進入 FRU 頁面...")
    time.sleep(3) 
    driver.get(FRU_URL)
    
    # --- [關鍵修改 2] 檢查是否掉入 Iframe 陷阱 ---
    # 很多 BMC 介面會把內容放在 iframe 裡
    iframes = driver.find_elements(By.TAG_NAME, "iframe")
    if len(iframes) > 0:
        print(f"[*] 警告：偵測到頁面有 {len(iframes)} 個 iframe，嘗試切換...")
        # 嘗試切換到第一個 iframe (通常是主視窗)
        driver.switch_to.frame(0)
        print("[*] 已切換至 iframe (index 0)")

    # ==========================
    # 3. 處理下拉選單與 Debug
    # ==========================
    print("[*] 等待 FRU 下拉選單 (#fru_device_id)...")
    
    try:
        # 先等待 Select 本體
        wait.until(EC.presence_of_element_located((By.ID, "fru_device_id")))
        
        # 再等待 Option 內容
        wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, "#fru_device_id option")))
    
    except Exception as e:
        print(f"[Error] 找不到控件！截圖並輸出 HTML 以供分析...")
        
        # 1. 截圖：這張圖會告訴你，Script 眼中的畫面到底是什麼
        driver.save_screenshot(os.path.join(SAVE_DIR, "fru_not_found_debug.png"))
        
        # 2. 輸出 HTML：這是最直接的證據，看 ID 到底叫什麼
        with open(os.path.join(SAVE_DIR, "debug_page_source.html"), "w", encoding="utf-8") as f:
            f.write(driver.page_source)
            
        print(f"    -> 已儲存案發截圖: fru_not_found_debug.png")
        print(f"    -> 已儲存網頁原始碼: debug_page_source.html")
        print("    -> 請下載這兩個檔案來分析原因。")

    time.sleep(2) # 緩衝

    # 初次取得選項數量
    select_element = driver.find_element(By.ID, "fru_device_id")
    select_object = Select(select_element)
    options_count = len(select_object.options)
    
    print(f"[*] 偵測到 {options_count} 個 FRU 裝置")

    # 開始迴圈
    for i in range(options_count):
        # --- A. 重新定位 (重要！每次迴圈都要重抓，否則會報 StaleElementReferenceException) ---
        select_element = driver.find_element(By.ID, "fru_device_id")
        select_object = Select(select_element)
        
        # 取得該選項的資訊
        target_option = select_object.options[i]
        val = target_option.get_attribute("value")
        text_label = target_option.text
        
        print(f"--- 正在處理第 {i+1}/{options_count} 個: ID={val} ({text_label}) ---")
        
        # --- B. 執行切換 ---
        select_object.select_by_index(i) # 使用 Index 切換最穩
        
        # 等待資料載入 (視 BMC 速度調整)
        time.sleep(3) 
        
        # --- C. 執行長截圖 ---
        file_img_name = os.path.join(SAVE_DIR, f"fru_{val}.png")
        capture_full_page(driver, file_img_name)
        
        # --- D. 抓取文字 ---
        page_text = driver.find_element(By.TAG_NAME, "body").text
        file_txt_name = os.path.join(SAVE_DIR, f"fru_{val}.txt")
        
        with open(file_txt_name, "w", encoding="utf-8") as f:
            f.write(f"URL: {FRU_URL}\n")
            f.write(f"FRU ID: {val}\n")
            f.write(f"Label: {text_label}\n")
            f.write("="*30 + "\n")
            f.write(page_text)
        print(f"    -> 已儲存文字: {os.path.basename(file_txt_name)}")

    print(f"\n[OK] 所有測試任務完成。產出位於: {SAVE_DIR}")

except Exception as e:
    print(f"[Error] 發生錯誤: {e}")
    # 發生錯誤時的當下截圖
    driver.save_screenshot(os.path.join(SAVE_DIR, "error_debug.png"))

finally:
    # 確保瀏覽器關閉，釋放記憶體
    if 'driver' in locals():
        driver.quit()
        print("[*] Chrome Driver 已關閉")
