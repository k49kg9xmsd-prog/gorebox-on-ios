# GoreBoxRunner Bootstrap 0.2

這版仍然 **不內建 GoreBox APK**。第一次開啟後從 iOS「檔案」匯入你自己的 GoreBox 13.7.9 APK。

## 這版和 0.1.1 最大差別
0.1.1 的 RayFire 按鈕只證明「從 Android binary 複製出來的 ARM64 指令可以在目前 iOS process 執行」。

0.2 新增真正的 ELF bootstrap loader：

- 對完整 Android ARM64 `.so` 建立 PT_LOAD image
- 複製 code/data/BSS 到正確 virtual-address layout
- 套用 `R_AARCH64_RELATIVE / GLOB_DAT / JUMP_SLOT / ABS64`
- 加入第一批 Android Bionic / liblog / Linux ABI compatibility shim
- 先把 `ANativeWindow / ALooper / ASensor / EGL` imports 接到 bootstrap stub，讓整顆 Unity ELF 可以完成 relocation
- `libmain.so` 會嘗試用最小 fake JavaVM/JNIEnv 執行真正的 `JNI_OnLoad`
- RayFire 會從 **完整 mapped + relocated ELF image** 執行 `GetTestIntValue` 並返回 iOS
- IL2CPP / Unity 目前只做到完整 map + relocation；Unity 的 EGL stub 還不是實際畫面 backend

## Build
Codemagic workflow：

`GoreBoxRunner Bootstrap 0.2 - Unsigned IPA`

輸出：

`GoreBoxRunner-Bootstrap-0.2-unsigned.ipa`

## 真機使用
1. 安裝 IPA。
2. `匯入 GoreBox APK`。
3. 選 GoreBox 13.7.9 APK。
4. 按 **實驗性啟動 GoreBox**。
5. 把畫面最下面的 Bootstrap 報告貼回來。

## 目前邊界
如果 4 顆 library 都顯示 `Relocations applied = total` 且 `Unresolved after shim table = 0`，代表 Android ELF loader / relocation / 第一批 ABI shim 已經過關。

真正看到 GoreBox 畫面仍需要把現在的 `ANativeWindow + EGL` bootstrap stub 換成真正能提供 drawable surface 的 iOS/Metal bridge。這版不宣稱已經完整可玩。
