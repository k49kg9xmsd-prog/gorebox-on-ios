# GoreBoxRunner Graphics Bridge 0.3.6

實機 0.3.5 已把 GoreBox 13.7.9 `libunity.so` initializer chain 從 **83/423 推到 117/423**。這證明 Android TLS 補償方向有效，但也暴露 0.3.5 的做法有一個更根本的風險：它在 guest code 執行期間暫時覆寫真正的 iOS `TPIDR_EL0`。

問題是 guest code 會透過 PLT 直接呼叫 Darwin/libSystem。這些 host 函式本身也依賴 iOS 的 thread pointer；如果它們在 synthetic Bionic TPIDR 下執行，就可能在看似無關的 constructor 內突然被終止。

## 0.3.6 核心改動：binary-level TLS virtualization

0.3.6 **不再修改 iOS 真正的 `TPIDR_EL0`**。

載入 Android ELF、relocation 完成後、頁面凍結為 RX 之前，Runner 會掃描 executable PT_LOAD，找到 Android ARM64：

```asm
MRS Xn, TPIDR_EL0
```

並在原位改寫成一條 `ADRP`，讓相同目的暫存器直接得到一個與 ELF 映像相鄰的 **synthetic Bionic TLS page**。

因此：

- Android guest 的 stack guard / TLS 讀取仍有合法資料
- Darwin/libSystem 永遠保留真正的 iOS TPIDR_EL0
- guest → host PLT/shim 轉移不再帶著錯誤 host TLS
- 不需要跳過任何 constructor
- 不需要 RWX；patch 在最終 `mprotect(RX)` 前完成並 flush instruction cache

GoreBox 13.7.9 原版 ARM64 靜態掃描可看到大量直接 `TPIDR_EL0` 讀取：`libunity.so` 約 2926 處、`libil2cpp.so` 約 985 處、RayFire 約 964 處、`libmain.so` 1 處。0.3.6 會在每顆實際匯入的 ELF 上動態掃描與改寫，不依賴硬編地址。

## 保留的相容層

仍包含前版已驗證有效的：Bionic pthread mutex/cond/once/key、semaphore、signal、Android syscall translator、Linux mmap/open flags、Android 4K guest page 行為、Bionic stdio/`__sF`、clock ID、`__cxa_atexit`、Android `.so` dlopen/dlsym、ANativeWindow/EGL bootstrap bridge。

## Codemagic

選：`GoreBoxRunner Graphics Bridge 0.3.6 - Unsigned IPA`

輸出：`GoreBoxRunner-Graphics-0.3.6-unsigned.ipa`

安裝後仍匯入原版 GoreBox 13.7.9 APK，按：

**Unity Constructors + 圖形橋 0.3.6**

如果 LiveContainer 再顯示 `This app has been terminated`，關掉死亡實例後重新開 GoreBoxRunner，把新的 durable checkpoint 截圖回傳即可。

> 0.3.6 仍是實驗性 Android→iOS compatibility runtime，不代表本版已能完整進入遊戲；這版目標是移除 0.3.5「改寫 host TPIDR」造成的結構性不穩定，讓 constructor chain 能繼續大幅前進。
