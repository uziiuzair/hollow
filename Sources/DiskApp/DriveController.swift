import DiskEngine
import Foundation
import os

public enum DriveActivity: Equatable, Sendable {
    case idle, opening, scanning, ready, offline
}

/// Owns one drive's `LiveIndex` and keeps it open only while the drive is in use.
/// Nothing here scans on its own: the index opens when `warm()` is called and closes
/// `coolDown` after the last `warm()` (spec 6.3).
@MainActor
public final class DriveController: ObservableObject {
    @Published public private(set) var summary: DriveSummary?
    @Published public private(set) var space: VolumeSpace?
    @Published public private(set) var activity: DriveActivity = .idle
    /// Rises by one each time the open index changes, across re-warms.
    @Published public private(set) var generation = 0
    /// The cleanup lens over the open index. Kept across a cool, so the dropdown still has it.
    @Published public private(set) var lens: LensReport?
    /// Every app-managed hit of the last lens walk, of any size and uncapped: the `protected` set for the review sheet and
    /// the Trasher. `lens` keeps only the hits big enough to show.
    public private(set) var protectedHits: [LensHit] = []
    @Published public var period: Int = 7 {
        didSet {
            guard period != oldValue else { return }
            summary = DriveSummary.load(from: store, period: period)
            Task { await self.run { if self.index != nil { await self.refresh() } } }
        }
    }

