import Foundation
import Testing
@testable import DiskEngine

@Test func compactionDropsGarbageAndKeepsTotals() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/gone/g.bin": 1_500_000, "b/x": 10])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    idx.lastEventID = 77
    try FileManager.default.removeItem(at: root.appending(path: "a/gone"))
    var r = BulkDirectoryReader()
    let a = try #require(idx.folder(atRelativePath: "a"))
    _ = try idx.relist(r.list(path: Fixtures.realPath(root.appending(path: "a")), folder: a))
    #expect(idx.garbageRatio > 0)

    let c = try idx.compacted(into: try Fixtures.tempDir())
    #expect(c.garbageRatio == 0)
    #expect(c.folders.count == 4) // root, a, a/keep, b
    #expect(c.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(c.files.count == 1)
    #expect(c.top.sortedDescending().count == 1)
    #expect(c.lastEventID == 77)
    #expect(c.rootPath == idx.rootPath)
    let keep = try #require(c.folder(atRelativePath: "a/keep"))
    #expect(c.path(of: try c.files.record(0).parent, rootPath: "") == "/a/keep")
    #expect(try c.children(of: keep).map(\.name) == ["f.bin"])
}

@Test func compactionKeepsReachablePendingAndHardLinks() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "b/": 0])
    try FileManager.default.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "b/link.bin"))
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let b = try #require(idx.folder(atRelativePath: "b"))
    idx.pending = [b]
    let c = try idx.compacted(into: try Fixtures.tempDir())
    #expect(c.pending.count == 1)
    #expect(c.folderName(c.pending[0]) == "b")
    #expect(c.hardLinkOwners.count == 1)
}
