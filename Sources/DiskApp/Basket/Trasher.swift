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

    /// Every item that would have moved fails with `.driveGone`. Items `Trasher` would refuse are left out, as it leaves them out.
    public static func driveGone(_ items: [BasketItem], protected: [LensHit], rules: LensRules = .bundled) -> TrashOutcome {
        TrashOutcome(moved: [], failures: items
            .filter { TrashPath.isPlainRelative($0.path) && ReviewSheet.refusalKind(for: $0, protected: protected, rules: rules) == nil }
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
/// app-managed items, system or account folders, or anything that resolves outside the drive or onto another device.
public enum Trasher {
    static let containsManaged = "Contains an item managed by another app."

    /// The result of `lstat`: the record, or the errno.
    enum StatResult { case ok(stat), failed(Int32) }

    static func realStat(_ path: String) -> StatResult {
        var st = stat()
        return lstat(path, &st) == 0 ? .ok(st) : .failed(errno)
    }

    /// `root` must be the drive's resolved root (`realpath`). Every item passes the review sheet's own refusal check again here,
    /// with `rules`, so app-managed locations are refused even when `protected` (the drive's app-managed hits) is empty or stale:
    /// an app-managed item is skipped silently, and a system folder or a folder that holds or could hold an app-managed
    /// location fails without moving. With `expectedDevice`, a root on any other device moves nothing. The moves run off main.
    public static func moveToTrash(_ items: [BasketItem], root: String, protected: [LensHit], rules: LensRules = .bundled,
                                   expectedDevice: dev_t? = nil, backend: some TrashBackend) async -> TrashOutcome {
        await Task.detached(priority: .utility) {
            move(items, root: root, protected: protected, rules: rules, expectedDevice: expectedDevice, backend: backend, stat: realStat)
        }.value
    }

    static func move(_ items: [BasketItem], root: String, protected: [LensHit], rules: LensRules, expectedDevice: dev_t?,
                     backend: some TrashBackend, stat statFn: (String) -> StatResult) -> TrashOutcome {
        let base = TrashPath.trimmed(root)
        // nil: moved. Paths absent from `results` were skipped silently.
        var results: [String: TrashFailure?] = [:]

        var candidates: [BasketItem] = []
        for item in items where results[item.path] == nil && !candidates.contains(where: { $0.path == item.path }) {
            guard TrashPath.isPlainRelative(item.path) else { results[item.path] = .some(.outsideDrive); continue }
            switch ReviewSheet.refusalKind(for: item, protected: protected, rules: rules) {
            case .managed?: continue
            case .structural?: results[item.path] = .some(.failed(ReviewSheet.structuralReason))
            case .holds?: results[item.path] = .some(.failed(containsManaged))
            case nil: candidates.append(item)
            }
        }
        // An item inside another item of the same request moves with it, and its bytes count once, in the outermost item.
        // Paths compare exactly: `moveOne` only moves an item written exactly as it is on disk, so a case variant of an item
        // here fails on its own rather than being counted twice.
        let paths = candidates.map(\.path)
        func outermost(_ i: Int) -> Int {
            paths.indices.filter { paths[i] == paths[$0] || paths[i].hasPrefix(paths[$0] + "/") }
                .min { (paths[$0].count, $0) < (paths[$1].count, $1) }!
        }
        let outerIndex = candidates.indices.map(outermost)
        let outers = candidates.indices.filter { outerIndex[$0] == $0 }.map { candidates[$0] }

        func rootDevice() -> dev_t? {
            if case .ok(let st) = statFn(base), (st.st_mode & S_IFMT) == S_IFDIR { return st.st_dev }
            return nil
        }
        var freed: UInt64 = 0
        let device = rootDevice()
        let resolvedRoot = realPath(base)
        var gone = false
        for item in outers {
            // The root is checked before every item, so an ejected or replaced drive fails the rest as gone, not as already gone.
            // Once gone, it stays gone for this request, even if something comes back at that path.
            guard !gone, let device, let resolvedRoot, expectedDevice == nil || expectedDevice == device, rootDevice() == device else {
                gone = true
                results[item.path] = .some(.driveGone)
                continue
            }
            let reason = moveOne(item, base: base, resolvedRoot: resolvedRoot, device: device, backend: backend, stat: statFn)
            results[item.path] = .some(reason)
            if reason == nil { freed += item.size }
        }
        for i in candidates.indices where outerIndex[i] != i {
            results[candidates[i].path] = results[candidates[outerIndex[i]].path] ?? .some(.driveGone)
        }

        var moved: [String] = []
        var failures: [TrashFailureItem] = []
        var seen: Set<String> = []
        for item in items where seen.insert(item.path).inserted {
            guard let result = results[item.path] else { continue }
            if let reason = result {
                failures.append(TrashFailureItem(path: item.path, name: item.name, reason: reason))
            } else {
                moved.append(item.path)
            }
        }
        return TrashOutcome(moved: moved, failures: failures, freed: freed)
    }

    /// Nil when the item moved.
    private static func moveOne(_ item: BasketItem, base: String, resolvedRoot: String, device: dev_t, backend: some TrashBackend,
                                stat statFn: (String) -> StatResult) -> TrashFailure? {
        let physical = TrashPath.physicalPath(root: base, relative: item.path)
        // lstat: the item itself is never followed, so a symlink item moves as the link.
        let itemStat: stat
        switch statFn(physical) {
        case .ok(let st): itemStat = st
        case .failed(let code): return failure(errno: code)
        }
        // A different drive mounted inside the root, or anything else on another device, is not this drive.
        guard itemStat.st_dev == device else { return .outsideDrive }
        // The parent must resolve to exactly the folder the path names: no symlink anywhere in the parent chain, and the same
        // spelling as on disk. Otherwise a link or another spelling could lead to an app-managed or system folder the checks
        // above never saw by that name. String `==` allows canonically equivalent Unicode, nothing else.
        // Known gap (accepted): the parent could still be swapped between this check and the move. That needs a local attacker
        // racing a list the user just reviewed by hand, and the check still stops every stale or mistaken path.
        let parent = (physical as NSString).deletingLastPathComponent
        guard let resolved = realPath(parent) else { return failure(errno: errno) }
        let writtenParent = item.path.split(separator: "/").dropLast().joined(separator: "/")
        let expected = writtenParent.isEmpty ? resolvedRoot : (resolvedRoot == "/" ? "/" : resolvedRoot + "/") + writtenParent
        guard resolved == expected else { return .outsideDrive }
        // The item's own name must be its on-disk name too. The file system folds case and Unicode (`ſ` opens `s`) more widely
        // than any check here could match, so ask it which item the written path opens.
        switch onDiskPath(physical) {
        case .failure(let e): return failure(errno: e.code)
        case .success(let actual):
            let exact = (expected == "/" ? "/" : expected + "/") + (physical as NSString).lastPathComponent
            // On the Data volume the kernel reports the firmlinked path (`/Users/...`), never `/System/Volumes/Data/Users/...`.
            guard actual == exact || actual == TrashPath.userPath(root: resolvedRoot, relative: item.path) else { return .outsideDrive }
        }

        let target = trashPath(physical: physical, physicalStat: itemStat, root: base, relative: item.path, stat: statFn)
        do {
            try backend.trash(URL(filePath: target, directoryHint: .notDirectory))
            return nil
        } catch {
            return failure(error)
        }
    }

    /// The user path when it names the very same file (same device and inode, checked without following the item), else the
    /// physical path. Not every top-level folder of the Data volume has a firmlink at `/`.
    private static func trashPath(physical: String, physicalStat: stat, root: String, relative: String,
                                  stat statFn: (String) -> StatResult) -> String {
        let user = TrashPath.userPath(root: root, relative: relative)
        guard user != physical, case .ok(let st) = statFn(user), st.st_dev == physicalStat.st_dev, st.st_ino == physicalStat.st_ino
        else { return physical }
        return user
    }

    /// The path the kernel holds for the item the written path opens (`F_GETPATH`). `O_SYMLINK` opens a symlink item as the
    /// link; `O_EVTONLY` needs no read access; `O_NONBLOCK` keeps a FIFO from blocking. The descriptor is closed before returning.
    static func onDiskPath(_ path: String) -> Result<String, Errno> {
        let fd = open(path, O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(Errno(errno)) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return .failure(Errno(errno)) }
        return .success(String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self))
    }

    struct Errno: Error { let code: Int32; init(_ code: Int32) { self.code = code } }

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
