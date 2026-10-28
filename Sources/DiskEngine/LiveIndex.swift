import CoreServices
import Darwin
import Foundation
import os

public enum OpenedFrom: Sendable, Equatable {
    case snapshot
    case resumed
    case fullScan(reason: String)
}

/// What one update of a `LiveIndex` changed.
public struct IndexChange: Equatable, Sendable {
    public var generation: Int
    /// Relative paths of the outermost changed folders ("" is the root), each with the change in its total. A path whose
    /// ancestor is also changed is not listed. Nil when anything may have changed: a full rescan, a compaction, an
    /// exclusions change, a retry of unreadable folders.
    public var folders: [String: Int64]?
    /// The same outermost paths, each with the bytes that came into or left every touched folder at or under it, added
    /// by magnitude: a move between two touched folders counts twice, though it nets zero in `folders`. Empty when
    /// `folders` is nil.
    public var moved: [String: UInt64]
    /// Relative paths of the touched folders whose blocks (subfolders and stored files, by name) were added, removed or
    /// renamed, whatever their sizes. Empty when `folders` is nil.
    public var renamed: Set<String>

    /// More paths than this in `folders` or `renamed` and the change says "anything may have changed" (nil folders),
    /// so a change merged for a long time stays small.
    public static let maxPaths = 256

    /// `moved` defaults to the magnitude of each net delta in `folders`.
    public init(generation: Int, folders: [String: Int64]?, moved: [String: UInt64]? = nil, renamed: Set<String> = []) {
        self.generation = generation
        guard let folders, folders.count <= Self.maxPaths, renamed.count <= Self.maxPaths else {
            self.folders = nil; self.moved = [:]; self.renamed = []
            return
        }
        self.folders = folders
        self.moved = moved ?? folders.mapValues(\.magnitude)
        self.renamed = renamed
    }

    /// Both changes as one (C16): nil folders win; otherwise each outermost path carries every delta at or below it,
    /// nets summed with their signs and moved bytes by magnitude, so a move out and back still counts.
    public func merged(with later: IndexChange) -> IndexChange {
        guard let mine = folders, let theirs = later.folders else { return IndexChange(generation: later.generation, folders: nil) }
        var sums = mine
        for (path, delta) in theirs { sums[path, default: 0] &+= delta }
        var moves = moved
        for (path, bytes) in later.moved { moves[path, default: 0] &+= bytes }
        return IndexChange(generation: later.generation, folders: Self.outermost(sums), moved: Self.outermost(moves),
                           renamed: renamed.union(later.renamed))
    }

    /// Drops every path that has an ancestor in `deltas`, adding its delta to that ancestor's.
    static func outermost<T: FixedWidthInteger>(_ deltas: [String: T]) -> [String: T] {
        var result: [String: T] = [:]
        for (path, delta) in deltas {
            result[outermostAncestor(of: path) { deltas[$0] != nil }, default: 0] &+= delta
        }
        return result
    }

    /// The shallowest relative path at or above `path` ("" is above everything) for which `present` holds; `path` itself
    /// when none above it does. Walks the path's own prefixes, so it costs its depth, not the number of paths.
    static func outermostAncestor(of path: String, where present: (String) -> Bool) -> String {
        guard !path.isEmpty else { return path }
        if present("") { return "" }
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            let prefix = String(path[..<slash])
            if present(prefix) { return prefix }
            index = path.index(after: slash)
        }
        return path
    }
}

/// What `LiveIndex.apply` has done since the index was created.
public struct ApplyStats: Equatable, Sendable {
    public var applies: Int
    public var foldersRelisted: Int
    public var subtreesRescanned: Int
    public var fullRescans: Int
    /// Time spent applying changes.
    public var busy: Duration

    public init(applies: Int, foldersRelisted: Int, subtreesRescanned: Int, fullRescans: Int, busy: Duration) {
        self.applies = applies
        self.foldersRelisted = foldersRelisted
        self.subtreesRescanned = subtreesRescanned
        self.fullRescans = fullRescans
        self.busy = busy
    }
}

