import Foundation

private func launchCheckpoint(_ text: String) {
    text.withCString { gbr_checkpoint_now($0) }
}

struct UnityLaunchLibraryReport {
    let name: String
    let mapped: Bool
    let relocationsApplied: Int
    let relocationsTotal: Int
    let unresolved: Int
    let initializersRan: Int
    let initializersTotal: Int
    let exportsRegistered: Int
    let jniResult: Int32?
}

struct UnityLaunchReport {
    let libraries: [UnityLaunchLibraryReport]
    let registeredNatives: Int
    let hasRecreate: Bool
    let hasResume: Bool
    let hasRender: Bool
    let firstRenderResult: Int32?
    let continuousRenderStarted: Bool

    var text: String {
        var out: [String] = []
        out.append("GoreBoxRunner Launch 0.4")
        out.append("Target: imported GoreBox 13.7.9 Android ARM64")
        out.append("Mode: persistent multi-ELF runtime + UnityPlayer lifecycle")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("Persistent Android runtime")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for lib in libraries {
            out.append("\(lib.name): \(lib.mapped ? "✅" : "❌") reloc \(lib.relocationsApplied)/\(lib.relocationsTotal), init \(lib.initializersRan)/\(lib.initializersTotal), exports \(lib.exportsRegistered), unresolved \(lib.unresolved)" + (lib.jniResult.map { String(format: ", JNI 0x%08X", UInt32(bitPattern: $0)) } ?? ""))
        }
        out.append("")
        out.append("Mapped guest exports are now visible to Android dlopen/dlsym, including libil2cpp.so and RayFire plugin exports.")
        out.append("Runtime assets: extracted from the imported APK into Application Support/assets/bin/Data.")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("UnityPlayer lifecycle")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("Registered natives captured: \(registeredNatives)")
        out.append("\(hasRecreate ? "✅" : "❌") nativeRecreateGfxState (ILandroid/view/Surface;)V")
        out.append("\(hasResume ? "✅" : "❌") nativeResume ()V")
        out.append("\(hasRender ? "✅" : "❌") nativeRender ()Z")
        if let firstRenderResult {
            out.append("First nativeRender call: ✅ returned \(firstRenderResult)")
        } else {
            out.append("First nativeRender call: not reached")
        }
        out.append("Continuous render loop: \(continuousRenderStarted ? "▶️ started" : "⏸ not started")")
        out.append("")
        out.append("Launch 0.4.1 keeps the real lifecycle path and adds a Bionic arm64 setjmp/longjmp bridge. 0.4 was the first build that actually calls the real GoreBox UnityPlayer lifecycle entrypoints. It still uses a compatibility Activity/JNI surface, so success here means first-frame/runtime progress — not yet a guarantee that touch/audio/save systems are playable.")
        return out.joined(separator: "\n")
    }
}

enum UnityLaunchError: LocalizedError {
    case missingLibrary(String)
    case mapFailed(String, Int32)
    case initializerFailed(String, Int32, Int, Int)
    case jniMissing(String)
    case requiredNativeMissing(String)
    case graphicsNotCurrent

    var errorDescription: String? {
        switch self {
        case .missingLibrary(let n): return "Missing imported library: \(n)"
        case .mapFailed(let n, let c): return "\(n) ELF map failed (code \(c))."
        case .initializerFailed(let n, let c, let ran, let total): return "\(n) initializer chain stopped (code \(c), \(ran)/\(total))."
        case .jniMissing(let n): return "\(n) JNI_OnLoad export was not found."
        case .requiredNativeMissing(let n): return "Unity did not register required native entrypoint: \(n)."
        case .graphicsNotCurrent: return "iOS OpenGL ES drawable/context is not current."
        }
    }
}

private final class PersistentGuestImage {
    let library: ImportedLibrary
    let data: Data
    var image = GBRELFImage()
    var loaded = false
    var exportsRegistered = 0
    var jniResult: Int32?

    init(library: ImportedLibrary) throws {
        self.library = library
        self.data = try ImportedGame.load(library)
    }

