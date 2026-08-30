import Foundation

struct EmbeddedLibrary {
    let displayName: String
    let chunkResources: [String]
}

enum BinaryBundle {
    static let libraries: [EmbeddedLibrary] = [
        EmbeddedLibrary(
            displayName: "libil2cpp.so",
            chunkResources: [
                "gb_libil2cpp_so_part00",
                "gb_libil2cpp_so_part01",
                "gb_libil2cpp_so_part02",
                "gb_libil2cpp_so_part03"
            ]
        ),
        EmbeddedLibrary(
            displayName: "libunity.so",
            chunkResources: [
                "gb_libunity_so_part00",
                "gb_libunity_so_part01"
            ]
        ),
        EmbeddedLibrary(
            displayName: "libRF_CNative_andr.so",
            chunkResources: [
                "gb_libRF_CNative_andr_so_part00",
                "gb_libRF_CNative_andr_so_part01",
                "gb_libRF_CNative_andr_so_part02"
            ]
        )
    ]

    private static func candidateURLs(for resource: String) -> [URL] {
        let filename = resource + ".bin"
        var urls: [URL] = []

        // Normal iOS bundle lookup.
        if let u = Bundle.main.url(forResource: resource, withExtension: "bin") {
            urls.append(u)
        }
        if let u = Bundle.main.url(forResource: resource, withExtension: "bin", subdirectory: "GoreBoxPayload") {
            urls.append(u)
        }

        // Explicit bundle/resource roots. This also helps containerized launchers.
        let roots: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent()
        ]
        for case let root? in roots {
            urls.append(root.appendingPathComponent(filename))
            urls.append(root.appendingPathComponent("GoreBoxPayload").appendingPathComponent(filename))
            urls.append(root.appendingPathComponent("Payload").appendingPathComponent(filename))
        }

        // Remove duplicates while preserving order.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func findURL(for resource: String) -> URL? {
        let fm = FileManager.default
        for url in candidateURLs(for: resource) where fm.fileExists(atPath: url.path) {
            return url
        }

        // Last resort: recursively search the current bundle for the exact filename.
        let filename = resource + ".bin"
        if let root = Bundle.main.bundleURL as URL?,
           let enumerator = fm.enumerator(at: root,
                                          includingPropertiesForKeys: nil,
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                return url
            }
        }
        return nil
    }

    static func load(_ library: EmbeddedLibrary) throws -> Data {
        var result = Data()
        for resource in library.chunkResources {
            guard let url = findURL(for: resource) else {
                let roots = [
                    "bundle=\(Bundle.main.bundleURL.path)",
                    "resource=\(Bundle.main.resourceURL?.path ?? \"nil\")",
                    "executable=\(Bundle.main.executableURL?.path ?? \"nil\")"
                ].joined(separator: " | ")
                throw NSError(
                    domain: "GoreBoxRunner.BinaryBundle",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing resource: \(resource).bin\nSearch roots: \(roots)"]
                )
            }
            let part = try Data(contentsOf: url, options: [.mappedIfSafe])
            result.append(part)
        }
        return result
    }
}
