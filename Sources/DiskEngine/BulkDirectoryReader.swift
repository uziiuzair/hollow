import Darwin

public enum EntryKind: UInt8, Sendable {
    case file = 0, directory = 1, symlink = 2, other = 3
}

public struct RawEntry: Sendable {
    public var name: String
    public var kind: EntryKind
    public var allocated: UInt64
    public var logical: UInt64
    public var device: Int32
    public var inode: UInt64
    public var linkCount: UInt32
    public var flags: FileFlags
    public var isMountPoint: Bool

    public init(name: String, kind: EntryKind, allocated: UInt64, logical: UInt64, device: Int32,
                inode: UInt64, linkCount: UInt32, flags: FileFlags, isMountPoint: Bool) {
        self.name = name
        self.kind = kind
        self.allocated = allocated
        self.logical = logical
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.flags = flags
        self.isMountPoint = isMountPoint
    }
}

public enum ListingOutcome: Sendable {
    case ok, unreadable, vanished
    /// Not read: the listing hung or was skipped (`DirectoryLister`). The folder keeps what it had.
    case timedOut
}

/// Stops this process from downloading dataless (cloud) files and folders when it touches them: they read as errors
/// instead. Call once at start; a scan must never cause a cloud download.
public func forbidDatalessMaterialization() {
    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
}

public struct DirectoryListing: Sendable {
    public var folder: FolderID
    public var outcome: ListingOutcome
    public var entries: [RawEntry]
    /// True when some entries could not be read, so `entries` is incomplete.
    public var partial: Bool

    public init(folder: FolderID, outcome: ListingOutcome, entries: [RawEntry], partial: Bool = false) {
        self.folder = folder
        self.outcome = outcome
        self.entries = entries
        self.partial = partial
    }
}

/// Lists one directory per call with `getattrlistbulk`, reusing one 64 KB buffer.
struct BulkDirectoryReader {
    static let bufferSize = 65_536

    // Not all of these are imported into Swift.
    private static let fsoptAttrCmnExtended: UInt64 = 0x20
    private static let sfDataless: UInt32 = 0x4000_0000
    private static let efMayShareBlocks: UInt64 = 0x1
    private static let cmnextExtFlags: UInt32 = 0x200

    private static let common = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID)
        | UInt32(ATTR_CMN_OBJTYPE) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID)
    private static let dir = UInt32(ATTR_DIR_LINKCOUNT) | UInt32(ATTR_DIR_MOUNTSTATUS)
    private static let file = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_ALLOCSIZE) | UInt32(ATTR_FILE_DATALENGTH)

    /// Owns the read buffer so it is freed with the reader.
    private final class Buffer {
        let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: BulkDirectoryReader.bufferSize, alignment: 8)
        deinit { bytes.deallocate() }
    }

    private let storage = Buffer()
    private var buffer: UnsafeMutableRawBufferPointer { storage.bytes }

    init() {}

    mutating func list(path: String, folder: FolderID) -> DirectoryListing {
        // Paths are rebuilt from the index, which never holds a symlinked folder, so a symlink anywhere on the way is
        // refused (O_NOFOLLOW_ANY covers O_NOFOLLOW; the two together are EINVAL).
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        if fd < 0 {
            let outcome: ListingOutcome = (errno == EACCES || errno == EPERM) ? .unreadable : .vanished
            return DirectoryListing(folder: folder, outcome: outcome, entries: [])
        }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.common
        request.dirattr = Self.dir
        request.fileattr = Self.file
        request.forkattr = Self.cmnextExtFlags

        var entries: [RawEntry] = []
        var partial = false
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress!, Self.bufferSize, Self.fsoptAttrCmnExtended)
            if count < 0 {
                if errno == EINTR { continue }
                let failure = errno
                if entries.isEmpty && (failure == EACCES || failure == EPERM) {
                    return DirectoryListing(folder: folder, outcome: .unreadable, entries: [])
                }
                // ENOENT: the folder was removed while we read it; what we have is all there is.
                return DirectoryListing(folder: folder, outcome: .ok, entries: entries, partial: partial || failure != ENOENT)
            }
            if count == 0 { break }
            var entryStart = 0
            for _ in 0..<count {
                let length = Int(buffer.load(fromByteOffset: entryStart, as: UInt32.self))
                let parsed = Self.parse(UnsafeRawBufferPointer(rebasing: buffer[entryStart..<(entryStart + length)]))
                if parsed.error == 0 { entries.append(parsed.entry) } else { partial = true }
                entryStart += length
            }
        }
        return DirectoryListing(folder: folder, outcome: .ok, entries: entries, partial: partial)
    }

    /// Parses one entry. Fields appear in the kernel's fixed order (common, directory,
    /// file, then extended common), and only those flagged in `returned` are present.
    /// A non-zero `error` means the kernel could not read this entry's attributes.
    static func parse(_ e: UnsafeRawBufferPointer) -> (entry: RawEntry, error: UInt32) {
        var cursor = 4
        func take<T>(_: T.Type) -> T {
            let value = e.loadUnaligned(fromByteOffset: cursor, as: T.self)
            cursor += MemoryLayout<T>.size
            return value
        }
        let returned = take(attribute_set_t.self)
        func has(_ set: UInt32, _ bit: Int32) -> Bool { set & UInt32(bit) != 0 }
        let error = has(returned.commonattr, ATTR_CMN_ERROR) ? take(UInt32.self) : 0

        var name = ""
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let refStart = cursor
            let ref = take(attrreference_t.self)
            let start = refStart + Int(ref.attr_dataoffset)
            let bytes = UnsafeRawBufferPointer(rebasing: e[start..<(start + Int(ref.attr_length))])
            // attr_length includes the trailing NUL.
            name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let device = has(returned.commonattr, ATTR_CMN_DEVID) ? take(Int32.self) : 0
        let objType = has(returned.commonattr, ATTR_CMN_OBJTYPE) ? take(UInt32.self) : 0
        let bsdFlags = has(returned.commonattr, ATTR_CMN_FLAGS) ? take(UInt32.self) : 0
        let inode = has(returned.commonattr, ATTR_CMN_FILEID) ? take(UInt64.self) : 0
        let dirLinkCount = has(returned.dirattr, ATTR_DIR_LINKCOUNT) ? take(UInt32.self) : 1
        let mountStatus = has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) ? take(UInt32.self) : 0
        let fileLinkCount = has(returned.fileattr, ATTR_FILE_LINKCOUNT) ? take(UInt32.self) : 1
        let allocated = has(returned.fileattr, ATTR_FILE_ALLOCSIZE) ? take(Int64.self) : 0
        let logical = has(returned.fileattr, ATTR_FILE_DATALENGTH) ? take(Int64.self) : 0
        let extFlags = returned.forkattr & cmnextExtFlags != 0 ? take(UInt64.self) : 0

        let kind: EntryKind
        switch objType {
        case UInt32(VREG.rawValue): kind = .file
        case UInt32(VDIR.rawValue): kind = .directory
        case UInt32(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }
        var flags: FileFlags = []
        if bsdFlags & sfDataless != 0 { flags.insert(.dataless) }
        if extFlags & efMayShareBlocks != 0 { flags.insert(.mayShareBlocks) }
        if kind == .symlink { flags.insert(.symlink) }

        let entry = RawEntry(
            name: name, kind: kind,
            allocated: kind == .directory ? 0 : UInt64(max(allocated, 0)),
            logical: UInt64(max(logical, 0)),
            device: device, inode: inode, linkCount: kind == .directory ? dirLinkCount : fileLinkCount, flags: flags,
            isMountPoint: mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0)
        return (entry, error)
    }
}
