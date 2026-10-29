import CoreServices
import Darwin
import Foundation
import os

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
    /// Event IDs started over, so this one says nothing about what came before it (never "already covered").
    public var idsWrapped: Bool

    public init(path: String, id: UInt64, rescanSubtree: Bool, historyLost: Bool, idsWrapped: Bool = false) {
        self.path = path
        self.id = id
        self.rescanSubtree = rescanSubtree
        self.historyLost = historyLost
        self.idsWrapped = idsWrapped
    }

    public static func from(path: String, flags: FSEventStreamEventFlags, id: UInt64) -> FSChange? {
        func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
        if has(kFSEventStreamEventFlagHistoryDone) { return nil }
        let mustScan = has(kFSEventStreamEventFlagMustScanSubDirs)
        let dropped = has(kFSEventStreamEventFlagUserDropped) || has(kFSEventStreamEventFlagKernelDropped)
        let wrapped = has(kFSEventStreamEventFlagEventIdsWrapped)
        let historyLost = wrapped || has(kFSEventStreamEventFlagRootChanged) || (mustScan && dropped)
        return FSChange(path: path, id: id, rescanSubtree: mustScan, historyLost: historyLost, idsWrapped: wrapped)
    }
}

/// Follows FSEvents for a whole device, from a stored event ID, and delivers one
/// batch of changes per callback.
public final class EventWatcher: @unchecked Sendable {
    #if DEBUG
    fileprivate static let log = Logger(subsystem: "com.uziiuzair.hollow", category: "index")
    #endif
    public let changes: AsyncStream<[FSChange]>
    private let sink: AsyncStream<[FSChange]>.Continuation
    /// What the callback reaches through the stream's context, retained by the stream: never the watcher, so a callback
    /// can't hold the watcher past its last owner.
    private final class Context {
        let sink: AsyncStream<[FSChange]>.Continuation
        init(_ sink: AsyncStream<[FSChange]>.Continuation) { self.sink = sink }
    }
    private let device: dev_t
    private let since: UInt64
    private let latency: Double
    /// Above utility: a callback delayed by a busy machine lets fseventsd's buffer for us overflow, which drops events
    /// and asks for a full rescan.
    private let queue = DispatchQueue(label: "EventWatcher", qos: .userInitiated)
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
        let box = Context(sink)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                _ = Unmanaged<Context>.fromOpaque(info!).retain()
                return info
            },
            release: { info in Unmanaged<Context>.fromOpaque(info!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            let context = Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
            let cPaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var batch: [FSChange] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                if let change = FSChange.from(path: String(cString: cPaths[i]), flags: flags[i], id: ids[i]) {
                    #if DEBUG
                    if change.historyLost || change.rescanSubtree {
                        let raw = String(flags[i], radix: 16), path = change.path, id = change.id
                        EventWatcher.log.info("event asks for a rescan: \(path, privacy: .public) id \(id) flags 0x\(raw, privacy: .public)")
                    }
                    #endif
                    batch.append(change)
                }
            }
            if !batch.isEmpty { context.sink.yield(batch) }
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

    /// On the callback's queue, so a callback still running finishes before the stream (and the event buffers it is
    /// reading) is released. Never called from a callback.
    public func stop() {
        guard let stream else { return }
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
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
