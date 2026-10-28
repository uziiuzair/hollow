import Foundation
import os
import Testing
@testable import DiskEngine

/// A clock the test moves by hand, so coalescing never depends on scheduler timing (C15).
private final class ManualClock: Sendable {
    private let start = ContinuousClock.now
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
    func advance(_ d: Duration) { offset.withLock { $0 += d } }
    var now: ContinuousClock.Instant { start + offset.withLock { $0 } }
}

/// Opens a fixture index with no FSEvents watcher. The returned base is far above any real event ID.
private func opened(_ spec: [String: Int], window: Duration, clock: ManualClock? = nil,
                    store: URL? = nil) async throws -> (LiveIndex, String, UInt64, URL) {
    let root = try Fixtures.tree(spec)
    let store = try store ?? Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, coalesceWindow: window)
    if let clock { await live.injectClock { clock.now } }
    // The fixture's own creation events can replay as soon as a watcher starts; only the test's changes may count.
    await live.disableWatcher()
    _ = try await live.open()
    return (live, Fixtures.realPath(root), await live.withIndex { $0.lastEventID } + 1_000_000_000, store)
}

private func change(_ path: String, _ id: UInt64, subtree: Bool = false) -> FSChange {
    FSChange(path: path, id: id, rescanSubtree: subtree, historyLost: false)
}

@Test func repeatedChangesToAFolderCoalesce() async throws {
    let clock = ManualClock()
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .seconds(10), clock: clock)
    for i in 1...10 {
        await live.enqueue([change(root + "/a", base + UInt64(i))])
        clock.advance(.milliseconds(20))
    }
    #expect(await live.stats().foldersRelisted == 1)
    clock.advance(.seconds(10))
    await live.flushDue()
    #expect(await live.stats().foldersRelisted == 2)
    #expect(await live.withIndex { $0.lastEventID } == base + 10)
    try await live.close()
}

@Test func deferredChangesFlushOnTheirOwn() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .milliseconds(200))
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2)])
    // Outcome only: the flush lands at some point after the window (no upper bound on the scheduler).
    for _ in 0..<100 where await live.stats().foldersRelisted < 2 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(await live.stats().foldersRelisted == 2)
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    try await live.close()
}

@Test func anotherFolderIsNotDelayed() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10, "b/g.bin": 10], window: .seconds(10), clock: ManualClock())
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/b", base + 2)])
    #expect(await live.stats().foldersRelisted == 2)
    try await live.close()
}

@Test func deferredChangesHoldBackTheEventID() async throws {
    let (live, root, base, store) = try await opened(["a/f.bin": 10, "b/g.bin": 10], window: .seconds(10), clock: ManualClock())
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2), change(root + "/b", base + 3)])
    #expect(await live.stats().foldersRelisted == 2)
    #expect(await live.withIndex { $0.lastEventID } == base + 1)
    // Quitting drops the deferred change, but the stored ID is below it, so the next open replays it.
    try await live.close()
    let reopened = LiveIndex(volumeRoot: URL(filePath: root), store: store)
    #expect(try await reopened.open() == .snapshot)
    #expect(await reopened.withIndex { $0.lastEventID } == base + 1)
    try await reopened.close()
}

@Test func subtreeRescansAreNeverDelayed() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .seconds(10), clock: ManualClock())
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2, subtree: true)])
    #expect(await live.stats().subtreesRescanned == 1)
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    try await live.close()
}

@Test func lostHistoryAppliesWhatWasDeferred() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .seconds(10), clock: ManualClock())
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2)])
    #expect(await live.withIndex { $0.lastEventID } == base + 1)
    await live.enqueue([FSChange(path: root, id: base + 3, rescanSubtree: false, historyLost: true)])
    let stats = await live.stats()
    #expect(stats.fullRescans == 1)
    #expect(await live.withIndex { $0.lastEventID } == base + 3)
    try await live.close()
}

