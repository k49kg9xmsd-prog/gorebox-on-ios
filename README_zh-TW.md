# GoreBoxRunner Compatibility Test 1.0

這是 GoreBox 13.7.9 Android ARM64 → iOS 相容層的全面安全診斷版。

內建原 APK 的：
- libmain.so
- libil2cpp.so
- libunity.so
- libRF_CNative_andr.so

啟動後一次自動測：
1. ELF64/AArch64 解析
2. PT_LOAD 實際匿名記憶體配置與 segment copy
3. relocation 類型與數量
4. Android imports 在 iOS/Darwin 可直接解析的比例
5. Bionic / liblog / ANativeWindow / ALooper / ASensor / EGL 缺口
6. RW mmap、RW→RX、MAP_JIT executable-memory 能力
7. 每顆 library 的 guest execution readiness gate

這一版不會自動跳進 Android guest code；如果 symbols 尚未補齊，直接執行只會讓 App SIGSEGV，反而拿不到診斷結果。

## GitHub
解壓後把整個專案內容上傳 repo。10 個 `gb_*.bin` 每個都小於 25 MiB。

## Codemagic
選：
`GoreBoxRunner Compatibility Test 1.0 - Unsigned IPA`

成功產物：
`GoreBoxRunner-CompatibilityTest-1.0-unsigned.ipa`

安裝後按「全部重測」，最後可按「分享」把完整 txt 報告傳回來。
