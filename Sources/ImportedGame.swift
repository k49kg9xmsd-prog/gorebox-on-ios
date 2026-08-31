import Foundation
import CryptoKit

struct ImportedLibrary {
    let fileName: String
    let apkPath: String
}

struct GameInstallMetadata: Codable {
    let sourceFileName: String
    let sha256: String
    let profile: String
    let importedAt: Date
}

enum ImportedGameError: LocalizedError {
    case notGoreBox([String])
    case installMissing

    var errorDescription: String? {
        switch self {
        case .notGoreBox(let missing): return "This APK does not contain the expected GoreBox ARM64/Unity files. Missing: \(missing.joined(separator: ", "))"
        case .installMissing: return "No imported GoreBox installation was found."
        }
    }
}

enum ImportedGame {
    static let known1379SHA256 = "63af90b644a9d18ebfc5bf5ede5fc061afaba46a19dda20a8b3320e2ec3bd7bd"
    static let requiredLibraries: [ImportedLibrary] = [
        ImportedLibrary(fileName: "libmain.so", apkPath: "lib/arm64-v8a/libmain.so"),
        ImportedLibrary(fileName: "libil2cpp.so", apkPath: "lib/arm64-v8a/libil2cpp.so"),
        ImportedLibrary(fileName: "libunity.so", apkPath: "lib/arm64-v8a/libunity.so"),
        ImportedLibrary(fileName: "libRF_CNative_andr.so", apkPath: "lib/arm64-v8a/libRF_CNative_andr.so")
    ]
    static let metadataAPKPath = "assets/bin/Data/Managed/Metadata/global-metadata.dat"

    static var root: URL {
        let fm = FileManager.default
        let base = try! fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("GoreBoxRunner", isDirectory: true)
    }
    static var gameRoot: URL { root.appendingPathComponent("Game", isDirectory: true) }
    static var libsRoot: URL { gameRoot.appendingPathComponent("lib", isDirectory: true) }
    static var apkURL: URL { gameRoot.appendingPathComponent("GoreBox.apk") }
    static var metadataURL: URL { gameRoot.appendingPathComponent("global-metadata.dat") }
    static var installJSONURL: URL { gameRoot.appendingPathComponent("install.json") }
    static var assetsRoot: URL { gameRoot.appendingPathComponent("assets", isDirectory: true) }
    static var dataRoot: URL { assetsRoot.appendingPathComponent("bin/Data", isDirectory: true) }
    static var runtimeAssetsMarkerURL: URL { gameRoot.appendingPathComponent("runtime-assets.ready") }
    static var userDataRoot: URL { gameRoot.appendingPathComponent("UserData", isDirectory: true) }
    static var bootstrapCheckpointURL: URL { root.appendingPathComponent("bootstrap-checkpoint.txt") }

    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: apkURL.path) && requiredLibraries.allSatisfy { fm.fileExists(atPath: libraryURL($0).path) }
    }

    static func libraryURL(_ library: ImportedLibrary) -> URL { libsRoot.appendingPathComponent(library.fileName) }

    static func load(_ library: ImportedLibrary) throws -> Data {
        let url = libraryURL(library)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ImportedGameError.installMissing }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func metadata() -> GameInstallMetadata? {
        guard let data = try? Data(contentsOf: installJSONURL) else { return nil }
        return try? JSONDecoder().decode(GameInstallMetadata.self, from: data)
    }

    static func removeInstall() throws {
        if FileManager.default.fileExists(atPath: gameRoot.path) { try FileManager.default.removeItem(at: gameRoot) }
    }

    static func importAPK(from source: URL, progress: @escaping (String, Double) -> Void) throws -> GameInstallMetadata {
        let fm = FileManager.default
        try fm.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: libsRoot, withIntermediateDirectories: true)

        progress("Copying APK…", 0.05)
        let tempAPK = gameRoot.appendingPathComponent("GoreBox.importing.apk")
        try? fm.removeItem(at: tempAPK)
        try fm.copyItem(at: source, to: tempAPK)

        progress("Reading APK directory…", 0.12)
        let archive = try APKArchive(url: tempAPK)
        var required = requiredLibraries.map { $0.apkPath }
        required.append(metadataAPKPath)
        let missing = required.filter { !archive.contains($0) }
        guard missing.isEmpty else {
            try? fm.removeItem(at: tempAPK)
            throw ImportedGameError.notGoreBox(missing)
        }

        progress("Calculating APK fingerprint…", 0.20)
        let sha = try sha256File(tempAPK)
        let profile = sha.lowercased() == known1379SHA256 ? "GoreBox 13.7.9 — exact known APK" : "GoreBox-compatible APK — unknown build"

        for (index, lib) in requiredLibraries.enumerated() {
            let start = 0.25 + Double(index) * 0.13
            progress("Extracting \(lib.fileName)…", start)
            try archive.extract(lib.apkPath, to: libraryURL(lib))
        }
        progress("Extracting IL2CPP metadata…", 0.79)
        try archive.extract(metadataAPKPath, to: metadataURL)

        progress("Finalizing installation…", 0.90)
        try? fm.removeItem(at: apkURL)
        try fm.moveItem(at: tempAPK, to: apkURL)

        let info = GameInstallMetadata(sourceFileName: source.lastPathComponent, sha256: sha, profile: profile, importedAt: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: installJSONURL, options: .atomic)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(values)
        progress("Installed", 1.0)
        return info
    }

    static func ensureRuntimeAssets(progress: @escaping (String, Double) -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: runtimeAssetsMarkerURL.path) {
            progress("Unity runtime assets ready", 1.0)
            return
        }
        guard fm.fileExists(atPath: apkURL.path) else { throw ImportedGameError.installMissing }
        try fm.createDirectory(at: userDataRoot, withIntermediateDirectories: true)
        let archive = try APKArchive(url: apkURL)
        let prefix = "assets/bin/Data/"
        let names = archive.entries.keys.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/") }.sorted()
        guard !names.isEmpty else { throw ImportedGameError.notGoreBox([prefix]) }
        for (index, name) in names.enumerated() {
            let relative = String(name.dropFirst("assets/".count))
            let destination = assetsRoot.appendingPathComponent(relative)
            progress("Extracting runtime asset \(index + 1)/\(names.count): \(name)", Double(index) / Double(max(names.count, 1)))
            try archive.extract(name, to: destination)
        }
        try Data("GoreBoxRunner Launch 0.4 runtime assets\n".utf8).write(to: runtimeAssetsMarkerURL, options: .atomic)
        progress("Unity runtime assets ready", 1.0)
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
