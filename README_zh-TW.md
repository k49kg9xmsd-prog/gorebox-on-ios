# GoreBoxRunner Launch 0.4

Target: user-imported GoreBox 13.7.9 Android ARM64 APK.

這版從 0.3.6 的「Unity 真入口已抓到」進入第一次真正 UnityPlayer lifecycle launch。

## 0.4 新增

- 保留四顆 Android ELF 映像，不再在 Probe 結束後立刻 unload。
- 預先載入並初始化：`libmain.so`、`libRF_CNative_andr.so`、`libil2cpp.so`、`libunity.so`。
- 建立 mapped guest export registry。
  - Android guest `dlopen("libil2cpp.so")` 可取得 Runner registry handle。
  - `dlsym("il2cpp_init")` 等可直接解析到已載入的原版 GoreBox IL2CPP 映像。
  - RayFire exports 同樣註冊。
- `ANativeWindow_fromSurface` 不再回 NULL，會接到 Runner 的 iOS drawable token。
- 第一次 Launch 會從使用者匯入的 APK 解出 `assets/bin/Data/` 到 Application Support（約 259 MB），不把遊戲本體包進 IPA。
- 實際呼叫 GoreBox/Unity 2021.3.28f1 在 `RegisterNatives` 註冊的：
  1. `nativeRecreateGfxState(0, Surface)`
  2. `nativeSendSurfaceChangedEvent()`（若存在）
  3. `nativeFocusChanged(true)`（若存在）
  4. `nativeResume()`
  5. `nativeRender()`
- 第一個 `nativeRender` 成功返回 1 時，Runner 會嘗試開始 60 FPS 實驗性 render loop。
- 每個危險 launch gate 與部分 frame 都會 fsync checkpoint；若 LiveContainer 終止 App，重新開啟即可看到最後一步。

## Codemagic

選：

`GoreBoxRunner Launch 0.4 - Unsigned IPA`

產物：

`GoreBoxRunner-Launch-0.4-unsigned.ipa`

## 使用

1. 安裝 IPA。
2. 若已經保留舊版 App 資料，GoreBox APK 不必重新匯入；否則匯入原版 GoreBox 13.7.9 APK。
3. 按 **▶︎ 啟動 GoreBox（實驗性 0.4）**。
4. 第一次會先解出 Unity Data，可能需要一些時間與額外約 259 MB 空間。
5. 若被終止，不要刪 App；重新開 GoreBoxRunner，截圖 `Launch 0.4` checkpoint。

## 目前限制

Launch 0.4 是第一次真的呼叫 UnityPlayer lifecycle，不代表已宣告「完整可玩」。若第一幀成功，後續仍可能需要補 Android Activity/JNI、檔案 ABI、輸入、音訊、存檔與更多 EGL/GLES 行為。目標是讓實機回報直接落在真正的 launch/render 路徑，而不是再停在 constructor probe。
