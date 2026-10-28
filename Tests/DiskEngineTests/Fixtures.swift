import Foundation

enum Fixtures {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiskEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
