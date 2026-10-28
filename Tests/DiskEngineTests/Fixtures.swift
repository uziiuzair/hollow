import Foundation

enum Fixtures {
    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DiskEngineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a tree from relative paths mapped to byte sizes. A trailing "/" means
    /// a folder. Parent folders are created as needed. Returns the root.
    static func tree(_ spec: [String: Int]) throws -> URL {
        let root = try tempDir()
        let fm = FileManager.default
        for (path, size) in spec {
            if path.hasSuffix("/") {
                try fm.createDirectory(at: root.appending(path: path), withIntermediateDirectories: true)
                continue
            }
            let url = root.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Non-zero bytes so APFS actually allocates blocks.
            try Data(repeating: 0xA5, count: size).write(to: url)
        }
        return root
    }

    static func allocatedSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? 0)
    }
}

extension Array {
    var single: Element? { count == 1 ? first : nil }
}
