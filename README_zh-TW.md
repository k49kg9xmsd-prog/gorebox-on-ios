# GoreBoxRunner Stage 0 — 平面版

這一版不是重製 GoreBox。它直接內建 GoreBox 13.7.9 APK 中的原始 Android ARM64：

- `libil2cpp.so`
- `libunity.so`
- `libRF_CNative_andr.so`（RayFire）

為了能直接用 GitHub 網頁上傳，三顆 library 被切成 9 個 `.bin`，每個都小於 25 MiB。**所有檔案都放在 repo 根目錄，不需要建立任何資料夾。**

## 上傳

解壓本 ZIP → GitHub `Add file` → `Upload files` → 一次全選解壓後的全部檔案 → Commit。

## Codemagic

選：`GoreBoxRunner Stage 0 - Unsigned IPA`

成功 Artifact：`GoreBoxRunner-Stage0-unsigned.ipa`

Stage 0 不執行 Android code，所以目前不需要 JIT。安裝後 App 會在 iOS 真機上讀取並解析三顆原 GoreBox ELF，顯示：

- ELF class / CPU
- Entry point
- Program / LOAD segments
- Section headers
- `DT_NEEDED`
- Dynamic symbols / imports
- Relocations

成功標準：最下面顯示三顆 ELF 全部解析成功。成功後才進 Stage 1：ELF memory mapping、relocations 與 Android API shim。

## 整理版目錄

```text
codemagic.yaml
project.yml
README_zh-TW.md
Sources/   <- 4 個 Swift 原始碼
Payload/   <- 9 個 GoreBox ARM64 ELF 分片
```

GitHub 上傳時請保留 `Sources` 與 `Payload` 兩個資料夾名稱。
