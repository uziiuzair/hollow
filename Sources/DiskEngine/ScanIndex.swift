import Foundation

/// Whether the walk should enter a directory: never onto another device, never
/// through a mount point.
public func shouldDescend(entryDevice: Int32, rootDevice: Int32, isMountPoint: Bool) -> Bool {
    entryDevice == rootDevice && !isMountPoint
}

/// All scan results. Folders live in RAM; stored files live in `files` on disk.
/// Only one caller may mutate it at a time (the scanner's collector loop).
public final class ScanIndex {
    public static let bigFileThreshold: UInt64 = 1_048_576

    public private(set) var folders = PagedArray<FolderRecord>()
    public let files: FileTable
    public private(set) var top = TopFiles()
    private var folderNames = NamePool()
    private var seenHardLinks: Set<UInt64> = []

    public enum ChildKind: Sendable {
        case folder(FolderID)
        case file(FileIndex)
        case smallFiles(count: UInt32)
    }

    public struct Child: Sendable {
        public var kind: ChildKind
        public var name: String
        public var allocated: UInt64
    }

    public init(rootName: String, storage: URL) throws {
        files = try FileTable(directory: storage)
        folders.append(FolderRecord(parent: noFolder, nameOffset: folderNames.append(rootName)))
    }

    /// Records one directory listing and returns the new subfolders to scan.
    public func integrate(_ listing: DirectoryListing, rootDevice: Int32) throws -> [FolderID] {
        let id = Int(listing.folder)
        switch listing.outcome {
        case .unreadable:
            folders[id].flags.insert(.unreadable)
            return []
        case .vanished:
            folders[id].flags.insert(.vanished)
            return []
        case .ok:
            break
        }

        if listing.partial { folders[id].flags.insert(.partial) }

        var newFolders: [FolderID] = []
        var direct: UInt64 = 0
        folders[id].firstChildFolder = FolderID(folders.count)
        folders[id].firstFile = FileIndex(files.count)

        for entry in listing.entries {
            if entry.kind == .directory {
                guard shouldDescend(entryDevice: entry.device, rootDevice: rootDevice, isMountPoint: entry.isMountPoint) else { continue }
                // Directory hard links (HFS+ Time Machine backups): walk each once.
                if entry.linkCount > 1, !seenHardLinks.insert(entry.inode).inserted { continue }
                newFolders.append(FolderID(folders.count))
                folders.append(FolderRecord(parent: listing.folder, nameOffset: folderNames.append(entry.name)))
                continue
            }

            var flags = entry.flags
            if entry.linkCount > 1 {
                guard seenHardLinks.insert(entry.inode).inserted else { continue }
                flags.insert(.hardLinked)
            }

            direct += entry.allocated
            if entry.allocated >= Self.bigFileThreshold {
                let record = FileRecord(
                    allocated: entry.allocated, parent: listing.folder, nameOffset: 0,
                    logicalKiB: UInt32(min(entry.logical / 1024, UInt64(UInt32.max))),
                    flags: flags, kind: entry.kind.rawValue)
                let index = try files.append(name: entry.name, record: record)
                top.offer(index, allocated: entry.allocated)
                folders[id].bigFileCount += 1
            } else {
                folders[id].smallFileCount += 1
                folders[id].smallAllocated += entry.allocated
            }
        }
        folders[id].childFolderCount = UInt32(newFolders.count)

        var cursor = listing.folder
        while cursor != noFolder {
            folders[Int(cursor)].totalAllocated += direct
            cursor = folders[Int(cursor)].parent
        }
        return newFolders
    }

    public func folderName(_ id: FolderID) -> String {
        folderNames.name(at: folders[Int(id)].nameOffset)
    }

    /// The folder's full path, rebuilt from the parent chain. The root maps to `rootPath`.
    public func path(of folder: FolderID, rootPath: String) -> String {
        var parts: [String] = []
        var cursor = folder
        while cursor != 0 {
            parts.append(folderName(cursor))
            cursor = folders[Int(cursor)].parent
        }
        return parts.reversed().reduce(rootPath) { $0 + "/" + $1 }
    }

    /// Subfolders, stored files, and one small-files bucket, largest first.
    public func children(of folder: FolderID) throws -> [Child] {
        let record = folders[Int(folder)]
        var result: [Child] = []
        let firstFolder = Int(record.firstChildFolder)
        for child in firstFolder..<(firstFolder + Int(record.childFolderCount)) {
            result.append(Child(kind: .folder(FolderID(child)), name: folderName(FolderID(child)), allocated: folders[child].totalAllocated))
        }
        let firstFile = record.firstFile
        for file in firstFile..<(firstFile + record.bigFileCount) {
            result.append(Child(kind: .file(file), name: try files.name(file), allocated: try files.record(file).allocated))
        }
        if record.smallFileCount > 0 {
            result.append(Child(kind: .smallFiles(count: record.smallFileCount),
                                name: "\(record.smallFileCount) small files", allocated: record.smallAllocated))
        }
        return result.sorted { $0.allocated > $1.allocated }
    }
}
