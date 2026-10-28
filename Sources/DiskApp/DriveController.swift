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
    @Published public var period: Int = 7 {
        didSet {
            guard period != oldValue else { return }
            summary = DriveSummary.load(from: store, period: period)
            if index != nil { Task { await refresh() } }
        }
    }

    public let volume: VolumeInfo
    private let store: URL
    private let coolDown: Duration
    private var index: LiveIndex?
    private var opening: Task<LiveIndex?, Never>?
    private var timer: Task<Void, Never>?
    /// Bumped by every close so an in-flight `warm()` knows it was superseded.
    private var epoch = 0

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

    public func warm() async {
        guard activity != .offline else { return }
        let start = epoch
        if index == nil {
            if let opening {
                _ = await opening.value
            } else {
                await open()
            }
        }
        guard epoch == start, index != nil else { return }
        await refresh()
        guard epoch == start, index != nil else { return }
        activity = .ready
        restartTimer()
    }

    /// The open task owns the instance. If `cool()`/`willUnmount()` ran meanwhile
    /// (epoch changed), they take the instance from the task and close it; this
    /// method then leaves everything alone.
    private func open() async {
        let live = LiveIndex(volumeRoot: volume.url, store: store)
        let start = epoch
        // Without a snapshot or a journal, open() will do a full scan.
        activity = (snapshotExists && hasJournal) ? .opening : .scanning
        let task = Task { () -> LiveIndex? in
            do { _ = try await live.open(); return live } catch { try? await live.close(); return nil }
        }
        opening = task
        let opened = await task.value
        guard epoch == start else { return }
        opening = nil
        if let opened {
            index = opened
        } else {
            activity = .idle
        }
    }

    private func refresh() async {
        guard let index else { return }
        refreshSpace()
        let days = period
        guard let fresh = try? await index.summary(since: days) else { return }
        try? fresh.save(to: store)
        if days == period { summary = fresh }
    }

    public func cool() async {
        timer?.cancel(); timer = nil
        await closeIndex()
        if activity != .offline { activity = .idle }
    }

    /// Closes the index (which records today's history), including one still opening.
    private func closeIndex() async {
        epoch += 1
        var live = index
        index = nil
        if let task = opening {
            opening = nil
            live = await task.value ?? live
        }
        try? await live?.close()
    }

    public func recordDailyHistoryIfNeeded() async {
        guard volume.isInternalData, index == nil, activity != .offline else { return }
        let today = Day(.now, calendar: .current)
        if let days = try? HistoryStore(directory: store.appending(path: "history")).days(), days.contains(today) {
            return
        }
        await warm()
        await cool()
    }

    public func willUnmount() async {
        timer?.cancel(); timer = nil
        await closeIndex()
        activity = .offline
    }

    public func refreshSpace() {
        if let s = try? VolumeSpace.read(volume.url) { space = s }
    }

    private func restartTimer() {
        timer?.cancel()
        let delay = coolDown
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.cool()
        }
    }
}
