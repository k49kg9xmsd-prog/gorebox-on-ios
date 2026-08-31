# GoreBoxRunner Launch 0.4.4

這版直接針對 0.4 卡在 `nativeRecreateGfxState` 的路徑繼續修。

## 0.4.4 核心修正

- 修正 Android/Bionic AArch64 `jmp_buf` 的實際欄位偏移：core registers 從 word 2（byte 16）開始，浮點暫存器從 word 16（byte 128）開始。
- 0.4.1 的 bridge 將 core 區提早一個 64-bit word，遇到 `longjmp` 時會還原錯誤的 LR/SP；0.4.4 已修正。
- Android `setjmp/longjmp` 不再碰 Darwin 的 `jmp_buf`。
- 在 `nativeRecreateGfxState`、`ANativeWindow_fromSurface`、`eglGetDisplay`、`eglInitialize`、`eglCreateContext`、`eglCreateWindowSurface` 增加 checkpoint，若仍被 iOS 終止可以直接知道下一個 ABI 邊界。
- 新增持久化 `launch-trace.txt`：每一個 checkpoint 都會追加保存，不再只留下最後一條。重新開 App 後的「未完成」彈窗會多出「複製完整紀錄」，可一次複製 crash 前完整流程。
- 保留原本 persistent `libmain.so` / `libRF_CNative_andr.so` / `libil2cpp.so` / `libunity.so` 映射、guest `dlopen/dlsym` registry、真實 UnityPlayer lifecycle 呼叫。

## Codemagic

workflow：`GoreBoxRunner Launch 0.4.4 - Unsigned IPA`

產物：`GoreBoxRunner-Launch-0.4.4-unsigned.ipa`
