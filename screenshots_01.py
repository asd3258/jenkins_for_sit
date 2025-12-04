from selenium import webdriver
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from webdriver_manager.firefox import GeckoDriverManager
import time
import os

# --- 設定區 ---
TARGET_URL = "https://www.youtube.com/"
SEARCH_KEYWORD = "i-dle"
SAVE_DIR = os.getcwd()

# --- 初始化 Firefox (Ubuntu 24.04 設定) ---
options = webdriver.FirefoxOptions()
# 在 Ubuntu Server 環境 (無 GUI) 必須開啟 headless，否則會報錯
# 如果您是在有桌面的 Ubuntu 測試，可以註解掉這行
options.add_argument("--headless") 
options.add_argument("--window-size=1920,1080") # 設定解析度確保截圖正常

# 自動安裝並管理 GeckoDriver
service = Service(GeckoDriverManager().install())
driver = webdriver.Firefox(service=service, options=options)

try:
    wait = WebDriverWait(driver, 15)
    
    # 2. 進入 YouTube
    print(f"正在進入 {TARGET_URL} ...")
    driver.get(TARGET_URL)

    # 3. 在 search_query 輸入 i-dle
    # 根據您提供的 HTML: <input name="search_query" ...>
    print(f"正在搜尋: {SEARCH_KEYWORD}")
    search_input = wait.until(EC.presence_of_element_located((By.NAME, "search_query")))
    search_input.clear()
    search_input.send_keys(SEARCH_KEYWORD)

    # 4. 按下 Search 按鈕
    # 根據您提供的 HTML: <button aria-label="Search" ...>
    # 使用 CSS Selector 定位 aria-label 最為精準
    search_btn = driver.find_element(By.CSS_SELECTOR, "button[aria-label='Search']")
    search_btn.click()

    # 等待搜尋結果載入 (簡單等待 3 秒，或偵測影片標題出現)
    time.sleep(3)
    wait.until(EC.presence_of_element_located((By.ID, "video-title")))

    # 5. 拍照 (截圖)
    screenshot_path = os.path.join(SAVE_DIR, "youtube_idle_result.png")
    driver.save_screenshot(screenshot_path)
    print(f"截圖已儲存: {screenshot_path}")

except Exception as e:
    print(f"發生錯誤: {e}")
    # 錯誤時也截圖，方便 Debug
    driver.save_screenshot("error_debug.png")

finally:
    driver.quit()
