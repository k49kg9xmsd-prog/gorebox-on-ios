import Foundation
import Darwin

enum GuestProbeError: LocalizedError {
    case invalidELF
    case noSegments
    case targetOutsideLoad
    case mmapFailed(Int32)
    case segmentBounds
    case mprotectFailed(Int32)
    case unexpectedInstruction(String)

    var errorDescription: String? {
        switch self {
        case .invalidELF: return "RayFire file is not a valid ELF64/AArch64 image."
        case .noSegments: return "No PT_LOAD segments were found."
        case .targetOutsideLoad: return "RayFire test address is outside PT_LOAD."
        case .mmapFailed(let e): return "mmap failed: errno \(e)"
        case .segmentBounds: return "ELF segment exceeds file bounds."
        case .mprotectFailed(let e): return "RW→RX failed: errno \(e)"
        case .unexpectedInstruction(let h): return "Expected ARM64 RET at probe address; found \(h)."
        }
    }
}

private struct ProbeSegment {
    let offset: UInt64
    let vaddr: UInt64
    let fileSize: UInt64
    let memSize: UInt64
}

private extension Data {
    func gp16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= count else { return nil }
        return UInt16(self[o]) | UInt16(self[o + 1]) << 8
    }
    func gp32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= count else { return nil }
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func gp64(_ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[o + i]) << UInt64(i * 8) }
        return v
    }
}

enum GuestProbe {
    // Confirmed in GoreBox 13.7.9 Android RayFire: GetTestIntValue @ 0xA4048 = `ret`.
    private static let rayFireSafeReturnVA: UInt64 = 0xA4048

    static func runRayFireSafeReturn() throws {
        guard let rf = ImportedGame.requiredLibraries.first(where: { $0.fileName == "libRF_CNative_andr.so" }) else {
            throw ImportedGameError.installMissing
        }
        let data = try ImportedGame.load(rf)
        let segments = try parseSegments(data)
        guard !segments.isEmpty else { throw GuestProbeError.noSegments }
        let targetVA = rayFireSafeReturnVA
        guard segments.contains(where: { targetVA >= $0.vaddr && targetVA + 4 <= $0.vaddr + $0.fileSize }) else {
            throw GuestProbeError.targetOutsideLoad
        }

        guard let instructionFileOffset = fileOffset(for: targetVA, in: segments),
              instructionFileOffset + 4 <= UInt64(data.count) else { throw GuestProbeError.targetOutsideLoad }
        let i = Int(instructionFileOffset)
        let bytes = data[i..<(i + 4)]
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard Array(bytes) == [0xC0, 0x03, 0x5F, 0xD6] else { throw GuestProbeError.unexpectedInstruction(hex) }

        let page = UInt64(max(getpagesize(), 4096))
        let minV = segments.map { $0.vaddr }.min()!
        let maxV = segments.map { $0.vaddr + $0.memSize }.max()!
        let lo = minV & ~(page - 1)
        let hi = (maxV + page - 1) & ~(page - 1)
        let span = hi - lo
        errno = 0
        let base = mmap(nil, Int(span), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard base != MAP_FAILED, let base else { throw GuestProbeError.mmapFailed(errno) }
        defer { munmap(base, Int(span)) }

        try data.withUnsafeBytes { raw in
            guard let srcBase = raw.baseAddress else { throw GuestProbeError.segmentBounds }
            for s in segments {
                guard s.fileSize <= s.memSize,
                      s.offset + s.fileSize <= UInt64(data.count),
                      s.vaddr >= lo else { throw GuestProbeError.segmentBounds }
                memcpy(base.advanced(by: Int(s.vaddr - lo)), srcBase.advanced(by: Int(s.offset)), Int(s.fileSize))
            }
        }

        let targetOffset = targetVA - lo
        let execPageOffset = targetOffset & ~(page - 1)
        let execEnd = (targetOffset + 4 + page - 1) & ~(page - 1)
        let execAddress = base.advanced(by: Int(execPageOffset))
        errno = 0
        guard gbr_make_rx(execAddress, Int(execEnd - execPageOffset)) == 0 else {
            throw GuestProbeError.mprotectFailed(errno)
        }

        let target = base.advanced(by: Int(targetOffset))
        typealias GuestFunction = @convention(c) () -> Void
        let function = unsafeBitCast(target, to: GuestFunction.self)
        function()
    }

    private static func fileOffset(for va: UInt64, in segments: [ProbeSegment]) -> UInt64? {
        for s in segments where va >= s.vaddr && va < s.vaddr + s.fileSize {
            return s.offset + (va - s.vaddr)
        }
        return nil
    }

    private static func parseSegments(_ data: Data) throws -> [ProbeSegment] {
        guard data.count >= 64,
              data[0] == 0x7F, data[1] == 0x45, data[2] == 0x4C, data[3] == 0x46,
              data[4] == 2, data[5] == 1, data.gp16(18) == 183 else { throw GuestProbeError.invalidELF }
        let phoff = Int(data.gp64(32) ?? 0)
        let entsize = Int(data.gp16(54) ?? 0)
        let count = Int(data.gp16(56) ?? 0)
        guard entsize >= 56 else { throw GuestProbeError.invalidELF }
        var result: [ProbeSegment] = []
        for n in 0..<count {
            let o = phoff + n * entsize
            guard o + 56 <= data.count else { continue }
            guard data.gp32(o) == 1 else { continue }
            result.append(ProbeSegment(
                offset: data.gp64(o + 8) ?? 0,
                vaddr: data.gp64(o + 16) ?? 0,
                fileSize: data.gp64(o + 32) ?? 0,
                memSize: data.gp64(o + 40) ?? 0
            ))
        }
        return result
    }
}
