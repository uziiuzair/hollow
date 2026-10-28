import Darwin
import Dispatch
import Foundation

/// The folders macOS guards with a privacy prompt unless the app has Full Disk Access. Opening one without it waits for
/// an answer that may never come (nobody there, or the screen locked), so they are read as unreadable without being
/// opened. Covers other apps' containers and the known protected data folders, the whole list in one place; never
/// this app's own containers.
public struct ProtectedData: Sendable, Equatable {
    /// Protected folders, relative to the home folder.
    public static let homeFolders = [
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Reminders",
        "Library/HomeKit", "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/com.apple.TCC", "Library/Suggestions", "Library/Cookies",
        "Library/IdentityServices", "Library/Metadata/CoreSpotlight", "Library/Biome",
    ]
    /// Folders whose every child is one app's container.
    public static let containerFolders = ["Library/Containers", "Library/Group Containers"]
    /// Photos libraries are protected wherever they sit under here.
    public static let photosFolder = "Pictures"

    /// The home folder as given and as seen from the internal disk's data volume, without a trailing "/".
    public let homes: [String]
    public let ownBundleID: String

    public init(home: String, ownBundleID: String) {
        let trimmed = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        let data = "/System/Volumes/Data"
        homes = trimmed.hasPrefix(data + "/") ? [trimmed] : [trimmed, data + trimmed]
        self.ownBundleID = ownBundleID
    }

    /// Whether `path` is a protected folder or lies inside one.
    public func covers(_ path: String) -> Bool {
        for home in homes where path.hasPrefix(home + "/") {
            let relative = path.dropFirst(home.count + 1)
            for folder in Self.homeFolders where relative == folder || relative.hasPrefix(folder + "/") { return true }
            for folder in Self.containerFolders where relative.hasPrefix(folder + "/") {
                let name = relative.dropFirst(folder.count + 1).prefix { $0 != "/" }
                // Ours: the app's own container, its App Group (`group.<id>`) or a team-prefixed one (`<team>.<id>`).
                return !name.isEmpty && name != ownBundleID && !name.hasSuffix("." + ownBundleID)
            }
            if relative.hasPrefix(Self.photosFolder + "/") {
                return relative.split(separator: "/").dropFirst().contains { $0.hasSuffix(".photoslibrary") }
            }
        }
        return false
    }
}

/// Lists directories on worker threads with a deadline on open(). A folder whose open() hangs in the kernel (a privacy
/// prompt that can't show, a File Provider folder, a dead mount) costs its caller `timeout`, not minutes: the caller
/// gets `.timedOut` and the worker is left blocked. The deadline starts when the worker starts, and a worker past
/// open() is reading and is always waited for, so a slow machine or a big folder never times out.
///
/// A folder that timed out, and anything under it, is skipped for `skipFor` and while its worker is still out. Once
/// `maxAbandoned` workers are out, what a listing does depends on `whenFull`.
public final class DirectoryLister: @unchecked Sendable {
    public enum Outcome: Sendable {
        case listed(DirectoryListing)
        /// open() didn't return in time; its worker is abandoned.
        case timedOut
        /// Not tried: the folder or one above it timed out recently or still has its worker out, or the cap is full
        /// and `whenFull` is `.skip`.
        case skipped
    }

    /// What a listing does while `maxAbandoned` workers are out.
    public enum WhenFull: Sendable {
        case skip
        /// Read on the caller, without a deadline: for a folder that listed fine before. Starts no thread.
        case inline
        /// A worker anyway, under the same deadline: for scans, which must not leave folders unread. Past the cap only
        /// a folder that itself hangs adds an abandoned worker, at most one per folder per `skipFor`.
        case worker
    }

    /// One per process, so the cap on abandoned workers covers every volume.
    public static let shared = DirectoryLister()

    public let timeout: Duration
    public let skipFor: Duration
    public let maxAbandoned: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private let read: @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing
    /// No QoS of its own: a listing runs at its caller's, as it did when the caller listed inline, so a busy machine
    /// doesn't starve a utility-QoS worker.
    private let queue = DispatchQueue(label: "DirectoryLister", attributes: .concurrent)

    /// A listing someone is waiting for.
    private struct Waiter {
        var path: String
        /// Set while the worker is inside open(); nil while it is queued or reading.
        var deadline: DispatchTime?
        var continuation: CheckedContinuation<Outcome, Never>
    }

