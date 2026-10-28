import Darwin
import Foundation
import Testing
@testable import DiskEngine

private func historyDays(_ store: URL) throws -> [Day] {
    try HistoryStore(directory: store.appending(path: "history")).days()
}

// Final review 1: a cancelled scan stops and keeps what it has not listed as pending.
@Test func cancelledScanKeepsPending() async throws {
    let root = try Fixtures.tree(["a/b/f.bin": 10, "c/g.bin": 10])
    let storage = try Fixtures.tempDir()
    let rootPath = Fixtures.realPath(root)
    let pending = try await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let index = try ScanIndex(rootName: root.lastPathComponent, storage: storage)
        index.rootPath = rootPath
        var info = stat()
        _ = stat(rootPath, &info)
        index.rootDevice = info.st_dev
        _ = try await DiskScanner(root: root, storage: storage).scan(into: index, starting: [0])
        return index.pending
    }.value
    #expect(!pending.isEmpty)
}

// Final review 1: an open cut short by cancellation throws, records no history, and
// leaves at most a resumable snapshot, which the next open finishes.
@Test func cancelledOpenSavesOnlyResumableSnapshot() async throws {
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000, "c/g.bin": 100])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    let opening = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await live.open()
    }
    await #expect(throws: CancellationError.self) { _ = try await opening.value }
    try await live.close()
    if let saved = try? ScanIndex.load(from: store) { #expect(!saved.pending.isEmpty) }
    #expect(try historyDays(store).isEmpty)

    let again = LiveIndex(volumeRoot: root, store: store)
    let opened = try await again.open()
    #expect(opened != .snapshot)
    #expect(await again.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await again.close()
}

// Final review 1: if the root disappears during the scan (cable pulled), open throws
// and neither open nor close saves the cut-short index or records history.
@Test func rootVanishingDuringScanSavesNothing() async throws {
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    let moved = root.deletingLastPathComponent().appending(path: "moved-\(UUID().uuidString)")
    await live.injectBeforeScan { try? FileManager.default.moveItem(at: root, to: moved) }
    await #expect(throws: (any Error).self) { _ = try await live.open() }
    try? await live.close()
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: ScanIndex.snapshotName).path))
    #expect(try historyDays(store).isEmpty)
}

// Final review M4: an exclusions change whose scan is cut short (the drive still mounted) keeps what it didn't list as
// pending, with no full rescan: the next apply finishes it, and so does the next open.
@Test func cutShortExclusionScanResumesWithoutAFullRescan() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/x/g.bin": 3_000_000, "a/skip/y/h.bin": 1_000_000])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, exclusions: ["a/skip"])
    await live.disableWatcher()
    _ = try await live.open()
    await live.injectBeforeScan { withUnsafeCurrentTask { $0?.cancel() } }
    await #expect(throws: CancellationError.self) { try await Task { try await live.setExclusions([]) }.value }
    await live.injectBeforeScan(nil)
    #expect(await live.withIndex { !$0.pending.isEmpty })
    #expect(FileManager.default.fileExists(atPath: store.appending(path: ScanIndex.snapshotName).path))
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a/keep", id: 0, rescanSubtree: false, historyLost: false)])
    #expect(await live.stats().fullRescans == 0)
    #expect(await live.withIndex { $0.pending.isEmpty })
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}

@Test func cutShortExclusionScanResumesAtTheNextOpen() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/x/g.bin": 3_000_000])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store, exclusions: ["a/skip"])
    await live.disableWatcher()
    _ = try await live.open()
    await live.injectBeforeScan { withUnsafeCurrentTask { $0?.cancel() } }
    await #expect(throws: CancellationError.self) { try await Task { try await live.setExclusions([]) }.value }
    try await live.close()
    let again = LiveIndex(volumeRoot: root, store: store)
    await again.disableWatcher()
    #expect(try await again.open() == .resumed)
    #expect(try await again.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await again.close()
}

// Final review M4: the same for a retry of unreadable folders.
@Test func cutShortUnreadableRetryResumesWithoutAFullRescan() async throws {
    let root = try Fixtures.tree(["a/locked/sub/f.bin": 2_000_000, "a/open.bin": 1_200_000])
    let locked = root.appending(path: "a/locked").path
    chmod(locked, 0); defer { chmod(locked, 0o755) }
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    await live.disableWatcher()
    _ = try await live.open()
    chmod(locked, 0o755)
    await #expect(throws: CancellationError.self) {
        try await Task { try await live.retryUnreadable(beforeScan: { withUnsafeCurrentTask { $0?.cancel() } }) }.value
    }
    #expect(await live.withIndex { !$0.pending.isEmpty })
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a", id: 0, rescanSubtree: false, historyLost: false)])
    #expect(await live.stats().fullRescans == 0)
    #expect(await live.withIndex { $0.pending.isEmpty })
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
