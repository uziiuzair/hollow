import Foundation

/// Moves one item to the Trash. The app's only implementation lives in the `Diskinventory` target; tests use a fixture bin.
public protocol TrashBackend: Sendable {
    func trash(_ url: URL) throws
}

public enum TrashFailure: Equatable, Sendable {
    case alreadyGone, permissionDenied, outsideDrive, driveGone, failed(String)
}

public struct TrashFailureItem: Equatable, Sendable {
    public var path: String
    public var name: String
    public var reason: TrashFailure

    public init(path: String, name: String, reason: TrashFailure) {
        self.path = path
        self.name = name
        self.reason = reason
    }
}

public struct TrashOutcome: Equatable, Sendable {
    public var moved: [String]
    public var failures: [TrashFailureItem]
    public var freed: UInt64

    public init(moved: [String], failures: [TrashFailureItem], freed: UInt64) {
        self.moved = moved
        self.failures = failures
        self.freed = freed
    }

    /// The paths that leave the basket: moved, or already gone.
    public var cleared: Set<String> {
        Set(moved).union(failures.filter { $0.reason == .alreadyGone }.map(\.path))
    }

    public var title: String { moved.isEmpty ? "Nothing moved to the Trash" : "Freed " + Format.gb(freed) }

    public var detail: String? { moved.isEmpty ? nil : "It stays in the Trash until you empty it." }

    public var failureHeader: String? {
        switch failures.count {
        case 0: nil
        case 1: "1 item wasn't moved."
        case let n: "\(n) items weren't moved."
        }
    }

    public var failureLines: [String] {
        failures.map { f in
            switch f.reason {
            case .alreadyGone: "\(f.name): already gone."
            case .permissionDenied: "\(f.name): you don't have permission to move it. Try it in Finder."
            case .outsideDrive: "\(f.name): no longer on this drive."
            case .driveGone: "\(f.name): the drive was disconnected."
            case .failed(let message): "\(f.name): \(message)"
            }
        }
    }

    /// Every item that would have moved fails with `.driveGone`. App-managed items are left out, as `Trasher` leaves them out.
    public static func driveGone(_ items: [BasketItem]) -> TrashOutcome {
        TrashOutcome(moved: [], failures: items.filter { $0.safety != .appManaged }
            .map { TrashFailureItem(path: $0.path, name: $0.name, reason: .driveGone) }, freed: 0)
    }
}

/// Absolute paths for an item relative to a drive root.
public enum TrashPath {
    /// The internal disk's index root.
    public static let dataVolume = "/System/Volumes/Data"

    /// `root + "/" + relative`: where the item physically is.
    public static func physicalPath(root: String, relative: String) -> String {
        trimmed(root) + "/" + relative
    }

    /// The path a user sees. On the Data volume the `/System/Volumes/Data` prefix is dropped, so the item goes to the user's
    /// Trash (`~/.Trash`) rather than the volume's `.Trashes`. Elsewhere it is the physical path.
    public static func userPath(root: String, relative: String) -> String {
        trimmed(root) == dataVolume ? "/" + relative : physicalPath(root: root, relative: relative)
    }

    /// True for a non-empty relative path with no empty, `.` or `..` component, so it names exactly one item below the root.
    static func isPlainRelative(_ relative: String) -> Bool {
        !relative.isEmpty && relative.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func trimmed(_ root: String) -> String {
        root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }
}

/// The only code that moves user files. It moves only what the caller passes (the items checked in the review sheet), never
/// app-managed items, and never anything that resolves outside the drive.
public enum Trasher {
    static let containsManaged = "Contains an item managed by another app."

    /// `root` must be the drive's resolved root (`realpath`). `protected` is the drive's app-managed hits: an item that is or is
    /// inside one is skipped silently, and an item holding one fails without moving. The moves run off the main thread.
    public static func moveToTrash(_ items: [BasketItem], root: String, protected: [LensHit],
                                   backend: some TrashBackend) async -> TrashOutcome {
        await Task.detached(priority: .utility) {
            move(items, root: root, protected: protected, backend: backend)
        }.value
    }

    private static func move(_ items: [BasketItem], root: String, protected: [LensHit], backend: some TrashBackend) -> TrashOutcome {
        let base = TrashPath.trimmed(root)
        var moved: [String] = []
        var failures: [TrashFailureItem] = []
        var freed: UInt64 = 0
        for item in items {
            if item.safety == .appManaged || item.managingHit(in: protected) != nil { continue }
            func fail(_ reason: TrashFailure) { failures.append(TrashFailureItem(path: item.path, name: item.name, reason: reason)) }
            if item.containedHit(in: protected) != nil { fail(.failed(containsManaged)); continue }
            guard TrashPath.isPlainRelative(item.path) else { fail(.outsideDrive); continue }

            let physical = TrashPath.physicalPath(root: base, relative: item.path)
            var itemStat = stat()
            // lstat: the item itself is never followed, so a symlink item moves as the link.
            guard lstat(physical, &itemStat) == 0 else { fail(failure(errno: errno)); continue }
            // The parent must still resolve inside the drive. A folder on the way swapped for a symlink fails here.
            // Known gap (accepted): the parent could still be swapped between this check and the move. That needs a local attacker
            // racing a list the user just reviewed by hand, and the check still stops every stale or mistaken path.
            let parent = (physical as NSString).deletingLastPathComponent
            guard let resolved = realPath(parent) else { fail(failure(errno: errno)); continue }
            guard resolved == base || resolved.hasPrefix(base == "/" ? "/" : base + "/") else { fail(.outsideDrive); continue }

            let target = trashPath(physical: physical, physicalStat: itemStat, root: base, relative: item.path)
            do {
                try backend.trash(URL(filePath: target, directoryHint: .notDirectory))
                moved.append(item.path)
                freed += item.size
            } catch {
                fail(failure(error))
            }
        }
        return TrashOutcome(moved: moved, failures: failures, freed: freed)
    }

    /// The user path when it names the very same file (same device and inode, checked without following the item), else the
    /// physical path. Not every top-level folder of the Data volume has a firmlink at `/`.
    private static func trashPath(physical: String, physicalStat: stat, root: String, relative: String) -> String {
        let user = TrashPath.userPath(root: root, relative: relative)
        guard user != physical else { return physical }
        var st = stat()
        guard lstat(user, &st) == 0, st.st_dev == physicalStat.st_dev, st.st_ino == physicalStat.st_ino else { return physical }
        return user
    }

    private static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func failure(errno code: Int32) -> TrashFailure {
        switch code {
        case ENOENT, ENOTDIR: .alreadyGone
        case EACCES, EPERM: .permissionDenied
        default: .failed(String(cString: strerror(code)))
        }
    }

    static func failure(_ error: Error) -> TrashFailure {
        if let cocoa = error as? CocoaError {
            switch cocoa.code {
            case .fileWriteNoPermission, .fileReadNoPermission: return .permissionDenied
            case .fileNoSuchFile, .fileReadNoSuchFile: return .alreadyGone
            default: break
            }
        }
        var next: NSError? = error as NSError
        while let ns = next {
            if ns.domain == NSPOSIXErrorDomain {
                switch Int32(ns.code) {
                case EACCES, EPERM: return .permissionDenied
                case ENOENT: return .alreadyGone
                default: break
                }
            }
            next = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .failed(error.localizedDescription)
    }
}
