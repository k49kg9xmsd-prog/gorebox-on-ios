# GoreBox iOS POC 0.2 — Codemagic 真機整合版

這版建立在已經成功於 iPad 真機運行的 0.1 上，不再只是灰色測試場。

## 0.2 已加入
- GoreBox 風格的手機 HUD 重新配置
- 原 APK 的 GoreBox App 圖示（來源：使用者提供的 v13.7.9 APK）
- 第一人稱低多邊形 carbine viewmodel
- 30 發彈匣、連射、換彈、後座、槍口閃光
- AIM：縮 FOV + 武器移至瞄準位置
- Crouch / Jump / 手動推物件
- Spawn Menu：Crate / Dummy / Barrel / Ball / Clear
- Dummy 命中後會轉成簡化 ragdoll parts
- 命中 Dummy 會產生短時間血液物理粒子
- 大型戶外 sandbox 場景：草地、混凝土平台、道路、倉庫、圍欄、樹、坡道、物理箱
- 靜態建築基本碰撞阻擋
- RayFire 缺席時不阻止遊戲啟動；可破壞物目前使用 SceneKit 動態物理替代
- 仍然可以使用 Codemagic 產生 unsigned ARM64 IPA

## 目前不是什麼
- 不是把 Android `libil2cpp.so` / `libunity.so` 硬塞進 IPA。
- 還不是 1:1 原版 `map_Plains` serialized scene；SceneKit 不能直接載入 Unity `.assets/.unity3d`。
- 還沒有 RayFire runtime fragmentation。

## Codemagic
把本資料夾全部覆蓋到 repo 根目錄後跑：

`GoreBox POC - Unsigned iPhone/iPad IPA`

產物：
`build/ipa/GoreBoxPOC-unsigned.ipa`

如果 Codemagic 出現 Swift 編譯錯誤，把最後一段 log 傳回來即可針對 Xcode 版本修。
