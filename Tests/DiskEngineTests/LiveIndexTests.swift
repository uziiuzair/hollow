import Foundation
import Testing
@testable import DiskEngine

@Test func secondOpenLoadsSnapshot() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store)
    #expect(try await first.open() == .fullScan(reason: "no snapshot"))
    try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .snapshot)
    #expect(await second.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await second.close()
}

@Test func burstOfChangesMatchesFreshScan() async throws {
    let root = try Fixtures.tree(["seed/": 0])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    _ = try await live.open()
    let base = Fixtures.realPath(root)
    // Event IDs are system-wide and already large; stay above the stored one.
    let firstID = await live.withIndex { $0.lastEventID } + 1_000_000_000
    var changes: [FSChange] = []
    for d in 0..<200 {
        for f in 0..<10 { try Fixtures.write(root.appending(path: "seed/d\(d)/f\(f)"), bytes: f == 0 ? 1_100_000 : 10) }
        changes.append(FSChange(path: base + "/seed/d\(d)", id: firstID + UInt64(d), rescanSubtree: false, historyLost: false))
    }
    changes.append(FSChange(path: base + "/seed", id: firstID + 999, rescanSubtree: false, historyLost: false))
    try await live.apply(changes)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    #expect(await live.withIndex { $0.lastEventID } == firstID + 999)
    try await live.close()
}

@Test func subtreeRescanAndOutsidePaths() async throws {
    let root = try Fixtures.tree(["a/b/c/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    _ = try await live.open()
    try Fixtures.write(root.appending(path: "a/b/c/d/g.bin"), bytes: 1_500_000)
    try FileManager.default.removeItem(at: root.appending(path: "a/b/c/f.bin"))
    let base = Fixtures.realPath(root)
    try await live.apply([
        FSChange(path: base + "/a", id: 5, rescanSubtree: true, historyLost: false),
        FSChange(path: "/somewhere/else", id: 6, rescanSubtree: false, historyLost: false),
    ])
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}

@Test func fseventsUUIDMismatchForcesFullScan() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store)
    _ = try await first.open()
    await first.withIndex { $0.fseventsUUID = "not-the-real-one" }
    try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .fullScan(reason: "event history changed"))
    try await second.close()
}

@Test func interruptedScanResumes() async throws {
    let root = try Fixtures.tree(Dictionary(uniqueKeysWithValues: (0..<200).map { ("d\($0)/f", 10) }))
    let store = try Fixtures.tempDir()
    let idx = try ScanIndex(rootName: root.lastPathComponent, storage: store)
    var st = stat()
    stat(root.path, &st)
    idx.rootPath = Fixtures.realPath(root)
    idx.rootDevice = st.st_dev
    idx.fseventsUUID = EventWatcher.journalUUID(device: st.st_dev)
    _ = try await DiskScanner(root: root, storage: store, workers: 1)
        .scan(into: idx, starting: [0], checkpointEvery: .zero) { i in
            try i.save(to: store)
            return .stop
        }
    let live = LiveIndex(volumeRoot: root, store: store)
    #expect(try await live.open() == .resumed)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}

@Test func storeDirectoryIsKeyedByVolumeUUID() throws {
    let tmp = FileManager.default.temporaryDirectory
    let uuid = try #require(try tmp.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let dir = try LiveIndex.storeDirectory(base: try Fixtures.tempDir(), volume: tmp)
    #expect(dir.lastPathComponent == uuid)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}
