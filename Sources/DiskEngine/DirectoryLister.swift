import Darwin
import Dispatch
import Foundation

/// Other apps' containers (`~/Library/Containers/<id>`, `~/Library/Group Containers/<id>`). Without Full Disk Access
/// macOS guards each with a privacy prompt, and open() waits for an answer that may never come, so they are read as
/// unreadable without being opened. This app's own container is never covered.
public struct ProtectedContainers: Sendable, Equatable {
    /// The two container folders, under the home path as given and as seen from the internal disk's data volume.
    public let parents: [String]
    public let ownBundleID: String

    public init(home: String, ownBundleID: String) {
        let data = "/System/Volumes/Data"
        let homes = home.hasPrefix(data + "/") ? [home] : [home, data + home]
        parents = homes.flatMap { [$0 + "/Library/Containers", $0 + "/Library/Group Containers"] }
        self.ownBundleID = ownBundleID
    }

    /// Whether `path` is another app's container or lies inside one.
    public func covers(_ path: String) -> Bool {
        for parent in parents where path.hasPrefix(parent + "/") {
            let name = path.dropFirst(parent.count + 1).prefix { $0 != "/" }
            return !name.isEmpty && name != ownBundleID
        }
        return false
    }
}

/// Lists directories on worker threads with a deadline. A folder whose open() hangs in the kernel (a privacy prompt
/// that can't show, a File Provider folder, a dead mount) costs its caller `timeout`, not minutes: the caller gets
/// `.timedOut` and the worker is left blocked. A folder that timed out is skipped for `skipFor`, and while its worker
/// is still out. Once `maxAbandoned` workers are out, no new worker starts until one comes back: a listing the caller
/// vouches for runs inline, without a deadline, and every other one is skipped.
public final class DirectoryLister: @unchecked Sendable {
    public enum Outcome: Sendable {
        case listed(DirectoryListing)
        /// The listing didn't return in time; its worker is abandoned.
        case timedOut
        /// Not tried: the folder timed out recently or its worker is still out, or too many workers are and the caller
        /// didn't vouch for it.
        case skipped
    }

    /// One per process, so the cap on abandoned workers covers every volume.
    public static let shared = DirectoryLister()

    public let timeout: Duration
    public let skipFor: Duration
    public let maxAbandoned: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private let read: @Sendable (String, FolderID) -> DirectoryListing
    /// No QoS of its own: a listing runs at its caller's, as it did when the caller listed inline, so a busy machine
    /// doesn't starve a utility-QoS worker past its deadline.
    private let queue = DispatchQueue(label: "DirectoryLister", attributes: .concurrent)

    /// A listing someone is waiting for.
    private struct Waiter {
        var path: String
        var deadline: DispatchTime
        var continuation: CheckedContinuation<Outcome, Never>
    }

    private let lock = NSLock()
    private var waiting: [UInt64: Waiter] = [:]
    private var nextTicket: UInt64 = 0
    /// Paths with a worker out, waited for or abandoned. At most one worker per path.
    private var busy: Set<String> = []
    private var abandoned = 0
    /// Paths that timed out, and when they may be tried again (by `now`).
    private var skipUntil: [String: ContinuousClock.Instant] = [:]
    private var watchdogArmed = false

    /// `now` (tests) is the clock `skipFor` is measured with; deadlines always use the real one.
    public init(timeout: Duration = .seconds(5), skipFor: Duration = .seconds(600), maxAbandoned: Int = 4,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                read: @escaping @Sendable (String, FolderID) -> DirectoryListing = DirectoryLister.read) {
        self.timeout = timeout
        self.skipFor = skipFor
        self.maxAbandoned = maxAbandoned
        self.now = now
        self.read = read
    }

    /// The real listing, with `getattrlistbulk`.
    public static func read(_ path: String, _ folder: FolderID) -> DirectoryListing {
        var reader = BulkDirectoryReader()
        return reader.list(path: path, folder: folder)
    }

    /// Workers that timed out and haven't returned.
    public var abandonedCount: Int { lock.withLock { abandoned } }

    /// `knownSafe`: the caller has listed this folder without trouble before, so while every worker slot is taken it
    /// may be listed inline rather than skipped.
    public func list(path: String, folder: FolderID, knownSafe: Bool = false) async -> Outcome {
        enum Admission { case worker, inline, skip }
        let admission = lock.withLock { () -> Admission in
            if busy.contains(path) { return .skip }
            if let until = skipUntil[path] {
                if now() < until { return .skip }
                skipUntil[path] = nil
            }
            if abandoned >= maxAbandoned { return knownSafe ? .inline : .skip }
            busy.insert(path)
            return .worker
        }
        switch admission {
        case .skip: return .skipped
        case .inline: return .listed(read(path, folder))
        case .worker: break
        }
        return await withCheckedContinuation { continuation in
            let ticket = lock.withLock { () -> UInt64 in
                nextTicket += 1
                waiting[nextTicket] = Waiter(path: path, deadline: .now() + dispatchTimeout, continuation: continuation)
                armWatchdog()
                return nextTicket
            }
            queue.async { [read] in
                let listing = read(path, folder)
                self.finished(ticket, path: path, listing)
            }
        }
    }

    private var dispatchTimeout: DispatchTimeInterval {
        let (seconds, attoseconds) = timeout.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    private func finished(_ ticket: UInt64, path: String, _ listing: DirectoryListing) {
        let waiter = lock.withLock { () -> Waiter? in
            busy.remove(path)
            guard let waiter = waiting.removeValue(forKey: ticket) else {
                // It had timed out: the worker is back, so it no longer counts against the cap.
                abandoned -= 1
                return nil
            }
            return waiter
        }
        waiter?.continuation.resume(returning: .listed(listing))
    }

    /// Fires at the earliest deadline, times out what is overdue and re-arms while anything is waited for. Call with
    /// the lock held.
    private func armWatchdog() {
        guard !watchdogArmed, let earliest = waiting.values.map(\.deadline).min() else { return }
        watchdogArmed = true
        queue.asyncAfter(deadline: earliest) { self.expire() }
    }

    private func expire() {
        let overdue = lock.withLock { () -> [Waiter] in
            watchdogArmed = false
            let current = DispatchTime.now()
            let late = waiting.filter { $0.value.deadline <= current }
            for (ticket, waiter) in late {
                waiting[ticket] = nil
                abandoned += 1
                skipUntil[waiter.path] = now() + skipFor
            }
            armWatchdog()
            return Array(late.values)
        }
        for waiter in overdue { waiter.continuation.resume(returning: .timedOut) }
    }
}
