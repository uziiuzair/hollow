import CoreServices
import Darwin
import Foundation

public enum OpenedFrom: Sendable, Equatable {
    case snapshot
    case resumed
    case fullScan(reason: String)
}

/// Keeps one volume's index on disk and current: loads or scans it, resumes unfinished
/// scans, follows FSEvents from the stored event ID, re-lists only folders that
/// changed, saves on a debounce, and compacts when garbage builds up.
public actor LiveIndex {
    public let volumeRoot: URL
    public let store: URL
    private let saveDebounce: Duration
    private let compactAbove: Double

    private var index: ScanIndex?
    private var rootPath = ""
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
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(volumeRoot: URL, store: URL, saveDebounce: Duration = .seconds(30), compactAbove: Double = 0.25) {
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
        let dir = base.appending(path: "Volumes").appending(path: uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        let journal = EventWatcher.journalUUID(device: device)
        let volumeURL = try URL(filePath: rootPath).resourceValues(forKeys: [.volumeURLKey]).volume ?? URL(filePath: "/")
        mountPoint = volumeURL.path(percentEncoded: false).trimmingTrailingSlash()

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

        let opened: OpenedFrom
        if let reason {
            index = try await fullScan(device: device, journal: journal)
            opened = .fullScan(reason: reason)
        } else if let loaded, !loaded.pending.isEmpty {
            loaded.rootDevice = device
            index = loaded
            try await scan(loaded, starting: loaded.pending)
            opened = .resumed
        } else {
            // st_dev changes when a drive is replugged or after a reboot.
            loaded?.rootDevice = device
            index = loaded
            opened = .snapshot
        }

        try startWatching(device: device)
        try saveLocked()
        return opened
    }

    /// Applies changed folders. Paths are absolute; ones outside the root are ignored.
    public func apply(_ changes: [FSChange]) async throws {
        await lock()
        defer { unlock() }
        guard !closed, let index, !changes.isEmpty else { return }
        let maxID = changes.map(\.id).max() ?? index.lastEventID
        do {
            try await applyLocked(changes, to: index)
        } catch {
            // Part of the change may be in the index; drop the snapshot so a crash means a
            // full rescan, and rescan on the next apply. The event ID stays put.
            needsFullRescan = true
            unlink(store.appending(path: ScanIndex.snapshotName).path)
            throw error
        }
        // Advance only after the changes are in the index (spec 6.6).
        index.lastEventID = max(index.lastEventID, maxID)
        scheduleSave()
    }

    private func applyLocked(_ changes: [FSChange], to index: ScanIndex) async throws {
        if needsFullRescan || changes.contains(where: \.historyLost) {
            index.resetContents(of: 0)
            try fault?()
            try await scan(index, starting: [0])
            needsFullRescan = false
        } else {
            var relists: Set<FolderID> = []
            var subtrees: Set<FolderID> = []
            for change in changes {
                guard let relative = relativePath(change.path) else { continue }
                let folder = deepestFolder(relative, in: index)
                if change.rescanSubtree { subtrees.insert(folder) } else { relists.insert(folder) }
            }

            var toScan: [FolderID] = []
            // Shallow first, so a reset ancestor turns its descendants into garbage first.
            for folder in subtrees.sorted(by: { depth($0, index) < depth($1, index) })
            where !index.folders[Int(folder)].flags.contains(.garbage) {
                index.resetContents(of: folder)
                toScan.append(folder)
            }
            var reader = BulkDirectoryReader()
            for folder in relists where !index.folders[Int(folder)].flags.contains(.garbage) && !toScan.contains(folder) {
                let listing = reader.list(path: index.path(of: folder, rootPath: index.rootPath), folder: folder)
                toScan += try index.relist(listing)
            }
            try fault?()
            if !toScan.isEmpty { try await scan(index, starting: toScan) }
        }
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

    private func saveLocked() throws {
        guard !needsFullRescan, var current = index else { return }
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
        }
        try current.save(to: store)
    }

    public func close() async throws {
        await lock()
        defer { unlock() }
        closed = true
        try? recordHistoryLocked(now: .now)
        watcher?.stop()
        watchTask?.cancel()
        saveTask?.cancel()
        watcher = nil
        watchTask = nil
        saveTask = nil
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

    // MARK: - Private

    private var history: HistoryStore { HistoryStore(directory: store.appending(path: "history")) }

    private func recordHistoryLocked(now: Date) throws {
        guard let index else { return }
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
        // Events during the scan are replayed afterwards and re-list what they touch.
        fresh.lastEventID = FSEventsGetCurrentEventId()
        try await scan(fresh, starting: [0])
        return fresh
    }

    private func scan(_ target: ScanIndex, starting: [FolderID]) async throws {
        let store = self.store
        _ = try await DiskScanner(root: URL(filePath: rootPath), storage: store)
            .scan(into: target, starting: starting) { checkpointed in
                try checkpointed.save(to: store)
                return .proceed
            }
    }

    private func startWatching(device: dev_t) throws {
        guard let index, index.fseventsUUID != nil else { return }
        let watcher = EventWatcher(device: device, since: index.lastEventID)
        try watcher.start()
        self.watcher = watcher
        let mount = mountPoint
        watchTask = Task { [weak self] in
            for await batch in watcher.changes {
                let absolute = batch.map {
                    FSChange(path: mount + "/" + $0.path, id: $0.id, rescanSubtree: $0.rescanSubtree, historyLost: $0.historyLost)
                }
                try? await self?.apply(absolute)
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

    private func lock() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func unlock() {
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
