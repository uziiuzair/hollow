import CoreServices
import Foundation
import os
import Testing
@testable import DiskEngine

/// Task 10c: a directory whose open() hangs in the kernel (a TCC prompt that can't show, a File Provider folder, a
/// dead mount) must not hold the live index for longer than the lister's deadline.

/// A clock the test moves by hand (C15).
private final class ManualClock: Sendable {
    private let start = ContinuousClock.now
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
    func advance(_ d: Duration) { offset.withLock { $0 += d } }
    var now: ContinuousClock.Instant { start + offset.withLock { $0 } }
}

/// Blocks the listings of chosen paths until released, and records every path listed.
private final class Hang: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (paths: Set<String>(), prefix: String?.none, opened: [String](),
                                                             reading: String?.none))
    private let gate = DispatchSemaphore(value: 0)

    func block(_ path: String) { state.withLock { _ = $0.paths.insert(path) } }
    func block(under prefix: String) { state.withLock { $0.prefix = prefix } }
    /// Listings under `prefix` get past open(), then block (a dead network mount mid-read).
    func blockReading(under prefix: String) { state.withLock { $0.reading = prefix } }
    /// Every blocked listing returns; later ones no longer block.
    func release() {
        state.withLock { $0.paths = []; $0.prefix = nil; $0.reading = nil }
        gate.signal()
    }
    var opened: [String] { state.withLock { $0.opened } }
    func opens(of path: String) -> Int { opened.filter { $0 == path }.count }

    /// A blocked listing blocks inside "open()", before `progress` first runs; a reading one right after.
    func read(_ path: String, _ folder: FolderID, _ progress: @escaping @Sendable () -> Void) -> DirectoryListing {
        let (blocked, reading) = state.withLock { s in
            s.opened.append(path)
            return (s.paths.contains(path) || s.prefix.map { path.hasPrefix($0) } == true,
                    s.reading.map { path.hasPrefix($0) } == true)
        }
        if reading { progress() }
        if blocked || reading {
            gate.wait()
            gate.signal()  // lets the next blocked listing go too
        }
        return DirectoryLister.read(path, folder, progress)
    }
}

private func lister(_ hang: Hang, timeout: Duration = .seconds(5), startTimeout: Duration = .seconds(5),
                    idleTimeout: Duration = .seconds(30), clock: ManualClock? = nil,
                    read: (@Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing)? = nil) -> DirectoryLister {
    let now: @Sendable () -> ContinuousClock.Instant
    if let clock { now = { clock.now } } else { now = { ContinuousClock.now } }
    let reader: @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing = read ?? { hang.read($0, $1, $2) }
    return DirectoryLister(timeout: timeout, startTimeout: startTimeout, idleTimeout: idleTimeout, now: now, read: reader)
}

private func opened(_ spec: [String: Int], clock: ManualClock, lister: DirectoryLister) async throws -> (LiveIndex, String, UInt64) {
    let root = try Fixtures.tree(spec)
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), coalesceWindow: .seconds(10))
    await live.injectClock { clock.now }
    await live.injectLister(lister)
    await live.disableWatcher()
    _ = try await live.open()
    return (live, Fixtures.realPath(root), await live.withIndex { $0.lastEventID } + 1_000_000_000)
}

private func change(_ path: String, _ id: UInt64) -> FSChange {
    FSChange(path: path, id: id, rescanSubtree: false, historyLost: false)
}

private func record(_ live: LiveIndex, _ path: String) async -> FolderRecord {
    await live.withIndex { $0.folders[Int($0.folder(atRelativePath: path)!)] }
}

@Test func aHangingFolderCannotHoldTheApply() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], clock: clock, lister: lister(hang, clock: clock))
    defer { hang.release() }
    var updates = await live.updates().makeAsyncIterator()
    let before = await record(live, "a").totalAllocated
    try Fixtures.write(URL(filePath: root + "/a/new.bin"), bytes: 2_000_000)
    try Fixtures.write(URL(filePath: root + "/b/new.bin"), bytes: 2_000_000)
    hang.block(root + "/a")
    let scanned = hang.opens(of: root + "/a")

    let started = ContinuousClock.now
    await live.enqueue([change(root + "/a", base + 1), change(root + "/b", base + 2)])
    #expect(ContinuousClock.now - started < .seconds(6.5))

    // The other folder's change landed; the hung one kept its old size and is marked stale; the change counts as done.
    #expect(await record(live, "b").totalAllocated > 2_000_000)
    let a = await record(live, "a")
    #expect(a.totalAllocated == before)
    #expect(a.flags.contains(.stale))
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    let reported = try #require(await updates.next())
    #expect(reported.renamed.contains("a"))

    // A second change within the skip period is not tried: no second worker, and no wait.
    clock.advance(.seconds(11))
    let again = ContinuousClock.now
    await live.enqueue([change(root + "/a", base + 3)])
    #expect(ContinuousClock.now - again < .seconds(1))
    #expect(hang.opens(of: root + "/a") == scanned + 1)
    #expect(await live.withIndex { $0.lastEventID } == base + 3)
    try await live.close()
}

