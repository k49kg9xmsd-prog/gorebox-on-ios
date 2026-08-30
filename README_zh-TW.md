# GoreBoxRunner Stage 0 V2

修正 Stage 0 顯示 `Missing resource` 的版本。

## 修正
- Codemagic Build 後強制把 9 個 GoreBox ARM64 `.bin` 分片複製到 `GoreBoxRunner.app/GoreBoxPayload/`。
- 打包 IPA 前會驗證 9/9 檔案真的存在。
- App 端不只使用 `Bundle.main.url(...)`，也會搜尋 `GoreBoxPayload/`、Bundle URL、resource URL 與 executable 所在目錄。
- 如果仍找不到，錯誤畫面會顯示實際 Bundle 搜尋路徑，方便判斷是否是 LiveContainer 路徑重導向。

## Codemagic
選：`GoreBoxRunner Stage 0 - Unsigned IPA`

正常時 Codemagic 的 `Force embed GoreBox payload` 應顯示 9 個分片，IPA 驗證也必須是 9 個。