    private let lock = NSLock()
    private var waiting: [UInt64: Waiter] = [:]
    private var nextTicket: UInt64 = 0
    /// Paths with a worker out, waited for or abandoned. At most one worker per path.
    private var busy: Set<String> = []
    /// Paths whose worker was abandoned and hasn't returned.
    private var hung: Set<String> = []
    /// Paths that timed out, and when they may be tried again (by `now`).
    private var skipUntil: [String: ContinuousClock.Instant] = [:]
    private var watchdogArmed = false

    /// `now` (tests) is the clock `skipFor` is measured with; deadlines always use the real one. `read` must call its
    /// third argument once open() has returned.
    public init(timeout: Duration = .seconds(5), skipFor: Duration = .seconds(600), maxAbandoned: Int = 4,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                read: @escaping @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing
                    = DirectoryLister.read) {
        self.timeout = timeout
        self.skipFor = skipFor
        self.maxAbandoned = maxAbandoned
        self.now = now
        self.read = read
    }

    /// The real listing, with `getattrlistbulk`.
    public static func read(_ path: String, _ folder: FolderID, _ opened: @escaping @Sendable () -> Void) -> DirectoryListing {
        var reader = BulkDirectoryReader()
        return reader.list(path: path, folder: folder, opened: opened)
    }

    /// Workers that timed out and haven't returned.
    public var abandonedCount: Int { lock.withLock { hung.count } }

    public func list(path: String, folder: FolderID, whenFull: WhenFull = .skip) async -> Outcome {
        enum Admission { case worker, inline, skip }
        let admission = lock.withLock { () -> Admission in
            let current = now()
            skipUntil = skipUntil.filter { $0.value > current }
            func under(_ top: String) -> Bool { path == top || path.hasPrefix(top + "/") }
            if busy.contains(path) || hung.contains(where: under) || skipUntil.keys.contains(where: under) { return .skip }
            if hung.count >= maxAbandoned {
                switch whenFull {
                case .skip: return .skip
                case .inline: return .inline
                case .worker: break
                }
            }
            busy.insert(path)
            return .worker
        }
        switch admission {
        case .skip: return .skipped
        case .inline: return .listed(read(path, folder, {}))
        case .worker: break
        }
        return await withCheckedContinuation { continuation in
            let ticket = lock.withLock { () -> UInt64 in
                nextTicket += 1
                waiting[nextTicket] = Waiter(path: path, deadline: nil, continuation: continuation)
                return nextTicket
            }
            queue.async { [read] in
                self.started(ticket)
                let listing = read(path, folder) { self.opened(ticket) }
                self.finished(ticket, path: path, listing)
            }
        }
    }

    private var dispatchTimeout: DispatchTimeInterval {
        let (seconds, attoseconds) = timeout.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// The worker is about to call open(): its deadline starts now.
    private func started(_ ticket: UInt64) {
        lock.withLock {
            waiting[ticket]?.deadline = .now() + dispatchTimeout
            armWatchdog()
        }
    }

    /// open() returned: the worker is reading, and is waited for however long that takes.
    private func opened(_ ticket: UInt64) {
        lock.withLock { waiting[ticket]?.deadline = nil }
    }

    private func finished(_ ticket: UInt64, path: String, _ listing: DirectoryListing) {
        let waiter = lock.withLock { () -> Waiter? in
            busy.remove(path)
            guard let waiter = waiting.removeValue(forKey: ticket) else {
                // It had timed out: the worker is back, so it no longer counts against the cap.
                hung.remove(path)
                return nil
            }
            return waiter
        }
        waiter?.continuation.resume(returning: .listed(listing))
    }

    /// Fires at the earliest deadline, times out what is overdue and re-arms while any worker is inside open(). Call
    /// with the lock held.
    private func armWatchdog() {
        guard !watchdogArmed, let earliest = waiting.values.compactMap(\.deadline).min() else { return }
        watchdogArmed = true
        queue.asyncAfter(deadline: earliest) { self.expire() }
    }

    private func expire() {
        let overdue = lock.withLock { () -> [Waiter] in
            watchdogArmed = false
            let current = DispatchTime.now()
            let late = waiting.filter { $0.value.deadline.map { $0 <= current } ?? false }
            for (ticket, waiter) in late {
                waiting[ticket] = nil
                hung.insert(waiter.path)
                skipUntil[waiter.path] = now() + skipFor
            }
            armWatchdog()
            return Array(late.values)
        }
        for waiter in overdue { waiter.continuation.resume(returning: .timedOut) }
    }
}
