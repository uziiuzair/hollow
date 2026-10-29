// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import DiskEngine

@Test func smallFilesFoldAndBigFilesAreStored() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("big.mov", allocated: 3_000_000), .file("a", allocated: 4096), .file("b", allocated: 4096),
    ]), rootDevice: 1)
    #expect(idx.folders[0].bigFileCount == 1)
    #expect(idx.folders[0].smallFileCount == 2)
    #expect(idx.folders[0].smallAllocated == 8192)
    #expect(idx.folders[0].totalAllocated == 3_008_192)
    #expect(try idx.files.name(idx.folders[0].firstFile) == "big.mov")
}

@Test func totalsPropagateToEveryAncestor() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    let l1 = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [.dir("a")]), rootDevice: 1)
    let l2 = try idx.integrate(.init(folder: l1[0], outcome: .ok, entries: [.dir("b")]), rootDevice: 1)
    _ = try idx.integrate(.init(folder: l2[0], outcome: .ok, entries: [.file("x", allocated: 5_000_000)]), rootDevice: 1)
    #expect(idx.folders[0].totalAllocated == 5_000_000)
    #expect(idx.folders[Int(l1[0])].totalAllocated == 5_000_000)
    #expect(idx.path(of: l2[0], rootPath: "/r") == "/r/a/b")
    #expect(idx.path(of: 0, rootPath: "/r") == "/r")
    #expect(idx.folderName(l2[0]) == "b")
}

@Test func hardLinkCountedOnce() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("one", allocated: 2_000_000, inode: 42, links: 2), .file("two", allocated: 2_000_000, inode: 42, links: 2),
    ]), rootDevice: 1)
    #expect(idx.folders[0].totalAllocated == 2_000_000)
    #expect(try idx.files.record(0).flags.contains(.hardLinked))
}

@Test func otherDeviceAndMountPointsAreNotDescended() throws {
    #expect(shouldDescend(entryDevice: 1, rootDevice: 1, isMountPoint: false))
    #expect(!shouldDescend(entryDevice: 2, rootDevice: 1, isMountPoint: false))
    #expect(!shouldDescend(entryDevice: 1, rootDevice: 1, isMountPoint: true))
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    var mounted = RawEntry.dir("Volume")
    mounted.isMountPoint = true
    #expect(try idx.integrate(.init(folder: 0, outcome: .ok, entries: [mounted]), rootDevice: 1).isEmpty)
}

@Test func unreadableFolderFlaggedAndZero() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    #expect(try idx.integrate(.init(folder: 0, outcome: .unreadable, entries: []), rootDevice: 1).isEmpty)
    #expect(idx.folders[0].flags.contains(.unreadable))
    #expect(idx.folders[0].totalAllocated == 0)
}

@Test func childrenSortedWithSmallFilesBucket() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("big.mov", allocated: 3_000_000), .file("a", allocated: 4096), .dir("d"),
    ]), rootDevice: 1)
    let c = try idx.children(of: 0)
    #expect(c.map(\.name) == ["big.mov", "1 small files", "d"])
}

@Test func topFilesKeepsLargestOnly() {
    var t = TopFiles(capacity: 2)
    t.offer(0, allocated: 10)
    t.offer(1, allocated: 30)
    t.offer(2, allocated: 20)
    #expect(t.sortedDescending().map(\.0) == [1, 2])
}
