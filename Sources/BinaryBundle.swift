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

    static func load(_ library: EmbeddedLibrary) throws -> Data {
        var result = Data()
        for resource in library.chunkResources {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "bin") else {
                throw NSError(
                    domain: "GoreBoxRunner.BinaryBundle",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing resource: \(resource).bin"]
                )
            }
            let part = try Data(contentsOf: url, options: [.mappedIfSafe])
            result.append(part)
        }
        return result
    }
}