    func mapAndInitialize(registerExports: Bool = true, callJNI: Bool = false) throws {
        var loadCode: Int32 = -999
        var initCode: Int32 = -999
        var foundJNI: UnsafeMutableRawPointer?
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw UnityLaunchError.mapFailed(library.fileName, -998)
            }
            loadCode = gbr_elf_load_image(base, data.count, &image)
            guard loadCode == 0 else { return }
            loaded = true
            if registerExports {
                library.fileName.withCString { name in
                    exportsRegistered = Int(gbr_guest_exports_register(name, base, data.count, &image))
                }
            }
            initCode = gbr_elf_run_initializers(&image)
            if callJNI && initCode == 0 {
                foundJNI = gbr_elf_find_symbol(base, data.count, &image, "JNI_OnLoad")
            }
        }
        guard loadCode == 0 else { throw UnityLaunchError.mapFailed(library.fileName, loadCode) }
        guard initCode == 0 else {
            throw UnityLaunchError.initializerFailed(library.fileName, initCode, Int(image.initializers_ran), Int(image.initializers_total))
        }
        if callJNI {
            guard let foundJNI else { throw UnityLaunchError.jniMissing(library.fileName) }
            jniResult = gbr_call_fake_jni_onload(foundJNI)
        }
    }

    var report: UnityLaunchLibraryReport {
        .init(
            name: library.fileName,
            mapped: loaded,
            relocationsApplied: Int(image.relocation_applied),
            relocationsTotal: Int(image.relocation_total),
            unresolved: Int(image.unresolved_count),
            initializersRan: Int(image.initializers_ran),
            initializersTotal: Int(image.initializers_total),
            exportsRegistered: exportsRegistered,
            jniResult: jniResult
        )
    }

    deinit {
        if loaded { gbr_elf_unload_image(&image) }
    }
}

final class UnityLaunchRuntime {
    static let shared = UnityLaunchRuntime()

    private var images: [PersistentGuestImage] = []
    private var renderFunction: UnsafeMutableRawPointer?
    private var pauseFunction: UnsafeMutableRawPointer?
    private var doneFunction: UnsafeMutableRawPointer?
    private var renderLoopRunning = false
    private let stateLock = NSLock()
    private let renderQueue = DispatchQueue(label: "GoreBoxRunner.UnityRender", qos: .userInteractive)
    private var frameCounter = 0

    private init() {}

