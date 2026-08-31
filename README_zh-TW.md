# GoreBoxRunner Graphics Bridge 0.3.5

0.3.3 實機已把 GoreBox 13.7.9 `libunity.so` initializer chain 從 **19/423 推到 83/423**；0.3.4 仍停在 `.init_array[82]` / `0xCDCD0`。重新反組譯後發現，該 constructor 後段會進入直接執行 `MRS TPIDR_EL0` 的 Unity helper。這是 Android arm64/Bionic TLS ABI 本身，不是 imported symbol，因此前幾版的 pthread/C++/stdio shim 根本攔不到。

## 0.3.5 新增

- **Bionic `FILE*` / `__sF` bridge**
  - 不再把 Android/Bionic 的 stdin/stdout/stderr 物件直接交給 Darwin `stdio`
  - 攔截 `fclose / fflush / fread / fwrite / fputc / putc / fputs / fprintf / vfprintf`
  - bootstrap 階段的 `fprintf/vfprintf` 不讀 guest varargs，避免 Android arm64 與 Darwin variadic/`va_list` ABI 差異造成 crash
- **Android clock bridge**
  - Linux/Android `CLOCK_REALTIME / MONOTONIC / PROCESS / THREAD / RAW / COARSE / BOOTTIME` → Darwin clock IDs
  - 攔截 `clock_gettime / clock_getres`
- **Linux `open()` flag translator**
  - `O_CREAT / O_EXCL / O_TRUNC / O_APPEND / O_NONBLOCK / O_DIRECTORY / O_NOFOLLOW / O_CLOEXEC...` → Darwin flags
  - `O_CREAT` 使用安全預設 mode，不讀 guest variadic mode argument
- **Guest C++ destructor registry**
  - 攔截 `__cxa_atexit / __cxa_finalize`
  - 不再讓 Darwin runtime 保存可能在 ELF unload 後失效的 Android guest destructor pointers
- 延續 0.3.3 的 TLS pthread key、mutex/cond/once、semaphore、signal、Linux mmap、Android 4K guest page、syscall、Android `.so` dlopen/dlsym compatibility layer

## 為什麼這版特別針對 83/423

實機最後 checkpoint：

```text
ELF initializer 83/423: about to CALL .init_array[82] guest=0xCDCD0
```

原版 GoreBox `libunity.so` 的 `0xCDCD0` initializer 會先建立數個全域物件，後段呼叫的 helper 直接從 `TPIDR_EL0 + 0x28` 讀 Android stack guard。`libunity.so` 內可靜態找到大量 `TPIDR_EL0` 讀取，因此 0.3.5 不跳過 constructor，而是在進入 guest code 時提供 Bionic-shaped TLS context。

同時，剩餘 constructors 後續很可能共用 stdio、clock 與 file-open 路徑，因此一併先補，目標是再次一次跨過一大段，而不是 83 → 84。

## Codemagic

選：`GoreBoxRunner Graphics Bridge 0.3.5 - Unsigned IPA`

輸出：`GoreBoxRunner-Graphics-0.3.5-unsigned.ipa`

安裝後仍使用原版 GoreBox 13.7.9 APK，按：

**Unity Constructors + 圖形橋測試**

如果 LiveContainer 再顯示 `This app has been terminated`，關掉死亡實例後重新開 GoreBoxRunner，把新的 durable checkpoint 截圖回傳即可。

> 0.3.5 仍是實驗性 Android→iOS compatibility runtime，不代表本版已能完整進入遊戲。目標是讓 Unity Android initializer/JNI lifecycle 繼續往真正 rendering entrypoint 前進。


## 0.3.5 修正重點

0.3.4 在 `.init_array[82]`（guest `0xCDCD0`）仍終止。重新反組譯後確認該 constructor 的後段會進入含 `MRS TPIDR_EL0` 的 Unity helper。GoreBox 的 Android/NDK arm64 程式直接從 `TPIDR_EL0 + 0x28` 讀 Bionic stack guard；這不是 imported symbol，因此前面的 pthread / C++ shim 無法攔截。

0.3.5 在每次 guest constructor / JNI / native call 前暫時安裝 Bionic-shaped TPIDR_EL0 TLS，返回 iOS 後立即恢復原 host TPIDR；guest pthread 新執行緒也經 trampoline 建立獨立 TLS block。這是針對 Android arm64 TLS ABI 本身的修復，不是跳過第 83 個 constructor。