    public let volume: VolumeInfo
    private let store: URL
    private let coolDown: Duration
    /// Relative paths the index leaves out; passed to every index this controller opens.
    private var exclusions: Set<String>
    /// Whether to retry unreadable folders after an open: false while macOS still denies access.
    private let fullDiskAccess: @Sendable () -> Bool
    private var index: LiveIndex?
    private var timer: Task<Void, Never>?
    private var timerID = 0
    private var unmounting = false
    /// The open in progress, so an unmount can cut its scan short.
    private var opening: Task<OpenedFrom, any Error>?
    private var spaceRead: Task<Void, Never>?
    /// Every warm/cool/unmount body runs through this chain, strictly one at a time.
    private var lifecycle: Task<Void, Never>?
    /// Open map windows. While any holds the drive, no cool-down timer runs.
    private(set) var holds = 0
    /// Counts the open index's updates into `generation`; lives from open to close.
    private var watching: Task<Void, Never>?
    private(set) var cachedBaseline: (period: Int, day: Day, snapshot: SizeSnapshot?)?
    /// The lens walk started after the drive turned ready (C25), off the lifecycle chain.
    private var lensTask: Task<Void, Never>?
    /// Orders lens walks: only a walk started after the one that set `lens` may replace it.
    private var lensRequests = 0
    private var lensApplied = 0
    /// Set when an unmount begins; read off main by a trash in progress, so it stops between items.
    private let stopFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated var stopRequested: Bool { stopFlag.withLock { $0 } }
    /// Tests only: the `protected` set the last trash used.
    private(set) var lastProtected: [LensHit] = []
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "index")
    /// Tests only: runs between a map build's index read and its unmount check.
    var afterMapRead: (() async -> Void)?

    /// Bytes the lens found that regenerate on their own (nil before the first report).
    public var clearable: UInt64? { lens?.total(.regenerates) }

    public var hasJournal: Bool { EventWatcher.journalUUID(device: volume.device) != nil }

    public init(volume: VolumeInfo, store: URL, coolDown: Duration = .seconds(300), exclusions: Set<String> = [],
                fullDiskAccess: @escaping @Sendable () -> Bool = { true }) {
        self.fullDiskAccess = fullDiskAccess
        self.exclusions = ExclusionPaths.normalized(exclusions)
        self.volume = volume
        self.store = store
        self.coolDown = coolDown
        self.summary = DriveSummary.load(from: store, period: 7)
    }

    private var snapshotExists: Bool {
        FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path)
    }

    private func run<R: Sendable>(_ body: @escaping @MainActor () async -> R) async -> R {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        lifecycle = Task { _ = await task.value }
        return await task.value
    }

    public func warm() async {
        await run { await self.warmBody() }
    }

    public func cool() async {
        await run { await self.coolBody() }
    }

    /// Leaves these folders out of the index (relative paths). A cold drive picks them up on its next open;
    /// an open one relists their parents, then recounts at once.
    public func setExclusions(_ paths: Set<String>) async {
        let paths = ExclusionPaths.normalized(paths)
        await run {
            guard paths != self.exclusions else { return }
            self.exclusions = paths
            guard !self.unmounting, let index = self.index else { return }
            do { try await index.setExclusions(paths) } catch {
                Self.log.error("exclusions change failed: \(error.localizedDescription)")
                return
            }
            await self.refresh()
            guard !self.unmounting else { return }
            await self.refreshLens(force: true)
        }
    }

    public func recordDailyHistoryIfNeeded() async {
        await run {
            guard self.volume.isInternalData, self.index == nil, !self.unmounting else { return }
            let today = Day(.now, calendar: .current)
            if let days = try? HistoryStore(directory: self.store.appending(path: "history")).days(),
               days.contains(today) { return }
            await self.warmBody()
            await self.coolBody()
        }
    }

    /// Marks the drive offline at once, stops any scan in progress (it stays resumable),
    /// then waits for everything queued before it and its own close. Later warm() calls
    /// do nothing.
    public func willUnmount() async {
        unmounting = true
        stopFlag.withLock { $0 = true }
        activity = .offline
        opening?.cancel()
        await run { await self.coolBody() }
    }

    /// Reads free space off the main thread (a read takes 7-57 ms); calls made while a
    /// read is in flight share it.
    public func refreshSpace() async {
        if let spaceRead { return await spaceRead.value }
        let url = volume.url
        let task = Task {
            let read = await Task.detached(priority: .userInitiated) { try? VolumeSpace.read(url) }.value
            if let read { self.space = read }
            self.spaceRead = nil
        }
        spaceRead = task
        await task.value
    }

    private func warmBody() async {
        guard !unmounting else { return }
        if index == nil {
            let live = LiveIndex(volumeRoot: volume.url, store: store, exclusions: exclusions)
            // Without a snapshot or a journal, open() will do a full scan.
            activity = (snapshotExists && hasJournal) ? .opening : .scanning
            // Held so willUnmount() can cancel it (nothing suspends between the
            // unmounting check above and this assignment).
            let task = Task { try await live.open() }
            opening = task
            do {
                _ = try await task.value
                opening = nil
                index = live
                // Folders that were unreadable may be readable now. The probe runs off the main actor.
                let probe = fullDiskAccess
                if await Task.detached(operation: { probe() }).value, !unmounting {
                    _ = try? await live.retryUnreadable()
                }
                let updates = await live.updates()
                watching = Task { [weak self] in
                    for await _ in updates { self?.generation += 1 }
                }
            } catch {
                opening = nil
                try? await live.close()
                if !unmounting { activity = .idle }
                return
            }
        }
        guard !unmounting else { return }
        await refresh()
        guard !unmounting else { return }
        activity = .ready
        restartTimer()
        // Its own task, so the walk (it holds the index lock) never delays `.ready` or the first map build.
        lensTask = Task { await self.refreshLens() }
    }

    /// Tests only: waits for the lens walk started by the last warm.
    func lensSettled() async { await lensTask?.value }

    private func refreshLens(force: Bool = false) async {
        guard let index, force || lens?.generation != generation else { return }
        let gen = generation
        lensRequests += 1
        let request = lensRequests
        let start = ContinuousClock.now
        // One uncapped walk: the shown report is its large hits, the protected set all its app-managed ones.
        guard let all = try? await index.read({ LensMatcher.report(index: $0, rules: .bundled, generation: gen, minBytes: 0, limit: .max) })
        else { return }
        let report = LensReport(hits: Array(all.hits.lazy.filter { $0.size >= Self.lensMinBytes }.prefix(Self.lensLimit)),
                                generation: gen)
        let ms = (ContinuousClock.now - start) / .milliseconds(1)
        Self.log.info("lens report: \(report.hits.count) hits in \(Int(ms)) ms")
        guard request > lensApplied else { return }
        lensApplied = request
        lens = report
        protectedHits = all.hits.filter { $0.safety == .appManaged }
    }

    /// What the shown report keeps (LensMatcher's defaults).
    private static let lensMinBytes: UInt64 = 1_000_000
    private static let lensLimit = 2_000

    /// Moves `items` (the ones checked in the review sheet) to the Trash, then relists their folders and recounts at once.
    /// Runs on the lifecycle chain, so it never races a cool or an unmount; a drive that is unmounting or cold moves nothing.
    public func trash(_ items: [BasketItem], backend: some TrashBackend) async -> TrashOutcome {
        await run { await self.trashBody(items, backend: backend) }
    }

    private func trashBody(_ items: [BasketItem], backend: some TrashBackend) async -> TrashOutcome {
        // The protected set must match the current index: wait for the walk started by warm, then walk again if the
        // index has changed since (a no-op otherwise).
        await lensTask?.value
        if !unmounting { await refreshLens() }
        let protected = protectedHits
        lastProtected = protected
        guard !unmounting, let index else { return .driveGone(items, protected: protected) }
        // The realpath'd root the index was opened with (C7).
        guard let root = try? await index.read({ $0.rootPath }) else { return .driveGone(items, protected: protected) }
        let outcome = await Trasher.moveToTrash(items, root: root, protected: protected, expectedDevice: volume.device,
                                                shouldStop: { [stopFlag] in stopFlag.withLock { $0 } },
                                                backend: backend)
        // An unmount that began during the moves: the index is about to close, so skip the relist, recount and lens walk
        // (the journal brings the changes in on the next mount) and let the eject go ahead.
        guard !unmounting, !outcome.cleared.isEmpty else { return outcome }
        var userTrash: String?
        if volume.isInternalData {
            // On the Data volume the items land in the user's Trash; relist it too when it is indexed (C8).
            let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            let trash = String(TrashPath.trimmed(home).drop { $0 == "/" }) + "/.Trash"
            if (try? await index.read({ $0.folder(atRelativePath: trash) })) != nil { userTrash = trash }
        }
        let changes = Self.foldersToRelist(cleared: outcome.cleared, userTrash: userTrash).map {
            FSChange(path: $0.isEmpty ? root : TrashPath.physicalPath(root: root, relative: $0), id: 0,
                     rescanSubtree: false, historyLost: false)
        }
        try? await index.apply(changes)
        guard !unmounting else { return outcome }
        await refresh()
        guard !unmounting else { return outcome }
        await refreshLens(force: true)
        return outcome
    }

    /// Each distinct parent of the cleared paths ("" for the root), then `userTrash` when given, sorted.
    nonisolated static func foldersToRelist(cleared: Set<String>, userTrash: String?) -> [String] {
        guard !cleared.isEmpty else { return [] }
        var folders = Set(cleared.map { path in path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" })
        if let userTrash { folders.insert(userTrash) }
        return folders.sorted()
    }

    private func coolBody() async {
        timer?.cancel(); timer = nil
        timerID += 1
        watching?.cancel(); watching = nil
        cachedBaseline = nil
        if let live = index {
            index = nil
            try? await live.close()  // records today's history
        }
        if !unmounting { activity = .idle }
    }

    private func refresh() async {
        guard let index else { return }
        await refreshSpace()
        let days = period
        guard let fresh = try? await index.summary(since: days) else { return }
        try? fresh.save(to: store)
        if days == period { summary = fresh }
    }

    private func restartTimer() {
        // A held drive stays warm; release() restarts the timer when the last hold goes.
        guard holds == 0 else { return }
        timer?.cancel()
        timerID += 1
        let id = timerID
        let delay = coolDown
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run {
                // A newer warm() or an explicit cool() supersedes this timer.
                guard let self, self.timerID == id, self.holds == 0 else { return }
                await self.coolBody()
            }
        }
    }
}