@Test func changesNameTheOutermostFolderAndItsDelta() async throws {
    let (live, root, base, _) = try await opened(["a/x/f.bin": 10, "b/g.bin": 10], window: .seconds(10))
    var it = await live.updates().makeAsyncIterator()
    try Fixtures.write(URL(filePath: root + "/a/x/new.bin"), bytes: 2_000_000)
    try Fixtures.write(URL(filePath: root + "/a/top.bin"), bytes: 1_200_000)
    try await live.apply([change(root + "/a/x", base + 1), change(root + "/a", base + 2)])
    let expected = Fixtures.allocatedSize(URL(filePath: root + "/a/x/new.bin"))
        + Fixtures.allocatedSize(URL(filePath: root + "/a/top.bin"))
    #expect(await it.next()?.folders == ["a": Int64(expected)])
    try await live.apply([FSChange(path: root, id: base + 3, rescanSubtree: false, historyLost: true)])
    let full = await it.next()
    #expect(full != nil && full?.folders == nil)
    try await live.close()
}

@Test func applyStatsCountTheWork() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .seconds(10), clock: ManualClock())
    try await live.apply([change(root + "/a", base + 1)])
    try await live.apply([change(root + "/a", base + 2, subtree: true)])
    try await live.apply([FSChange(path: root, id: base + 3, rescanSubtree: false, historyLost: true)])
    let s = await live.stats()
    #expect(s.applies == 3 && s.foldersRelisted == 1 && s.subtreesRescanned == 1 && s.fullRescans == 1)
    #expect(s.busy > .zero)
    try await live.close()
}

@Test func mergedChangesSumUnderTheOutermostPath() {
    let first = IndexChange(generation: 2, folders: ["a/x": 5, "b": -2])
    let second = IndexChange(generation: 3, folders: ["a": 3, "c/d": 1])
    #expect(first.merged(with: second) == IndexChange(generation: 3, folders: ["a": 8, "b": -2, "c/d": 1]))
    #expect(first.merged(with: IndexChange(generation: 4, folders: nil)) == IndexChange(generation: 4, folders: nil))
    #expect(IndexChange(generation: 1, folders: nil).merged(with: second).folders == nil)
    #expect(first.merged(with: IndexChange(generation: 5, folders: ["": 1])).folders == ["": 4])
}

// Fix round 1: a move between two touched folders nets zero but moved bytes; the gross figure keeps it.
@Test func aMoveIntoAChildReportsTheMovedBytes() async throws {
    let (live, root, base, _) = try await opened(["a/big.bin": 2_000_000, "a/d/g.bin": 10, "b/h.bin": 10], window: .seconds(10))
    var it = await live.updates().makeAsyncIterator()
    let size = Int64(Fixtures.allocatedSize(URL(filePath: root + "/a/big.bin")))
    try FileManager.default.moveItem(atPath: root + "/a/big.bin", toPath: root + "/a/d/big.bin")
    try await live.apply([change(root + "/a", base + 1), change(root + "/a/d", base + 2)])
    let moved = try #require(await it.next())
    #expect(moved.folders == ["a": 0])
    #expect(moved.moved == ["a": UInt64(2 * size)])
    #expect(moved.renamed == ["a", "a/d"])
    try await live.close()
}

@Test func aSameSizeRenameIsReportedAsRenamed() async throws {
    let (live, root, base, _) = try await opened(["a/big.bin": 2_000_000, "b/h.bin": 10], window: .seconds(10))
    var it = await live.updates().makeAsyncIterator()
    try FileManager.default.moveItem(atPath: root + "/a/big.bin", toPath: root + "/a/other.bin")
    try await live.apply([change(root + "/a", base + 1)])
    let renamed = try #require(await it.next())
    #expect(renamed.folders == ["a": 0] && renamed.moved == ["a": 0] && renamed.renamed == ["a"])
    try await live.close()
}

@Test func mergedMovesAddByMagnitude() {
    let out = IndexChange(generation: 2, folders: ["a/x": 5_000], moved: ["a/x": 5_000], renamed: ["a/x"])
    let back = IndexChange(generation: 3, folders: ["a": -5_000], moved: ["a": 5_000], renamed: ["a"])
    let merged = out.merged(with: back)
    #expect(merged.folders == ["a": 0] && merged.moved == ["a": 10_000] && merged.renamed == ["a", "a/x"])
    #expect(IndexChange(generation: 1, folders: ["b": -7]).moved == ["b": 7])
    #expect(out.merged(with: IndexChange(generation: 4, folders: nil)) == IndexChange(generation: 4, folders: nil))
}

