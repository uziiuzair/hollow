import Darwin
import Foundation
import Testing
@testable import DiskEngine

// Critical 1: a changed device number (replug, reboot) must not garbage the tree.
@Test func reopenedWithNewDeviceNumberKeepsSubfolders() async throws {
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store)
    _ = try await first.open()
    await first.withIndex { $0.rootDevice = 123_456 }
    try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .snapshot)
    try Fixtures.write(root.appending(path: "a/new.bin"), bytes: 10)
    let next = await second.withIndex { $0.lastEventID } + 1
    try await second.apply([FSChange(path: Fixtures.realPath(root) + "/a", id: next, rescanSubtree: false, historyLost: false)])
    #expect(await second.withIndex { $0.folder(atRelativePath: "a/b") } != nil)
    #expect(await second.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await second.close()
}

// Important 2: a failed apply must not advance the event ID, and must self-repair.
@Test func failedApplyDoesNotAdvanceAndRecovers() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    _ = try await live.open()
    let before = await live.withIndex { $0.lastEventID }
    try Fixtures.write(root.appending(path: "a/g.bin"), bytes: 1_500_000)
    await live.injectFault { throw DiskEngineError.posix("injected", ENOSPC) }
    let change = FSChange(path: Fixtures.realPath(root) + "/a", id: before + 10, rescanSubtree: false, historyLost: false)
    await #expect(throws: (any Error).self) { try await live.apply([change]) }
    #expect(await live.withIndex { $0.lastEventID } == before)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
    await live.injectFault(nil)
    try await live.apply([FSChange(path: Fixtures.realPath(root), id: before + 11, rescanSubtree: false, historyLost: false)])
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    #expect(await live.withIndex { $0.lastEventID } == before + 11)
    try await live.close()
}

// Important 3: a partial write followed by an error must not shift later records.
@Test func partialWriteFailureDoesNotShiftRecords() throws {
    let file = try MappedAppendFile(url: try Fixtures.tempDir().appending(path: "t.bin"))
    var calls = 0
    file.writer = { fd, p, n, off in
        calls += 1
        if calls == 1 {
            _ = pwrite(fd, p, n / 2, off)
            errno = ENOSPC
            return -1
        }
        return pwrite(fd, p, n, off)
    }
    let bytes: [UInt8] = Array(0..<100)
    try bytes.withUnsafeBytes { _ = try file.append($0) }
    #expect(throws: (any Error).self) { try file.flush() }
    try file.flush()
    let back = try file.withMappedBytes { Array($0) }
    #expect(back == bytes)
}

// Important 4: corrupt IDs or missing file tables are rejected, never trusted.
@Test func snapshotWithBadFolderLinkIsRejected() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["a/f": 10]), storage: store).run()
    try r.index.save(to: store)
    let url = store.appending(path: "index.snapshot")
    var data = try Data(contentsOf: url)
    let foldersStart = 92 + 4 + r.index.rootPath.utf8.count + 4
    data.replaceSubrange((foldersStart + 8)..<(foldersStart + 12), with: [0xFF, 0xFF, 0xFF, 0x7F])
    try data.write(to: url)
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
}

@Test func snapshotWithMissingFileTableIsRejected() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["big.bin": 2_000_000]), storage: store).run()
    try r.index.save(to: store)
    try FileManager.default.removeItem(at: store.appending(path: "files.bin"))
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
}

// Important 5: items crossing the size floor are not reported as huge changes.
@Test func crossingTheFloorIsNotAHugeChange() {
    let old = SizeSnapshot(sizes: ["": 50_000_000_000, "a": 110_000_000, "f": 510_000_000], files: ["f"])
    let new = SizeSnapshot(sizes: ["": 49_975_000_000], files: [])
    #expect(ChangeReport.changes(from: old, to: new).isEmpty)
}

// Important 6: saving goes through the lock.
@Test func lockedSaveWritesSnapshot() async throws {
    let root = try Fixtures.tree(["a/f": 10])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    _ = try await live.open()
    try FileManager.default.removeItem(at: store.appending(path: "index.snapshot"))
    try await live.save()
    #expect(FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
    try await live.close()
}

// Promoted minor: no history yet means no changes, not "the whole disk grew".
@Test func noHistoryMeansNoChanges() async throws {
    let root = try Fixtures.tree(["big.bin": 150_000_000])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    #expect(try await live.changes(since: 1).isEmpty)
    try await live.close()
}
