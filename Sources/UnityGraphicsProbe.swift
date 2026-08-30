import Foundation

struct RegisteredUnityNative {
    let className: String
    let name: String
    let signature: String
    let address: UInt
}

struct UnityGraphicsProbeReport {
    let graphicsSelfTest: Bool
    let unityLoadCode: Int32
    let initializerCode: Int32?
    let initializerTotal: Int
    let initializerRan: Int
    let unityJNIResult: Int32?
    let relocationApplied: Int
    let relocationTotal: Int
    let unresolvedCount: Int
    let natives: [RegisteredUnityNative]

    var text: String {
        var out: [String] = []
        out.append("GoreBoxRunner Graphics Bridge 0.3.3")
        out.append("Target: GoreBox 13.7.9 / Unity Android ARM64")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("iOS drawable / EGL bridge")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("CAEAGLLayer + EAGLContext self-test: \(graphicsSelfTest ? "✅ presented" : "❌ failed")")
        out.append("Drawable: \(gbr_ios_gles_width()) × \(gbr_ios_gles_height())")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("libunity.so Android linker lifecycle")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("ELF map: \(unityLoadCode == 0 ? "✅" : "❌") (code \(unityLoadCode))")
        out.append("Relocations: \(relocationApplied)/\(relocationTotal)")
        out.append("Unresolved: \(unresolvedCount)")
        out.append("DT_INIT + DT_INIT_ARRAY discovered: \(initializerTotal)")
        if let initCode = initializerCode {
            out.append("Initializers: \(initCode == 0 ? "✅" : "❌") \(initializerRan)/\(initializerTotal) (code \(initCode))")
        } else {
            out.append("Initializers: not reached")
        }
        if let jni = unityJNIResult {
            out.append(String(format: "Unity JNI_OnLoad: %@ 0x%08X", jni == 0x00010006 ? "✅" : "⚠️", UInt32(bitPattern: jni)))
        } else {
            out.append("Unity JNI_OnLoad: not reached")
        }
        out.append("Registered native methods captured: \(natives.count)")
        out.append("")
        for n in natives {
            out.append("• \(n.className).\(n.name) \(n.signature) @ 0x\(String(n.address, radix: 16).uppercased())")
        }
        out.append("")
        let names = Set(natives.map(\.name))
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("Next lifecycle gates")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        for wanted in ["nativeRecreateGfxState", "nativeRender", "nativeResume", "nativePause", "nativeDone", "nativeFocusChanged"] {
            out.append("\(names.contains(wanted) ? "✅" : "⚠️") \(wanted)")
        }
        out.append("")
        out.append("0.3.3 is the batch ABI pass: Bionic TLS pthread keys, mutex/cond/once, semaphores, signal setup, Linux mmap flags, Android 4 KiB guest page reporting, Android-arm64 syscall translation, and Android .so dlopen/dlsym routing are all intercepted before Darwin. If the process is terminated, reopen GoreBoxRunner; the durable checkpoint identifies the constructor or compatibility call.")
        return out.joined(separator: "\n")
    }
}

enum UnityGraphicsProbeError: LocalizedError {
    case missingUnity
    case bytesUnavailable
    case initializerFailed(Int32, Int, Int)
    case jniMissing

    var errorDescription: String? {
        switch self {
        case .missingUnity: return "libunity.so is missing from the imported APK."
        case .bytesUnavailable: return "Could not access libunity.so bytes."
        case let .initializerFailed(code, ran, total): return "libunity.so initializer chain stopped with code \(code) after \(ran)/\(total)."
        case .jniMissing: return "libunity.so JNI_OnLoad export was not found."
        }
    }
}

enum UnityGraphicsProbe {
    static func run(graphicsSelfTest: Bool) throws -> UnityGraphicsProbeReport {
        guard let lib = ImportedGame.requiredLibraries.first(where: { $0.fileName == "libunity.so" }) else {
            throw UnityGraphicsProbeError.missingUnity
        }
        let data = try ImportedGame.load(lib)
        var image = GBRELFImage()
        var loadCode: Int32 = -999
        var initCode: Int32?
        var jniResult: Int32?

        ImportedGame.bootstrapCheckpointURL.path.withCString { gbr_set_checkpoint_path($0) }
        gbr_checkpoint_now("graphics 0.3.3: before libunity ELF load")
        gbr_jni_reset_registered_natives()

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw UnityGraphicsProbeError.bytesUnavailable
            }
            loadCode = gbr_elf_load_image(base, data.count, &image)
            gbr_checkpoint_now("graphics 0.3.3: libunity ELF mapped + relocated")
            guard loadCode == 0 else { return }

            gbr_checkpoint_now("graphics 0.3.3: about to execute libunity DT_INIT/DT_INIT_ARRAY")
            let rc = gbr_elf_run_initializers(&image)
            initCode = rc
            guard rc == 0 else {
                throw UnityGraphicsProbeError.initializerFailed(rc, Int(image.initializers_ran), Int(image.initializers_total))
            }
            gbr_checkpoint_now("graphics 0.3.3: libunity initializers completed")

            guard let onLoad = gbr_elf_find_symbol(base, data.count, &image, "JNI_OnLoad") else {
                throw UnityGraphicsProbeError.jniMissing
            }
            gbr_checkpoint_now("graphics 0.3.3: about to CALL libunity JNI_OnLoad AFTER constructors")
            jniResult = gbr_call_fake_jni_onload(onLoad)
            gbr_checkpoint_now("graphics 0.3.3: returned from libunity JNI_OnLoad")
        }

        var captured: [RegisteredUnityNative] = []
        let count = Int(gbr_jni_registered_native_count())
        if count > 0 {
            for i in 0..<count {
                let idx = UInt32(i)
                let clazz = gbr_jni_registered_class_at(idx).map { String(cString: $0) } ?? "<unknown>"
                let name = gbr_jni_registered_name_at(idx).map { String(cString: $0) } ?? "<unnamed>"
                let sig = gbr_jni_registered_signature_at(idx).map { String(cString: $0) } ?? ""
                let fn = UInt(gbr_jni_registered_function_at(idx))
                captured.append(.init(className: clazz, name: name, signature: sig, address: fn))
            }
        }

        let report = UnityGraphicsProbeReport(
            graphicsSelfTest: graphicsSelfTest,
            unityLoadCode: loadCode,
            initializerCode: initCode,
            initializerTotal: Int(image.initializers_total),
            initializerRan: Int(image.initializers_ran),
            unityJNIResult: jniResult,
            relocationApplied: Int(image.relocation_applied),
            relocationTotal: Int(image.relocation_total),
            unresolvedCount: Int(image.unresolved_count),
            natives: captured
        )
        gbr_elf_unload_image(&image)
        gbr_checkpoint_now("graphics 0.3.3: completed")
        return report
    }
}
