# GoreBoxRunner Bootstrap 0.2.1

這版修正 0.2 真機「This app has been terminated」的第一個高機率原因：**Android 4 KB ELF page 與 iOS 16 KB host page 權限碰撞**。

## 0.2 的問題
GoreBox 的 `libmain.so` 兩個 PT_LOAD：

- code 約 `0x0000–0x0F48`：`R-X`
- data 約 `0x2D80–0x3040`：`RW-`

Android 4 KB page 下它們分開，但 16 KB iOS page 下都落在同一個 `0x0000–0x3FFF` host page。0.2 是逐 segment `mprotect`，第二個 RW segment 會把前面的 X 權限移掉；一跳 `JNI_OnLoad` 就可能被 iOS 終止。

## 0.2.1 修正
- 先以 **host page** 為單位合併所有 PT_LOAD 權限
- 偵測 `W+X` collision page
- 先嘗試 host page 的合併權限
- 若 iOS W^X 不允許 RWX，當前受控 bootstrap 會 fallback 到 `R-X`（relocation 已完成；目前 probe 不會改 guest data）
- 每個危險階段都保存 `BootstrapCheckpoint`
- 若 App 再被終止，重新打開會直接顯示最後停在：
  - ELF loader
  - libmain JNI_OnLoad
  - full-image RayFire call
  - IL2CPP
  - Unity
- 報告新增 host page size / W+X collision / RWX accepted / RX fallback 統計

## Build
Codemagic workflow：

`GoreBoxRunner Bootstrap 0.2.1 - Unsigned IPA`

輸出：

`GoreBoxRunner-Bootstrap-0.2.1-unsigned.ipa`

## 真機
保留原本匯入的 GoreBox APK 即可（如果換成新安裝 App 導致容器不同，就重新匯入一次）。按 **實驗性啟動 GoreBox**。

這版仍是 bootstrap，不宣稱已經完整可玩；目標是讓整顆 Android ELF 的 controlled calls 穩定跨過 16 KB page 差異，之後才能繼續真正的 JNI / ANativeWindow / EGL bridge。
