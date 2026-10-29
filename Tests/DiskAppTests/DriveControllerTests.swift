// SPDX-License-Identifier: GPL-3.0-or-later

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
    c.beginObservingChanges()
    await c.hold()
    let s = try #require(await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)))
    #expect(s.total > 0 && s.layout.topLevelCount >= 1)
    let before = c.generation
    try Data(count: 2_000_000).write(to: root.appending(path: "new.bin"))
    // Up to the watcher's latency plus one coalescing window: a folder applied in the last 10 s waits out the window.
    for _ in 0..<200 where c.generation == before { try await Task.sleep(for: .milliseconds(100)) }
    #expect(c.generation > before)
    #expect(c.lastChange != nil)
    #expect(c.takeChange() != nil && c.takeChange() == nil)
    c.release(); await c.cool()
}

// Two updates before the map reads them: neither is lost (C16).
@MainActor @Test func changesMergeUntilTaken() async throws {
    let c = DriveController(volume: try Fixtures.volume(try Fixtures.tree(["a/f.bin": 10])), store: try Fixtures.tempDir())
    c.beginObservingChanges()
    c.receive(IndexChange(generation: 1, folders: ["a/x": 5]))
    c.receive(IndexChange(generation: 2, folders: ["b": 7]))
    #expect(c.generation == 2 && c.lastChange == IndexChange(generation: 2, folders: ["b": 7]))
    #expect(c.takeChange() == IndexChange(generation: 2, folders: ["a/x": 5, "b": 7]))
    #expect(c.takeChange() == nil)
}

// Fix round 2: with no window watching, updates don't pile up; one starting to watch begins from nothing.
@MainActor @Test func changesAreNotKeptWithoutAnObserver() async throws {
    let c = DriveController(volume: try Fixtures.volume(try Fixtures.tree(["a/f.bin": 10])), store: try Fixtures.tempDir())
    c.receive(IndexChange(generation: 1, folders: ["a": 5]))
    #expect(c.generation == 1 && c.takeChange() == nil)
    c.beginObservingChanges()
    c.receive(IndexChange(generation: 2, folders: ["b": 7]))
    c.endObservingChanges()
    #expect(c.takeChange() == nil)
    c.beginObservingChanges()
    c.receive(IndexChange(generation: 3, folders: ["c": 1]))
    #expect(c.takeChange() == IndexChange(generation: 3, folders: ["c": 1]))
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

// App-managed hits of any size are protected, not just the ones big enough to show. A trash right after warm doesn't wait
// for the walk (final review I3): the rules alone refuse an app-managed location.
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
    // No lensSettled(), and an item with no rule of its own: still refused, and nothing moves.
    let simulators = BasketItem(path: "Users/u/Library/Developer/CoreSimulator", name: "CoreSimulator", size: 100_000,
                                kind: nil, isFolder: true, ruleID: nil, safety: nil)
    let out = await fresh.trash([simulators], backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Developer/CoreSimulator/dev/x.bin").path))
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
    // Neither recounted nor re-walked; the moved item leaves the report in memory (final review I3).
    #expect(c.summary?.scannedBytes == before)
    #expect(c.lens?.hits.isEmpty == true && c.lensWalks == 1)
    #expect(c.activity == .offline)
}

@MainActor @Test func exclusionsChangeTheSummary() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/m.mov": 3_000_000, "Users/u/VMs/v.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.setExclusions(["Users/u/VMs"])
    #expect(c.summary?.scannedBytes == Fixtures.allocatedSize(root.appending(path: "Users/u/Movies/m.mov")))
    await c.cool()
}

@MainActor @Test func warmRetriesUnreadableFoldersOnlyWhenAccessIsNotDenied() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000, "locked/g.bin": 1_200_000])
    let locked = root.appending(path: "locked").path
    defer { chmod(locked, 0o755) }
    let store = try Fixtures.tempDir()
    let request = MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)
    chmod(locked, 0)
    let first = DriveController(volume: try Fixtures.volume(root), store: store)
    await first.warm(); await first.cool()
    chmod(locked, 0o755)
    // Denied: the snapshot is loaded as it was.
    let denied = DriveController(volume: try Fixtures.volume(root), store: store, fullDiskAccess: { false })
    await denied.warm()
    #expect(await denied.buildMap(request)?.unreadableCount == 1)
    await denied.cool()
    // Not denied: the folder is relisted once the drive opens.
    let allowed = DriveController(volume: try Fixtures.volume(root), store: store, fullDiskAccess: { true })
    await allowed.warm()
    #expect(await allowed.buildMap(request)?.unreadableCount == 0)
    await allowed.cool()
}

