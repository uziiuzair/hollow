import Foundation
@testable import DiskApp

enum Fixtures {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiskAppTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension Fixtures {
    /// Builds a tree from relative paths mapped to byte sizes. Returns the root.
    static func tree(_ spec: [String: Int]) throws -> URL {
        let root = try tempDir()
        let fm = FileManager.default
        for (path, size) in spec {
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: size).write(to: url)
        }
        return root
    }

    /// A non-internal `VolumeInfo` for a temp folder, with a unique fake UUID.
    static func volume(_ root: URL) throws -> VolumeInfo {
        var st = stat()
        guard stat(root.path(percentEncoded: false), &st) == 0 else { throw CocoaError(.fileReadUnknown) }
        return VolumeInfo(url: root, uuid: "test-" + UUID().uuidString, name: root.lastPathComponent,
                          isInternalData: false, device: st.st_dev)
    }
}
