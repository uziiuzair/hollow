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
    private let state = OSAllocatedUnfairLock(initialState: (paths: Set<String>(), prefix: String?.none, opened: [String]()))
    private let gate = DispatchSemaphore(value: 0)

    func block(_ path: String) { state.withLock { _ = $0.paths.insert(path) } }
    func block(under prefix: String) { state.withLock { $0.prefix = prefix } }
    /// Every blocked listing returns; later ones no longer block.
    func release() {
        state.withLock { $0.paths = []; $0.prefix = nil }
        gate.signal()
    }
    var opened: [String] { state.withLock { $0.opened } }
    func opens(of path: String) -> Int { opened.filter { $0 == path }.count }

    func read(_ path: String, _ folder: FolderID) -> DirectoryListing {
        let blocked = state.withLock { s in
            s.opened.append(path)
            return s.paths.contains(path) || s.prefix.map { path.hasPrefix($0) } == true
        }
        if blocked {
            gate.wait()
            gate.signal()  // lets the next blocked listing go too
        }
        return DirectoryLister.read(path, folder)
    }
}

private func lister(_ hang: Hang, timeout: Duration = .seconds(5), clock: ManualClock? = nil,
                    read: (@Sendable (String, FolderID) -> DirectoryListing)? = nil) -> DirectoryLister {
    let now: @Sendable () -> ContinuousClock.Instant
    if let clock { now = { clock.now } } else { now = { ContinuousClock.now } }
    let reader: @Sendable (String, FolderID) -> DirectoryListing = read ?? { hang.read($0, $1) }
    return DirectoryLister(timeout: timeout, now: now, read: reader)
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

@Test func theWorkerCapHolds() async throws {
    let hang = Hang()
    hang.block(under: "/hang/")
    let folders = lister(hang, timeout: .milliseconds(100))
    defer { hang.release() }
    var outcomes: [String] = []
    for i in 0..<6 {
        switch await folders.list(path: "/hang/\(i)", folder: 0) {
        case .listed: outcomes.append("listed")
        case .timedOut: outcomes.append("timedOut")
        case .skipped: outcomes.append("skipped")
        }
    }
    #expect(outcomes == ["timedOut", "timedOut", "timedOut", "timedOut", "skipped", "skipped"])
    #expect(hang.opened.count == 4)
    #expect(folders.abandonedCount == 4)

    // Once workers return, listing resumes.
    hang.release()
    for _ in 0..<100 where folders.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(folders.abandonedCount == 0)
    if case .listed = await folders.list(path: "/fresh", folder: 0) {} else { Issue.record("not listed after the cap cleared") }
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
private func cloudRoot(_ real: String, _ hang: Hang) -> @Sendable (String, FolderID) -> DirectoryListing {
    var info = stat()
    lstat(real, &info)
    let device = info.st_dev
    return { path, folder in
        guard path == real else { return hang.read(path, folder) }
        _ = hang.read("root-listed", folder)
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
