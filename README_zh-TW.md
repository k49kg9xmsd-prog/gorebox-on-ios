# GoreBoxRunner Graphics Bridge 0.3

這版建立在 Bootstrap 0.2.2 實機成功結果上：完整 ELF mapping、relocation、libmain JNI_OnLoad、RayFire full-image call 都已通過。

## 新增
- 真正的 iOS `CAEAGLLayer` + `EAGLContext` drawable
- EGL shim 由 bootstrap token 升級成可 present 的 OpenGL ES bridge
- `ANativeWindow_getWidth/Height` 改讀真 drawable 尺寸
- `eglCreateContext / eglCreateWindowSurface / eglMakeCurrent / eglSwapBuffers / eglQuerySurface` 等接到 iOS
- `eglGetProcAddress` 會解析 iOS OpenGLES symbols，並對 framebuffer 0 做 iOS default-FBO wrapper
- 真正呼叫 `libunity.so` 的 `JNI_OnLoad`
- fake JNI `RegisterNatives` 會捕捉 class / method / signature / function pointer
- 報告直接列出 `nativeRender / nativeResume / nativeRecreateGfxState` 等是否存在

## 還不是可玩版
0.3 的目標是建立真 drawable 並取得 Unity lifecycle 真入口。它故意不直接呼叫 `nativeRender`：在 UnityPlayer / Activity / Surface lifecycle 尚未建好時硬呼叫很容易直接崩潰。

Codemagic workflow：`GoreBoxRunner Graphics Bridge 0.3 - Unsigned IPA`
