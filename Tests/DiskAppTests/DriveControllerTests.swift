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
    await c.refreshSpace()
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

@MainActor @Test func holdKeepsWarmUntilReleased() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir(), coolDown: .milliseconds(200))
    await c.hold(); await c.warm()
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .ready)
    c.release()
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .idle)
}

@MainActor @Test func holdAfterUnmountStaysOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.willUnmount(); await c.hold()
    #expect(c.activity == .offline)
    #expect(await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}

@MainActor @Test func buildMapAndGenerationWhileHeld() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.hold()
    let s = try #require(await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)))
    #expect(s.total > 0 && s.layout.topLevelCount >= 1)
    let before = c.generation
    try Data(count: 2_000_000).write(to: root.appending(path: "new.bin"))
    for _ in 0..<50 where c.generation == before { try await Task.sleep(for: .milliseconds(100)) }
    #expect(c.generation > before)
    c.release(); await c.cool()
}

// Ejecting with the map open: the window's model ends offline with no map, and lets go of the drive.
@MainActor @Test func unmountWithMapOpenEndsOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000, "b/g.bin": 1_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    let m = MapModel(source: c, driveName: "Ext", reduceMotion: true, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 400, height: 300))
    await m.open(path: "", select: nil); await m.settle()
    #expect(m.status == .ready && c.holds == 1)
    await c.willUnmount()
    m.driveDisconnected()
    await m.settle()
    #expect(m.status == .offline && m.snapshot == nil && c.holds == 0)
}

// A build already reading the index when the unmount starts lands nothing.
@MainActor @Test func buildInFlightAtUnmountReturnsNil() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.hold()
    let request = MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)
    #expect(await c.buildMap(request) != nil)
    // The unmount begins while the build is reading the index.
    c.afterMapRead = { await c.willUnmount() }
    #expect(await c.buildMap(request) == nil)
    #expect(c.activity == .offline)
}

// A drive with no history has no baseline; that answer is cached too.
@MainActor @Test func nilBaselineIsCached() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.hold()
    _ = await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7))
    let cached = try #require(c.cachedBaseline)
    #expect(cached.period == 7 && cached.snapshot == nil)
    c.release(); await c.cool()
}

// The lens report is built after the drive is ready (its own task) and outlives a cool.
@MainActor @Test func lensReportFollowsTheIndex() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000, "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    #expect(c.activity == .ready)
    await c.lensSettled()
    #expect(c.lens?.hits.map(\.ruleID) == ["xcode-derived-data"])
    #expect(c.clearable == Fixtures.allocatedSize(root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin")))
    await c.cool()
    #expect(c.lens != nil)
}

@MainActor @Test func trashMovesUpdatesAndRecounts() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000, "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.lensSettled()
    let before = try #require(c.summary?.scannedBytes)
    let out = await c.trash(c.lens!.hits.map(BasketItem.from(hit:)), backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved == ["Users/u/Library/Developer/Xcode/DerivedData"])
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData").path))
    #expect(c.summary?.scannedBytes == before - out.freed)
    #expect(c.clearable == 0)
    await c.cool()
}

@MainActor @Test func trashAfterUnmountTouchesNothing() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.lensSettled()
    let items = c.lens!.hits.map(BasketItem.from(hit:))
    await c.willUnmount()
    let out = await c.trash(items, backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == [.driveGone])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin").path))
}

// A cold drive (never warmed, no open index) moves nothing either.
@MainActor @Test func trashOnColdDriveTouchesNothing() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    let item = BasketItem(path: "Users/u/Library/Developer/Xcode/DerivedData", name: "DerivedData", size: 3_000_000,
                          kind: nil, isFolder: true, ruleID: "xcode-derived-data", safety: .regenerates)
    let out = await c.trash([item], backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == [.driveGone])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin").path))
}

// The folders to relist after a move: each distinct parent (the root as ""), plus the user's Trash when given (C8).
@Test func trashRelistsEachParentOnce() {
    let parents = DriveController.foldersToRelist(cleared: ["a/x", "a/y", "top", "b/c/d"], userTrash: nil)
    #expect(parents == ["", "a", "b/c"])
    #expect(DriveController.foldersToRelist(cleared: ["Users/u/x"], userTrash: "Users/u/.Trash") == ["Users/u", "Users/u/.Trash"])
    #expect(DriveController.foldersToRelist(cleared: [], userTrash: "Users/u/.Trash").isEmpty)
}

// App-managed hits of any size are protected, not just the ones big enough to show; a trash right after warm waits for them.
@MainActor @Test func smallAppManagedHitsAreProtectedWithoutARace() async throws {
    let spec = ["Users/u/Library/Developer/CoreSimulator/dev/x.bin": 100_000,
                "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000]
    let root = try Fixtures.tree(spec)
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.lensSettled()
    #expect(c.protectedHits.map(\.path) == ["Users/u/Library/Developer/CoreSimulator"])
    #expect(c.lens?.hits.contains { $0.ruleID == "simulator-devices" } == false)
    await c.cool()

    let fresh = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await fresh.warm()
    // No lensSettled(): the trash itself must wait for the walk.
    _ = await fresh.trash([], backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(fresh.lastProtected.map(\.path) == ["Users/u/Library/Developer/CoreSimulator"])
    await fresh.cool()
}

/// Moves with `FixtureTrash`, and after the first item starts an unmount and waits until it is requested.
private struct UnmountingTrash: TrashBackend {
    let inner: FixtureTrash
    let controller: DriveController
    let calls = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    func trash(_ url: URL) throws {
        try inner.trash(url)
        guard calls.next() == 1 else { return }
        let c = controller
        Task { @MainActor in await c.willUnmount() }
        let deadline = Date.now.addingTimeInterval(5)
        while !c.stopRequested && Date.now < deadline { usleep(1_000) }
    }
}

// An unmount during a trash stops it between items and skips the relist, recount and lens walk.
@MainActor @Test func unmountDuringTrashStopsBetweenItems() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000,
                                  "Users/u/Documents/b/y.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.lensSettled()
    let before = c.summary?.scannedBytes
    let items = c.lens!.hits.map(BasketItem.from(hit:)) +
        [BasketItem(path: "Users/u/Documents/b", name: "b", size: 2_000_000, kind: nil, isFolder: true, ruleID: nil, safety: nil)]
    let out = await c.trash(items, backend: UnmountingTrash(inner: FixtureTrash(bin: try Fixtures.tempDir()), controller: c))
    #expect(out.moved == ["Users/u/Library/Developer/Xcode/DerivedData"])
    #expect(out.failures.map(\.path) == ["Users/u/Documents/b"] && out.failures.map(\.reason) == [.driveGone])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Documents/b/y.bin").path))
    // Neither recounted nor re-walked.
    #expect(c.summary?.scannedBytes == before)
    #expect(c.lens?.hits.map(\.path) == ["Users/u/Library/Developer/Xcode/DerivedData"])
    #expect(c.activity == .offline)
}
