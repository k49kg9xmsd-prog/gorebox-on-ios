import Foundation

struct BootstrapLibraryResult {
    let name: String
    let loadCode: Int32
    let mappedBytes: Int
    let segments: Int
    let relocationsApplied: Int
    let relocationsTotal: Int
    let unresolved: [String]
    let hostPageSize: Int
    let wxCollisionPages: Int
    let rwxPages: Int
    let rxFallbackPages: Int
    let executedProbe: String?

    var loaded: Bool { loadCode == 0 }
    var fullyRelocated: Bool { loadCode == 0 && unresolved.isEmpty && relocationsApplied == relocationsTotal }
}

struct GoreBoxBootstrapReport {
    let libraries: [BootstrapLibraryResult]
    let libmainJNIResult: Int32?
    let libmainMappedRetReturned: Bool
    let rayFireFullImageReturned: Bool

    var text: String {
        var out: [String] = []
        out.append("GoreBoxRunner Bootstrap 0.2.2")
        out.append("Target: imported GoreBox 13.7.9 Android ARM64")
        out.append("Mode: real PT_LOAD + relocation patching + compatibility shims")
        out.append("")
        for r in libraries {
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append(r.name)
            out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            out.append("ELF image map: \(r.loaded ? "✅" : "❌") (code \(r.loadCode))")
            out.append("Mapped span: \(ByteCountFormatter.string(fromByteCount: Int64(r.mappedBytes), countStyle: .memory))")
            out.append("PT_LOAD segments: \(r.segments)")
            out.append("Relocations applied: \(r.relocationsApplied)/\(r.relocationsTotal)")
            out.append("Unresolved after shim table: \(r.unresolved.count)")
            out.append("Host page size: \(r.hostPageSize / 1024) KB")
            out.append("4K→host-page W+X collisions: \(r.wxCollisionPages)")
            if r.rwxPages > 0 { out.append("RWX host pages: \(r.rwxPages) (unexpected in 0.2.2)") }
            if r.rxFallbackPages > 0 { out.append("W^X collision pages frozen RX: \(r.rxFallbackPages) ⚠️ bootstrap-only") }
            if !r.unresolved.isEmpty { out.append("  • " + r.unresolved.joined(separator: "\n  • ")) }
            if let p = r.executedProbe { out.append(p) }
            out.append("")
        }
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("Controlled execution")
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("libmain.so FULL mapped-image RET sanity probe: \(libmainMappedRetReturned ? "✅ returned" : "not reached")")
        if let jni = libmainJNIResult {
            out.append(String(format: "libmain.so JNI_OnLoad via fake JavaVM: %@ (0x%08X)", jni == 0x00010006 ? "✅" : "⚠️", UInt32(bitPattern: jni)))
        } else {
            out.append("libmain.so JNI_OnLoad: not reached")
        }
        out.append("RayFire GetTestIntValue from FULL mapped ELF image: \(rayFireFullImageReturned ? "✅ returned" : "not reached")")
        out.append("")
        out.append("Current launch boundary:")
        out.append("✅ APK import")
        out.append("✅ Android ARM64 executable memory")
        out.append("✅ Whole-ELF PT_LOAD mapping")
        out.append("✅ RELATIVE / GLOB_DAT / JUMP_SLOT / ABS64 patcher")
        out.append("✅ first Bionic/Linux/liblog compatibility shims")
        out.append("✅ controlled full-image Android code calls (when lines above passed)")
        out.append("⚠️ ANativeWindow/EGL entries are still bootstrap stubs, not a real drawable surface")
        out.append("⚠️ Unity JNI_OnLoad is intentionally not auto-called yet; the next graphics bridge must give it a real window/EGL backend")
        return out.joined(separator: "\n")
    }
}

enum BootstrapLoaderError: LocalizedError {
    case missingBaseAddress
    case symbolMissing(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseAddress: return "The imported library could not expose its bytes."
        case .symbolMissing(let s): return "Expected exported symbol was not found: \(s)"
        }
    }
}