@Test func aTimedOutFolderIsRelistedLater() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let folders = lister(hang, timeout: .milliseconds(300), clock: clock)
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], clock: clock, lister: folders)
    defer { hang.release() }
    try Fixtures.write(URL(filePath: root + "/a/new.bin"), bytes: 2_000_000)
    hang.block(root + "/a")
    await live.enqueue([change(root + "/a", base + 1)])
    #expect(await record(live, "a").flags.contains(.stale))

    // The worker comes back on its own; once the skip period has passed, the rescan runs without a new event.
    hang.release()
    for _ in 0..<100 where folders.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    clock.advance(.seconds(601))
    await live.flushDue()
    let a = await record(live, "a")
    #expect(!a.flags.contains(.stale))
    #expect(a.totalAllocated > 2_000_000)
    #expect(await live.withIndex { $0.lastEventID } == base + 1)
    try await live.close()
}

// Fix round 3: a fixed pool of 8 listing threads; one that hangs stays counted.
@Test func thePoolNeverExceedsEightThreads() async throws {
    let hang = Hang()
    hang.block(under: "/hang/")
    let folders = lister(hang, timeout: .milliseconds(100), startTimeout: .milliseconds(300))
    defer { hang.release() }
    let outcomes = await withTaskGroup(of: String.self) { group in
        for i in 0..<20 {
            group.addTask {
                switch await folders.list(path: "/hang/\(i)", folder: 0) {
                case .listed: "listed"
                case .timedOut: "timedOut"
                case .skipped: "skipped"
                }
            }
        }
        return await group.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(outcomes.filter { $0 == "timedOut" }.count == 8)
    #expect(outcomes.filter { $0 == "skipped" }.count == 12)
    #expect(hang.opened.count == 8)
    #expect(folders.threadCount == 8)
    #expect(folders.abandonedCount == 8)
    // Drained: every listing skips at once.
    let started = ContinuousClock.now
    if case .skipped = await folders.list(path: "/elsewhere", folder: 0) {} else { Issue.record("not skipped") }
    #expect(ContinuousClock.now - started < .milliseconds(100))

    // Threads that come back serve again.
    hang.release()
    for _ in 0..<100 where folders.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(folders.abandonedCount == 0)
    #expect(folders.threadCount <= 8)
    if case .listed = await folders.list(path: "/fresh", folder: 0) {} else { Issue.record("not listed after the pool drained") }
}

@Test func aRequestBehindAFullPoolIsSkippedAndTheLockReleased() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let folders = lister(hang, clock: clock)
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], clock: clock, lister: folders)
    defer { hang.release() }
    // Eight healthy-looking reads that never finish: every thread is busy, none is hung.
    hang.blockReading(under: "/busy/")
    for i in 0..<8 { Task { _ = await folders.list(path: "/busy/\(i)", folder: 0) } }
    for _ in 0..<100 where hang.opened.filter({ $0.hasPrefix("/busy/") }).count < 8 {
        try await Task.sleep(for: .milliseconds(10))
    }

    let scanned = hang.opens(of: root + "/a")
    let started = ContinuousClock.now
    await live.enqueue([change(root + "/a", base + 1)])
    #expect(ContinuousClock.now - started < .seconds(6.5))
    #expect(await record(live, "a").flags.contains(.stale))
    #expect(hang.opens(of: root + "/a") == scanned)
    // The lock is free again.
    let read = ContinuousClock.now
    _ = try await live.read { $0.folders.count }
    #expect(ContinuousClock.now - read < .seconds(1))
    try await live.close()
}

