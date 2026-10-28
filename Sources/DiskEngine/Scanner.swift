import Darwin
import Foundation

public struct ScanProgress: Sendable {
    public var foldersDone: Int
    public var filesSeen: Int
    public var bytesSeen: UInt64
}

public enum CheckpointDecision: Sendable {
    case proceed, stop
}

public struct ScanResult {
    public var index: ScanIndex
    public var elapsed: Duration
    public var unreadableFolders: Int
}

/// Walks a tree with up to `workers` directory listings in flight. Workers only
/// read; the loop in `run()` is the single writer of the index.
public final class DiskScanner: Sendable {
    public let root: URL
    public let storage: URL
    public let workers: Int
    public let progress: AsyncStream<ScanProgress>
    private let progressSink: AsyncStream<ScanProgress>.Continuation

    public init(root: URL, storage: URL, workers: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.root = root
        self.storage = storage
        self.workers = max(1, workers)
        (progress, progressSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func run() async throws -> ScanResult {
        let clock = ContinuousClock()
        let started = clock.now

        // Resolve a symlinked root (/tmp, /var, user aliases) so the walk starts at a real folder.
        let given = root.path(percentEncoded: false)
        guard let resolved = realpath(given, nil) else {
            progressSink.finish()
            throw DiskEngineError.posix("realpath \(given)", errno)
        }
        let rootPath = String(cString: resolved).trimmingSuffix("/")
        free(resolved)
        var info = stat()
        guard lstat(rootPath, &info) == 0 else {
            progressSink.finish()
            throw DiskEngineError.posix("lstat \(rootPath)", errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            progressSink.finish()
            throw DiskEngineError.notADirectory(rootPath)
        }

        let index = try ScanIndex(rootName: root.lastPathComponent, storage: storage)
        index.rootPath = rootPath
        index.rootDevice = info.st_dev
        let unreadable = try await scan(into: index, starting: [0])
        return ScanResult(index: index, elapsed: clock.now - started, unreadableFolders: unreadable)
    }

    /// Lists `starting` and everything below them into `index`, using `index.rootPath`
    /// and `index.rootDevice`. Every `checkpointEvery`, `index.pending` is set to all
    /// queued and in-flight folders and `checkpoint` runs; returning `.stop` ends the
    /// scan with those folders still pending. Cancelling the task does the same. On
    /// completion `pending` is empty. Returns the number of unreadable folders. Finishes `progress` when done.
    public func scan(
        into index: ScanIndex,
        starting: [FolderID],
        checkpointEvery: Duration = .seconds(30),
        checkpoint: (ScanIndex) throws -> CheckpointDecision = { _ in .proceed },
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Int {
        defer { progressSink.finish() }
        let clock = ContinuousClock()
        let rootPath = index.rootPath
        let rootDevice = index.rootDevice
        var queue = starting
        var head = 0
        var inFlight: Set<FolderID> = []
        var stats = ScanProgress(foldersDone: 0, filesSeen: 0, bytesSeen: 0)
        var unreadable = 0
        var lastReport = clock.now
        var lastCheckpoint = clock.now
        var failure: (any Error)?
        var stopped = false

        await withTaskGroup(of: DirectoryListing.self) { group in
            func launch() {
                while inFlight.count < workers, head < queue.count, !Task.isCancelled {
                    let folder = queue[head]
                    head += 1
                    let path = index.path(of: folder, rootPath: rootPath)
                    group.addTask(priority: .utility) {
                        var reader = BulkDirectoryReader()
                        return reader.list(path: path, folder: folder)
                    }
                    inFlight.insert(folder)
                }
                if head > 4096, head * 2 > queue.count {
                    queue.removeFirst(head)
                    head = 0
                }
            }

            launch()
            while let listing = await group.next() {
                inFlight.remove(listing.folder)
                if listing.outcome == .unreadable { unreadable += 1 }
                stats.foldersDone += 1
                for entry in listing.entries where entry.kind != .directory {
                    stats.filesSeen += 1
                    stats.bytesSeen += entry.allocated
                }
                do {
                    queue += try index.integrate(listing, rootDevice: rootDevice)
                    if clock.now - lastCheckpoint >= checkpointEvery {
                        lastCheckpoint = clock.now
                        index.pending = Array(inFlight) + queue[head...]
                        if try checkpoint(index) == .stop {
                            stopped = true
                            group.cancelAll()
                            break
                        }
                    }
                } catch {
                    // Writing the file table or a checkpoint failed (disk full, storage removed).
                    failure = error
                    group.cancelAll()
                    break
                }
                if Task.isCancelled {
                    stopped = true
                    group.cancelAll()
                    break
                }
                if clock.now - lastReport >= .milliseconds(100) {
                    progressSink.yield(stats)
                    lastReport = clock.now
                }
                launch()
            }
            // Listings still arriving after a stop are dropped; those folders stay pending.
            while await group.next() != nil {}
            // Cancelled before anything was launched: nothing came back to notice it.
            if !stopped, Task.isCancelled, !(inFlight.isEmpty && head == queue.count) { stopped = true }
        }

        if let failure {
            index.pending = Array(inFlight) + queue[head...]
            throw failure
        }
        if stopped {
            index.pending = Array(inFlight) + queue[head...]
        } else {
            index.pending = []
        }
        progressSink.yield(stats)
        return unreadable
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
