import Foundation
import Darwin

struct SafeLibraryDiagnostic {
    let name: String
    let mapped: Bool
    let mappedSpan: UInt64
    let mapError: String?
    let relocationCount: Int
    let relocationTypes: [(UInt32, Int)]
    let hostResolved: Int
    let totalImports: Int
    let unresolved: [String]
    let androidLog: [String]
    let androidNative: [String]
    let egl: [String]
    let bionic: [String]
    let bundledDependencyNames: [String]
    let otherNeededLibraries: [String]

    var hostCoveragePercent: Int {
        guard totalImports > 0 else { return 100 }
        return Int((Double(hostResolved) / Double(totalImports) * 100.0).rounded())
    }
}

struct JITProbeResult {
    let rwMapping: Bool
    let rxTransition: Bool
    let mapJIT: Bool
    let detail: String
}

private struct DReader {
    let data: Data

    func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= data.count else { return nil }
        return UInt16(data[o]) | (UInt16(data[o + 1]) << 8)
    }
    func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[o + i]) << UInt32(i * 8) }
        return v
    }
    func u64(_ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[o + i]) << UInt64(i * 8) }
        return v
    }
}

private struct DSegment {
    let offset: UInt64
    let vaddr: UInt64
    let fileSize: UInt64
    let memSize: UInt64
}

private struct DSection {
    let type: UInt32
    let offset: UInt64
    let size: UInt64
    let entrySize: UInt64
}

enum CompatibilityDiagnostics {
    private static let PT_LOAD: UInt32 = 1
    private static let SHT_RELA: UInt32 = 4
    private static let SHT_REL: UInt32 = 9

    // Darwin's MAP_JIT value. Kept local so the source also compiles on SDKs where the Swift overlay hides the name.
    private static let mapJITFlag: Int32 = 0x800

