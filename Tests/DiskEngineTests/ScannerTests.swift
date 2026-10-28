import Foundation
import Testing
@testable import DiskEngine

@Test func scansTreeAndTotalsMatchFoundation() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "a/s1": 100, "b/c/s2": 100, "b/c/big2.bin": 1_500_000])
    let r = try await DiskScanner(root: root, storage: try Fixtures.tempDir(), workers: 4).run()
    #expect(r.index.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(r.index.files.count == 2)
    #expect(r.index.top.sortedDescending().count == 2)
    #expect(r.unreadableFolders == 0)
}

@Test func symlinkLoopTerminates() async throws {
    let root = try Fixtures.tree(["d/f": 10])
    try FileManager.default.createSymbolicLink(at: root.appending(path: "d/up"), withDestinationURL: root)
    let r = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.index.folders.count == 2)
}

@Test func unreadableSubfolderDoesNotStopScan() async throws {
    let root = try Fixtures.tree(["ok/f": 2_000_000, "locked/g": 10])
    let locked = root.appending(path: "locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let r = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.unreadableFolders == 1)
    #expect(r.index.files.count == 1)
}

@Test func hardLinkedFileCountedOnceOnDisk() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "b/": 0])
    try FileManager.default.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "b/link.bin"))
    let r = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.index.folders[0].totalAllocated == Fixtures.allocatedSize(root.appending(path: "a/big.bin")))
}

@Test func manyFoldersWithFewWorkers() async throws {
    var spec: [String: Int] = [:]
    for i in 0..<300 { spec["d\(i % 30)/e\(i)/f"] = 10 }
    let root = try Fixtures.tree(spec)
    let r = try await DiskScanner(root: root, storage: try Fixtures.tempDir(), workers: 2).run()
    #expect(r.index.folders.count == 1 + 30 + 300)
    #expect(r.index.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
}

@Test func progressStreamFinishesAndReportsFolders() async throws {
    let root = try Fixtures.tree(["a/f": 10, "b/g": 10])
    let scanner = DiskScanner(root: root, storage: try Fixtures.tempDir())
    let progress = scanner.progress
    async let result = scanner.run()
    var last: ScanProgress?
    for await p in progress { last = p }
    _ = try await result
    #expect(last?.foldersDone == 3)
    #expect(last?.filesSeen == 2)
}
