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

/// Opens a fixture index. The returned base is far above any real event ID, so the live watcher's own events never
/// collide with the synthetic ones.
private func opened(_ spec: [String: Int], window: Duration, clock: ManualClock? = nil,
                    store: URL? = nil) async throws -> (LiveIndex, String, UInt64, URL) {
    let root = try Fixtures.tree(spec)
    let store = try store ?? Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, coalesceWindow: window)
    if let clock { await live.injectClock { clock.now } }
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

@Test func missingMountPointFailsOpen() async throws {
    let live = LiveIndex(volumeRoot: try Fixtures.tree(["a/f.bin": 10]), store: try Fixtures.tempDir())
    await live.injectMountPointLookup { _ in nil }
    await #expect(throws: (any Error).self) { try await live.open() }
}
