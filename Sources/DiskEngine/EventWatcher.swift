import CoreServices
import Darwin
import Foundation

/// One changed folder reported by FSEvents.
public struct FSChange: Sendable, Equatable {
    /// Relative to the volume's mount point when it comes from `EventWatcher`;
    /// `LiveIndex.apply` expects absolute paths.
    public var path: String
    public var id: UInt64
    /// Something below `path` changed too, and FSEvents can't say what.
    public var rescanSubtree: Bool
    /// Event history can't be trusted any more; only a full rescan is safe.
    public var historyLost: Bool

    public init(path: String, id: UInt64, rescanSubtree: Bool, historyLost: Bool) {
        self.path = path
        self.id = id
        self.rescanSubtree = rescanSubtree
        self.historyLost = historyLost
    }

    public static func from(path: String, flags: FSEventStreamEventFlags, id: UInt64) -> FSChange? {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { return nil }
        let mustScan = has(kFSEventStreamEventFlagMustScanSubDirs)
        let dropped = has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
        let historyLost = has(kFSEventStreamEventFlagEventIdsWrapped) || has(kFSEventStreamEventFlagRootChanged)
            || (mustScan && dropped)
        return FSChange(path: path, id: id, rescanSubtree: mustScan, historyLost: historyLost)
    }
}

/// Follows FSEvents for a whole device, from a stored event ID, and delivers one
/// batch of changes per callback.
public final class EventWatcher: @unchecked Sendable {
    public let changes: AsyncStream<[FSChange]>
    private let sink: AsyncStream<[FSChange]>.Continuation
    private let device: dev_t
    private let since: UInt64
    private let latency: Double
    private let queue = DispatchQueue(label: "EventWatcher", qos: .utility)
    // Touched only from start()/stop(), which callers don't race.
    private var stream: FSEventStreamRef?

    public init(device: dev_t, since: UInt64, latency: Double = 3.0) {
        self.device = device
        self.since = since
        self.latency = latency
        (changes, sink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        stop()
    }

    public func start() throws {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let watcher = Unmanaged<EventWatcher>.fromOpaque(info!).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch: [FSChange] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                if let change = FSChange.from(path: String(cString: cPaths[i]), flags: flags[i], id: ids[i]) {
                    batch.append(change)
                }
            }
            if !batch.isEmpty { watcher.sink.yield(batch) }
        }
        let sinceWhen = since == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : since
        guard let stream = FSEventStreamCreateRelativeToDevice(
            nil, callback, &context, device, [""] as CFArray, sinceWhen, latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        else { throw DiskEngineError.posix("FSEventStreamCreateRelativeToDevice", EINVAL) }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw DiskEngineError.posix("FSEventStreamStart", EIO)
        }
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        sink.finish()
    }

    /// The device's FSEvents journal UUID, or nil when the volume keeps no event
    /// history (exFAT, FAT, some network volumes).
    public static func journalUUID(device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