/// Keeps one volume's index on disk and current: loads or scans it, resumes unfinished
/// scans, follows FSEvents from the stored event ID, re-lists only folders that
/// changed, saves on a debounce, and compacts when garbage builds up.
public actor LiveIndex {
    #if DEBUG
    private static let log = Logger(subsystem: "com.ooozzy.diskinventory", category: "index")
    #endif
    public let volumeRoot: URL
    public let store: URL
    private let saveDebounce: Duration
    private let compactAbove: Double

    var index: ScanIndex?
    private var rootPath = ""
    private var rootDevice: dev_t = 0
    /// Set once the root is found gone or replaced (volume unmounted under us). The
    /// index may then be missing whole subtrees, so it is never saved or recorded again.
    private var rootLost = false
    private var mountPoint = ""
    private var watcher: EventWatcher?
    private var watchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    // Index work suspends inside scans; this keeps a second apply or save from running
    // in between (actor reentrancy).
    private var closed = false
    /// Set when an apply failed part-way: the index can't be trusted until a full rescan.
    private var needsFullRescan = false
    private var fault: (@Sendable () throws -> Void)?
    private var beforeScan: (@Sendable () -> Void)?
    private var busy = false
    /// `ContentKind.totals` for the current index; nil after anything changes it.
    var cachedKinds: [ContentKind: UInt64]?
    private var generation = 0
    private var subscribers: [UUID: AsyncStream<IndexChange>.Continuation] = [:]
    var kindsComputations = 0
    /// Folders relisted by `apply` (not by exclusion changes or scans).
    var relistCount = 0
    private var applies = 0
    private var subtreeCount = 0
    private var fullRescanCount = 0
    private var busyTime: Duration = .zero
    /// A folder applied within this window of its last apply waits until the window has passed (background churn).
    private let coalesceWindow: Duration
    /// Changes waiting out the window, by path, merged: the highest ID, flags OR-ed.
    private var deferred: [String: FSChange] = [:]
    /// When each recently changed path was last applied. Entries older than the window are pruned.
    private var lastRelist: [String: ContinuousClock.Instant] = [:]
    private var flushTask: Task<Void, Never>?
    /// Folders whose listing hung or was skipped, by absolute path, and when to list them again. Not deferred changes:
    /// their events count as applied (with what the folder had), so they never hold back the stored event ID.
    private var staleRetry: [String: ContinuousClock.Instant] = [:]
    private var lister = DirectoryLister.shared
    private var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    /// Tests only: false leaves FSEvents unwatched, so only the changes a test feeds in reach the index.
    private var watchEvents = true
    private var mountPointLookup: @Sendable (String) throws -> String = { try EventPathMapper.requireMountPoint(of: $0) }
    /// Relative paths the index leaves out; what the index currently reflects.
    private var exclusions: Set<String>
    /// What `exclusions.json` last held, so a save rewrites it only when it differs.
    private var writtenExclusions: Set<String>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(volumeRoot: URL, store: URL, saveDebounce: Duration = .seconds(30), compactAbove: Double = 0.25,
                exclusions: Set<String> = [], coalesceWindow: Duration = .seconds(10)) {
        self.coalesceWindow = coalesceWindow
        self.exclusions = ExclusionPaths.normalized(exclusions)
        self.volumeRoot = volumeRoot
        self.store = store
        self.saveDebounce = saveDebounce
        self.compactAbove = compactAbove
    }

    /// `base/Volumes/<volume UUID>/`, created if needed.
    public static func storeDirectory(base: URL, volume: URL) throws -> URL {
        guard let uuid = try volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else {
            throw DiskEngineError.posix("volume UUID for \(volume.path)", ENOTSUP)
        }
        let dir = storeDirectory(base: base, uuid: uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `base/Volumes/<uuid>/`; does not create it.
    public static func storeDirectory(base: URL, uuid: String) -> URL {
        base.appending(path: "Volumes").appending(path: uuid)
    }

    private static let exclusionsName = "exclusions.json"

    /// The exclusions the stored snapshot was built with; empty when none were recorded.
    private func storedExclusions() -> Set<String> {
        guard let data = try? Data(contentsOf: store.appending(path: Self.exclusionsName)),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ExclusionPaths.normalized(Set(paths))
    }

    private func writeExclusions() throws {
        guard writtenExclusions != exclusions else { return }
        let data = try JSONEncoder().encode(exclusions.sorted())
        try data.write(to: store.appending(path: Self.exclusionsName), options: .atomic)
        writtenExclusions = exclusions
    }

    /// Relists the parent of every added or removed exclusion that exists in the index, and scans
    /// the folders that brings back. Never a full scan.
    private func reconcile(from old: Set<String>, in index: ScanIndex) async throws {
        var parents: Set<String> = []
        for path in old.symmetricDifference(exclusions) {
            parents.insert(path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "")
        }
        var toScan: [FolderID] = []
        for parent in parents.sorted() {
            guard let folder = index.folder(atRelativePath: parent), !index.folders[Int(folder)].flags.contains(.garbage) else { continue }
            toScan += try index.relist(await listing(of: folder, in: index)).newFolders
        }
        try fault?()
        if !toScan.isEmpty { try await scan(index, starting: toScan) }
    }

    /// Changes the folders left out of the index. Relists only their parents; never a full scan.
    public func setExclusions(_ requested: Set<String>) async throws {
        let paths = ExclusionPaths.normalized(requested)
        await lock()
        defer { unlock() }
        guard !closed, let index, paths != exclusions else { return }
        let old = exclusions
        exclusions = paths
        index.exclusions = paths
        defer { armStaleRetries(index) }
        do {
            try await reconcile(from: old, in: index)
        } catch {
            indexChanged(folders: nil)
            needsFullRescan = true
            unlink(store.appending(path: ScanIndex.snapshotName).path)
            throw error
        }
        indexChanged(folders: nil)
        // exclusions.json follows the snapshot (saveLocked), so a crash before then reconciles again on reopen.
        scheduleSave()
    }

    /// Relists every folder that was unreadable when it was last listed (Full Disk Access may have been granted
    /// since), scans what turns up, and returns how many of them are readable now. `beforeScan` (tests) runs just before
    /// the scan of what turned up starts.
    public func retryUnreadable(beforeScan: (@Sendable () -> Void)? = nil) async throws -> Int {
        await lock()
        defer { unlock() }
        guard !closed, let index else { return 0 }
        defer { armStaleRetries(index) }
        var readable = 0
        var toScan: [FolderID] = []
        // Cancelled (an unmount): the folders not yet relisted stay unreadable and are retried at the next open.
        for id in 0..<index.folders.count where !Task.isCancelled {
            let flags = index.folders[id].flags
            guard flags.contains(.unreadable), !flags.contains(.garbage) else { continue }
            let listing = await listing(of: FolderID(id), in: index)
            if listing.outcome == .ok { readable += 1 }
            toScan += try index.relist(listing).newFolders
        }
        if !toScan.isEmpty {
            beforeScan?()
            try await scan(index, starting: toScan)
        }
        if readable > 0 {
            indexChanged(folders: nil)
            scheduleSave()
        }
        return readable
    }

    public func open() async throws -> OpenedFrom {
        await lock()
        defer { unlock() }
        guard let resolved = realpath(volumeRoot.path, nil) else { throw DiskEngineError.posix("realpath", errno) }
        rootPath = String(cString: resolved)
        free(resolved)
        var info = stat()
        guard stat(rootPath, &info) == 0 else { throw DiskEngineError.posix("stat \(rootPath)", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DiskEngineError.notADirectory(rootPath) }
        let device = info.st_dev
        rootDevice = device
        let journal = EventWatcher.journalUUID(device: device)
        // The device's real mount point ("/System/Volumes/Data" for the internal disk, where the
        // volume URL says "/"): FSEvents device streams report paths relative to it.
        // No fallback: a wrong mount point would silently drop every event for the volume. Throws statfs's own errno.
        mountPoint = try mountPointLookup(rootPath)

        cachedKinds = nil
        var reason: String?
        var loaded: ScanIndex?
        do {
            loaded = try ScanIndex.load(from: store)
        } catch SnapshotError.missing {
            reason = "no snapshot"
        } catch {
            reason = "incompatible snapshot"
        }
        if let loaded, reason == nil {
            if loaded.rootPath != rootPath {
                reason = "different root"
            } else if journal == nil {
                reason = "no event history"
            } else if loaded.fseventsUUID != journal {
                reason = "event history changed"
            }
        }

        let storedExclusions = self.storedExclusions()
        let opened: OpenedFrom
        if let reason {
            index = try await fullScan(device: device, journal: journal)
            opened = .fullScan(reason: reason)
        } else if let loaded, !loaded.pending.isEmpty {
            loaded.rootDevice = device
            loaded.exclusions = exclusions
            index = loaded
            try await scan(loaded, starting: loaded.pending)
            try await reconcile(from: storedExclusions, in: loaded)
            opened = .resumed
        } else {
            // st_dev changes when a drive is replugged or after a reboot.
            loaded?.rootDevice = device
            loaded?.exclusions = exclusions
            index = loaded
            if let loaded { try await reconcile(from: storedExclusions, in: loaded) }
            opened = .snapshot
        }

        guard rootPresent() else {
            throw DiskEngineError.posix("volume removed during scan of \(rootPath)", ENODEV)
        }
        if let index, !index.pending.isEmpty {
            // Cut short (cancelled): keep it only as a resumable snapshot, never as complete.
            try saveLocked()
            throw CancellationError()
        }

        if let index { retryStale(in: index) }
        try startWatching(device: device)
        try saveLocked()
        scheduleFlush()
        return opened
    }

    /// Applies changed folders. Paths are absolute; ones outside the root are ignored.
    public func apply(_ changes: [FSChange]) async throws {
        try await apply(changes, advanceTo: changes.map(\.id).max() ?? 0)
    }

    /// Applies changed folders, then advances the stored event ID to `eventID` (never back).
    func apply(_ changes: [FSChange], advanceTo eventID: UInt64) async throws {
        await lock()
        defer { unlock() }
        guard !closed, let index, !changes.isEmpty else { return }
        defer { armStaleRetries(index) }
        do {
            let start = ContinuousClock.now
            let outcome = try await applyLocked(changes, to: index)
            busyTime += ContinuousClock.now - start
            // A scan cut short (cancelled, or the volume going) leaves folders pending: not applied, whatever it says.
            guard index.pending.isEmpty else { throw CancellationError() }
            switch outcome {
            case .untouched: break
            case .full: indexChanged(folders: nil)
            case .folders(let deltas, let moved, let renamed): indexChanged(folders: deltas, moved: moved, renamed: renamed)
            }
        } catch {
            indexChanged(folders: nil)
            // Part of the change may be in the index; drop the snapshot so a crash means a
            // full rescan, and rescan on the next apply. The event ID stays put. A vanished root saves
            // nothing again, so the older snapshot on disk stays consistent and is kept.
            needsFullRescan = true
            if rootPresent() { unlink(store.appending(path: ScanIndex.snapshotName).path) }
            throw error
        }
        // Advance only after the changes are in the index (spec 6.6).
        index.lastEventID = max(index.lastEventID, eventID)
        scheduleSave()
    }

    /// Takes a batch from the watcher. A folder applied within `coalesceWindow` waits until the window has passed, so a
    /// folder another app writes to every second costs one relist per window. Subtree rescans and lost history never
    /// wait, and a busy folder never holds up another.
    func enqueue(_ changes: [FSChange]) async {
        guard !closed else { return }
        let now = self.now()
        var due: [FSChange] = []
        for change in changes {
            if change.historyLost || change.rescanSubtree {
                // The rescan covers a relist of the same folder that is waiting out its window.
                if let waiting = deferred.removeValue(forKey: change.path) { due.append(waiting) }
                due.append(change)
                lastRelist[change.path] = now
            } else if let last = lastRelist[change.path], now - last < coalesceWindow {
                deferred[change.path] = deferred[change.path].map { Self.merged($0, change) } ?? change
            } else {
                // Leading edge: the first change in a while applies at once.
                due.append(change)
                lastRelist[change.path] = now
            }
        }
        // A full rescan covers everything waiting.
        if due.contains(where: \.historyLost) {
            due += deferred.values
            deferred = [:]
        }
        if let applied = due.map(\.id).max() {
            try? await apply(due, advanceTo: min(applied, deferredFloor))
        }
        scheduleFlush()
    }

    /// Applies the deferred changes whose window has passed. Called by the flush timer, and by tests.
    func flushDue() async {
        guard !closed else { return }
        let now = self.now()
        var due = deferred.values.filter { change in lastRelist[change.path].map { now - $0 >= coalesceWindow } ?? true }
        for change in due {
            deferred[change.path] = nil
            lastRelist[change.path] = now
        }
        // ID 0: a retry moves the stored event ID nowhere.
        for (path, at) in staleRetry where at <= now {
            staleRetry[path] = nil
            due.append(FSChange(path: path, id: 0, rescanSubtree: false, historyLost: false))
        }
        if let applied = due.map(\.id).max() {
            try? await apply(due, advanceTo: min(applied, deferredFloor))
        }
        scheduleFlush()
    }

    /// One timer, due when the earliest deferred change's window ends. Prunes paths whose window has passed.
    func scheduleFlush() {
        flushTask?.cancel()
        flushTask = nil
        guard !closed else { return }
        let now = self.now()
        lastRelist = lastRelist.filter { path, last in deferred[path] != nil || now - last < coalesceWindow }
        guard !deferred.isEmpty || !staleRetry.isEmpty else { return }
        let ends = deferred.keys.compactMap { lastRelist[$0] }.map { $0 + coalesceWindow } + staleRetry.values
        let end = ends.min() ?? now
        let delay = max(end - now, .zero)
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.flushFromTimer()
        }
    }

    /// The timer is cancelled only while it sleeps: once it starts flushing it lets go of `flushTask`, so a batch that
    /// arrives meanwhile (which reschedules) can't cancel the scan it is running.
    private func flushFromTimer() async {
        guard !Task.isCancelled else { return }
        flushTask = nil
        await flushDue()
    }

    /// The highest event ID the stored one may reach: just below the oldest change still deferred (spec 6.6). Quitting
    /// drops those, and the next open replays them from the stored ID. Taken when a batch is formed, before its apply
    /// waits for the lock, so a flush already queued ahead of it is still counted.
    private var deferredFloor: UInt64 {
        deferred.values.map(\.id).min().map { $0 - 1 } ?? .max
    }

    /// Lists again, once the lister would try them, the folders the index marked stale since the last call.
    private func armStaleRetries(_ index: ScanIndex) {
        guard !index.newlyStale.isEmpty else { return }
        let due = now() + lister.skipFor
        for folder in index.newlyStale {
            let flags = index.folders[Int(folder)].flags
            guard flags.contains(.stale), !flags.contains(.garbage) else { continue }
            let path = index.path(of: folder, rootPath: index.rootPath)
            staleRetry[path] = min(staleRetry[path] ?? due, due)
        }
        index.newlyStale = []
        scheduleFlush()
    }

    /// At open: every stale folder in the index is listed again soon, including those a snapshot carried over.
    private func retryStale(in index: ScanIndex) {
        let now = self.now()
        for id in 0..<index.folders.count {
            let flags = index.folders[id].flags
            guard flags.contains(.stale), !flags.contains(.garbage) else { continue }
            staleRetry[index.path(of: FolderID(id), rootPath: index.rootPath)] = now
        }
        index.newlyStale = []
    }

    /// Lists one folder through the lister, so a folder that hangs costs its deadline, not the lock. One that timed
    /// out or was skipped reads as `.timedOut`, which `relist` leaves as it was.
    private func listing(of folder: FolderID, in index: ScanIndex) async -> DirectoryListing {
        let path = index.path(of: folder, rootPath: index.rootPath)
        #if DEBUG
        Self.log.debug("relist \(path, privacy: .public)")
        #endif
        let outcome = await lister.list(path: path, folder: folder)
        guard case .listed(let listing) = outcome else {
            #if DEBUG
            Self.log.info("relist \(String(describing: outcome), privacy: .public): \(path, privacy: .public)")
            #endif
            return DirectoryListing(folder: folder, outcome: .timedOut, entries: [])
        }
        return listing
    }

    private static func merged(_ a: FSChange, _ b: FSChange) -> FSChange {
        FSChange(path: a.path, id: max(a.id, b.id), rescanSubtree: a.rescanSubtree || b.rescanSubtree,
                 historyLost: a.historyLost || b.historyLost)
    }

    /// What one `apply` did to the index.
    private enum ApplyOutcome {
        /// Every path was outside the root or excluded.
        case untouched
        case full
        /// The outermost folders touched, by relative path, with the change in each one's total and the bytes moved
        /// under each; and the touched folders whose blocks changed by name.
        case folders([String: Int64], moved: [String: UInt64], renamed: Set<String>)
    }

    private func applyLocked(_ changes: [FSChange], to index: ScanIndex) async throws -> ApplyOutcome {
        applies += 1
        if needsFullRescan || changes.contains(where: \.historyLost) {
            fullRescanCount += 1
            index.resetContents(of: 0)
            try fault?()
            try await scan(index, starting: [0])
            needsFullRescan = false
            return .full
        } else {
            var relists: Set<FolderID> = []
            var subtrees: Set<FolderID> = []
            for change in changes {
                guard let relative = relativePath(change.path), !isExcluded(relative) else { continue }
                var folder = deepestFolder(relative, in: index)
                // A dataless folder is never opened; its parent's listing says whether it still is.
                while index.folders[Int(folder)].flags.contains(.dataless), index.folders[Int(folder)].parent != noFolder {
                    folder = index.folders[Int(folder)].parent
                }
                if change.rescanSubtree { subtrees.insert(folder) } else { relists.insert(folder) }
            }

            guard !relists.isEmpty || !subtrees.isEmpty else { return .untouched }
            // The outermost touched folders, and their totals before, to report the change in each.
            var paths: [String: FolderID] = [:]
            for folder in relists.union(subtrees) { paths[index.relativePath(of: folder)] = folder }
            let outer = paths.filter { path, _ in IndexChange.outermostAncestor(of: path) { paths[$0] != nil } == path }
            // Every touched folder's total before, to report what moved, not only the net.
            let before = paths.mapValues { index.folders[Int($0)].totalAllocated }
            // A subtree rescan doesn't know what changed by name inside it: count it as renamed.
            var renamed = Set(subtrees.map { index.relativePath(of: $0) })

            var toScan: [FolderID] = []
            // Shallow first, so a reset ancestor turns its descendants into garbage first.
            for folder in subtrees.sorted(by: { depth($0, index) < depth($1, index) })
            where !index.folders[Int(folder)].flags.contains(.garbage) {
                index.resetContents(of: folder)
                subtreeCount += 1
                toScan.append(folder)
            }
            for folder in relists where !index.folders[Int(folder)].flags.contains(.garbage) && !toScan.contains(folder) {
                let listing = await listing(of: folder, in: index)
                relistCount += 1
                let result = try index.relist(listing)
                toScan += result.newFolders
                // A folder left stale is reported too, so the map is redrawn with it marked.
                if result.namesChanged || listing.outcome == .timedOut { renamed.insert(index.relativePath(of: folder)) }
            }
            try fault?()
            if !toScan.isEmpty { try await scan(index, starting: toScan) }
            // A garbage folder is found again by path: one a relist removed is gone (0), and one a subtree rescan
            // rebuilt is the new one.
            var delta: [String: Int64] = [:]
            for (path, folder) in paths {
                let now = index.folders[Int(folder)].flags.contains(.garbage) ? index.folder(atRelativePath: path) : folder
                let after = now.map { index.folders[Int($0)].totalAllocated } ?? 0
                delta[path] = Int64(bitPattern: after &- before[path]!)
            }
            // A folder's own change is its net minus that of the touched folders nearest below it.
            var own = delta
            for path in paths.keys {
                if let parent = Self.nearestAncestor(of: path, in: paths) { own[parent]! &-= delta[path]! }
            }
            var moved: [String: UInt64] = [:]
            for (path, bytes) in own {
                moved[IndexChange.outermostAncestor(of: path) { paths[$0] != nil }, default: 0] &+= bytes.magnitude
            }
            return .folders(outer.reduce(into: [:]) { $0[$1.key] = delta[$1.key]! }, moved: moved, renamed: renamed)
        }
    }

    /// The deepest strict ancestor of `path` among `paths` ("" is above everything), or nil.
    private static func nearestAncestor(of path: String, in paths: [String: FolderID]) -> String? {
        guard !path.isEmpty else { return nil }
        var rest = path[...]
        while let slash = rest.lastIndex(of: "/") {
            rest = rest[..<slash]
            if paths[String(rest)] != nil { return String(rest) }
        }
        return paths[""] != nil ? "" : nil
    }

    /// Saves now (compacting first if needed), waiting for any apply in progress.
    public func save() async throws {
        await lock()
        defer { unlock() }
        try saveLocked()
    }

    /// Test hook: runs inside the next applies after the index has been changed.
    func injectFault(_ fault: (@Sendable () throws -> Void)?) {
        self.fault = fault
    }

    /// Test hook: replaces `statfs` for finding the root's mount point; throwing fails `open()`.
    func injectMountPointLookup(_ lookup: @escaping @Sendable (String) throws -> String) {
        mountPointLookup = lookup
    }

    /// Test hook, before `open()`: don't start the FSEvents watcher.
    func disableWatcher() {
        watchEvents = false
    }

    /// Test hook: the lister every directory read goes through.
    func injectLister(_ lister: DirectoryLister) {
        self.lister = lister
    }

    /// Test hook: the clock the coalescing window is measured with.
    func injectClock(_ now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    /// What `apply` has done so far. `foldersRelisted` counts folders relisted by `apply` only.
    public func stats() -> ApplyStats {
        ApplyStats(applies: applies, foldersRelisted: relistCount, subtreesRescanned: subtreeCount,
                   fullRescans: fullRescanCount, busy: busyTime)
    }

    /// Test hook: runs before every scan starts.
    func injectBeforeScan(_ hook: (@Sendable () -> Void)?) {
        beforeScan = hook
    }

    private func saveLocked() throws {
        guard !needsFullRescan, var current = index, rootPresent() else { return }
        if current.garbageRatio > compactAbove {
            let temp = store.appending(path: "compact.tmp")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let compacted = try current.compacted(into: temp)
            try compacted.files.sync()
            // With no snapshot, a crash from here on means a full rescan, never a
            // snapshot pointing at the wrong file table.
            unlink(store.appending(path: ScanIndex.snapshotName).path)
            for name in ["files.bin", "filenames.bin"] {
                guard rename(temp.appending(path: name).path, store.appending(path: name).path) == 0 else {
                    throw DiskEngineError.posix("rename \(name)", errno)
                }
            }
            try? FileManager.default.removeItem(at: temp)
            current = compacted
            index = compacted
            indexChanged(folders: nil)
        }
        try current.save(to: store)
        // After the snapshot: a crash between the two only costs one redundant, idempotent reconcile.
        try writeExclusions()
    }

    public func close() async throws {
        await lock()
        defer { unlock() }
        closed = true
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
        try? recordHistoryLocked(now: .now)
        watcher?.stop()
        watchTask?.cancel()
        saveTask?.cancel()
        flushTask?.cancel()
        watcher = nil
        watchTask = nil
        saveTask = nil
        flushTask = nil
        // Their IDs are above the stored event ID, so the next open replays them.
        deferred = [:]
        lastRelist = [:]
        // Their folders stay marked stale in the snapshot, so the next open lists them again.
        staleRetry = [:]
        try saveLocked()
    }

    /// Records today's size snapshot and prunes old history (spec 6.4: once a day and at
    /// app quit).
    public func recordHistory(now: Date = .now) async throws {
        await lock()
        defer { unlock() }
        try recordHistoryLocked(now: now)
    }

    /// What changed over the last `days` days: live sizes against the stored snapshot
    /// from that day.
    public func changes(since days: Int, now: Date = .now) async throws -> [Change] {
        await lock()
        defer { unlock() }
        guard let index else { return [] }
        let today = Day(now, calendar: .current)
        // No history yet: nothing to compare against, rather than "everything grew".
        guard let then = try history.snapshot(onOrBefore: today.adding(days: -days, calendar: .current)) else { return [] }
        return ChangeReport.changes(from: then, to: try SizeSnapshot.capture(index))
    }

    public func withIndex<R: Sendable>(_ body: (ScanIndex) throws -> R) rethrows -> R {
        guard let index else { preconditionFailure("LiveIndex used before open()") }
        return try body(index)
    }

    /// Like `withIndex`, but waits for any apply or save in progress. Needs `open()`.
    public func read<R: Sendable>(_ body: @Sendable (ScanIndex) throws -> R) async throws -> R {
        await lock()
        defer { unlock() }
        guard let index else { preconditionFailure("LiveIndex used before open()") }
        return try body(index)
    }

    /// One change, with a rising generation (from 1), each time the index changes after `open()`: an apply that touched
    /// it, a compaction, an exclusions change or a retry of unreadable folders. Finishes on `close()`.
    public func updates() -> AsyncStream<IndexChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<IndexChange>.makeStream()
        if closed {
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// The history snapshot on or before `today - days`, or nil when there is none.
    public func baseline(days: Int, now: Date = .now) async throws -> SizeSnapshot? {
        await lock()
        defer { unlock() }
        let today = Day(now, calendar: .current)
        return try history.snapshot(onOrBefore: today.adding(days: -days, calendar: .current))
    }

    // MARK: - Private

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    private func indexChanged(folders: [String: Int64]?, moved: [String: UInt64] = [:], renamed: Set<String> = []) {
        cachedKinds = nil
        generation += 1
        let change = IndexChange(generation: generation, folders: folders, moved: moved, renamed: renamed)
        for continuation in subscribers.values { continuation.yield(change) }
    }

    var history: HistoryStore { HistoryStore(directory: store.appending(path: "history")) }

    private func recordHistoryLocked(now: Date) throws {
        // A cut-short scan or a vanished root would record sizes that are too small.
        guard let index, index.pending.isEmpty, rootPresent() else { return }
        let today = Day(now, calendar: .current)
        try history.record(try SizeSnapshot.capture(index), on: today)
        try history.prune(today: today)
    }

    private func fullScan(device: dev_t, journal: String?) async throws -> ScanIndex {
        // The old snapshot refers to file tables about to be truncated; drop it first.
        unlink(store.appending(path: ScanIndex.snapshotName).path)
        let fresh = try ScanIndex(rootName: URL(filePath: rootPath).lastPathComponent, storage: store)
        fresh.rootPath = rootPath
        fresh.rootDevice = device
        fresh.fseventsUUID = journal
        fresh.exclusions = exclusions
        // Events during the scan are replayed afterwards and re-list what they touch.
        fresh.lastEventID = FSEventsGetCurrentEventId()
        try await scan(fresh, starting: [0])
        return fresh
    }

    private func scan(_ target: ScanIndex, starting: [FolderID]) async throws {
        let store = self.store
        let path = rootPath
        let device = rootDevice
        beforeScan?()
        _ = try await DiskScanner(root: URL(filePath: rootPath), storage: store, lister: lister)
            .scan(into: target, starting: starting) { checkpointed in
                // Folders listed after the volume went away read as vanished; stop, don't save.
                guard Self.isPresent(path, device: device) else { return .stop }
                try checkpointed.save(to: store)
                return .proceed
            }
    }

    /// False once the root has gone or is now a different file system. Sticky.
    private func rootPresent() -> Bool {
        if !rootLost, !Self.isPresent(rootPath, device: rootDevice) { rootLost = true }
        return !rootLost
    }

    private static func isPresent(_ path: String, device: dev_t) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_dev == device
    }

    private func startWatching(device: dev_t) throws {
        guard watchEvents, let index, index.fseventsUUID != nil else { return }
        let watcher = EventWatcher(device: device, since: index.lastEventID)
        try watcher.start()
        self.watcher = watcher
        let mapper = EventPathMapper(rootPath: rootPath, mountPoint: mountPoint)
        watchTask = Task { [weak self] in
            for await batch in watcher.changes {
                let absolute = batch.compactMap { change -> FSChange? in
                    var path = mapper.absolute(change.path)
                    // Lost history, or a rescan of a folder above the root, covers the whole root.
                    if path == nil, change.historyLost || (change.rescanSubtree && mapper.isAncestorOfRoot(change.path)) {
                        path = mapper.rootPath
                    }
                    return path.map {
                        FSChange(path: $0, id: change.id, rescanSubtree: change.rescanSubtree, historyLost: change.historyLost)
                    }
                }
                guard !absolute.isEmpty else { continue }
                await self?.enqueue(absolute)
            }
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.saveFromTimer()
        }
    }

    private func saveFromTimer() async {
        await lock()
        defer { unlock() }
        saveTask = nil
        guard !closed else { return }
        try? saveLocked()
    }

    func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// The path relative to the root, or nil when it is outside the root.
    private func relativePath(_ path: String) -> String? {
        var normalized = path
        while normalized.contains("//") { normalized = normalized.replacingOccurrences(of: "//", with: "/") }
        normalized = normalized.trimmingTrailingSlash()
        if normalized == rootPath { return "" }
        guard normalized.hasPrefix(rootPath + "/") || rootPath == "/" else { return nil }
        return String(normalized.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
    }

    /// Whether `relative` is an excluded folder or lies under one.
    private func isExcluded(_ relative: String) -> Bool {
        exclusions.contains { relative == $0 || relative.hasPrefix($0 + "/") }
    }

    /// The deepest folder in the index on the way to `relative`.
    private func deepestFolder(_ relative: String, in index: ScanIndex) -> FolderID {
        var parts = relative.split(separator: "/").map(String.init)
        while true {
            if let folder = index.folder(atRelativePath: parts.joined(separator: "/")) { return folder }
            parts.removeLast()
        }
    }

    private func depth(_ folder: FolderID, _ index: ScanIndex) -> Int {
        var depth = 0
        var cursor = folder
        while index.folders[Int(cursor)].parent != noFolder {
            depth += 1
            cursor = index.folders[Int(cursor)].parent
        }
        return depth
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}

/// Exclusion paths are relative to the volume root: no leading or trailing "/", no "//", never empty.
public enum ExclusionPaths {
    public static func normalized(_ paths: Set<String>) -> Set<String> {
        Set(paths.compactMap { path in
            let joined = path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
            return joined.isEmpty ? nil : joined
        })
    }
}
