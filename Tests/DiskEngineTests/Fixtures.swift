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

@testable import DiskEngine

private nonisolated(unsafe) var nextInode: UInt64 = 1_000

extension RawEntry {
    static func file(_ name: String, allocated: UInt64, inode: UInt64? = nil, links: UInt32 = 1) -> RawEntry {
        nextInode += 1
        return RawEntry(name: name, kind: .file, allocated: allocated, logical: allocated, device: 1,
                        inode: inode ?? nextInode, linkCount: links, flags: [], isMountPoint: false)
    }

    static func dir(_ name: String) -> RawEntry {
        nextInode += 1
        return RawEntry(name: name, kind: .directory, allocated: 0, logical: 0, device: 1,
                        inode: nextInode, linkCount: 1, flags: [], isMountPoint: false)
    }
}

extension Fixtures {
    /// Sum of allocated sizes under `root`, counting each inode once, not following symlinks.
    static func sumAllocated(under root: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .fileResourceIdentifierKey]
        var seen = Set<String>()
        var total: UInt64 = 0
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)! {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let id = "\(v.fileResourceIdentifier!)"
            guard seen.insert(id).inserted else { continue }
            total += UInt64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

extension Fixtures {
    /// The real path with every symlink resolved, keeping "/private" (Foundation's
    /// `resolvingSymlinksInPath` strips it, FSEvents and realpath don't).
    static func realPath(_ url: URL) -> String {
        guard let p = realpath(url.path, nil) else { return url.path }
        defer { free(p) }
        return String(cString: p)
    }

    static func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xA5, count: bytes).write(to: url)
    }
}