    func prepareAndLaunch(progress: @escaping (String, Double) -> Void) throws -> UnityLaunchReport {
        stopRenderLoop()
        images.removeAll()
        gbr_guest_exports_reset()
        gbr_jni_reset_registered_natives()

        ImportedGame.bootstrapCheckpointURL.path.withCString { gbr_set_checkpoint_path($0) }
        ImportedGame.gameRoot.path.withCString { gbr_set_runtime_root($0) }
        _ = FileManager.default.changeCurrentDirectoryPath(ImportedGame.gameRoot.path)

        launchCheckpoint("Launch 0.4.1: extracting/checking Unity runtime assets")
        try ImportedGame.ensureRuntimeAssets { message, value in
            progress(message, value * 0.25)
        }

        guard gbr_ios_gles_make_current() != 0 else { throw UnityLaunchError.graphicsNotCurrent }
        launchCheckpoint("Launch 0.4.1: iOS drawable is current")

        let order: [(String, Bool)] = [
            ("libmain.so", true),
            ("libRF_CNative_andr.so", false),
            ("libil2cpp.so", true),
            ("libunity.so", true)
        ]

        for (index, item) in order.enumerated() {
            guard let lib = ImportedGame.requiredLibraries.first(where: { $0.fileName == item.0 }) else {
                throw UnityLaunchError.missingLibrary(item.0)
            }
            let image = try PersistentGuestImage(library: lib)
            if item.0 == "libunity.so" { gbr_jni_reset_registered_natives() }
            launchCheckpoint("Launch 0.4.1: mapping \(item.0)")
            try image.mapAndInitialize(registerExports: true, callJNI: item.1)
            images.append(image)
            progress("Loaded \(item.0) — reloc \(image.image.relocation_applied)/\(image.image.relocation_total), init \(image.image.initializers_ran)/\(image.image.initializers_total)", 0.25 + Double(index + 1) * 0.12)
        }

        let recreateValue = gbr_jni_registered_function_named("nativeRecreateGfxState")
        let resumeValue = gbr_jni_registered_function_named("nativeResume")
        let renderValue = gbr_jni_registered_function_named("nativeRender")
        let focusValue = gbr_jni_registered_function_named("nativeFocusChanged")
        let surfaceChangedValue = gbr_jni_registered_function_named("nativeSendSurfaceChangedEvent")
        let pauseValue = gbr_jni_registered_function_named("nativePause")
        let doneValue = gbr_jni_registered_function_named("nativeDone")

        guard recreateValue != 0 else { throw UnityLaunchError.requiredNativeMissing("nativeRecreateGfxState") }
        guard resumeValue != 0 else { throw UnityLaunchError.requiredNativeMissing("nativeResume") }
        guard renderValue != 0 else { throw UnityLaunchError.requiredNativeMissing("nativeRender") }

        let recreate = UnsafeMutableRawPointer(bitPattern: recreateValue)!
        let resume = UnsafeMutableRawPointer(bitPattern: resumeValue)!
        let render = UnsafeMutableRawPointer(bitPattern: renderValue)!
        let focus = focusValue == 0 ? nil : UnsafeMutableRawPointer(bitPattern: focusValue)
        let surfaceChanged = surfaceChangedValue == 0 ? nil : UnsafeMutableRawPointer(bitPattern: surfaceChangedValue)

        renderFunction = render
        pauseFunction = pauseValue == 0 ? nil : UnsafeMutableRawPointer(bitPattern: pauseValue)
        doneFunction = doneValue == 0 ? nil : UnsafeMutableRawPointer(bitPattern: doneValue)

        progress("Calling real UnityPlayer nativeRecreateGfxState…", 0.78)
        launchCheckpoint("Launch 0.4.1: about to CALL nativeRecreateGfxState(0, Surface)")
        _ = gbr_jni_call_native_recreate_gfx_state(recreate, 0)
        if let surfaceChanged { gbr_jni_call_native_surface_changed(surfaceChanged) }
        if let focus { gbr_jni_call_native_focus_changed(focus, 1) }

        progress("Calling real UnityPlayer nativeResume…", 0.86)
        gbr_jni_call_native_resume(resume)

        progress("Calling first real UnityPlayer nativeRender frame…", 0.94)
        launchCheckpoint("Launch 0.4.1: about to CALL first nativeRender")
        _ = gbr_ios_gles_make_current()
        let first = gbr_jni_call_native_render(render)
        launchCheckpoint("Launch 0.4.1: first nativeRender returned")
        _ = gbr_ios_gles_swap_buffers()
        progress("First nativeRender returned \(first)", 1.0)

        let nativeCount = Int(gbr_jni_registered_native_count())
        let reports = images.map(\.report)
        let shouldLoop = first == 1
        if shouldLoop { startRenderLoop() }

        return UnityLaunchReport(
            libraries: reports,
            registeredNatives: nativeCount,
            hasRecreate: recreateValue != 0,
            hasResume: resumeValue != 0,
            hasRender: renderValue != 0,
            firstRenderResult: first,
            continuousRenderStarted: shouldLoop
        )
    }

    func startRenderLoop() {
        stateLock.lock()
        if renderLoopRunning { stateLock.unlock(); return }
        renderLoopRunning = true
        frameCounter = 0
        stateLock.unlock()

        renderQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.stateLock.lock()
                let running = self.renderLoopRunning
                self.stateLock.unlock()
                guard running, let render = self.renderFunction else { break }

                autoreleasepool {
                    _ = gbr_ios_gles_make_current()
                    self.frameCounter += 1
                    if self.frameCounter <= 5 || self.frameCounter % 120 == 0 {
                        launchCheckpoint("Launch 0.4.1: nativeRender loop frame \(self.frameCounter)")
                    }
                    let result = gbr_jni_call_native_render(render)
                    _ = gbr_ios_gles_swap_buffers()
                    if result < 0 {
                        self.stateLock.lock(); self.renderLoopRunning = false; self.stateLock.unlock()
                    }
                }
                Thread.sleep(forTimeInterval: 1.0 / 60.0)
            }
        }
    }

    func stopRenderLoop() {
        stateLock.lock()
        let wasRunning = renderLoopRunning
        renderLoopRunning = false
        stateLock.unlock()
        if wasRunning, let pauseFunction { _ = gbr_jni_call_native_pause(pauseFunction) }
    }

    func shutdown() {
        stopRenderLoop()
        if let doneFunction { _ = gbr_jni_call_native_done(doneFunction) }
        renderFunction = nil
        pauseFunction = nil
        doneFunction = nil
        images.removeAll()
        gbr_guest_exports_reset()
    }
}
