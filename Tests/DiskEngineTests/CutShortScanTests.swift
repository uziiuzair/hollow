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
