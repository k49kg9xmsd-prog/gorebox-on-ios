# GoreBoxRunner APK Importer 0.1.1

這版 Runner **不內建 GoreBox 本體**。

## 使用方式
1. 把此 repo 上傳 GitHub。
2. Codemagic 選 `GoreBoxRunner APK Importer 0.1.1 - Unsigned IPA`。
3. 安裝輸出的 `GoreBoxRunner-APKImporter-0.1.1-unsigned.ipa`。
4. 開啟 Runner → `匯入 GoreBox APK` → 在 iOS「檔案」選 `GoreBox_v13.7.9.apk`。
5. Runner 會保存原 APK，並抽出 ARM64 `libmain.so / libil2cpp.so / libunity.so / libRF_CNative_andr.so` 與 `global-metadata.dat`。
6. 可直接跑「全面相容性診斷」。
7. `RayFire ARM64 真執行測試` 是實驗性按鈕；它會嘗試執行 APK 內 RayFire 的原 Android ARM64 `ret` 指令。若目前簽名/JIT環境阻擋 anonymous executable memory，App 可能直接被 iOS 終止。

## 目前狀態
- APK 匯入/保存：有
- APK ZIP 解析與 raw-deflate 解壓：有（內建 zlib bridge）
- GoreBox 13.7.9 SHA256 精確辨識：有
- ARM64 ELF 診斷：有
- PT_LOAD / relocations / symbol coverage：有
- RayFire 最小 guest-call probe：有，需真機測試
- 完整 GoreBox 啟動：尚未完成；後續需 relocation patcher、Bionic/JNI/ANativeWindow/EGL bridge。
