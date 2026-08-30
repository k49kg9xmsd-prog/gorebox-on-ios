# GoreBoxRunner Stage 0 V4

這版取消 `Payload/` 資料夾。9 個 GoreBox `.bin` 分片直接放在專案根目錄。

GitHub repo 根目錄應看到：

- `codemagic.yaml`
- `project.yml`
- `README_zh-TW.md`
- `Sources/`
- 9 個 `gb_*.bin`

Codemagic 選：`GoreBoxRunner Stage 0 - Unsigned IPA`。

Build 時會自動把根目錄的 9 個 `.bin` 複製進最終 App 的 `GoreBoxPayload/`，不需要你自己建立任何 Payload 資料夾。
