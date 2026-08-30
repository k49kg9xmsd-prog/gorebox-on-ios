# GoreBox iOS Codemagic POC 0.1

這是 **第一階段打包與操作鏈測試版**，不是完整 GoreBox 移植，也沒有包含原遊戲素材。

## 這版在測什麼
- iPhone / iPad 原生 ARM64 編譯鏈
- 橫向全螢幕
- 左側虛擬搖桿
- 右側滑動視角
- Jump
- Fire
- SceneKit 3D 物理
- 射擊物理方塊並施加衝量
- Codemagic 自動產生 unsigned IPA

## 為什麼第一版不用 Unity
Codemagic 的 Unity 雲端建置目前要求 Unity Plus / Pro 授權。這個 POC 先用 Apple 原生 SceneKit，把「Codemagic → iOS device app → IPA → 重簽 → 真機啟動」整條鏈先驗證掉。

等這版真機正常，再進 Phase B：Unity 2021.3.28f1 重建 GoreBox 地圖/資源與遊戲邏輯。

## Codemagic 使用方式
1. 把這個資料夾完整放到 GitHub/GitLab/Bitbucket repository 根目錄。
2. 在 Codemagic 新增該 repository。
3. 選擇 `codemagic.yaml`。
4. 選 workflow：`GoreBox POC - Unsigned iPhone/iPad IPA`。
5. Build。
6. 完成後 Artifacts 會出現：`GoreBoxPOC-unsigned.ipa`。

這個 IPA **沒有 Apple 簽名**。安裝到實機前，需要用你自己的簽名方式重新簽名。

## 不需要設定的東西
- 不需要 Unity
- 不需要 Unity Plus / Pro
- 不需要 CocoaPods
- 不需要 Google Play / Ads / Photon
- 產出 unsigned IPA 時不需要 Apple Developer signing profile

## 操作
- 左圓盤：移動
- 右半螢幕拖曳：轉視角
- JUMP：跳
- FIRE：射擊；打到箱子會推飛
- RESET：重置物理箱牆與玩家位置

## 專案結構
- `project.yml`：XcodeGen 專案規格
- `codemagic.yaml`：Codemagic 工作流
- `GoreBoxPOC/Sources/`：Swift / SceneKit POC

## Phase B 預定
- 換回 Unity 2021.3.28f1
- 匯入合法可用的已還原資源
- 重建 Menu / Player / Mobile UI
- 第一張原版地圖載入測試
- 再逐步加入武器、NPC、Gore、RayFire iOS
