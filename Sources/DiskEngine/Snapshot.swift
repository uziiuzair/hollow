// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public enum SnapshotError: Error {
    case missing
    case incompatible(String)
}

/// The RAM side of a `ScanIndex` in one file, replaced atomically on every save.
///
/// Layout (native little-endian): magic "DINX", header fields, length-prefixed
/// rootPath and fseventsUUID, folder records, folder name bytes, (inode, owner folder) pairs,
/// pending folder IDs. The file table's committed lengths are in the header, so
/// file records appended after the last save are cut off on load.
extension ScanIndex {
    static let snapshotName = "index.snapshot"
    static let snapshotVersion: UInt32 = 1
    private static let magic = Array("DINX".utf8)

    public func save(to directory: URL) throws {
        try files.sync()
        let finalURL = directory.appending(path: Self.snapshotName)
        let tempURL = directory.appending(path: "\(Self.snapshotName).\(UUID().uuidString).tmp")
        do {
            let out = try MappedAppendFile(url: tempURL)
            func put<T>(_ value: T) throws { try withUnsafeBytes(of: value) { _ = try out.append($0) } }
            func putString(_ s: String?) throws {
                let utf8 = Array((s ?? "").utf8)
                try put(UInt32(utf8.count))
                try utf8.withUnsafeBytes { _ = try out.append($0) }
            }

            try Self.magic.withUnsafeBytes { _ = try out.append($0) }
            try put(Self.snapshotVersion)
            try put(UInt64(folders.count))
            try put(UInt64(folderNames.byteCount))
            try put(UInt64(files.count))
            try put(files.nameBytes)
            try put(UInt64(hardLinkOwners.count))
            try put(UInt64(pending.count))
            try put(lastEventID)
            try put(rootDevice)
            try put(UInt64(garbageFolders))
            try put(UInt64(garbageFiles))
            try put(scannedAt.timeIntervalSince1970)
            try putString(rootPath)
            try putString(fseventsUUID)

            for record in folders { try put(record) }
            try folderNames.forEachChunk { _ = try out.append($0) }
            for (inode, owner) in hardLinkOwners {
                try put(inode)
                try put(owner)
            }
            try pending.withUnsafeBytes { _ = try out.append($0) }
            try out.sync()
        } catch {
            unlink(tempURL.path)
            throw error
        }
        guard rename(tempURL.path, finalURL.path) == 0 else {
            let failure = errno
            unlink(tempURL.path)
            throw DiskEngineError.posix("rename snapshot", failure)
        }
    }

    /// Every stored ID and offset must point inside its table, or the snapshot is rejected.
    private static func validate(_ index: ScanIndex, fileCount: Int) throws {
        let count = UInt32(index.folders.count)
        let nameBytes = index.folderNames.byteCount
        func folderOK(_ id: FolderID) -> Bool { id == noFolder || id < count }
        for (i, f) in index.folders.enumerated() {
            guard (i == 0 ? f.parent == noFolder : f.parent < count),
                  folderOK(f.firstChildFolder), folderOK(f.nextSibling),
                  Int(f.nameOffset) + 2 <= nameBytes,
                  Int(f.firstFile) + Int(f.bigFileCount) <= fileCount
            else { throw SnapshotError.incompatible("folder \(i) out of range") }
            let offset = Int(f.nameOffset)
            let length = Int(index.folderNames.byte(at: offset)) | Int(index.folderNames.byte(at: offset + 1)) << 8
            guard length <= NamePool.maxNameBytes, offset + 2 + length <= nameBytes else { throw SnapshotError.incompatible("folder \(i) name out of range") }
        }
        guard index.pending.allSatisfy({ $0 < count }), index.hardLinkOwners.values.allSatisfy({ $0 < count }) else {
            throw SnapshotError.incompatible("pending or hard-link owner out of range")
        }
    }

    public static func load(from directory: URL) throws -> ScanIndex {
        let url = directory.appending(path: snapshotName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SnapshotError.missing }
        let data = try Data(contentsOf: url, options: .alwaysMapped)

        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> ScanIndex in
            var cursor = 0
            func take<T>(_: T.Type) throws -> T {
                guard cursor + MemoryLayout<T>.size <= bytes.count else { throw SnapshotError.incompatible("truncated") }
                defer { cursor += MemoryLayout<T>.size }
                return bytes.loadUnaligned(fromByteOffset: cursor, as: T.self)
            }
            func takeBytes(_ n: Int) throws -> UnsafeRawBufferPointer {
                guard n >= 0, cursor + n <= bytes.count else { throw SnapshotError.incompatible("truncated") }
                defer { cursor += n }
                return UnsafeRawBufferPointer(rebasing: bytes[cursor..<(cursor + n)])
            }
            func takeString() throws -> String {
                String(decoding: try takeBytes(Int(try take(UInt32.self))), as: UTF8.self)
            }

            guard Array(try takeBytes(4)) == magic else { throw SnapshotError.incompatible("not a snapshot") }
            let version = try take(UInt32.self)
            guard version == snapshotVersion else { throw SnapshotError.incompatible("version \(version)") }
            let folderCount = Int(try take(UInt64.self))
            let folderNameBytes = Int(try take(UInt64.self))
            let fileCount = Int(try take(UInt64.self))
            let fileNameBytes = try take(UInt64.self)
            let hardLinkCount = Int(try take(UInt64.self))
            let pendingCount = Int(try take(UInt64.self))
            let lastEventID = try take(UInt64.self)
            let rootDevice = try take(Int32.self)
            let garbageFolders = Int(try take(UInt64.self))
            let garbageFiles = Int(try take(UInt64.self))
            let scannedAt = try take(Double.self)
            let rootPath = try takeString()
            let uuid = try takeString()

            let expectedRest = folderCount * MemoryLayout<FolderRecord>.size + folderNameBytes
                + hardLinkCount * 12 + pendingCount * MemoryLayout<FolderID>.size
            guard folderCount > 0, bytes.count - cursor == expectedRest else {
                throw SnapshotError.incompatible("length mismatch")
            }

            // A file table shorter than committed would be padded with zeros by ftruncate.
            for (name, needed) in [("files.bin", UInt64(fileCount * MemoryLayout<FileRecord>.stride)), ("filenames.bin", fileNameBytes)] {
                var info = stat()
                guard stat(directory.appending(path: name).path, &info) == 0, UInt64(info.st_size) >= needed else {
                    throw SnapshotError.incompatible("\(name) shorter than committed")
                }
            }
            let files = try FileTable(directory: directory, keepingRecords: fileCount, nameBytes: fileNameBytes)
            let index = ScanIndex(files: files)
            for _ in 0..<folderCount { index.folders.append(try take(FolderRecord.self)) }
            index.folderNames = NamePool(bytes: try takeBytes(folderNameBytes))
            index.hardLinkOwners.reserveCapacity(hardLinkCount)
            for _ in 0..<hardLinkCount {
                let inode = try take(UInt64.self)
                index.hardLinkOwners[inode] = try take(FolderID.self)
            }
            index.pending = (0..<pendingCount).map { _ in (try? take(FolderID.self)) ?? 0 }

            try validate(index, fileCount: fileCount)
            index.rootPath = rootPath
            index.rootDevice = rootDevice
            index.lastEventID = lastEventID
            index.fseventsUUID = uuid.isEmpty ? nil : uuid
            index.garbageFolders = garbageFolders
            index.garbageFiles = garbageFiles
            index.scannedAt = Date(timeIntervalSince1970: scannedAt)
            for file in 0..<FileIndex(fileCount) {
                index.top.offer(file, allocated: try files.record(file).allocated)
            }
            return index
        }
    }
}
