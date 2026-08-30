# GoreBox One-Click Cloud Builder

這個 repo 是「控制器」，不需要把 200MB+ 的 GoreBox 資料 commit 到 GitHub。

## 最省事的流程

1. 把已合併好的 `GoreBox_iOS_REAL_PORT_STAGE1_MOBILE_V2` 資料夾壓縮成：
   `GoreBoxSource.zip`
2. 在你的 GitHub repo 建一個 **Release**，把 `GoreBoxSource.zip` 當 Release asset 上傳。
   - GitHub Release asset 單檔可到 2 GiB，所以不會撞一般 repo 網頁的 25 MiB 限制。
3. 把這個 OneClick builder repo 的小檔案 commit 到 GitHub。
4. 在 Codemagic 的 Environment variables 新增：
   `SOURCE_ARCHIVE_URL`
   值填 Release asset 的直接下載網址，例如：
   `https://github.com/OWNER/REPO/releases/download/source/GoreBoxSource.zip`
5. 先跑：
   `GoreBox One-Click - Recover Unity Project`
   - 不需要 Unity 授權。
   - 產物：`BuildArtifacts/GoreBox_Recovered_Unity_Project.zip`
6. 要直接嘗試產生 IPA，再跑：
   `GoreBox One-Click - Recover + Unity iOS + Unsigned IPA`
   並在 Codemagic 設定 `UNITY_EMAIL`、`UNITY_PASSWORD`、`UNITY_SERIAL`。

## 重要限制

Codemagic 官方要求雲端 Unity build 使用 Unity Plus / Pro license。沒有 Plus/Pro 時，Recover workflow 仍可完整跑 AssetRipper，但 Full IPA workflow 會在 Unity 授權檢查停止。

即使 Unity 授權正確，APK 還原的工程仍可能有缺失腳本、shader、plugin 或序列化引用；所以 Full IPA 是「自動跑到第一個真正的移植錯誤」，不是保證一次成功。所有 log 都保存在 `BuildArtifacts/`，方便下一輪修。

## 沒有隱藏檔

本 repo 不依賴 `.tools`、`.gitignore` 或任何 `.` 開頭路徑。
