# GoreBoxRunner Bootstrap 0.2.2

這版針對真機 checkpoint `about to CALL libmain JNI_OnLoad` 後被 LiveContainer 終止。

## 0.2.2 修正
- **完全禁止 RWX guest page**：Android 4 KB RX/RW segment 在 iOS 16 KB host page 發生 W+X collision 時，relocation 完成後直接凍結成 `R-X`，不再先嘗試 `RWX`。
- **ARM64 instruction-cache flush**：任何可執行 host page 在 `mprotect` 前都呼叫 iOS `sys_icache_invalidate`。
- **完整 libmain image RET sanity probe**：GoreBox 13.7.9 的 `libmain.so` 在 vaddr `0x93C` 有原生 `ret`，會先從完整 mapped ELF image 執行它，再進 JNI。這能分辨「整頁不能執行」與「JNI callback 出錯」。
- **耐斷電 checkpoint**：危險步驟直接寫 `bootstrap-checkpoint.txt` 並 `fsync`。
- **JNI 內部 checkpoint**：會記錄 `AttachCurrentThread`、`FindClass`、`RegisterNatives`、`ExceptionClear` 是否真的被 Android `JNI_OnLoad` 呼叫。

## 期待的成功順序
```text
returned from libmain full-image RET sanity probe
JNI callback: AttachCurrentThread entered
JNI callback: FindClass entered
JNI callback: RegisterNatives entered
C bridge: guest JNI_OnLoad returned
```

如果仍被終止，重新開 GoreBoxRunner，彈窗會讀磁碟上最後一個 checkpoint，定位會比 0.2.1 更精確。

## Build
Codemagic workflow：

`GoreBoxRunner Bootstrap 0.2.2 - Unsigned IPA`

輸出：

`GoreBoxRunner-Bootstrap-0.2.2-unsigned.ipa`

這仍是 bootstrap 版本；它不是已完成的 GoreBox iOS 相容層。
