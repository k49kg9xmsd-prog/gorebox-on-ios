import Foundation

struct ELFSection {
    let nameOffset: UInt32
    let type: UInt32
    let flags: UInt64
    let address: UInt64
    let offset: UInt64
    let size: UInt64
    let link: UInt32
    let info: UInt32
    let alignment: UInt64
    let entrySize: UInt64
    var name: String = ""
}

struct ELFProgramHeader {
    let type: UInt32
    let flags: UInt32
    let offset: UInt64
    let virtualAddress: UInt64
    let fileSize: UInt64
    let memorySize: UInt64
    let alignment: UInt64
}

struct ELFReport {
    let fileName: String
    let fileSize: Int
    var validELF = false
    var elfClass = "Unknown"
    var endian = "Unknown"
    var machine = "Unknown"
    var entryPoint: UInt64 = 0
    var programHeaderCount = 0
    var sectionHeaderCount = 0
    var loadSegmentCount = 0
    var dynamicSymbolCount = 0
    var undefinedSymbolCount = 0
    var relocationCount = 0
    var neededLibraries: [String] = []
    var undefinedSymbols: [String] = []
    var notes: [String] = []

    var formatted: String {
        var out: [String] = []
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append(fileName)
        out.append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        out.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))")
        let arm64Status = validELF && elfClass == "ELF64" && machine == "AArch64" ? "✅" : "❌"
        out.append("ELF64 ARM64: \(arm64Status)")
        out.append("Class: \(elfClass)")
        out.append("Endian: \(endian)")
        out.append("Machine: \(machine)")
        out.append(String(format: "Entry: 0x%llX", entryPoint))
        out.append("Program headers: \(programHeaderCount)")
        out.append("LOAD segments: \(loadSegmentCount)")
        out.append("Section headers: \(sectionHeaderCount)")
        out.append("Dynamic symbols: \(dynamicSymbolCount)")
        out.append("Undefined/imported symbols: \(undefinedSymbolCount)")
        out.append("Relocations: \(relocationCount)")
        out.append("")
        out.append("DT_NEEDED:")
        if neededLibraries.isEmpty {
            out.append("  (none found)")
        } else {
            neededLibraries.forEach { out.append("  • \($0)") }
        }
        if !undefinedSymbols.isEmpty {
            out.append("")
            out.append("Imported symbols (first \(undefinedSymbols.count)):")
            undefinedSymbols.forEach { out.append("  • \($0)") }
        }
        if !notes.isEmpty {
            out.append("")
            out.append("Notes:")
            notes.forEach { out.append("  • \($0)") }
        }
        return out.joined(separator: "\n")
    }
}

private struct LEReader {
    let data: Data

    func u8(_ o: Int) -> UInt8? {
        guard o >= 0, o < data.count else { return nil }
        return data[o]
    }

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

    func cString(at offset: Int, maxLength: Int = 4096) -> String? {
        guard offset >= 0, offset < data.count else { return nil }
        let endLimit = min(data.count, offset + maxLength)
        var end = offset
        while end < endLimit, data[end] != 0 { end += 1 }
        guard end > offset else { return "" }
        return String(data: data[offset..<end], encoding: .utf8)
    }
}

final class ELFParser {
    private static let SHT_RELA: UInt32 = 4
    private static let SHT_DYNAMIC: UInt32 = 6
    private static let SHT_REL: UInt32 = 9
    private static let SHT_DYNSYM: UInt32 = 11
    private static let PT_LOAD: UInt32 = 1
    private static let DT_NULL: UInt64 = 0
    private static let DT_NEEDED: UInt64 = 1

