import Foundation
import Testing
@testable import DiskEngine

@Test func snapshotRoundTripsAFullScan() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "a/s": 10, "b/c/big2.bin": 1_500_000])
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: root, storage: store).run()
    r.index.lastEventID = 4242
    r.index.fseventsUUID = "abc"
    try r.index.save(to: store)
    let loaded = try ScanIndex.load(from: store)
    #expect(loaded.folders.count == r.index.folders.count)
    #expect(loaded.folders[0].totalAllocated == r.index.folders[0].totalAllocated)
    #expect(loaded.lastEventID == 4242)
    #expect(loaded.fseventsUUID == "abc")
    #expect(loaded.rootPath == r.index.rootPath)
    #expect(loaded.rootDevice == r.index.rootDevice)
    #expect(try loaded.children(of: 0).map(\.name) == (try r.index.children(of: 0).map(\.name)))
    #expect(loaded.top.sortedDescending().count == 2)
}

@Test func filesAppendedAfterSaveAreDroppedOnLoad() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["big.bin": 2_000_000]), storage: store).run()
    try r.index.save(to: store)
    _ = try r.index.files.append(name: "ghost", record: .init(allocated: 9, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    try r.index.files.flush()
    let loaded = try ScanIndex.load(from: store)
    #expect(loaded.files.count == 1)
    #expect(try loaded.files.name(0) == "big.bin")
}

@Test func missingCorruptOrForeignSnapshotIsRejected() throws {
    let store = try Fixtures.tempDir()
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
    try Data(Array("DINX".utf8) + [9, 0, 0, 0]).write(to: store.appending(path: "index.snapshot"))
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
    try Data(repeating: 7, count: 300).write(to: store.appending(path: "index.snapshot"))
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
}

@Test func truncatedSnapshotIsRejected() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["a/big.bin": 2_000_000]), storage: store).run()
    try r.index.save(to: store)
    let url = store.appending(path: "index.snapshot")
    let data = try Data(contentsOf: url)
    try data.prefix(data.count - 5).write(to: url)
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
}

@Test func failedSaveKeepsPreviousSnapshot() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["big.bin": 2_000_000]), storage: store).run()
    r.index.lastEventID = 1
    try r.index.save(to: store)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
    r.index.lastEventID = 2
    #expect(throws: (any Error).self) { try r.index.save(to: store) }
    #expect(try ScanIndex.load(from: store).lastEventID == 1)
}
