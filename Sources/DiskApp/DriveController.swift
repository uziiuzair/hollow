import DiskEngine
import Foundation

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
    private var cachedBaseline: (period: Int, day: Day, snapshot: SizeSnapshot?)?

    public var hasJournal: Bool { EventWatcher.journalUUID(device: volume.device) != nil }

    public init(volume: VolumeInfo, store: URL, coolDown: Duration = .seconds(300)) {
        self.volume = volume
        self.store = store
        self.coolDown = coolDown
        self.summary = DriveSummary.load(from: store, period: 7)
    }

    private var snapshotExists: Bool {
        FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path)
    }

    private func run(_ body: @escaping @MainActor () async -> Void) async {
        let previous = lifecycle
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        lifecycle = task
        await task.value
    }

    public func warm() async {
        await run { await self.warmBody() }
    }

    public func cool() async {
        await run { await self.coolBody() }
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
            let live = LiveIndex(volumeRoot: volume.url, store: store)
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
        return try? await index.read { MapBuilder.build(index: $0, request: request, baseline: baseline) }
    }

    /// The history snapshot growth is measured from, cached per period and day.
    private func baseline(days: Int, from index: LiveIndex) async -> SizeSnapshot? {
        let today = Day(.now, calendar: .current)
        if let cached = cachedBaseline, cached.period == days, cached.day == today { return cached.snapshot }
        guard let snapshot = try? await index.baseline(days: days) else { return nil }
        if self.index === index { cachedBaseline = (days, today, snapshot) }
        return snapshot
    }
}