/// Whether the probe has been asked, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// Task 7 review: the unreadable-folder retry after an open is not `opening`, so willUnmount must cancel it on its own,
// or an eject waits for the whole retry scan. A cut-short retry stays resumable.
@MainActor @Test func willUnmountCancelsTheUnreadableRetry() async throws {
    let root = try wideTree(outer: 300, inner: 100)
    let base = root.path
    let locked = base + "/locked"
    mkdir(locked, 0o755)
    // Move the wide tree under one folder that is unreadable at the first scan.
    for i in 0..<300 { rename(base + "/d\(i)", locked + "/d\(i)") }
    defer { chmod(locked, 0o755) }
    let store = try Fixtures.tempDir()
    chmod(locked, 0)
    let first = DriveController(volume: try Fixtures.volume(root), store: store)
    await first.warm(); await first.cool()
    chmod(locked, 0o755)
    // Past the chmod's FSEvents event, so only the retry (not a replayed event) relists the folder.
    let snapshot = try ScanIndex.load(from: store)
    snapshot.lastEventID += 1_000_000_000
    try snapshot.save(to: store)

    let started = Flag(), go = DispatchSemaphore(value: 0)
    let c = DriveController(volume: try Fixtures.volume(root), store: store, fullDiskAccess: { true })
    // Holds the retry at the start of its scan until willUnmount has begun (it cancels synchronously).
    c.beforeRetryScan = { started.set(); _ = go.wait(timeout: .now() + 30) }
    let warming = Task { await c.warm() }
    for _ in 0..<6_000 where !started.isSet { try await Task.sleep(for: .milliseconds(5)) }
    #expect(started.isSet)
    let unmounting = Task { await c.willUnmount() }
    for _ in 0..<6_000 where c.activity != .offline { try await Task.sleep(for: .milliseconds(5)) }
    go.signal()
    await unmounting.value
    await warming.value
    #expect(c.activity == .offline)
    let saved = try ScanIndex.load(from: store)
    #expect(!saved.pending.isEmpty, "the retry ran to the end instead of stopping")
}

// Final re-review N1: a walk that read the index before a move doesn't publish over the move's in-memory removal.
@MainActor @Test func aWalkInFlightDuringATrashDoesNotBringTheMovedItemsBack() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000,
                                  "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    // The warm's walk, held after it has read the index (DerivedData still there) and before it publishes.
    let (held, release) = AsyncStream.makeStream(of: Void.self)
    let (reached, signal) = AsyncStream.makeStream(of: Void.self)
    c.beforeLensPublish = {
        signal.yield()
        for await _ in held { break }
    }
    await c.warm()
    for await _ in reached { break }
    let item = BasketItem(path: "Users/u/Library/Developer/Xcode/DerivedData", name: "DerivedData", size: 3_000_000,
                          kind: nil, isFolder: true, ruleID: "xcode-derived-data", safety: .regenerates)
    let out = await c.trash([item], backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved == ["Users/u/Library/Developer/Xcode/DerivedData"])
    release.yield()
    await c.lensSettled()
    let lens = try #require(c.lens)
    #expect(!lens.hits.contains { $0.path == "Users/u/Library/Developer/Xcode/DerivedData" })
    #expect(c.clearable == 0)
    c.beforeLensPublish = nil
    await c.cool()
}

// Final review I3: a move to the Trash walks the lens neither before nor after. The report loses the moved items and their
// bytes in memory; the next warm walks again because the index has changed since.
@MainActor @Test func trashUpdatesTheLensInMemoryWithoutAWalk() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000,
                                  "Users/u/code/web/node_modules/big.bin": 2_000_000,
                                  "Users/u/code/web/node_modules/small.bin": 1_500_000,
                                  "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.lensSettled()
    let before = try #require(c.lens)
    let walks = c.lensWalks
    #expect(walks == 1 && before.hits.map(\.path) == ["Users/u/code/web/node_modules", "Users/u/Library/Developer/Xcode/DerivedData"])
    let big = Fixtures.allocatedSize(root.appending(path: "Users/u/code/web/node_modules/big.bin"))
    let derived = try #require(before.hits.first { $0.ruleID == "xcode-derived-data" })
    let out = await c.trash([BasketItem.from(hit: derived),
                             BasketItem(path: "Users/u/code/web/node_modules/big.bin", name: "big.bin", size: big, kind: nil,
                                        isFolder: false, ruleID: nil, safety: nil)],
                            backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(Set(out.moved) == ["Users/u/Library/Developer/Xcode/DerivedData", "Users/u/code/web/node_modules/big.bin"])
    #expect(c.lensWalks == walks)
    var expected = before.hits.filter { $0.ruleID != "xcode-derived-data" }
    expected[0].size -= big
    #expect(c.lens?.hits == expected)
    #expect(c.clearable == before.total(.regenerates) - derived.size - big)
    #expect(c.lens?.generation == before.generation)
    // Marked stale: the next warm walks once more.
    await c.warm()
    await c.lensSettled()
    #expect(c.lensWalks == walks + 1)
    await c.cool()
}
