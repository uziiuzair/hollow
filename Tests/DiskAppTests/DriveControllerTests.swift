import Foundation
import Testing
@testable import DiskApp
@testable import DiskEngine

/// Yields until warm() has started opening, so the next call really races it.
@MainActor private func waitUntilBusy(_ c: DriveController) async {
    for _ in 0..<10_000 where c.activity == .idle { await Task.yield() }
}

private func todayRecorded(_ store: URL) throws -> Bool {
    try HistoryStore(directory: store.appending(path: "history")).days().contains(Day(.now, calendar: .current))
}

/// The index was closed: a snapshot is on disk, and today's history was recorded exactly
/// when that snapshot is complete (an unmount may cut the scan short; then it is
/// resumable and records nothing).
private func closedCleanly(_ store: URL) throws -> Bool {
    let saved = try ScanIndex.load(from: store)
    return try todayRecorded(store) == saved.pending.isEmpty
}

@MainActor @Test func warmThenCoolReleasesIndex() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/m.mov": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir(), coolDown: .milliseconds(200))
    await c.warm()
    #expect(c.activity == .ready)
    #expect(c.summary?.kinds[.media] != nil)
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .idle)
}

@MainActor @Test func cachedSummaryShowsBeforeWarm() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let first = DriveController(volume: try Fixtures.volume(root), store: store)
    await first.warm(); await first.cool()
    let second = DriveController(volume: try Fixtures.volume(root), store: store)
    #expect(second.summary?.scannedBytes == first.summary?.scannedBytes)
    #expect(second.activity == .idle)
}

@MainActor @Test func willUnmountClosesWarmIndex() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.warm()
    await c.willUnmount()
    #expect(c.activity == .offline)
    #expect(try todayRecorded(store))
}

@MainActor @Test func exFATScansOnlyWhenSelected() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    c.refreshSpace()
    #expect(c.space != nil)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}

@MainActor @Test func willUnmountDuringWarmLeavesOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await waitUntilBusy(c)
    await c.willUnmount()
    await warming.value
    #expect(c.activity == .offline)
    await c.cool()
    #expect(c.activity == .offline)
    #expect(try closedCleanly(store))
}

@MainActor @Test func coolDuringWarmEndsIdle() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await waitUntilBusy(c)
    await c.cool()
    await warming.value
    #expect(c.activity == .idle)
    #expect(try todayRecorded(store))
}

@MainActor @Test func coolThenUnmountDuringWarmClosesBeforeReturn() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await waitUntilBusy(c)
    let cooling = Task { await c.cool() }
    await Task.yield()
    await c.willUnmount()
    #expect(try closedCleanly(store))
    #expect(c.activity == .offline)
    await warming.value; await cooling.value
}

@MainActor @Test func warmDuringUnmountDoesNotReopen() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.warm()
    let unmounting = Task { await c.willUnmount() }
    await Task.yield()
    await c.warm()
    await unmounting.value
    #expect(c.activity == .offline)
    await c.cool()
    #expect(c.activity == .offline)
    let snapshot = store.appending(path: "index.snapshot")
    let before = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date
    try await Task.sleep(for: .seconds(1))
    let after = try FileManager.default.attributesOfItem(atPath: snapshot.path)[.modificationDate] as? Date
    #expect(before == after)
}

@MainActor @Test func failedOpenDuringUnmountStaysOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    try FileManager.default.removeItem(at: root)  // open() will throw (realpath fails)
    let warming = Task { await c.warm() }
    await waitUntilBusy(c)
    await c.willUnmount()
    await warming.value
    #expect(c.activity == .offline)
}

/// A tree of `outer` x `inner` empty folders: slow to scan, cheap to build.
private func wideTree(outer: Int, inner: Int) throws -> URL {
    let root = try Fixtures.tempDir()
    for i in 0..<outer {
        let dir = root.appending(path: "d\(i)").path
        mkdir(dir, 0o755)
        for j in 0..<inner { mkdir(dir + "/e\(j)", 0o755) }
    }
    return root
}

// Final review 1: eject during a first scan must not wait for the whole scan, and must
// not leave a snapshot that a remount would trust as complete, nor record history.
@MainActor @Test func willUnmountCancelsScanInProgress() async throws {
    let root = try wideTree(outer: 300, inner: 100); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await waitUntilBusy(c)
    let clock = ContinuousClock()
    let started = clock.now
    await c.willUnmount()
    let unmountTook = clock.now - started
    await warming.value
    #expect(c.activity == .offline)
    if let saved = try? ScanIndex.load(from: store) { #expect(!saved.pending.isEmpty) }
    #expect(try !todayRecorded(store))

    let fullScan = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().elapsed
    // Uncancelled, the unmount waits for the full scan plus two saves.
    #expect(unmountTook < fullScan, "unmount took \(unmountTook), a full scan \(fullScan)")
}
