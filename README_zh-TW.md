# GoreBoxRunner Graphics Bridge 0.3.3

這版針對 0.3 在 `libunity.so JNI_OnLoad` 入口前被終止的結果，補上 Android ELF linker 原本一定會執行的初始化生命週期。

## 這次新增

- 解析 `PT_DYNAMIC`
- 解析 `DT_INIT`
- 解析 `DT_INIT_ARRAY` / `DT_INIT_ARRAYSZ`
- `libunity.so` 在 `JNI_OnLoad` 前執行完整 initializer chain
- GoreBox 13.7.9 的 `libunity.so` 目前偵測到 `423` 個 init-array entries
- 每個 initializer 呼叫前都會 durable checkpoint + fsync
- checkpoint 包含 constructor ordinal 與 guest virtual address
- constructors 全部返回後才呼叫 `JNI_OnLoad` / 捕捉 `RegisterNatives`
- 保留 0.3 的 CAEAGLLayer + EAGLContext / EGL bridge

## 如果又出現 This app has been terminated

關掉 LiveContainer 的死亡實例後重新開 GoreBoxRunner。彈窗會顯示類似：

```text
ELF initializer 57/423: about to CALL .init_array[56] guest=0x...
```

這樣下一版可以直接反組譯那一個 constructor，而不是再猜。

## Codemagic

選：`GoreBoxRunner Graphics Bridge 0.3.3 - Unsigned IPA`

輸出：`GoreBoxRunner-Graphics-0.3.3-unsigned.ipa`

> 這仍是實驗性相容層，不保證本版已能進遊戲；本版的主要目標是把 Android linker lifecycle 補完整並把 Unity 初始化推進到 JNI registration。


## 0.3.3 延續既有 constructor/runtime 修正
實機 0.3.1 停在 `.init_array[11]` guest `0xC4384`。反組譯顯示該 initializer 進入 Unity/Bionic 的 once-guard 後會使用 guest `pthread_mutex_t` / `pthread_cond_t`，並執行 Android ARM64 `syscall(178)` (`gettid`)。

0.3.3 因此新增：
- guest-address keyed pthread mutex/cond/once host-side bridge（不再把 Bionic pthread object 直接交給 Darwin）
- pthread attr / mutexattr / condattr compatibility adapters
- pthread_create guest-attr adapter
- Android ARM64 syscall translator：178=gettid、122/123=affinity；98 futex / 270 process_vm_readv 先以 ENOSYS 走 guest fallback
- 未知 Android syscall 一律 ENOSYS，絕不直接轉交 Darwin `syscall()`
- first pthread / syscall bridge durable checkpoints


## 0.3.3 批次 Android ABI 修正

0.3.2 實機已從 initializer 12/423 前進到 19/423；第 19 個會使用 Android/Bionic `pthread_key_create`。0.3.3 不只修這一個 constructor，而是一次加入：

- Bionic 32-bit `pthread_key_t` → Darwin host TLS key 對照表
- `pthread_key_create/delete/get/setspecific`
- `pthread_setname_np` ABI adapter
- opaque guest `pthread_attr_t` / `pthread_attr_getstack` adapter
- guest semaphore table（不把 Android `sem_t` 直接交給 Darwin）
- Android/Linux `mmap` flags → Darwin flags（特別是 `MAP_ANONYMOUS`）
- guest `getpagesize/sysconf(_SC_PAGESIZE)` 固定回 Android 4 KiB
- guest signal/sigset/sigaction bootstrap adapters
- Android `.so` `dlopen/dlsym/dlclose/dlerror` compatibility routing
- 原有 mutex/cond/once + Android ARM64 syscall bridge

目的不是只跨過第 19 個，而是讓後續 constructor 遇到同類 Bionic ABI 時一次通過。