@Test func aReadThatStallsAfterOpenTimesOut() async throws {
    let hang = Hang()
    hang.blockReading(under: "/mount/")
    let folders = lister(hang, idleTimeout: .milliseconds(300))
    defer { hang.release() }
    let started = ContinuousClock.now
    if case .timedOut = await folders.list(path: "/mount/dead", folder: 0) {} else { Issue.record("not timed out") }
    #expect(ContinuousClock.now - started < .seconds(2))
    // Skipped like a hung open(), along with what lies under it.
    if case .skipped = await folders.list(path: "/mount/dead/sub", folder: 0) {} else { Issue.record("not skipped") }
}

@Test func aWorkerBackAfterItsDeadlineLeavesNoSkip() async throws {
    let slow = DirectoryLister(timeout: .milliseconds(100), read: { path, folder, progress in
        usleep(400_000)  // open() returns just after the deadline
        return DirectoryLister.read(path, folder, progress)
    })
    let root = Fixtures.realPath(try Fixtures.tree(["f.bin": 10]))
    if case .timedOut = await slow.list(path: root, folder: 0) {} else { Issue.record("not timed out") }
    for _ in 0..<100 where slow.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(slow.abandonedCount == 0)
    #expect(slow.skippedPaths.isEmpty)
}

@Test func aHangingFolderDoesNotStopTheScan() async throws {
    let root = try Fixtures.tree(["a/f.bin": 10, "b/g.bin": 2_000_000])
    let real = Fixtures.realPath(root)
    let hang = Hang()
    hang.block(real + "/a")
    defer { hang.release() }
    let started = ContinuousClock.now
    let result = try await DiskScanner(root: root, storage: try Fixtures.tempDir(),
                                       lister: lister(hang, timeout: .milliseconds(300))).run()
    #expect(ContinuousClock.now - started < .seconds(3))
    let index = result.index
    #expect(index.pending.isEmpty)
    #expect(index.folders[Int(index.folder(atRelativePath: "a")!)].flags.contains(.stale))
    #expect(index.folders[Int(index.folder(atRelativePath: "b")!)].totalAllocated >= 2_000_000)
}

/// The root lists one real file, a dataless (cloud) folder and a local one; everything else reads as usual.
private func cloudRoot(_ real: String, _ hang: Hang) -> @Sendable (String, FolderID, @escaping @Sendable () -> Void) -> DirectoryListing {
    var info = stat()
    lstat(real, &info)
    let device = info.st_dev
    return { path, folder, opened in
        guard path == real else { return hang.read(path, folder, opened) }
        opened()
        _ = hang.read("root-listed", folder, {})
        var entries = [RawEntry.dir("cloud"), .dir("local"), .file("f.bin", allocated: 4096)]
        entries[0].flags.insert(.dataless)
        for i in entries.indices { entries[i].device = device }
        return DirectoryListing(folder: folder, outcome: .ok, entries: entries)
    }
}

@Test func aDatalessSubfolderIsNeverOpened() async throws {
    let root = try Fixtures.tree(["local/g.bin": 10, "cloud/h.bin": 10])
    let real = Fixtures.realPath(root)
    let hang = Hang()
    let folders = lister(hang, read: cloudRoot(real, hang))
    let index = try await DiskScanner(root: root, storage: try Fixtures.tempDir(), lister: folders).run().index
    let cloud = try #require(index.folder(atRelativePath: "cloud"))
    #expect(index.folders[Int(cloud)].flags.contains(.dataless))
    #expect(hang.opens(of: real + "/local") == 1)
    #expect(hang.opens(of: real + "/cloud") == 0)

    // A change to it relists the parent, whose listing says whether it is still dataless.
    let clock = ManualClock()
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), coalesceWindow: .seconds(10))
    await live.injectClock { clock.now }
    await live.injectLister(folders)
    await live.disableWatcher()
    _ = try await live.open()
    let base = await live.withIndex { $0.lastEventID } + 1_000_000_000
    let rootListings = hang.opens(of: "root-listed")
    await live.enqueue([change(real + "/cloud", base + 1), change(real + "/cloud/h.bin", base + 2)])
    #expect(hang.opens(of: real + "/cloud") == 0)
    #expect(hang.opens(of: "root-listed") == rootListings + 1)
    #expect(await live.withIndex { $0.lastEventID } == base + 2)
    try await live.close()
}

