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
}

public struct FileFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let dataless = FileFlags(rawValue: 1 << 0)
    public static let mayShareBlocks = FileFlags(rawValue: 1 << 1)
    public static let hardLinked = FileFlags(rawValue: 1 << 2)
    public static let symlink = FileFlags(rawValue: 1 << 3)
}

/// One folder, 48 bytes. A folder's subfolders and stored files are contiguous,
/// so a range (first + count) replaces linked lists.
public struct FolderRecord: Sendable {
    public var parent: FolderID
    public var nameOffset: UInt32
    public var firstChildFolder: FolderID
    public var childFolderCount: UInt32
    public var firstFile: FileIndex
    public var bigFileCount: UInt32
    public var smallFileCount: UInt32
    public var flags: FolderFlags
    public var totalAllocated: UInt64
    public var smallAllocated: UInt64

    public init(parent: FolderID, nameOffset: UInt32) {
        self.parent = parent
        self.nameOffset = nameOffset
        firstChildFolder = 0
        childFolderCount = 0
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
