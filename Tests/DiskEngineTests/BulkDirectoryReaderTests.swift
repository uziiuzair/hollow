import Darwin
import Foundation
import Testing
@testable import DiskEngine

@Test func listsFilesDirsAndSizesMatchingFoundation() throws {
    let root = try Fixtures.tree(["a.bin": 2_000_000, "b.txt": 10, "sub/": 0])
    var r = BulkDirectoryReader()
    let l = r.list(path: root.path, folder: 0)
    #expect(l.outcome == .ok)
    #expect(l.folder == 0)
    let byName = Dictionary(uniqueKeysWithValues: l.entries.map { ($0.name, $0) })
    #expect(byName.count == 3)
    #expect(byName["sub"]?.kind == .directory)
    #expect(byName["a.bin"]?.kind == .file)
    #expect(byName["a.bin"]?.allocated == Fixtures.allocatedSize(root.appending(path: "a.bin")))
    #expect(byName["a.bin"]?.logical == 2_000_000)
    #expect(byName["a.bin"]?.linkCount == 1)
    #expect(byName["b.txt"]?.logical == 10)
}

@Test func symlinkIsReportedNotFollowed() throws {
    let root = try Fixtures.tree(["d/": 0])
    try FileManager.default.createSymbolicLink(at: root.appending(path: "d/loop"), withDestinationURL: root)
    var r = BulkDirectoryReader()
    let l = r.list(path: root.appending(path: "d").path, folder: 1)
    #expect(l.entries.single?.kind == .symlink)
}

@Test func unicodeNamesSurvive() throws {
    let root = try Fixtures.tree(["Ünïcødé 写真 🗂.txt": 1])
    var r = BulkDirectoryReader()
    #expect(r.list(path: root.path, folder: 0).entries.first?.name == "Ünïcødé 写真 🗂.txt")
}

@Test func missingFolderIsVanishedNotError() {
    var r = BulkDirectoryReader()
    let l = r.list(path: "/nonexistent-\(UUID())", folder: 3)
    #expect(l.outcome == .vanished && l.entries.isEmpty)
}

@Test func lockedFolderIsUnreadable() throws {
    let root = try Fixtures.tree(["locked/x": 5])
    let locked = root.appending(path: "locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    var r = BulkDirectoryReader()
    #expect(r.list(path: locked.path, folder: 2).outcome == .unreadable)
}

@Test func largeFolderSpansSeveralBulkCalls() throws {
    var spec: [String: Int] = [:]
    for n in 0..<3_000 { spec["many/file-with-a-longish-name-\(n).txt"] = 1 }
    let root = try Fixtures.tree(spec)
    var r = BulkDirectoryReader()
    #expect(r.list(path: root.appending(path: "many").path, folder: 0).entries.count == 3_000)
}

@Test func clonedFileIsMarkedMayShareBlocks() throws {
    let root = try Fixtures.tree(["a.bin": 2_000_000])
    #expect(clonefile(root.appending(path: "a.bin").path, root.appending(path: "b.bin").path, 0) == 0)
    var r = BulkDirectoryReader()
    let byName = Dictionary(uniqueKeysWithValues: r.list(path: root.path, folder: 0).entries.map { ($0.name, $0) })
    #expect(byName["b.bin"]?.flags.contains(.mayShareBlocks) == true)
    #expect(byName["b.bin"]?.logical == 2_000_000)
}
