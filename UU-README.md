# UU 簽署

Feather 的 GPL-3.0 客製版本。保留原作者版權及 LICENSE；修改原始碼公開於 https://github.com/ajyichen-pixel/uu-signer 。

## 目前的官網交付模式

`UUCloudDelivery=true` 的版本開啟 UU 官網會員安裝頁。客戶先從官網安裝已簽署的 UU 簽署，再從 App 內選擇遊戲安裝或更新。iOS 的安裝確認仍需客戶操作。

自己的 Apple Developer 共用私鑰只留在私人簽署主機，絕不放進客戶 App、公開原始碼或 GitHub Actions。客戶不必匯入憑證。每個 App 及裝置使用相符的 Ad Hoc 描述檔；憑證及描述檔的有效期不等於永不撤銷的保證。

## 私人交付工具

- `tools/cloud_sign.py`：macOS 簽署、codesign 驗證及分段交付。
- `tools/deliver_signed.py`：驗證私人主機已簽署的 IPA，符合條件後才上傳官網。可處理 Windows zsign 產物。
- `tools/verify_ipa_signature.py`：檢查 Mach-O 程式頁面雜湊、CMS 簽章與預期憑證、Info.plist／資源封印。這不是 Apple 根信任與裝置政策驗證的替代品。
- `tools/prepare_cloud.py`：移除上游供本機 HTTPS 伺服器使用的 server.pem 和舊簽章資料，並拒絕其他私鑰檔。產物仍須正式簽署。

交付前檢查描述檔 CMS、憑證與私鑰匹配、有效期、App ID、描述檔僅含指定一台裝置，以及 IPA 內嵌描述檔完全一致。檔案以 8 MiB 分段上傳，每段驗證 SHA-256，會員只能取得自己的限時 OTA 連結。

`personalize.py` 與 `first_sign.py` 是舊的單裝置供應商憑證模式，不可用來將店主共用的 Apple 私鑰嵌入客戶 App。

## 驗證狀態與限制

2026-11-14 已用真實 Apple Distribution 憑證簽署兩個測試 App，通過本機完整性檢查並交付官網。iPad 安裝、開啟及後續版本升級仍須實機確認；不得把後台 ready 狀態宣稱為裝置已安裝。

Apple 裝置註冊／描述檔核發目前人工操作；已付款訂單到簽署工作的全自動執行仍未完成。不能宣稱所有新客戶付款後已可自動交付。

## 檢查與建置

macOS/Xcode：GitHub Actions `Build UU Signer` 產生未正式簽署 IPA，公開 CI 不使用私人憑證。
交付工具：安裝 `tools/requirements.txt` 後執行 `python -m unittest discover -s tools -p 'test_*.py' -v`。
上游子模組：Zsign c4ba9da4283031c07efa03bce42c4b8602d22e73；IDeviceKitten 837cf1e14d4875771dd5ee1b754a4c86215c5db3。
