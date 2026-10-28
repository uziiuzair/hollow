import Foundation
import DiskEngine
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

extension Fixtures {
    static let internalDrive = KnownDrive(uuid: "I", name: "Macintosh HD", tintIndex: 0, lastSeen: .now)

    static func t7(lastSeen: Date, lastFreeGB: UInt64? = nil) -> KnownDrive {
        KnownDrive(uuid: "T7", name: "Samsung T7", tintIndex: 1, lastSeen: lastSeen,
                   lastFree: lastFreeGB.map { $0 * 1_000_000_000 }, lastTotal: 1_000_000_000_000)
    }

    static func summary(net: Int64?, changes: [Change], kinds: [ContentKind: UInt64] = [:], period: Int = 1) -> DriveSummary {
        DriveSummary(scannedBytes: kinds.values.reduce(0, +), kinds: kinds, changes: changes, net: net,
                     period: period, updatedAt: .now)
    }

    static func space(totalGB: UInt64, freeGB: UInt64, reclaimableGB: UInt64) -> VolumeSpace {
        let gb: UInt64 = 1_000_000_000
        return VolumeSpace(total: totalGB * gb, available: (freeGB - reclaimableGB) * gb,
                           availableForImportantUsage: freeGB * gb)
    }
}