@Test func aDownloadedFolderIsListedOnTheParentsNextRelist() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    var cloud = RawEntry.dir("cloud")
    cloud.flags.insert(.dataless)
    #expect(try idx.integrate(DirectoryListing(folder: 0, outcome: .ok, entries: [cloud]), rootDevice: 1).isEmpty)
    let id = try #require(idx.folder(atRelativePath: "cloud"))
    #expect(idx.folders[Int(id)].flags.contains(.dataless))
    let result = try idx.relist(DirectoryListing(folder: 0, outcome: .ok, entries: [.dir("cloud")]))
    #expect(result.newFolders == [id])
    #expect(result.namesChanged)
    #expect(!idx.folders[Int(id)].flags.contains(.dataless))
}

// Fix round 1: other apps' containers are never opened without Full Disk Access.

private let ownID = "com.ooozzy.diskinventory"

private func containerIndex(fullDiskAccess: Bool, hang: Hang) async throws -> (LiveIndex, String) {
    let root = try Fixtures.tree(["Library/Containers/com.other.app/Data/f.bin": 10,
                                  "Library/Containers/\(ownID)/Data/g.bin": 10,
                                  "Library/Group Containers/group.com.other/h.bin": 10, "plain/i.bin": 10])
    let real = Fixtures.realPath(root)
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), coalesceWindow: .seconds(10),
                         protectedData: ProtectedData(home: real, ownBundleID: ownID),
                         fullDiskAccess: { fullDiskAccess })
    await live.injectLister(lister(hang))
    await live.disableWatcher()
    _ = try await live.open()
    return (live, real)
}

@Test func otherAppsContainersAreNotOpenedWithoutFullDiskAccess() async throws {
    let hang = Hang()
    let (live, root) = try await containerIndex(fullDiskAccess: false, hang: hang)
    let other = root + "/Library/Containers/com.other.app"
    let group = root + "/Library/Group Containers/group.com.other"
    #expect(hang.opened.allSatisfy { !$0.hasPrefix(other) && !$0.hasPrefix(group) })
    #expect(hang.opens(of: root + "/Library/Containers/\(ownID)") == 1)
    #expect(await record(live, "Library/Containers/com.other.app").flags.contains(.unreadable))
    #expect(await record(live, "Library/Group Containers/group.com.other").flags.contains(.unreadable))
    #expect(await record(live, "plain").totalAllocated > 0)

    // A change inside one relists it as unreadable again, still unopened.
    let base = await live.withIndex { $0.lastEventID } + 1_000_000_000
    await live.enqueue([change(other + "/Data", base + 1)])
    #expect(hang.opened.allSatisfy { !$0.hasPrefix(other) })
    #expect(await record(live, "Library/Containers/com.other.app").flags.contains(.unreadable))
    try await live.close()
}

@Test func withFullDiskAccessContainersOpen() async throws {
    let hang = Hang()
    let (live, root) = try await containerIndex(fullDiskAccess: true, hang: hang)
    #expect(hang.opens(of: root + "/Library/Containers/com.other.app") == 1)
    #expect(hang.opens(of: root + "/Library/Group Containers/group.com.other") == 1)
    #expect(await record(live, "Library/Containers/com.other.app").totalAllocated > 0)
    try await live.close()
}

@Test func protectedContainersCoverOtherAppsOnly() {
    let c = ProtectedData(home: "/Users/u/", ownBundleID: ownID)
    #expect(c.covers("/Users/u/Library/Containers/com.other.app"))
    #expect(c.covers("/System/Volumes/Data/Users/u/Library/Containers/com.other.app/Data/Library"))
    #expect(c.covers("/Users/u/Library/Group Containers/ABCDE.group.other"))
    #expect(!c.covers("/Users/u/Library/Containers/\(ownID)/Data"))
    #expect(!c.covers("/Users/u/Library/Containers"))
    #expect(!c.covers("/Users/u/Library/ContainersX/a"))
    #expect(!c.covers("/Users/v/Library/Containers/com.other.app"))
    // Our own App Group, plain or team-prefixed.
    #expect(!c.covers("/Users/u/Library/Group Containers/group.\(ownID)/x"))
    #expect(!c.covers("/Users/u/Library/Group Containers/ABCDE12345.\(ownID)"))
}

