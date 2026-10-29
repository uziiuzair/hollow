// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension ScanIndex {
    /// Share of folder and file slots that are garbage.
    public var garbageRatio: Double {
        Double(garbageFolders + garbageFiles) / Double(max(1, folders.count + files.count))
    }

    /// A copy holding only what is reachable from the root, with a fresh file table in
    /// `storage`. Folders are renumbered breadth-first, so siblings sit together.
    public func compacted(into storage: URL) throws -> ScanIndex {
        let result = ScanIndex(files: try FileTable(directory: storage))
        var newID: [FolderID: FolderID] = [0: 0]
        var queue: [FolderID] = [0]
        var head = 0

        var rootRecord = FolderRecord(parent: noFolder, nameOffset: result.folderNames.append(folderName(0)))
        rootRecord.flags = folders[0].flags.subtracting(.garbage)
        result.folders.append(rootRecord)

        while head < queue.count {
            let old = queue[head]
            head += 1
            let new = newID[old]!
            let source = folders[Int(old)]

            result.folders[Int(new)].totalAllocated = source.totalAllocated
            result.folders[Int(new)].smallAllocated = source.smallAllocated
            result.folders[Int(new)].smallFileCount = source.smallFileCount
            result.folders[Int(new)].firstFile = FileIndex(result.files.count)
            result.folders[Int(new)].bigFileCount = source.bigFileCount
            for file in source.firstFile..<(source.firstFile + source.bigFileCount) {
                var record = try files.record(file)
                record.parent = new
                let index = try result.files.append(name: try files.name(file), record: record)
                result.top.offer(index, allocated: record.allocated)
            }

            var children: [FolderID] = []
            var child = source.firstChildFolder
            while child != noFolder {
                let id = FolderID(result.folders.count)
                var record = FolderRecord(parent: new, nameOffset: result.folderNames.append(folderName(child)))
                record.flags = folders[Int(child)].flags.subtracting(.garbage)
                result.folders.append(record)
                newID[child] = id
                children.append(id)
                queue.append(child)
                child = folders[Int(child)].nextSibling
            }
            result.folders[Int(new)].firstChildFolder = children.first ?? noFolder
            for (a, b) in zip(children, children.dropFirst() + [noFolder]) {
                result.folders[Int(a)].nextSibling = b
            }
        }

        for (inode, owner) in hardLinkOwners {
            if let mapped = newID[owner] { result.hardLinkOwners[inode] = mapped }
        }
        result.pending = pending.compactMap { newID[$0] }
        result.rootPath = rootPath
        result.rootDevice = rootDevice
        result.lastEventID = lastEventID
        result.fseventsUUID = fseventsUUID
        result.scannedAt = scannedAt
        result.exclusions = exclusions
        return result
    }
}
