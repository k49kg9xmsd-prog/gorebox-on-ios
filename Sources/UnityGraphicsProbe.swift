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
    let unityJNIResult: Int32?
    let relocationApplied: Int
    let relocationTotal: Int
    let unresolvedCount: Int
    let natives: [RegisteredUnityNative]

    var text: String {
        var out: [String] = []
        out.append("GoreBoxRunner Graphics Bridge 0.3")
        out.append("Target: GoreBox 13.7.9 / Unity Android ARM64")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("iOS drawable / EGL bridge")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("CAEAGLLayer + EAGLContext self-test: \(graphicsSelfTest ? "✅ presented" : "❌ failed")")
        out.append("Drawable: \(gbr_ios_gles_width()) × \(gbr_ios_gles_height())")
        out.append("")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("libunity.so JNI registration")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("ELF map: \(unityLoadCode == 0 ? "✅" : "❌") (code \(unityLoadCode))")
        out.append("Relocations: \(relocationApplied)/\(relocationTotal)")
        out.append("Unresolved: \(unresolvedCount)")
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
        out.append("This build establishes a REAL iOS OpenGL ES drawable and captures Unity's actual JNI native entrypoints. It does not call nativeRender yet because UnityPlayer/Activity lifecycle state must be constructed first.")
        return out.joined(separator: "\n")
    }
}

enum UnityGraphicsProbeError: LocalizedError {
    case missingUnity
    case bytesUnavailable
    case jniMissing

    var errorDescription: String? {
        switch self {
        case .missingUnity: return "libunity.so is missing from the imported APK."
        case .bytesUnavailable: return "Could not access libunity.so bytes."
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
        var jniResult: Int32?

        ImportedGame.bootstrapCheckpointURL.path.withCString { gbr_set_checkpoint_path($0) }
        gbr_checkpoint_now("graphics 0.3: before libunity ELF load")
        gbr_jni_reset_registered_natives()

        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw UnityGraphicsProbeError.bytesUnavailable
            }
            loadCode = gbr_elf_load_image(base, data.count, &image)
            gbr_checkpoint_now("graphics 0.3: libunity ELF mapped")
            guard loadCode == 0 else { return }
            guard let onLoad = gbr_elf_find_symbol(base, data.count, &image, "JNI_OnLoad") else {
                throw UnityGraphicsProbeError.jniMissing
            }
            gbr_checkpoint_now("graphics 0.3: about to CALL libunity JNI_OnLoad")
            jniResult = gbr_call_fake_jni_onload(onLoad)
            gbr_checkpoint_now("graphics 0.3: returned from libunity JNI_OnLoad")
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
            unityJNIResult: jniResult,
            relocationApplied: Int(image.relocation_applied),
            relocationTotal: Int(image.relocation_total),
            unresolvedCount: Int(image.unresolved_count),
            natives: captured
        )
        gbr_elf_unload_image(&image)
        gbr_checkpoint_now("graphics 0.3: completed")
        return report
    }
}
