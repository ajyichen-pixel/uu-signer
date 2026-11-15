# UU 簽署

Feather 的 GPL-3.0 客製版本。保留原作者版權與 LICENSE；對應修改原始碼公開於 https://github.com/ajyichen-pixel/uu-signer 。

## 3.0 原生介面

商店、會員登入、下載清單、下載進度、取消下載、裝置簽署狀態與安裝／更新按鈕由 SwiftUI 實作，不使用 WKWebView。首次以 UU 會員登入；登入工作階段存於此裝置的 Keychain，不保存會員密碼。裝置專屬版本以目前 App 內嵌描述檔中的唯一裝置篩選。

本版本是原生客戶端加私人後台簽署，並非在客戶 iPad 上持有店主私鑰的本機簽署器。Apple Distribution 私鑰、Apple API 金鑰及管理 token 不放進 App 或公開 GitHub Actions。後台負責已付款訂單的裝置描述檔、簽署及專屬 IPA 交付；客戶端用自己的會員權限讀取進度和安裝連結。

「下載 IPA」使用 URLSession 直接寫入磁碟、顯示實際傳輸進度，檢查回應、長度與 ZIP 檔頭。這不是獨立的 Apple 簽章驗證；完整簽章與描述檔驗證由私人交付主機執行。「安裝／更新」取得有效的專屬 OTA 連結並交給 iOS；iOS 會自行取得安裝包，仍需使用者確認。下載完成、打開 OTA 連結均不代表裝置已安裝成功。

註冊、購買、裝置登記及訂單管理仍以明確外部連結開啟官網，不冒充原生付款流程。

## 私人交付

- `tools/order_runner.py`：付費簽署工作、有效期限、更新掃描與郵件重試。
- `tools/apple_provision.py`：裝置與專屬描述檔。
- `tools/deliver_signed.py`、`tools/verify_ipa_signature.py`：描述檔、憑證、Mach-O、資源封印及交付驗證。
- `tools/prepare_cloud.py`：移除上游本機 HTTPS 伺服器的舊測試私鑰與舊簽章；`UUCloudDelivery` 標記代表使用後台簽署，不代表網頁介面。

`personalize.py` 與 `first_sign.py` 是舊的個別供應商裝置憑證模式，不可用來把店主共用 Apple 私鑰嵌入客戶 App。

## 編譯與測試

GitHub Actions `Build UU Signer` 在 macOS/Xcode 編譯，公開 CI 不使用私人憑證。未正式簽署 IPA 必須經私人主機簽署與驗證，才能交付客戶。

交付工具測試：`python -m unittest discover -s tools -p 'test_*.py' -v`。
原生介面的安裝、登入、下載、取消、重新下載、遊戲安裝與版本更新必須分別實機確認。不得將 CI 成功或後台 ready 宣稱為 iPad 測試成功。
