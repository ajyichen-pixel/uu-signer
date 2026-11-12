# UU 簽署

Feather 的 GPL-3.0 客製版本。保留原作者版權及 LICENSE；修改原始碼公開於 https://github.com/ajyichen-pixel/uu-signer 。

## 客戶流程

每台裝置取得專屬、已簽署的 UU 簽署安裝包後，App 自動驗證並匯入隨附憑證。客戶在 UU 商店按「安裝」，App 接續下載、解包、簽署並顯示 iOS 安裝提示。客戶不需選憑證檔或輸入憑證密碼。系統安裝確認不能跳過。

此流程要求裝置專屬憑證。普通 GitHub build 不含憑證，開啟後會清楚顯示未就緒，不能作為客戶安裝包。實機安裝尚未驗證。

## 交付端

`tools/personalize.py` 接受原始 UU 簽署 IPA、供應商交付的 P12、描述檔及裝置 UDID。P12 密碼從 `UU_P12_PASSWORD` 環境變數讀取，不放在命令列。

工具驗證：描述檔 CMS 內容簽章、有效期、P12/描述檔憑證匹配、App ID、描述檔僅列出一台且與訂單裝置相同。CMS 檢查不是 Apple 根憑證鏈驗證，也不代表 Apple 已准許裝置安裝。

工具產出 `personalized_requires_signing` 狀態的私人 IPA；必須再用該裝置有效憑證完成簽署，才能發送私人安裝連結。打包不等於簽署、簽署不等於實機安裝成功。

專屬包含該客戶簽署私鑰及密碼；只能透過會員授權的私有下載交付該客戶，不能放在公開軟體源、GitHub Releases、Actions artifacts。腳本不會自行上傳，公開編譯不得取得憑證。

多裝置共用的描述檔會被拒絕；供應商必須可交付單裝置描述檔。描述檔可能需要針對不同 App ID 分別核發；尚未驗證 UU 遊戲及 extension 的 provisioning 相容性。

## 尚未接通

商店金流、服務商付款/核發 API、已付款訂單至私人交付的自動工作、專屬 UU 簽署 IPA 的首次簽署與 OTA 交付均未完成。不能將本工具宣稱為已上線的付款後自動交付系統。尚無付費憑證，未在 iPad 完成實機測試。

## 檢查

macOS/Xcode：GitHub Actions `Build UU Signer`。
交付工具：`python -m pip install -r tools/requirements.txt`，然後 `python -m unittest discover -s tools -p 'test_*.py' -v`。測試使用自簽測試資料，無 Apple 憑證且不會安裝到裝置。

上游子模組：Zsign c4ba9da4283031c07efa03bce42c4b8602d22e73；IDeviceKitten 837cf1e14d4875771dd5ee1b754a4c86215c5db3。

