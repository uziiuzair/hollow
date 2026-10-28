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

    public internal(set) var folders = PagedArray<FolderRecord>()
    public let files: FileTable
    public internal(set) var top = TopFiles()
    var folderNames = NamePool()
    /// Hard-linked inodes and the folder that counts them.
    var hardLinkOwners: [UInt64: FolderID] = [:]

    /// The scanned folder's real path (symlinks resolved).
    public var rootPath = ""
    public var rootDevice: Int32 = 0
    /// Folders created but never listed; a resumed scan starts from these.
    public var pending: [FolderID] = []
    /// Last FSEvents event applied to this index; 0 = none.
    public var lastEventID: UInt64 = 0
    /// The volume's FSEvents journal UUID when this index was last current.
    public var fseventsUUID: String?
    /// Folders (paths relative to the root, no leading or trailing "/") that listings leave out.
    /// Not stored in the snapshot; the owner sets it after loading.
    public var exclusions: Set<String> = [] {
        didSet {
            var map: [String: Set<String>] = [:]
            for path in exclusions {
                guard let slash = path.lastIndex(of: "/") else { map["", default: []].insert(path); continue }
                map[String(path[..<slash]), default: []].insert(String(path[path.index(after: slash)...]))
            }
            excludedChildren = map
        }
    }
    /// `exclusions` as parent relative path -> excluded child names.
    private var excludedChildren: [String: Set<String>] = [:]
    /// Big folders' subfolders by name, built when a lookup in one misses and dropped whenever its children change, so a
    /// temp folder with 20,000 entries isn't passed over for every event under it. At most `maxTabled` names in all.
    private var childTables: [FolderID: [String: FolderID]] = [:]
    private var tabledNames = 0
    static let tableAbove = 1024
    static let maxTabled = 65_536
    /// Tests only.
    var childLookupTables: Int { childTables.count }
    /// Folders marked `.stale` since the owner last took them, to list again later.
    public var newlyStale: [FolderID] = []
    public internal(set) var garbageFolders = 0
    public internal(set) var garbageFiles = 0
    public var scannedAt = Date()

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

    /// Used by `load(from:)`; the caller fills in every table.
    init(files: FileTable) {
        self.files = files
    }

    /// Records one directory listing of a never-listed (or reset) folder and returns
    /// the new subfolders to scan.
    public func integrate(_ listing: DirectoryListing, rootDevice: Int32) throws -> [FolderID] {
        let id = Int(listing.folder)
        switch listing.outcome {
        case .unreadable:
            folders[id].flags.insert(.unreadable)
            return []
        case .vanished:
            folders[id].flags.insert(.vanished)
            return []
        case .timedOut:
            markStale(listing.folder)
            return []
        case .ok:
            break
        }

        if listing.partial { folders[id].flags.insert(.partial) }

        var children: [FolderID] = []
        var newFolders: [FolderID] = []
        var direct: UInt64 = 0
        var pass: Set<UInt64> = []
        folders[id].firstFile = FileIndex(files.count)
        let skipped = excludedNames(in: listing.folder)

        for entry in listing.entries {
            if entry.kind == .directory {
                if skipped?.contains(entry.name) == true { continue }
                guard shouldDescend(entryDevice: entry.device, rootDevice: rootDevice, isMountPoint: entry.isMountPoint) else { continue }
                // Directory hard links (HFS+ Time Machine backups): walk each once.
                if entry.linkCount > 1, !claimHardLink(entry.inode, for: listing.folder, pass: &pass) { continue }
                let new = FolderID(folders.count)
                folders.append(FolderRecord(parent: listing.folder, nameOffset: folderNames.append(entry.name)))
                children.append(new)
                // A dataless folder stays unlisted: opening it could download it.
                if entry.flags.contains(.dataless) { folders[Int(new)].flags.insert(.dataless) } else { newFolders.append(new) }
                continue
            }
            direct += try addFile(entry, to: listing.folder, pass: &pass)
        }
        link(children, under: listing.folder)
        addToTotals(from: listing.folder, Int64(bitPattern: direct))
        return newFolders
    }

    /// Re-reads one already-listed folder's direct contents. Subfolders that are still
    /// there keep their IDs and subtrees; new ones are returned for scanning; gone ones
    /// become garbage. Totals of this folder and every ancestor are corrected.
    /// What a relist found: the new subfolders still to scan, and whether the folder's blocks (subfolders and stored
    /// files) changed by name.
    public struct RelistResult: Sendable {
        public var newFolders: [FolderID]
        public var namesChanged: Bool
    }

    public func relist(_ listing: DirectoryListing) throws -> RelistResult {
        let folder = listing.folder
        let id = Int(folder)
        // Not read: everything it had stays, sizes included.
        guard listing.outcome != .timedOut else {
            markStale(folder)
            return RelistResult(newFolders: [], namesChanged: false)
        }
        let old = folders[id]

        var oldDirect = old.smallAllocated
        var oldBigNames: [String] = []
        for file in old.firstFile..<(old.firstFile + old.bigFileCount) {
            oldDirect += try files.record(file).allocated
            oldBigNames.append(try files.name(file))
        }
        var oldChildren: [String: FolderID] = [:]
        var child = old.firstChildFolder
        while child != noFolder {
            oldChildren[folderName(child)] = child
            child = folders[Int(child)].nextSibling
        }

        garbageFiles += Int(old.bigFileCount)
        folders[id].firstFile = FileIndex(files.count)
        folders[id].bigFileCount = 0
        folders[id].smallFileCount = 0
        folders[id].smallAllocated = 0
        folders[id].flags.remove([.unreadable, .vanished, .partial, .stale, .dataless])
        switch listing.outcome {
        case .unreadable: folders[id].flags.insert(.unreadable)
        case .vanished: folders[id].flags.insert(.vanished)
        case .ok: if listing.partial { folders[id].flags.insert(.partial) }
        case .timedOut: break
        }

        var children: [FolderID] = []
        var newFolders: [FolderID] = []
        var newDirect: UInt64 = 0
        var newBigNames: [String] = []
        var reshaped = false
        var pass: Set<UInt64> = []
        let skipped = excludedNames(in: folder)
        for entry in listing.outcome == .ok ? listing.entries : [] {
            if entry.kind == .directory {
                if skipped?.contains(entry.name) == true { continue }
                guard shouldDescend(entryDevice: entry.device, rootDevice: rootDevice, isMountPoint: entry.isMountPoint) else { continue }
                if let kept = oldChildren.removeValue(forKey: entry.name) {
                    children.append(kept)
                    let wasDataless = folders[Int(kept)].flags.contains(.dataless)
                    if wasDataless != entry.flags.contains(.dataless) {
                        // Downloaded since: list it now. Evicted: what it held is no longer on this Mac.
                        resetContents(of: kept)
                        if wasDataless { newFolders.append(kept) } else { folders[Int(kept)].flags.insert(.dataless) }
                        reshaped = true
                    }
                    continue
                }
                if entry.linkCount > 1, !claimHardLink(entry.inode, for: folder, pass: &pass) { continue }
                let new = FolderID(folders.count)
                folders.append(FolderRecord(parent: folder, nameOffset: folderNames.append(entry.name)))
                children.append(new)
                reshaped = true
                if entry.flags.contains(.dataless) { folders[Int(new)].flags.insert(.dataless) } else { newFolders.append(new) }
                continue
            }
            let stored = folders[id].bigFileCount
            newDirect += try addFile(entry, to: folder, pass: &pass)
            if folders[id].bigFileCount != stored { newBigNames.append(entry.name) }
        }
        link(children, under: folder)
        // Kept subfolders were removed from oldChildren, so any left there are gone. Stored files usually list in the
        // same order; only when they don't are they compared as sets.
        let namesChanged = !oldChildren.isEmpty || reshaped
            || (newBigNames != oldBigNames && Set(newBigNames) != Set(oldBigNames))

        var removedTotal: UInt64 = 0
        for gone in oldChildren.values {
            removedTotal += folders[Int(gone)].totalAllocated
            markGarbage(gone)
        }
        let delta = Int64(bitPattern: newDirect) - Int64(bitPattern: oldDirect) - Int64(bitPattern: removedTotal)
        addToTotals(from: folder, delta)
        return RelistResult(newFolders: newFolders, namesChanged: namesChanged)
    }

    /// Marks a folder whose listing hung or was skipped; it keeps what it had.
    func markStale(_ folder: FolderID) {
        folders[Int(folder)].flags.insert(.stale)
        newlyStale.append(folder)
    }

    /// Empties a folder so `integrate` can list it from scratch: its total leaves its
    /// ancestors, and everything below it becomes garbage.
    public func resetContents(of folder: FolderID) {
        let id = Int(folder)
        if folders[id].parent != noFolder {
            addToTotals(from: folders[id].parent, -Int64(bitPattern: folders[id].totalAllocated))
        }
        var child = folders[id].firstChildFolder
        while child != noFolder {
            let next = folders[Int(child)].nextSibling
            markGarbage(child)
            child = next
        }
        garbageFiles += Int(folders[id].bigFileCount)
        untable(folder)
        let keep = folders[id].flags.intersection(.garbage)
        folders[id] = FolderRecord(parent: folders[id].parent, nameOffset: folders[id].nameOffset)
        folders[id].flags = keep
    }

    /// The folder at a path relative to `rootPath` ("" is the root), or nil.
    public func folder(atRelativePath path: String) -> FolderID? {
        var current: FolderID = 0
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let child = child(named: part, of: current) else { return nil }
            current = child
        }
        return current
    }

    /// The deepest folder in the index on the way to a path relative to `rootPath` ("" is the root): one walk down,
    /// so a missing child costs one pass over its parent's subfolders.
    public func deepestFolder(onRelativePath path: String) -> FolderID {
        var current: FolderID = 0
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            guard let child = child(named: part, of: current) else { return current }
            current = child
        }
        return current
    }

    /// `folder`'s subfolder named `name`, or nil. An ASCII name is matched on its bytes, read in place: a lookup passes
    /// over every sibling, and event paths and listings both carry a name's own bytes. Any other name is compared as
    /// String comparison has it, so its NFC and NFD spellings agree.
    private func child(named name: Substring, of folder: FolderID) -> FolderID? {
        if let table = childTables[folder] { return table[String(name)] }
        var child = folders[Int(folder)].firstChildFolder
        var passed = 0
        if name.utf8.allSatisfy({ $0 < 0x80 }) {
            let bytes = Array(name.utf8)
            while child != noFolder, !folderNames.hasBytes(at: folders[Int(child)].nameOffset, bytes) {
                child = folders[Int(child)].nextSibling
                passed += 1
            }
        } else {
            while child != noFolder, folderName(child) != name {
                child = folders[Int(child)].nextSibling
                passed += 1
            }
        }
        guard child != noFolder else {
            if passed > Self.tableAbove { tableChildren(of: folder) }
            return nil
        }
        return child
    }

    /// After a miss in a folder with more than `tableAbove` subfolders: its subfolders by name. The first of two equal
    /// names wins, as in a pass over the siblings.
    private func tableChildren(of folder: FolderID) {
        var table: [String: FolderID] = [:]
        var child = folders[Int(folder)].firstChildFolder
        while child != noFolder {
            let name = folderName(child)
            if table[name] == nil { table[name] = child }
            child = folders[Int(child)].nextSibling
        }
        guard table.count <= Self.maxTabled else { return }
        if tabledNames + table.count > Self.maxTabled { dropChildTables() }
        childTables[folder] = table
        tabledNames += table.count
    }

    /// `folder`'s children changed (or it became garbage): its table, if any, goes.
    private func untable(_ folder: FolderID) {
        guard !childTables.isEmpty else { return }
        if let table = childTables.removeValue(forKey: folder) { tabledNames -= table.count }
    }

    private func dropChildTables() {
        childTables = [:]
        tabledNames = 0
    }

    /// The folder's path relative to the root ("" for the root).
    public func relativePath(of folder: FolderID) -> String {
        var parts: [String] = []
        var cursor = folder
        while cursor != 0 {
            parts.append(folderName(cursor))
            cursor = folders[Int(cursor)].parent
        }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: - Helpers

    /// Names of `folder`'s excluded subfolders, nil when there are none. Pays for one
    /// `relativePath(of:)` only when any exclusion is set.
    private func excludedNames(in folder: FolderID) -> Set<String>? {
        excludedChildren.isEmpty ? nil : excludedChildren[relativePath(of: folder)]
    }

    /// Counts a hard link once: it belongs to the first folder that claims it. It can be
    /// claimed again once that folder is garbage, or by the same folder in a later
    /// listing of it (a relist). `pass` holds the inodes claimed by the current listing.
    private func claimHardLink(_ inode: UInt64, for folder: FolderID, pass: inout Set<UInt64>) -> Bool {
        guard pass.insert(inode).inserted else { return false }
        if let owner = hardLinkOwners[inode], owner != folder, !folders[Int(owner)].flags.contains(.garbage) {
            return false
        }
        hardLinkOwners[inode] = folder
        return true
    }

    /// Adds one non-directory entry to `folder` and returns its counted bytes.
    private func addFile(_ entry: RawEntry, to folder: FolderID, pass: inout Set<UInt64>) throws -> UInt64 {
        var flags = entry.flags
        if entry.linkCount > 1 {
            guard claimHardLink(entry.inode, for: folder, pass: &pass) else { return 0 }
            flags.insert(.hardLinked)
        }
        let id = Int(folder)
        if entry.allocated >= Self.bigFileThreshold {
            let record = FileRecord(
                allocated: entry.allocated, parent: folder, nameOffset: 0,
                logicalKiB: UInt32(min(entry.logical / 1024, UInt64(UInt32.max))),
                flags: flags, kind: entry.kind.rawValue)
            let index = try files.append(name: entry.name, record: record)
            top.offer(index, allocated: entry.allocated)
            folders[id].bigFileCount += 1
        } else {
            folders[id].smallFileCount += 1
            folders[id].smallAllocated += entry.allocated
        }
        return entry.allocated
    }

    private func link(_ children: [FolderID], under folder: FolderID) {
        untable(folder)
        folders[Int(folder)].firstChildFolder = children.first ?? noFolder
        for (child, next) in zip(children, children.dropFirst() + [noFolder]) {
            folders[Int(child)].nextSibling = next
        }
    }

    /// Adds a signed change to `folder` and every ancestor (wrapping arithmetic keeps
    /// unsigned totals exact).
    private func addToTotals(from folder: FolderID, _ delta: Int64) {
        var cursor = folder
        while cursor != noFolder {
            folders[Int(cursor)].totalAllocated &+= UInt64(bitPattern: delta)
            cursor = folders[Int(cursor)].parent
        }
    }

    private func markGarbage(_ root: FolderID) {
        var stack = [root]
        while let folder = stack.popLast() {
            folders[Int(folder)].flags.insert(.garbage)
            untable(folder)
            garbageFolders += 1
            garbageFiles += Int(folders[Int(folder)].bigFileCount)
            var child = folders[Int(folder)].firstChildFolder
            while child != noFolder {
                stack.append(child)
                child = folders[Int(child)].nextSibling
            }
        }
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
        var child = record.firstChildFolder
        while child != noFolder {
            result.append(Child(kind: .folder(child), name: folderName(child), allocated: folders[Int(child)].totalAllocated))
            child = folders[Int(child)].nextSibling
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
