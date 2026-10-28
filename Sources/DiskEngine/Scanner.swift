import Darwin
import Foundation

public struct ScanProgress: Sendable {
    public var foldersDone: Int
    public var filesSeen: Int
    public var bytesSeen: UInt64
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
        defer { progressSink.finish() }
        let clock = ContinuousClock()
        let started = clock.now

        // Resolve a symlinked root (/tmp, /var, user aliases) so the walk starts at a real folder.
        let given = root.path(percentEncoded: false)
        guard let resolved = realpath(given, nil) else { throw DiskEngineError.posix("realpath \(given)", errno) }
        let rootPath = String(cString: resolved).trimmingSuffix("/")
        free(resolved)
        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw DiskEngineError.posix("lstat \(rootPath)", errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw DiskEngineError.notADirectory(rootPath) }
        let rootDevice = info.st_dev

        let index = try ScanIndex(rootName: root.lastPathComponent, storage: storage)
        index.rootPath = rootPath
        index.rootDevice = rootDevice
        var pending: [FolderID] = [0]
        var head = 0
        var stats = ScanProgress(foldersDone: 0, filesSeen: 0, bytesSeen: 0)
        var unreadable = 0
        var lastReport = started
        var failure: (any Error)?

        await withTaskGroup(of: DirectoryListing.self) { group in
            var inFlight = 0
            func launch() {
                while inFlight < workers, head < pending.count, !Task.isCancelled {
                    let folder = pending[head]
                    head += 1
                    let path = index.path(of: folder, rootPath: rootPath)
                    group.addTask(priority: .utility) {
                        var reader = BulkDirectoryReader()
                        return reader.list(path: path, folder: folder)
                    }
                    inFlight += 1
                }
                if head > 4096, head * 2 > pending.count {
                    pending.removeFirst(head)
                    head = 0
                }
            }

            launch()
            while let listing = await group.next() {
                inFlight -= 1
                if listing.outcome == .unreadable { unreadable += 1 }
                stats.foldersDone += 1
                for entry in listing.entries where entry.kind != .directory {
                    stats.filesSeen += 1
                    stats.bytesSeen += entry.allocated
                }
                do {
                    pending += try index.integrate(listing, rootDevice: rootDevice)
                } catch {
                    // Writing the file table failed (disk full, storage removed).
                    failure = error
                    group.cancelAll()
                    break
                }
                if clock.now - lastReport >= .milliseconds(100) {
                    progressSink.yield(stats)
                    lastReport = clock.now
                }
                launch()
            }
        }

        if let failure { throw failure }
        progressSink.yield(stats)
        return ScanResult(index: index, elapsed: clock.now - started, unreadableFolders: unreadable)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        count > 1 && hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
