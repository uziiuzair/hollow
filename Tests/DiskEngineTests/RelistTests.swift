// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

private func scanned(_ root: URL) async throws -> ScanIndex {
    try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
}

@discardableResult
private func relist(_ idx: ScanIndex, _ rel: String) throws -> [FolderID] {
    var r = BulkDirectoryReader()
    let id = try #require(idx.folder(atRelativePath: rel))
    return try idx.relist(r.list(path: idx.path(of: id, rootPath: idx.rootPath), folder: id)).newFolders
}

@Test func addedFileUpdatesAncestors() async throws {
    let root = try Fixtures.tree(["a/b/x": 10])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 3_000_000).write(to: root.appending(path: "a/b/new.bin"))
    try relist(idx, "a/b")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.garbageFiles == 0)
}

@Test func renamedFolderIsReportedForScanning() async throws {
    let root = try Fixtures.tree(["a/old/deep/f.bin": 2_000_000])
    let idx = try await scanned(root)
    try FileManager.default.moveItem(at: root.appending(path: "a/old"), to: root.appending(path: "a/new"))
    let toScan = try relist(idx, "a")
    #expect(toScan.count == 1)
    #expect(idx.folder(atRelativePath: "a/old") == nil)
    #expect(idx.folder(atRelativePath: "a/new") == toScan[0])
    #expect(idx.garbageFolders == 2)
}

@Test func untouchedSiblingSubtreeSurvivesRelist() async throws {
    let root = try Fixtures.tree(["a/keep/deep/f.bin": 2_000_000, "a/x": 10])
    let idx = try await scanned(root)
    let deepBefore = idx.folder(atRelativePath: "a/keep/deep")
    try Data(repeating: 1, count: 50).write(to: root.appending(path: "a/y"))
    #expect(try relist(idx, "a").isEmpty)
    let deep = try #require(idx.folder(atRelativePath: "a/keep/deep"))
    #expect(deep == deepBefore)
    #expect(idx.path(of: deep, rootPath: "/r") == "/r/a/keep/deep")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.garbageFolders == 0)
}

@Test func fileParentsStayValidAfterRelist() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/x": 10])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 50).write(to: root.appending(path: "a/y"))
    try relist(idx, "a")
    let parent = try idx.files.record(0).parent
    #expect(idx.path(of: parent, rootPath: "") == "/a/keep")
}

@Test func removedFolderSubtractsItsTotal() async throws {
    let root = try Fixtures.tree(["a/gone/f.bin": 2_000_000, "a/stay": 10])
    let idx = try await scanned(root)
    try FileManager.default.removeItem(at: root.appending(path: "a/gone"))
    try relist(idx, "a")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.folder(atRelativePath: "a/gone") == nil)
    #expect(try idx.children(of: idx.folder(atRelativePath: "a")!).map(\.name) == ["1 small files"])
}

@Test func replacedBigFileCountsAsGarbage() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let idx = try await scanned(root)
    try Data(repeating: 2, count: 3_000_000).write(to: root.appending(path: "a/f.bin"))
    try relist(idx, "a")
    #expect(idx.garbageFiles == 1)
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
}

@Test func vanishedFolderRelistedAsEmpty() async throws {
    let root = try Fixtures.tree(["a/b/f.bin": 2_000_000])
    let idx = try await scanned(root)
    let b = try #require(idx.folder(atRelativePath: "a/b"))
    try FileManager.default.removeItem(at: root.appending(path: "a/b"))
    _ = try idx.relist(DirectoryListing(folder: b, outcome: .vanished, entries: []))
    #expect(idx.folders[0].totalAllocated == 0)
}

@Test func resetContentsThenRescanMatchesFresh() async throws {
    let root = try Fixtures.tree(["a/b/c/f.bin": 2_000_000])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 1_500_000).write(to: root.appending(path: "a/b/c/g.bin"))
    let a = try #require(idx.folder(atRelativePath: "a"))
    idx.resetContents(of: a)
    _ = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).scan(into: idx, starting: [a])
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.folder(atRelativePath: "a/b/c") != nil)
}

@Test func relistKeepsHardLinkedFileCounted() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "b/": 0])
    try FileManager.default.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "b/link.bin"))
    let idx = try await scanned(root)
    let before = idx.folders[0].totalAllocated
    try Data(repeating: 1, count: 50).write(to: root.appending(path: "a/y"))
    try relist(idx, "a")
    try relist(idx, "b")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.folders[0].totalAllocated > before)
}