@Test func protectedDataCoversTheKnownPrivacyFolders() {
    let c = ProtectedData(home: "/Users/u", ownBundleID: ownID)
    for folder in ProtectedData.homeFolders {
        #expect(c.covers("/Users/u/" + folder), "\(folder)")
        #expect(c.covers("/System/Volumes/Data/Users/u/" + folder + "/deep/er"), "\(folder)")
    }
    #expect(ProtectedData.homeFolders.contains("Library/Mail") && ProtectedData.homeFolders.contains("Library/Biome"))
    #expect(c.covers("/Users/u/Pictures/Photos Library.photoslibrary"))
    #expect(c.covers("/Users/u/Pictures/Old/Trip.photoslibrary/resources/x"))
    #expect(!c.covers("/Users/u/Pictures/Screenshots"))
    #expect(!c.covers("/Users/u/Library/MailExtras"))
    #expect(!c.covers("/Users/u/Library/Application Support/Other"))
    #expect(!c.covers("/Users/u/Documents/Library/Mail"))
}

// Fix round 1: a full worker cap doesn't stop relists of folders that listed fine before.
@Test func aFullWorkerCapStillLetsOrdinaryChangesLand() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let folders = lister(hang, timeout: .milliseconds(100), clock: clock)
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], clock: clock, lister: folders)
    defer { hang.release() }
    hang.block(under: "/hang/")
    for i in 0..<4 { _ = await folders.list(path: "/hang/\(i)", folder: 0) }
    #expect(folders.abandonedCount == 4)

    try Fixtures.write(URL(filePath: root + "/a/new.bin"), bytes: 2_000_000)
    try Fixtures.write(URL(filePath: root + "/a/sub/deep.bin"), bytes: 2_000_000)
    await live.enqueue([change(root + "/a", base + 1)])
    let a = await record(live, "a")
    #expect(a.totalAllocated > 2_000_000)
    #expect(!a.flags.contains(.stale))
    // Never listed, so not vouched for: still read, by a worker under the deadline (a scan never skips).
    #expect(await record(live, "a/sub").totalAllocated > 2_000_000)
    #expect(hang.opens(of: root + "/a/sub") == 1)
    #expect(await live.withIndex { $0.lastEventID } == base + 1)
    try await live.close()
}

// Fix round 1: a subtree rescan whose root hangs keeps the old size.
@Test func aSubtreeRescanWhoseRootHangsKeepsItsSize() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let (live, root, base) = try await opened(["a/f.bin": 2_000_000, "a/x/g.bin": 2_000_000, "b/h.bin": 10], clock: clock,
                                              lister: lister(hang, timeout: .milliseconds(200), clock: clock))
    defer { hang.release() }
    let before = await record(live, "a").totalAllocated
    hang.block(root + "/a")
    await live.enqueue([FSChange(path: root + "/a", id: base + 1, rescanSubtree: true, historyLost: false)])
    let a = await record(live, "a")
    #expect(a.totalAllocated == before)
    #expect(a.flags.contains(.stale))
    #expect(await live.withIndex { $0.folder(atRelativePath: "a/x") } != nil)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } >= before)
    #expect(await live.withIndex { $0.lastEventID } == base + 1)
    try await live.close()
}

// Fix round 2.

private func lost(_ path: String, _ id: UInt64) -> FSChange {
    FSChange(path: path, id: id, rescanSubtree: false, historyLost: true)
}

/// Four workers stuck in open(): the cap is full.
private func fillCap(_ folders: DirectoryLister, _ hang: Hang) async {
    hang.block(under: "/hang/")
    for i in 0..<4 { _ = await folders.list(path: "/hang/\(i)", folder: 0) }
}

@Test func aSlowReadPastOpenIsWaitedFor() async throws {
    let root = try Fixtures.tree(["f.bin": 10])
    let folders = DirectoryLister(timeout: .milliseconds(200), read: { path, folder, opened in
        var reader = BulkDirectoryReader()
        return reader.list(path: path, folder: folder) {
            opened()
            usleep(600_000)  // reading a huge folder on a busy machine
        }
    })
    guard case .listed(let listing) = await folders.list(path: Fixtures.realPath(root), folder: 0) else {
        Issue.record("a worker past open() was abandoned")
        return
    }
    #expect(listing.entries.count == 1)
    #expect(folders.abandonedCount == 0)
}

@Test func aFullCapStillScansAnotherVolume() async throws {
    let hang = Hang()
    let folders = lister(hang, timeout: .milliseconds(100))
    defer { hang.release() }
    await fillCap(folders, hang)
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000, "c/g.bin": 1_200_000])
    let index = try await DiskScanner(root: root, storage: try Fixtures.tempDir(), lister: folders).run().index
    #expect(index.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect((0..<index.folders.count).allSatisfy { !index.folders[$0].flags.contains(.stale) })
}

