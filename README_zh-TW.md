# GoreBoxRunner Graphics Bridge 0.3.1

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

選：`GoreBoxRunner Graphics Bridge 0.3.1 - Unsigned IPA`

輸出：`GoreBoxRunner-Graphics-0.3.1-unsigned.ipa`

> 這仍是實驗性相容層，不保證本版已能進遊戲；本版的主要目標是把 Android linker lifecycle 補完整並把 Unity 初始化推進到 JNI registration。