extension DriveController: MapSource {
    /// Keeps the drive warm until the matching `release()`. Does nothing after `willUnmount()`.
    public func hold() async {
        guard !unmounting else { return }
        holds += 1
        // Also supersedes a timer already past its sleep and queued on the chain.
        timer?.cancel(); timer = nil
        timerID += 1
        await warm()
    }

    public func release() {
        guard holds > 0 else { return }
        holds -= 1
        if holds == 0, index != nil, !unmounting { restartTimer() }
    }

    /// Nil while the drive is cold or unmounting.
    public func buildMap(_ request: MapRequest) async -> MapSnapshot? {
        guard !unmounting, let index else { return nil }
        let baseline = await baseline(days: request.period, from: index)
        guard !unmounting else { return nil }
        let map = try? await index.read { MapBuilder.build(index: $0, request: request, baseline: baseline) }
        await afterMapRead?()
        // An unmount that began during the read: its map must not land.
        guard !unmounting else { return nil }
        return map
    }

    /// The history snapshot growth is measured from, cached per period and day.
    private func baseline(days: Int, from index: LiveIndex) async -> SizeSnapshot? {
        let today = Day(.now, calendar: .current)
        if let cached = cachedBaseline, cached.period == days, cached.day == today { return cached.snapshot }
        // No history that far back is an answer too (nil), and cached; a failed read is not.
        let snapshot: SizeSnapshot?
        do { snapshot = try await index.baseline(days: days) } catch { return nil }
        if self.index === index { cachedBaseline = (days, today, snapshot) }
        return snapshot
    }
}
