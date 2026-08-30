import Foundation

struct APKEntry {
    let name: String
    let compression: UInt16
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

enum APKArchiveError: LocalizedError {
    case tooSmall
    case endRecordNotFound
    case unsupportedZip64
    case invalidCentralDirectory
    case entryNotFound(String)
    case unsupportedCompression(String, UInt16)
    case corruptLocalHeader(String)
    case inflateFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .tooSmall: return "APK/ZIP file is too small."
        case .endRecordNotFound: return "ZIP end-of-central-directory was not found."
        case .unsupportedZip64: return "ZIP64 APK is not supported by this importer yet."
        case .invalidCentralDirectory: return "APK central directory is invalid."
        case .entryNotFound(let n): return "APK is missing required entry: \(n)"
        case .unsupportedCompression(let n, let m): return "Unsupported ZIP compression method \(m) for \(n)."
        case .corruptLocalHeader(let n): return "Corrupt local ZIP header for \(n)."
        case .inflateFailed(let n, let rc): return "Deflate failed for \(n) (zlib rc=\(rc))."
        }
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func le32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset]) |
            UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 |
            UInt32(self[offset + 3]) << 24
    }
}

final class APKArchive {
    let url: URL
    let entries: [String: APKEntry]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22 else { throw APKArchiveError.tooSmall }

        let tailSize = min(UInt64(22 + 0xFFFF), size)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocd: Int?
        if tail.count >= 22 {
            for i in stride(from: tail.count - 22, through: 0, by: -1) {
                if Array(tail[i..<min(i + 4, tail.count)]) == signature {
                    eocd = i
                    break
                }
            }
        }
        guard let e = eocd else { throw APKArchiveError.endRecordNotFound }
        guard let totalEntries = tail.le16(e + 10),
              let centralSize = tail.le32(e + 12),
              let centralOffset = tail.le32(e + 16) else {
            throw APKArchiveError.invalidCentralDirectory
        }
        if totalEntries == 0xFFFF || centralSize == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF {
            throw APKArchiveError.unsupportedZip64
        }

        try handle.seek(toOffset: UInt64(centralOffset))
        let central = try handle.read(upToCount: Int(centralSize)) ?? Data()
        var result: [String: APKEntry] = [:]
        var cursor = 0
        var parsed = 0
        while cursor + 46 <= central.count, parsed < Int(totalEntries) {
            guard central.le32(cursor) == 0x02014B50 else { throw APKArchiveError.invalidCentralDirectory }
            guard let method = central.le16(cursor + 10),
                  let compressed = central.le32(cursor + 20),
                  let uncompressed = central.le32(cursor + 24),
                  let nameLen = central.le16(cursor + 28),
                  let extraLen = central.le16(cursor + 30),
                  let commentLen = central.le16(cursor + 32),
                  let localOffset = central.le32(cursor + 42) else {
                throw APKArchiveError.invalidCentralDirectory
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= central.count,
                  let name = String(data: central[nameStart..<nameEnd], encoding: .utf8) else {
                throw APKArchiveError.invalidCentralDirectory
            }
            result[name] = APKEntry(
                name: name,
                compression: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            )
            cursor = nameEnd + Int(extraLen) + Int(commentLen)
            parsed += 1
        }
        guard !result.isEmpty else { throw APKArchiveError.invalidCentralDirectory }
        self.entries = result
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func extract(_ name: String, to destination: URL) throws {
        guard let entry = entries[name] else { throw APKArchiveError.entryNotFound(name) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let local = try handle.read(upToCount: 30) ?? Data()
        guard local.count == 30, local.le32(0) == 0x04034B50,
              let nameLen = local.le16(26), let extraLen = local.le16(28) else {
            throw APKArchiveError.corruptLocalHeader(name)
        }
        let dataOffset = UInt64(entry.localHeaderOffset) + 30 + UInt64(nameLen) + UInt64(extraLen)
        try handle.seek(toOffset: dataOffset)
        let compressed = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard compressed.count == Int(entry.compressedSize) else { throw APKArchiveError.corruptLocalHeader(name) }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)

        switch entry.compression {
        case 0:
            try compressed.write(to: destination, options: .atomic)
        case 8:
            var output = Data(count: Int(entry.uncompressedSize))
            let rc: Int32 = compressed.withUnsafeBytes { src in
                output.withUnsafeMutableBytes { dst in
                    guard let s = src.bindMemory(to: UInt8.self).baseAddress,
                          let d = dst.bindMemory(to: UInt8.self).baseAddress else { return -2 }
                    return Int32(gbr_inflate_raw(s, compressed.count, d, output.count))
                }
            }
            guard rc == 0 else { throw APKArchiveError.inflateFailed(name, rc) }
            try output.write(to: destination, options: .atomic)
        default:
            throw APKArchiveError.unsupportedCompression(name, entry.compression)
        }
    }
}
