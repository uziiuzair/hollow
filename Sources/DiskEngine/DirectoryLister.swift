import Darwin
import Dispatch
import Foundation
import os

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

/// Lists directories on a fixed pool of `threads` listing threads, each listing under deadlines, so a folder that hangs
/// in the kernel (a privacy prompt that can't show, a File Provider folder, a dead mount) costs its caller seconds, not
/// minutes. Three deadlines, each giving up on the caller's behalf while the thread, if it has one, is left blocked:
/// - a request that hasn't started `startTimeout` after it was made is skipped, but only once the pool is stuck: every
///   thread hung, or none finished or read a batch in the last `startTimeout`. A pool that is only busy keeps it queued;
/// - open() must return within `timeout` of the thread starting the request;
/// - after that, each `getattrlistbulk` batch must return within `idleTimeout` of the last (a dead network mount).
///
/// A thread that hangs stays counted, so the pool can drain to nothing; then every listing is skipped at once, and that
/// is logged (by the kind of folder, never the path) along with the pool coming back. A folder that timed out, and
/// anything under it, is skipped for `skipFor` and while its thread is still out.
public final class DirectoryLister: @unchecked Sendable {
    public enum Outcome: Sendable {
        case listed(DirectoryListing)
        /// open() or a read didn't return in time; its thread is left blocked.
        case timedOut
        /// Not tried: the folder or one above it hung recently or still has its thread, every thread hung, or the pool
        /// made no progress for `startTimeout` while it waited.
        case skipped
    }

    /// One per process, so the pool covers every volume.
    public static let shared = DirectoryLister()
    private static let log = Logger(subsystem: "com.ooozzy.diskinventory", category: "lister")

    public let threads: Int
    public let timeout: Duration
    public let startTimeout: Duration
    public let idleTimeout: Duration
    public let skipFor: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let read: @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing
    /// Runs only the deadline timer, never a listing, so a pool full of blocked threads can't hold it up.
    private let watchdog = DispatchQueue(label: "DirectoryLister.watchdog", qos: .userInitiated)

    private enum Phase { case queued, opening, reading }

    /// A listing someone is waiting for.
    private struct Request {
        var path: String
        var folder: FolderID
        var phase: Phase
        var deadline: DispatchTime
        var continuation: CheckedContinuation<Outcome, Never>
    }

    /// Guards everything below; listing threads wait on it for work.
    private let condition = NSCondition()
    private var requests: [UInt64: Request] = [:]
    /// Requests not yet taken by a thread, oldest first.
    private var queue: [UInt64] = []
    private var nextTicket: UInt64 = 0
    /// Listing threads alive, idle ones included; never more than `threads`.
    private var running = 0
    private var idle = 0
    /// Paths with a request in progress, waited for or abandoned. At most one per path.
    private var busy: Set<String> = []
    /// Paths whose thread was abandoned and hasn't returned.
    private var hung: Set<String> = []
    /// Paths that timed out, and when they may be tried again (by `now`).
    private var skipUntil: [String: ContinuousClock.Instant] = [:]
    /// When the watchdog will next fire; a deadline earlier than that arms it again.
    private var watchdogDue: DispatchTime?
    /// When a thread last finished a listing or read a batch: the pool is getting through its queue.
    private var lastProgress = DispatchTime.now()
    /// Every thread hung, and that has been reported.
    private var down = false
    private var report: @Sendable (String) -> Void = { DirectoryLister.log.info("\($0, privacy: .public)") }

    /// `now` (tests) is the clock `skipFor` is measured with; deadlines always use the real one. `read` must call its
    /// third argument when open() returns and after each batch it reads.
    public init(threads: Int = 8, timeout: Duration = .seconds(5), startTimeout: Duration = .seconds(5),
                idleTimeout: Duration = .seconds(30), skipFor: Duration = .seconds(600),
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                read: @escaping @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing
                    = DirectoryLister.read) {
        self.threads = max(1, threads)
        self.timeout = timeout
        self.startTimeout = startTimeout
        self.idleTimeout = idleTimeout
        self.skipFor = skipFor
        self.now = now
        self.read = read
    }

    /// The real listing, with `getattrlistbulk`.
    public static func read(_ path: String, _ folder: FolderID, _ progress: @escaping @Sendable () -> Void) -> DirectoryListing {
        var reader = BulkDirectoryReader()
        return reader.list(path: path, folder: folder, progress: progress)
    }

    /// Threads that timed out and haven't returned.
    public var abandonedCount: Int { condition.withLock { hung.count } }
    /// Listing threads alive.
    public var threadCount: Int { condition.withLock { running } }
    /// Paths skipped because they timed out recently.
    public var skippedPaths: Set<String> { condition.withLock { Set(skipUntil.keys) } }
    /// Requests made and not yet answered, queued ones included.
    var outstandingCount: Int { condition.withLock { requests.count } }

    /// Test hook: where the pool going down and coming back is reported, instead of the log.
    func injectReport(_ report: @escaping @Sendable (String) -> Void) {
        condition.withLock { self.report = report }
    }

    /// What kind of folder `path` is, for the log: a home folder's path names its owner.
    static func pathClass(_ path: String) -> String {
        let data = "/System/Volumes/Data"
        let path = path.hasPrefix(data + "/") ? String(path.dropFirst(data.count)) : path
        if path.hasPrefix("/Volumes/") { return "other volume" }
        if path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/") { return "cloud storage" }
        if ProtectedData.containerFolders.contains(where: { path.contains("/\($0)/") }) { return "app container" }
        guard path.hasPrefix("/Users/") else { return "system" }
        return path.split(separator: "/").dropFirst(2).first == "Library" ? "home Library" : "home folder"
    }

