# GoreBox 13.7.9 → iOS REAL PORT Stage 1 V2

這是修正版，**完全不使用隱藏檔案或隱藏資料夾**。

## 修正內容
- 不再使用 `.tools`、`.gitignore` 等隱藏名稱。
- Runtime 工具目錄改成 `RuntimeTools/`。
- 輸出目錄固定為 `BuildArtifacts/`。
- 補回上一版 Mobile 分包漏掉的 `PortOverlay/`。
- 補回完整 `GameRoot/assets/bin/Data` 小檔案、Managed Metadata 與 Resources。
- Codemagic 一開始就建立 `BuildArtifacts/CodemagicStarted.txt`；即使後面失敗，也應有可下載的診斷檔。
- 最終成功輸出 `BuildArtifacts/GoreBox_13.7.9_REAL_Recovered_Unity_Project.zip`。

## GitHub
把本資料夾**所有可見內容**放在 repo 根目錄：

- `codemagic.yaml`
- `README_zh-TW.md`
- `PortOverlay/`
- `SourceData/`
- `Tools/`

不要改 Chunk 名稱。

## Codemagic workflow
選：

`GoreBox REAL Port Stage 1 V2 - Recover Original Unity Project`

Artifacts 使用萬用規則 `BuildArtifacts/**`，所以不會只盯著一個可能尚未產生的 ZIP。