    static func parse(data: Data, fileName: String, importedSymbolLimit: Int = 80) -> ELFReport {
        var report = ELFReport(fileName: fileName, fileSize: data.count)
        let r = LEReader(data: data)

        guard data.count >= 64,
              r.u8(0) == 0x7F,
              r.u8(1) == 0x45,
              r.u8(2) == 0x4C,
              r.u8(3) == 0x46 else {
            report.notes.append("Invalid ELF magic")
            return report
        }
        report.validELF = true

        let elfClass = r.u8(4) ?? 0
        let endian = r.u8(5) ?? 0
        report.elfClass = elfClass == 2 ? "ELF64" : (elfClass == 1 ? "ELF32" : "Unknown(\(elfClass))")
        report.endian = endian == 1 ? "Little endian" : (endian == 2 ? "Big endian" : "Unknown(\(endian))")
        guard elfClass == 2, endian == 1 else {
            report.notes.append("Stage 0 parser currently expects ELF64 little-endian")
            return report
        }

        let machine = r.u16(18) ?? 0
        switch machine {
        case 183: report.machine = "AArch64"
        case 40: report.machine = "ARM"
        case 62: report.machine = "x86_64"
        default: report.machine = "Machine(\(machine))"
        }
        report.entryPoint = r.u64(24) ?? 0

        let phoff = Int(r.u64(32) ?? 0)
        let shoff = Int(r.u64(40) ?? 0)
        let phentsize = Int(r.u16(54) ?? 0)
        let phnum = Int(r.u16(56) ?? 0)
        let shentsize = Int(r.u16(58) ?? 0)
        let shnum = Int(r.u16(60) ?? 0)
        let shstrndx = Int(r.u16(62) ?? 0)

        report.programHeaderCount = phnum
        report.sectionHeaderCount = shnum

        var programHeaders: [ELFProgramHeader] = []
        if phentsize >= 56, phoff >= 0, phnum >= 0 {
            for i in 0..<phnum {
                let o = phoff + i * phentsize
                guard o >= 0, o + 56 <= data.count else { break }
                let ph = ELFProgramHeader(
                    type: r.u32(o) ?? 0,
                    flags: r.u32(o + 4) ?? 0,
                    offset: r.u64(o + 8) ?? 0,
                    virtualAddress: r.u64(o + 16) ?? 0,
                    fileSize: r.u64(o + 32) ?? 0,
                    memorySize: r.u64(o + 40) ?? 0,
                    alignment: r.u64(o + 48) ?? 0
                )
                programHeaders.append(ph)
            }
        }
        report.loadSegmentCount = programHeaders.filter { $0.type == PT_LOAD }.count

        var sections: [ELFSection] = []
        if shentsize >= 64, shoff >= 0, shnum >= 0 {
            for i in 0..<shnum {
                let o = shoff + i * shentsize
                guard o >= 0, o + 64 <= data.count else { break }
                sections.append(ELFSection(
                    nameOffset: r.u32(o) ?? 0,
                    type: r.u32(o + 4) ?? 0,
                    flags: r.u64(o + 8) ?? 0,
                    address: r.u64(o + 16) ?? 0,
                    offset: r.u64(o + 24) ?? 0,
                    size: r.u64(o + 32) ?? 0,
                    link: r.u32(o + 40) ?? 0,
                    info: r.u32(o + 44) ?? 0,
                    alignment: r.u64(o + 48) ?? 0,
                    entrySize: r.u64(o + 56) ?? 0
                ))
            }
        }

        if shstrndx >= 0, shstrndx < sections.count {
            let stringSection = sections[shstrndx]
            let base = Int(stringSection.offset)
            for i in sections.indices {
                let nameOffset = base + Int(sections[i].nameOffset)
                sections[i].name = r.cString(at: nameOffset) ?? ""
            }
        }

        // DT_NEEDED via SHT_DYNAMIC and its linked string table.
        if let dynIndex = sections.firstIndex(where: { $0.type == SHT_DYNAMIC || $0.name == ".dynamic" }) {
            let dyn = sections[dynIndex]
            let strIndex = Int(dyn.link)
            if strIndex >= 0, strIndex < sections.count {
                let str = sections[strIndex]
                let entrySize = Int(dyn.entrySize == 0 ? 16 : dyn.entrySize)
                let count = entrySize > 0 ? Int(dyn.size) / entrySize : 0
                var needed: [String] = []
                for i in 0..<count {
                    let o = Int(dyn.offset) + i * entrySize
                    guard o + 16 <= data.count else { break }
                    let tag = r.u64(o) ?? 0
                    let value = r.u64(o + 8) ?? 0
                    if tag == DT_NULL { break }
                    if tag == DT_NEEDED {
                        let so = Int(str.offset) + Int(value)
                        if let s = r.cString(at: so), !s.isEmpty { needed.append(s) }
                    }
                }
                var seen = Set<String>()
                report.neededLibraries = needed.filter { seen.insert($0).inserted }
            }
        }

        // Dynamic symbol table + imports.
        if let dynSymIndex = sections.firstIndex(where: { $0.type == SHT_DYNSYM || $0.name == ".dynsym" }) {
            let dynSym = sections[dynSymIndex]
            let strIndex = Int(dynSym.link)
            let entrySize = Int(dynSym.entrySize == 0 ? 24 : dynSym.entrySize)
            let count = entrySize > 0 ? Int(dynSym.size) / entrySize : 0
            report.dynamicSymbolCount = count
            if strIndex >= 0, strIndex < sections.count {
                let str = sections[strIndex]
                var undefined: [String] = []
                var undefinedCount = 0
                for i in 0..<count {
                    let o = Int(dynSym.offset) + i * entrySize
                    guard o + 24 <= data.count else { break }
                    let nameOffset = Int(r.u32(o) ?? 0)
                    let sectionIndex = r.u16(o + 6) ?? 0
                    if sectionIndex == 0 && nameOffset != 0 {
                        undefinedCount += 1
                        if undefined.count < importedSymbolLimit,
                           let name = r.cString(at: Int(str.offset) + nameOffset),
                           !name.isEmpty {
                            undefined.append(name)
                        }
                    }
                }
                report.undefinedSymbolCount = undefinedCount
                report.undefinedSymbols = undefined
            }
        }

        var relocationCount = 0
        for section in sections where section.type == SHT_RELA || section.type == SHT_REL {
            let fallback = section.type == SHT_RELA ? 24 : 16
            let entrySize = Int(section.entrySize == 0 ? UInt64(fallback) : section.entrySize)
            if entrySize > 0 { relocationCount += Int(section.size) / entrySize }
        }
        report.relocationCount = relocationCount

        if sections.isEmpty {
            report.notes.append("No usable section-header table; future loader must fall back to PT_DYNAMIC")
        }
        if report.neededLibraries.contains("libandroid.so") {
            report.notes.append("Android native window/input shim will be required")
        }
        if report.neededLibraries.contains("libEGL.so") {
            report.notes.append("EGL graphics compatibility is required before Unity rendering can initialize")
        }
        if report.neededLibraries.contains("liblog.so") {
            report.notes.append("liblog shim can map __android_log_* calls to os_log")
        }
        if fileName.contains("RF_CNative") {
            report.notes.append("This is GoreBox's Android RayFire native library")
        }
        return report
    }
}
