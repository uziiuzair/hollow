// SPDX-License-Identifier: GPL-3.0-or-later

public typealias FolderID = UInt32
public typealias FileIndex = UInt32

/// Marks "no folder", used as the root's parent.
public let noFolder: FolderID = .max

public struct FolderFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let unreadable = FolderFlags(rawValue: 1 << 0)
    public static let vanished = FolderFlags(rawValue: 1 << 1)
    public static let otherDevice = FolderFlags(rawValue: 1 << 2)
    /// Some entries could not be read; the folder total may be low.
    public static let partial = FolderFlags(rawValue: 1 << 3)
    /// No longer reachable from the root; removed at the next compaction.
    public static let garbage = FolderFlags(rawValue: 1 << 4)
    /// A cloud folder whose contents aren't on this Mac. Never opened, so never downloaded; its parent's listing says
    /// when that changes.
    public static let dataless = FolderFlags(rawValue: 1 << 5)
    /// Its listing hung or was skipped (`DirectoryLister`): it keeps what it had and is listed again later.
    public static let stale = FolderFlags(rawValue: 1 << 6)
}

public struct FileFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let dataless = FileFlags(rawValue: 1 << 0)
    public static let mayShareBlocks = FileFlags(rawValue: 1 << 1)
    public static let hardLinked = FileFlags(rawValue: 1 << 2)
    public static let symlink = FileFlags(rawValue: 1 << 3)
}

/// One folder, 48 bytes. Subfolders form a linked list (first child, next sibling)
/// so folder IDs never change once assigned; stored files are one contiguous block.
public struct FolderRecord: Sendable {
    public var parent: FolderID
    public var nameOffset: UInt32
    public var firstChildFolder: FolderID
    public var nextSibling: FolderID
    public var firstFile: FileIndex
    public var bigFileCount: UInt32
    public var smallFileCount: UInt32
    public var flags: FolderFlags
    public var totalAllocated: UInt64
    public var smallAllocated: UInt64

    public init(parent: FolderID, nameOffset: UInt32) {
        self.parent = parent
        self.nameOffset = nameOffset
        firstChildFolder = noFolder
        nextSibling = noFolder
        firstFile = 0
        bigFileCount = 0
        smallFileCount = 0
        flags = []
        totalAllocated = 0
        smallAllocated = 0
    }
}

/// One stored file, 24 bytes. Lives in a memory-mapped file, not in RAM.
public struct FileRecord: Sendable {
    public var allocated: UInt64
    public var parent: FolderID
    public var nameOffset: UInt32
    public var logicalKiB: UInt32
    public var flags: FileFlags
    public var kind: UInt8
    var pad: UInt8 = 0

    public init(allocated: UInt64, parent: FolderID, nameOffset: UInt32, logicalKiB: UInt32, flags: FileFlags, kind: UInt8) {
        self.allocated = allocated
        self.parent = parent
        self.nameOffset = nameOffset
        self.logicalKiB = logicalKiB
        self.flags = flags
        self.kind = kind
    }
}