// Fix round 2: a change naming more paths than the cap is "anything may have changed", so merging stays bounded.
@Test func tooManyPathsCollapseToAnything() {
    let cap = IndexChange.maxPaths
    let wide = IndexChange(generation: 2, folders: ["a": 1], renamed: Set((0...cap).map { "a/\($0)" }))
    #expect(wide.folders == nil && wide.renamed.isEmpty && wide.moved.isEmpty)
    let atCap = IndexChange(generation: 2, folders: ["a": 1], renamed: Set((1...cap).map { "a/\($0)" }))
    #expect(atCap.folders == ["a": 1] && atCap.renamed.count == cap)
    var merged = IndexChange(generation: 1, folders: ["f0": 1])
    for i in 1...cap { merged = merged.merged(with: IndexChange(generation: i + 1, folders: ["f\(i)": 1])) }
    #expect(merged.folders == nil && merged.generation == cap + 1)
    #expect(merged.merged(with: IndexChange(generation: 999, folders: ["g": 1])).folders == nil)
}

@Test func missingMountPointFailsOpen() async throws {
    let live = LiveIndex(volumeRoot: try Fixtures.tree(["a/f.bin": 10]), store: try Fixtures.tempDir())
    await live.injectMountPointLookup { _ in throw DiskEngineError.posix("statfs", EIO) }
    await #expect(throws: (any Error).self) { try await live.open() }
}

// A watcher batch arriving while a flush is scanning must not cut that scan short (fix round 1). Every enqueue ends by
// rescheduling the flush timer; the hook does exactly that, on the actor, while the flush is about to scan a/new.
@Test func anEnqueueDuringAFlushScanDoesNotCutItShort() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10, "b/g.bin": 10], window: .milliseconds(300))
    await live.enqueue([change(root + "/a", base + 1)])
    try Fixtures.write(URL(filePath: root + "/a/new/deep/h.bin"), bytes: 2_000_000)
    await live.enqueue([change(root + "/a", base + 2)])  // deferred: the timer flushes it, and its relist finds a/new
    let fired = OSAllocatedUnfairLock(initialState: false)
    await live.injectBeforeScan {
        guard !fired.withLock({ let was = $0; $0 = true; return was }) else { return }
        live.assumeIsolated { $0.scheduleFlush() }
    }
    for _ in 0..<100 where await live.withIndex({ $0.lastEventID }) < base + 2 { try await Task.sleep(for: .milliseconds(50)) }
    #expect(fired.withLock { $0 })
    #expect(await live.withIndex { $0.pending.isEmpty })
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: URL(filePath: root)))
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    try await live.close()
}

// Defence in depth: an apply whose scan is cancelled never counts as applied (fix round 1).
@Test func aCancelledApplyScanIsAFailure() async throws {
    let (live, root, base, _) = try await opened(["a/f.bin": 10], window: .seconds(10), clock: ManualClock())
    let before = await live.withIndex { $0.lastEventID }
    try Fixtures.write(URL(filePath: root + "/a/new/deep/h.bin"), bytes: 2_000_000)
    await live.injectBeforeScan { withUnsafeCurrentTask { $0?.cancel() } }
    let applied = Task { try await live.apply([change(root + "/a", base + 1)]) }
    await #expect(throws: (any Error).self) { try await applied.value }
    #expect(await live.withIndex { $0.lastEventID } == before)
    await live.injectBeforeScan(nil)
    // The next apply rescans everything, so nothing the cut-short scan missed stays missing.
    try await live.apply([change(root + "/a", base + 2)])
    #expect(await live.stats().fullRescans == 1)
    #expect(await live.withIndex { $0.pending.isEmpty })
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: URL(filePath: root)))
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    try await live.close()
}