enum BootstrapLoader {
    static func run(progress: @escaping (String, Float) -> Void) throws -> GoreBoxBootstrapReport {
        let order = ["libmain.so", "libRF_CNative_andr.so", "libil2cpp.so", "libunity.so"]
        var results: [BootstrapLibraryResult] = []
        var mainResult: Int32?
        var libmainRetReturned = false
        var rayReturned = false

        ImportedGame.bootstrapCheckpointURL.path.withCString { gbr_set_checkpoint_path($0) }
        gbr_checkpoint_now("bootstrap start")

        for (index, name) in order.enumerated() {
            guard let lib = ImportedGame.requiredLibraries.first(where: { $0.fileName == name }) else { continue }
            let defaults = UserDefaults.standard
            func checkpoint(_ value: String) {
                defaults.set(value, forKey: "BootstrapCheckpoint")
                defaults.synchronize()
                value.withCString { gbr_checkpoint_now($0) }
            }
            checkpoint("before load: \(name)")
            progress("Loading + relocating \(name)…", Float(index) / Float(order.count))
            let data = try ImportedGame.load(lib)
            var image = GBRELFImage()
            var probeText: String?
            var unresolved: [String] = []
            var code: Int32 = -999

            try data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw BootstrapLoaderError.missingBaseAddress }
                checkpoint("inside ELF loader: \(name)")
                code = gbr_elf_load_image(base, data.count, &image)
                checkpoint("ELF mapped + protected: \(name), code=\(code)")
                if image.unresolved_count > 0 {
                    let cap = min(Int(image.unresolved_count), 16)
                    for i in 0..<cap {
                        if let p = gbr_elf_unresolved_at(&image, UInt32(i)) { unresolved.append(String(cString: p)) }
                    }
                }
                guard code == 0 else { return }

                if name == "libmain.so", unresolved.isEmpty {
                    // GoreBox 13.7.9 libmain has a plain `ret` at vaddr 0x93C.
                    // Executing it from the FULL mapped image proves host-page
                    // permissions/cache coherency before we involve fake JNI callbacks.
                    if ImportedGame.metadata()?.sha256.lowercased() == ImportedGame.known1379SHA256,
                       let retProbe = gbr_elf_address_for_vaddr(&image, 0x93C) {
                        checkpoint("about to CALL libmain full-image RET sanity probe")
                        gbr_call_void_function(retProbe)
                        checkpoint("returned from libmain full-image RET sanity probe")
                        libmainRetReturned = true
                    }
                    if let sym = gbr_elf_find_symbol(base, data.count, &image, "JNI_OnLoad") {
                        checkpoint("about to CALL libmain JNI_OnLoad")
                        mainResult = gbr_call_fake_jni_onload(sym)
                        checkpoint("returned from libmain JNI_OnLoad")
                        probeText = String(format: "JNI_OnLoad controlled call: %@ 0x%08X", mainResult == 0x00010006 ? "✅" : "⚠️", UInt32(bitPattern: mainResult ?? -1))
                    } else {
                        probeText = "JNI_OnLoad controlled call: ❌ symbol missing"
                    }
                }

                if name == "libRF_CNative_andr.so", unresolved.isEmpty {
                    if let sym = gbr_elf_find_symbol(base, data.count, &image, "GetTestIntValue") {
                        checkpoint("about to CALL full-image RayFire GetTestIntValue")
                        gbr_call_void_function(sym)
                        checkpoint("returned from full-image RayFire GetTestIntValue")
                        rayReturned = true
                        probeText = "Full mapped/relocated RayFire image call: ✅ returned to iOS"
                    } else {
                        probeText = "RayFire full-image call: ❌ GetTestIntValue missing"
                    }
                }
            }

            results.append(BootstrapLibraryResult(
                name: name,
                loadCode: code,
                mappedBytes: Int(image.mapping_size),
                segments: Int(image.load_segment_count),
                relocationsApplied: Int(image.relocation_applied),
                relocationsTotal: Int(image.relocation_total),
                unresolved: unresolved,
                hostPageSize: Int(image.host_page_size),
                wxCollisionPages: Int(image.wx_collision_pages),
                rwxPages: Int(image.rwx_pages),
                rxFallbackPages: Int(image.rx_fallback_pages),
                executedProbe: probeText
            ))
            gbr_elf_unload_image(&image)
            progress("Finished \(name)", Float(index + 1) / Float(order.count))
        }
        UserDefaults.standard.set("completed", forKey: "BootstrapCheckpoint")
        UserDefaults.standard.synchronize()
        gbr_checkpoint_now("completed")
        return GoreBoxBootstrapReport(libraries: results, libmainJNIResult: mainResult, libmainMappedRetReturned: libmainRetReturned, rayFireFullImageReturned: rayReturned)
    }
}