    public func list(path: String, folder: FolderID) async -> Outcome {
        await withCheckedContinuation { continuation in
            let admitted = condition.withLock { () -> Bool in
                let current = now()
                skipUntil = skipUntil.filter { $0.value > current }
                func under(_ top: String) -> Bool { path == top || path.hasPrefix(top + "/") }
                if busy.contains(path) || hung.contains(where: under) || skipUntil.keys.contains(where: under)
                    || hung.count >= threads {
                    return false
                }
                busy.insert(path)
                nextTicket += 1
                requests[nextTicket] = Request(path: path, folder: folder, phase: .queued,
                                               deadline: .now() + Self.interval(startTimeout), continuation: continuation)
                queue.append(nextTicket)
                if queue.count > idle, running < threads {
                    running += 1
                    let thread = Thread { self.serve() }
                    thread.name = "DirectoryLister"
                    thread.qualityOfService = .userInitiated
                    thread.start()
                }
                condition.signal()
                armWatchdog()
                return true
            }
            if !admitted { continuation.resume(returning: .skipped) }
        }
    }

    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = d.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// One listing thread: takes requests until it has been idle for a minute, then ends.
    private func serve() {
        while true {
            condition.lock()
            idle += 1
            var ticket: UInt64?
            while ticket == nil {
                if !queue.isEmpty {
                    ticket = queue.removeFirst()
                } else if !condition.wait(until: Date(timeIntervalSinceNow: 60)) && queue.isEmpty {
                    idle -= 1
                    running -= 1
                    condition.unlock()
                    return
                }
            }
            idle -= 1
            guard let ticket, var request = requests[ticket] else { condition.unlock(); continue }
            request.phase = .opening
            request.deadline = .now() + Self.interval(timeout)
            requests[ticket] = request
            armWatchdog()
            condition.unlock()

            let listing = read(request.path, request.folder) { self.progress(ticket) }
            finished(ticket, path: request.path, listing)
        }
    }

    /// open() returned, or a batch was read: the request is alive, and has `idleTimeout` for the next batch.
    private func progress(_ ticket: UInt64) {
        condition.withLock {
            lastProgress = .now()
            guard requests[ticket] != nil else { return }
            requests[ticket]!.phase = .reading
            requests[ticket]!.deadline = .now() + Self.interval(idleTimeout)
            armWatchdog()
        }
    }

    private func finished(_ ticket: UInt64, path: String, _ listing: DirectoryListing) {
        let (request, message) = condition.withLock { () -> (Request?, String?) in
            busy.remove(path)
            lastProgress = .now()
            guard let request = requests.removeValue(forKey: ticket) else {
                // It had timed out and the thread is back: it serves again, and the folder (likely only slow) is no
                // longer skipped.
                hung.remove(path)
                skipUntil[path] = nil
                guard down else { return (nil, nil) }
                down = false
                return (nil, "Listing pool back: a hung thread returned, \(hung.count) of \(threads) still hung")
            }
            return (request, nil)
        }
        if let message { condition.withLock { report }(message) }
        request?.continuation.resume(returning: .listed(listing))
    }

    /// Fires at the earliest deadline, gives up on what is overdue and re-arms while anything is waited for. Deadlines
    /// differ in length, so a new one can be earlier than the one armed for. Call with the lock held.
    private func armWatchdog() {
        guard let earliest = requests.values.map(\.deadline).min() else { return }
        if let due = watchdogDue, due <= earliest { return }
        watchdogDue = earliest
        watchdog.asyncAfter(deadline: earliest) { self.expire() }
    }

    private func expire() {
        let (overdue, message) = condition.withLock { () -> ([(Request, Outcome)], String?) in
            let current = DispatchTime.now()
            // A later timer is still pending when an earlier one was armed after it; only the due one clears this.
            if let due = watchdogDue, due <= current { watchdogDue = nil }
            var given: [(Request, Outcome)] = []
            for (ticket, request) in requests where request.phase != .queued && request.deadline <= current {
                requests[ticket] = nil
                hung.insert(request.path)
                skipUntil[request.path] = now() + skipFor
                given.append((request, .timedOut))
            }
            // A queued request past its deadline waits on while threads still finish or read; once every thread hung,
            // or none has for `startTimeout`, it is skipped. Never started: no thread to leave behind.
            let drained = hung.count >= threads
            let stalled = lastProgress + Self.interval(startTimeout)
            for (ticket, request) in requests where request.phase == .queued && (drained || request.deadline <= current) {
                if !drained, stalled > current {
                    requests[ticket]!.deadline = stalled
                    continue
                }
                requests[ticket] = nil
                queue.removeAll { $0 == ticket }
                busy.remove(request.path)
                given.append((request, .skipped))
            }
            var message: String?
            if drained, !down {
                down = true
                let kinds = Dictionary(grouping: hung, by: Self.pathClass).map { "\($0.key) \($0.value.count)" }.sorted()
                message = "Listing pool down: all \(threads) threads hung (\(kinds.joined(separator: ", "))); listings skip until one returns"
            }
            armWatchdog()
            return (given, message)
        }
        if let message { condition.withLock { report }(message) }
        for (request, outcome) in overdue { request.continuation.resume(returning: outcome) }
    }
}