@Test func aLostHistoryRescanWithTheCapFullKeepsACorrectIndex() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let folders = lister(hang, timeout: .milliseconds(100), clock: clock)
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000, "c/g.bin": 10])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, coalesceWindow: .seconds(10))
    await live.injectClock { clock.now }
    await live.injectLister(folders)
    await live.disableWatcher()
    _ = try await live.open()
    defer { hang.release() }
    let base = await live.withIndex { $0.lastEventID } + 1_000_000_000
    await fillCap(folders, hang)
    try Fixtures.write(root.appending(path: "c/new/h.bin"), bytes: 1_500_000)
    try await live.apply([lost(Fixtures.realPath(root), base + 1)])
    #expect(await live.stats().fullRescans == 1)
    let total = Fixtures.sumAllocated(under: root)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == total)
    try await live.save()
    #expect(try ScanIndex.load(from: store).folders[0].totalAllocated == total)
    try await live.close()
}

@Test func aLostHistoryRescanWhoseRootHangsKeepsTheIndex() async throws {
    let clock = ManualClock()
    let hang = Hang()
    let folders = lister(hang, timeout: .milliseconds(200), clock: clock)
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let real = Fixtures.realPath(root)
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, coalesceWindow: .seconds(10))
    await live.injectClock { clock.now }
    await live.injectLister(folders)
    await live.disableWatcher()
    _ = try await live.open()
    defer { hang.release() }
    let base = await live.withIndex { $0.lastEventID } + 1_000_000_000
    let before = await live.withIndex { $0.folders[0].totalAllocated }
    hang.block(real)
    try await live.apply([lost(real, base + 1)])
    #expect(await live.stats().fullRescans == 0)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == before)
    // Nothing empty is saved: the snapshot on disk is still the one from open().
    try await live.save()
    #expect(try ScanIndex.load(from: store).folders[0].totalAllocated == before)

    // Once the root reads again, the next apply does the rescan that is still owed.
    hang.release()
    for _ in 0..<100 where folders.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    clock.advance(.seconds(601))
    try await live.apply([change(real + "/a", base + 2)])
    #expect(await live.stats().fullRescans == 1)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}

@Test func lostHistoryCoveredByAFullRescanIsIgnored() async throws {
    let clock = ManualClock()
    let (live, root, base) = try await opened(["a/f.bin": 10], clock: clock, lister: DirectoryLister())
    await live.injectCurrentEventID { base + 10 }
    try await live.apply([lost(root, base + 1)])
    #expect(await live.stats().fullRescans == 1)
    // Dropped while that rescan ran: already covered.
    try await live.apply([lost(root, base + 5), FSChange(path: root + "/a", id: base + 6, rescanSubtree: true, historyLost: false)])
    #expect(await live.stats().fullRescans == 1)
    #expect(await live.stats().subtreesRescanned == 0)
    #expect(await live.withIndex { $0.lastEventID } == base + 6)
    try await live.apply([lost(root, base + 11)])
    #expect(await live.stats().fullRescans == 2)
    try await live.close()
}

@Test func reconcileRelistsTheParentOfADatalessFolder() async throws {
    let root = try Fixtures.tree(["local/g.bin": 10, "cloud/x/h.bin": 10])
    let real = Fixtures.realPath(root)
    let hang = Hang()
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), coalesceWindow: .seconds(10))
    await live.injectLister(lister(hang, read: cloudRoot(real, hang)))
    await live.disableWatcher()
    _ = try await live.open()
    let rootListings = hang.opens(of: "root-listed")
    // Excluding cloud/x reconciles cloud, which is dataless: its parent is listed instead.
    try await live.setExclusions(["cloud/x"])
    #expect(hang.opens(of: real + "/cloud") == 0)
    #expect(hang.opens(of: "root-listed") == rootListings + 1)
    try await live.close()
}

@Test func wrappedEventIDsAreNeverCovered() async throws {
    let clock = ManualClock()
    let (live, root, base) = try await opened(["a/f.bin": 10], clock: clock, lister: DirectoryLister())
    await live.injectCurrentEventID { base + 10 }
    try await live.apply([lost(root, base + 1)])
    #expect(await live.stats().fullRescans == 1)
    // Wrapped IDs say nothing about order: below the coverage or not, it rescans.
    try await live.apply([FSChange(path: root, id: base + 2, rescanSubtree: false, historyLost: true, idsWrapped: true)])
    #expect(await live.stats().fullRescans == 2)
    #expect(FSChange.from(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped), id: 7)?.idsWrapped == true)
    try await live.close()
}
