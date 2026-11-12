# UU 簽署 — 開發中

以 Feather 為基礎的 UU 商店客製版。保留 Feather 及其依賴的著作權與授權，不是從零開發的簽署引擎。

目前已修改原始碼，尚未完成 Xcode 編譯、有效憑證簽署或 iPad 實機驗證。不要將此資料夾或工作流程檢查通過宣稱為安裝成功。

## 使用流程

1. 簽署 App 本身必須先用涵蓋目標裝置的有效憑證簽署並安裝，不能繞過第一次安裝所需憑證。
2. 開啟即預設 UU 商店，不需貼來源網址；來源 https://uuxp.click/source.json。
3. 在「憑證」匯入供應商提供的 P12、描述檔及密碼。購買憑證不會自動匯入；供應商 API 尚未串接。
4. 在「UU 商店」選擇遊戲，下載後到「遊戲庫」簽署，再安裝並確認 iOS 提示。
5. UU 的遊戲使用授權另外驗證；簽署 App 不包含免費遊戲授權。

這版沿用 Feather 的本機簽署／安裝流程，未完成單一按鈕串起下載、簽署、安裝，也未承諾每個修改版遊戲可用。

## 編譯

- 原始上游：https://github.com/claration/Feather
- 上游基準：31ab6de455f2a6108f6830e343dee826310c03be
- Zsign 子模組：c4ba9da4283031c07efa03bce42c4b8602d22e73
- IDeviceKit 子模組：837cf1e14d4875771dd5ee1b754a4c86215c5db3
- 需要相容 Xcode 的 macOS；本 Windows 環境不能編譯 SwiftUI/UIKit 專案。
- Mac：`git submodule update --init --recursive`，接著 `make iphoneos`。
- GitHub：在自己的儲存庫啟用 `.github/workflows/uu-build.yml`，執行 Build UU Signer。macOS Actions 是否收費依儲存庫及帳號額度，使用前確認。
- 工作流程產物 `UU-Signer-UNSIGNED.ipa` 只有本機 ad-hoc signature，仍需有效 Apple 分發簽署才能在一般 iPad 安裝。
- 上游 Makefile 會下載 backloop.dev 的本機安裝 HTTPS 憑證資料；它不是 Apple App 簽署憑證。

## 授權與發佈

本修改版依 GPL-3.0 提供。發佈二進位時須同時提供對應完整原始碼（包含修改與建置流程）及授權文件。`LICENSE` 保留上游原文，子模組各自授權保留。不可只提供上游連結而省略本修改版原始碼。

憑證／私鑰／Apple 帳號／客戶資料不得提交 GitHub 或包入原始碼壓縮檔。