    static func analyze(data: Data, basic: ELFReport) -> SafeLibraryDiagnostic {
        let segments = parseSegments(data)
        let mapping = testMemoryMapping(data: data, segments: segments)
        let relocTypes = parseRelocationTypes(data)

        let imports = basic.undefinedSymbols
        var hostResolvedNames = Set<String>()
        if let handle = dlopen(nil, RTLD_NOW) {
            defer { dlclose(handle) }
            for name in imports {
                let found = name.withCString { dlsym(handle, $0) != nil }
                if found { hostResolvedNames.insert(name) }
            }
        }

        let unresolved = imports.filter { !hostResolvedNames.contains($0) }
        let androidLog = unresolved.filter { $0.hasPrefix("__android_log_") }
        let egl = unresolved.filter { $0.hasPrefix("egl") }
        let androidNative = unresolved.filter {
            $0.hasPrefix("ANativeWindow_") ||
            $0.hasPrefix("ALooper_") ||
            $0.hasPrefix("ASensor") ||
            $0.hasPrefix("AAsset") ||
            $0.hasPrefix("AChoreographer") ||
            $0.hasPrefix("AInput") ||
            $0.hasPrefix("AConfiguration")
        }
        let bionic = unresolved.filter { isBionicSpecific($0) }

        let bundledNames = Set(ImportedGame.requiredLibraries.map { $0.fileName })
        let bundledDeps = basic.neededLibraries.filter { bundledNames.contains($0) }
        let virtualSystem = Set(["libc.so", "libm.so", "libdl.so", "libz.so", "liblog.so"])
        let otherNeeded = basic.neededLibraries.filter { !bundledNames.contains($0) && !virtualSystem.contains($0) }

        return SafeLibraryDiagnostic(
            name: basic.fileName,
            mapped: mapping.ok,
            mappedSpan: mapping.span,
            mapError: mapping.error,
            relocationCount: relocTypes.values.reduce(0, +),
            relocationTypes: relocTypes.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            },
            hostResolved: hostResolvedNames.count,
            totalImports: imports.count,
            unresolved: unresolved,
            androidLog: androidLog,
            androidNative: androidNative,
            egl: egl,
            bionic: bionic,
            bundledDependencyNames: bundledDeps,
            otherNeededLibraries: otherNeeded
        )
    }

    static func jitProbe() -> JITProbeResult {
        let page = max(Int(getpagesize()), 4096)
        var details: [String] = []

        errno = 0
        let rw = mmap(nil, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        let rwOK = rw != nil && rw != MAP_FAILED
        var rxOK = false
        if rwOK, let rwPointer = rw {
            errno = 0
            rxOK = mprotect(rwPointer, page, PROT_READ | PROT_EXEC) == 0
            if !rxOK { details.append("RW→RX mprotect: \(errnoText())") }
            munmap(rwPointer, page)
        } else {
            details.append("RW mmap: \(errnoText())")
        }

        errno = 0
        let jitFlags = MAP_PRIVATE | MAP_ANON | mapJITFlag
        let jit = mmap(nil, page, PROT_READ | PROT_WRITE | PROT_EXEC, jitFlags, -1, 0)
        let jitOK = jit != nil && jit != MAP_FAILED
        if jitOK, let jitPointer = jit {
            munmap(jitPointer, page)
        } else {
            details.append("MAP_JIT RWX: \(errnoText())")
        }

        if details.isEmpty { details.append("Executable-memory permission probes returned success.") }
        return JITProbeResult(rwMapping: rwOK, rxTransition: rxOK, mapJIT: jitOK, detail: details.joined(separator: " | "))
    }

    static func relocationName(_ type: UInt32) -> String {
        switch type {
        case 0: return "NONE"
        case 257: return "ABS64"
        case 1025: return "GLOB_DAT"
        case 1026: return "JUMP_SLOT"
        case 1027: return "RELATIVE"
        case 1032: return "IRELATIVE"
        default: return "TYPE_\(type)"
        }
    }

    static func executionGateText(_ diag: SafeLibraryDiagnostic, jit: JITProbeResult) -> String {
        var blockers: [String] = []
        if !diag.mapped { blockers.append("PT_LOAD mapping failed") }
        if !diag.egl.isEmpty { blockers.append("EGL \(diag.egl.count)") }
        if !diag.androidNative.isEmpty { blockers.append("Android native API \(diag.androidNative.count)") }
        if !diag.androidLog.isEmpty { blockers.append("liblog \(diag.androidLog.count)") }
        if !diag.bionic.isEmpty { blockers.append("Bionic ABI \(diag.bionic.count)") }

        let classified = Set(diag.egl + diag.androidNative + diag.androidLog + diag.bionic)
        let unknown = diag.unresolved.filter { !classified.contains($0) }
        if !unknown.isEmpty { blockers.append("other unresolved \(unknown.count)") }
        if !diag.otherNeededLibraries.isEmpty { blockers.append("needed libs \(diag.otherNeededLibraries.joined(separator: ","))") }
        if !jit.mapJIT && !jit.rxTransition { blockers.append("executable memory unavailable") }

        if blockers.isEmpty {
            return "🟡 Preflight READY — imports/mapping look sufficient for a controlled guest-call experiment."
        }
        return "🔒 Guest execution BLOCKED — " + blockers.joined(separator: "; ")
    }

    private static func isBionicSpecific(_ name: String) -> Bool {
        let exact: Set<String> = [
            "__errno", "__sF", "memalign", "mallinfo", "mallinfo2",
            "__FD_SET_chk", "__FD_ISSET_chk", "__strlen_chk", "__vsnprintf_chk",
            "__snprintf_chk", "__memcpy_chk", "__memmove_chk", "__strcpy_chk",
            "__strcat_chk", "__read_chk", "__write_chk"
        ]
        if exact.contains(name) { return true }
        if name.hasPrefix("__system_property_") { return true }
        if name.hasPrefix("android_") { return true }
        return false
    }

    private static func parseSegments(_ data: Data) -> [DSegment] {
        let r = DReader(data: data)
        guard data.count >= 64,
              data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46,
              data[4] == 2, data[5] == 1 else { return [] }
        let phoff = Int(r.u64(32) ?? 0)
        let entsize = Int(r.u16(54) ?? 0)
        let count = Int(r.u16(56) ?? 0)
        guard entsize >= 56 else { return [] }
        var out: [DSegment] = []
        for i in 0..<count {
            let o = phoff + i * entsize
            guard o >= 0, o + 56 <= data.count else { continue }
            guard r.u32(o) == PT_LOAD else { continue }
            out.append(DSegment(
                offset: r.u64(o + 8) ?? 0,
                vaddr: r.u64(o + 16) ?? 0,
                fileSize: r.u64(o + 32) ?? 0,
                memSize: r.u64(o + 40) ?? 0
            ))
        }
        return out
    }

    private static func testMemoryMapping(data: Data, segments: [DSegment]) -> (ok: Bool, span: UInt64, error: String?) {
        guard let minV = segments.map({ $0.vaddr }).min(),
              let maxV = segments.map({ $0.vaddr &+ $0.memSize }).max(),
              maxV >= minV else {
            return (false, 0, "No valid PT_LOAD range")
        }
        let page = UInt64(max(Int(getpagesize()), 4096))
        let lo = minV & ~(page - 1)
        let hi = (maxV + page - 1) & ~(page - 1)
        let span = hi - lo
        guard span > 0, span <= UInt64(Int.max) else { return (false, span, "Invalid mapping span") }

        errno = 0
        let base = mmap(nil, Int(span), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard base != nil, base != MAP_FAILED, let basePointer = base else { return (false, span, errnoText()) }
        defer { munmap(basePointer, Int(span)) }

        var bad: String?
        data.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { bad = "Data has no base address"; return }
            for s in segments {
                guard s.fileSize <= s.memSize,
                      s.offset <= UInt64(data.count),
                      s.fileSize <= UInt64(data.count) - s.offset else {
                    bad = "Segment exceeds file bounds"
                    return
                }
                let destOffset64 = s.vaddr - lo
                guard destOffset64 <= UInt64(Int.max), s.fileSize <= UInt64(Int.max) else {
                    bad = "Segment offset too large"
                    return
                }
                let dest = basePointer.advanced(by: Int(destOffset64))
                let src = srcBase.advanced(by: Int(s.offset))
                memcpy(dest, src, Int(s.fileSize))
            }
        }
        if let bad { return (false, span, bad) }
        return (true, span, nil)
    }

    private static func parseRelocationTypes(_ data: Data) -> [UInt32: Int] {
        let r = DReader(data: data)
        guard data.count >= 64 else { return [:] }
        let shoff = Int(r.u64(40) ?? 0)
        let entsize = Int(r.u16(58) ?? 0)
        let count = Int(r.u16(60) ?? 0)
        guard entsize >= 64 else { return [:] }
        var sections: [DSection] = []
        for i in 0..<count {
            let o = shoff + i * entsize
            guard o >= 0, o + 64 <= data.count else { continue }
            sections.append(DSection(
                type: r.u32(o + 4) ?? 0,
                offset: r.u64(o + 24) ?? 0,
                size: r.u64(o + 32) ?? 0,
                entrySize: r.u64(o + 56) ?? 0
            ))
        }

        var counts: [UInt32: Int] = [:]
        for s in sections where s.type == SHT_RELA || s.type == SHT_REL {
            let defaultEntry: UInt64 = s.type == SHT_RELA ? 24 : 16
            let entry = s.entrySize == 0 ? defaultEntry : s.entrySize
            guard entry >= 16, s.offset <= UInt64(data.count), s.size <= UInt64(data.count) - s.offset else { continue }
            let n = Int(s.size / entry)
            for i in 0..<n {
                let o64 = s.offset + UInt64(i) * entry
                guard o64 <= UInt64(Int.max) else { continue }
                let o = Int(o64)
                guard let info = r.u64(o + 8) else { continue }
                let type = UInt32(info & 0xFFFF_FFFF)
                counts[type, default: 0] += 1
            }
        }
        return counts
    }

    private static func errnoText() -> String {
        let e = errno
        if let c = strerror(e) { return "errno \(e): \(String(cString: c))" }
        return "errno \(e)"
    }
}
