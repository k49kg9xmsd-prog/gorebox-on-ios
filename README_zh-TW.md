# GoreBoxRunner Launch 0.4.1

這版針對 0.4 實機最後 checkpoint：`entering nativeRecreateGfxState`。

## 0.4.1 核心修正

GoreBox 13.7.9 的 `nativeRecreateGfxState (ILandroid/view/Surface;)V` 在函式前段會呼叫 Android/Bionic `setjmp`。0.4 仍會把這個 import 解析到 Darwin `setjmp`，但 Android arm64 `jmp_buf` 與 Darwin ABI 不相容。

0.4.1 新增 `BionicJump.S`：

- 原生 arm64 Bionic-shaped `setjmp`
- 原生 arm64 Bionic-shaped `longjmp`
- 256-byte Android arm64 jmp_buf layout
- 不混用 Darwin signal-mask/jmp_buf 結構
- setjmp/longjmp 都會留下 durable checkpoint

另外 `ANativeWindow_fromSurface` 改成真正被 Unity 呼叫時才記 checkpoint。若下次失敗，可直接判斷：

- `Bionic setjmp bridge: guest setjmp entered`：已跨進 nativeRecreate 前段
- `ANativeWindow_fromSurface CALLED...`：已跨過 setjmp 並開始建立 Android window
- `nativeRecreateGfxState returned`：圖形狀態重建完成

## Codemagic

選擇：`GoreBoxRunner Launch 0.4.1 - Unsigned IPA`

產物：`GoreBoxRunner-Launch-0.4.1-unsigned.ipa`

仍屬實驗性相容層。這版的目的不是宣稱遊戲已可玩，而是修正目前實機已確認的下一個 ABI 邊界。
