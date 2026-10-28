import CoreGraphics
import Foundation
import Testing
import DiskEngine
@testable import DiskApp

private let size = CGSize(width: 800, height: 600)

@Test func nodesCarryKindsNamesAndPaths() async throws {
    let idx = try await Fixtures.index(["Users/u/Movies/clip.mov": 3_000_000, "Users/u/Library/Caches/c.bin": 2_000_000, "Users/u/notes.txt": 10])
    let s = MapBuilder.build(index: idx, request: .init(path: "Users/u", size: size, period: 7), baseline: nil)
    #expect(s.path == "Users/u" && s.crumbs == [Crumb(name: "Users", path: "Users"), Crumb(name: "u", path: "Users/u")])
    #expect(s.nodes.first { $0.key == "Users/u/Movies" } == MapNode(key: "Users/u/Movies", name: "Movies", kind: .media, growth: 0, isFolder: true))
    #expect(s.nodes.first { $0.key == "Users/u/Movies/clip.mov" }?.kind == .media)
    #expect(s.nodes.first { $0.key == "Users/u/Library/Caches" }?.kind == .caches)
    #expect(s.nodes.contains { $0.key == "Users/u#small" && $0.kind == nil && $0.name == "1 small file" })
    #expect(s.total == idx.folders[Int(idx.folder(atRelativePath: "Users/u")!)].totalAllocated)
    #expect(s.url(of: s.nodes.firstIndex { $0.key == "Users/u/Movies" }!)?.path == idx.rootPath + "/Users/u/Movies")
}
@Test func zoomByPathSurvivesDeletionAndCompaction() async throws {
    let idx = try await Fixtures.index(["a/b/c/f.bin": 2_000_000, "a/x.bin": 1_200_000])
    #expect(MapBuilder.build(index: idx, request: .init(path: "a/b/gone/deeper", size: size, period: 7), baseline: nil).path == "a/b")
    idx.resetContents(of: idx.folder(atRelativePath: "a/b")!)
    #expect(MapBuilder.build(index: idx, request: .init(path: "a/b/c", size: size, period: 7), baseline: nil).path == "a/b")
    let compacted = try idx.compacted(into: try Fixtures.tempDir())
    #expect(MapBuilder.build(index: compacted, request: .init(path: "a", size: size, period: 7), baseline: nil).nodes.contains { $0.key == "a/x.bin" })
}
@Test func growthComesFromBaseline() async throws {
    let idx = try await Fixtures.index(["big/f.bin": 3_000_000, "other/g.bin": 2_000_000])
    let bigNow = idx.folders[Int(idx.folder(atRelativePath: "big")!)].totalAllocated
    let s = MapBuilder.build(index: idx, request: .init(path: "", size: size, period: 1),
                             baseline: SizeSnapshot(sizes: ["": 1, "big": bigNow - 1_000_000]))
    #expect(s.nodes.first { $0.key == "big" }?.growth == 1_000_000)
    #expect(s.nodes.first { $0.key == "other" }?.growth == 0)
}
@Test func listRowsCapAt200PlusRemainder() async throws {
    let idx = try await Fixtures.index(Dictionary(uniqueKeysWithValues: (0..<250).map { ("d\($0)/f", 10) }))
    let s = MapBuilder.build(index: idx, request: .init(path: "", size: size, period: 7), baseline: nil)
    #expect(s.list.count == 201)
    #expect(s.list.last?.name == "50 more items" && s.list.last?.node == nil)
    #expect(s.list.first?.fraction == 1)
}

@Test func unreadableChildrenAreListedLast() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000, "locked/g.bin": 1_200_000])
    let locked = root.appending(path: "locked").path
    chmod(locked, 0); defer { chmod(locked, 0o755) }
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let s = MapBuilder.build(index: idx, request: MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7), baseline: nil)
    #expect(s.list.last == ListRow(node: nil, name: "locked", size: 0, fraction: 0, kind: nil, isUnreadable: true))
    #expect(s.unreadableCount == 1 && s.unreadableNote == "1 folder here can't be read.")
}
