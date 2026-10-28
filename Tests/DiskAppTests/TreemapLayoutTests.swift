import CoreGraphics
import DiskEngine
import Foundation
import Testing
@testable import DiskApp

struct FakeSource: TreemapSource {
    var table: [FolderID: [TreemapItem]]
    func items(in folder: FolderID) -> [TreemapItem] { table[folder] ?? [] }
}
func files(_ sizes: [UInt64], from first: FileIndex = 0) -> [TreemapItem] {
    sizes.enumerated().map { TreemapItem(ref: .file(first + FileIndex($0.offset)), size: $0.element) }
}
func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}
let flat = TreemapOptions(gutter: 0, minSide: 2, headerHeight: 0, cap: 50_000)

@Test func squarifyMatchesThePaper() {
    let r = Squarify.tiles([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
    let e: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 3, 2), (0, 2, 3, 2), (3, 0, 1.7143, 2.3333), (4.7143, 0, 1.2857, 2.3333),
                                                     (3, 2.3333, 1.2, 1.6667), (4.2, 2.3333, 1.2, 1.6667), (5.4, 2.3333, 0.6, 1.6667)]
    #expect(r.count == 7)
    for (t, x) in zip(r, e) {
        #expect(abs(t.minX - x.0) < 1e-3 && abs(t.minY - x.1) < 1e-3 && abs(t.width - x.2) < 1e-3 && abs(t.height - x.3) < 1e-3)
    }
}
@Test func squarifyTilesWithoutGapsOrOverlap() {
    let bounds = CGRect(x: 10, y: 20, width: 640, height: 400)
    let r = Squarify.tiles((1...40).map { Double(41 - $0) * 1.7 }, in: bounds)
    #expect(abs(r.reduce(0) { $0 + $1.width * $1.height } - bounds.width * bounds.height) < 0.01)
    #expect(r.allSatisfy { bounds.insetBy(dx: -1e-6, dy: -1e-6).contains($0) })
    for i in r.indices { for j in r.indices where j > i { let x = r[i].intersection(r[j]); #expect(x.width * x.height < 1e-6) } }
}
@Test func tinyItemsFoldIntoOneSmallBlock() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 9_000), .init(ref: .small(parent: 0, files: 50, folders: 0), size: 200)]
                                   + files(Array(repeating: 2, count: 400))])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), options: flat)
    #expect(l.topLevelCount == 2)
    #expect(l.rects[0].ref == .folder(1) && close(l.rects[0].frame, CGRect(x: 0, y: 0, width: 90, height: 100)))
    #expect(l.rects[1].ref == .small(parent: 0, files: 450, folders: 0) && l.rects[1].size == 1_000)
    #expect(close(l.rects[1].frame, CGRect(x: 90, y: 0, width: 10, height: 100)))
}
@Test func capMergesTheSmallestSiblings() {
    let l = TreemapLayout.make(source: FakeSource(table: [0: files(Array(repeating: 100, count: 20))]), root: 0,
                               bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), options: .init(gutter: 0, minSide: 2, headerHeight: 0, cap: 10))
    #expect(l.rects.count == 10)
    #expect(l.rects.filter { $0.ref == .more(parent: 0, count: 11) }.map(\.size) == [1_100])
}
@Test func capIsSharedBreadthFirst() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 300), .init(ref: .folder(2), size: 150)],
                                 1: files(Array(repeating: 10, count: 30)), 2: files(Array(repeating: 5, count: 30), from: 100)])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                               options: .init(gutter: 0, minSide: 2, headerHeight: 0, cap: 20))
    #expect(l.rects.count == 20)
    #expect(l.rects[0].ref == .folder(1) && l.rects[0].childCount == 18)
    #expect(l.rects[1].ref == .folder(2) && l.rects[1].childCount == 0)
}
@Test func hugeFolderStaysUnderCap() {
    let l = TreemapLayout.make(source: FakeSource(table: [0: files(Array(repeating: 1, count: 200_000))]), root: 0,
                               bounds: CGRect(x: 0, y: 0, width: 4000, height: 4000))
    #expect(l.rects.count == 50_000)
    #expect(l.rects.contains { $0.ref == .more(parent: 0, count: 150_001) })
}
@Test func topLevelFoldersGetAHeaderAndHoldTheirChildren() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 100)], 1: files([50, 50])])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
                               options: .init(gutter: 2, minSide: 2, headerHeight: 34, cap: 50_000))
    #expect(close(l.rects[0].frame, CGRect(x: 1, y: 1, width: 198, height: 198)) && l.rects[0].hasHeader)
    #expect(close(l.rects[1].frame, CGRect(x: 3, y: 37, width: 96, height: 160)))
    #expect(close(l.rects[2].frame, CGRect(x: 101, y: 37, width: 96, height: 160)))
    #expect(l.rects[1].parent == 0 && l.rects[1].depth == 2)
    #expect(l.hitTest(CGPoint(x: 50, y: 100)) == 1)
    #expect(l.hitTest(CGPoint(x: 50, y: 20)) == 0)
    #expect(l.hitTest(CGPoint(x: 199.5, y: 100)) == nil)
    #expect(l.topLevel(of: 2) == 0)
}
@Test func zeroSizedItemsMakeNoRects() {
    #expect(TreemapLayout.make(source: FakeSource(table: [0: files([0, 0, 0])]), root: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)).rects.isEmpty)
    #expect(TreemapLayout.make(source: FakeSource(table: [0: files([5])]), root: 0, bounds: .zero).rects.isEmpty)
    #expect(Squarify.tiles([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
}
@Test func zoomTransforms() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600), block = CGRect(x: 400, y: 0, width: 400, height: 300)
    let zin = ZoomAnimation.zoomIn(from: block, bounds: bounds)
    #expect(zin.transform(progress: 0).scale == CGSize(width: 0.5, height: 0.5) && zin.transform(progress: 0).offset == CGPoint(x: 400, y: 0))
    #expect(abs(zin.transform(progress: 0.5).scale.width - 0.9375) < 1e-9 && abs(zin.transform(progress: 0.5).offset.x - 50) < 1e-9)
    #expect(zin.transform(progress: 1).scale == CGSize(width: 1, height: 1) && zin.transform(progress: 1).offset == .zero)
    let zout = ZoomAnimation.zoomOut(to: block, bounds: bounds)
    #expect(zout.transform(progress: 0).scale == CGSize(width: 2, height: 2) && zout.transform(progress: 0).offset == CGPoint(x: -800, y: 0))
    #expect(ZoomAnimation.eased(0.5) == 0.875 && ZoomAnimation.duration == 0.2)
}

/// Counts which folders the layout reads.
final class CountingSource: TreemapSource {
    let table: [FolderID: [TreemapItem]]
    var reads: [FolderID] = []
    init(_ table: [FolderID: [TreemapItem]]) { self.table = table }
    func items(in folder: FolderID) -> [TreemapItem] { reads.append(folder); return table[folder] ?? [] }
}

@Test func spentCapReadsNoMoreFolders() {
    let src = CountingSource([0: [.init(ref: .folder(1), size: 300), .init(ref: .folder(2), size: 150)],
                              1: files(Array(repeating: 10, count: 30)), 2: files(Array(repeating: 5, count: 30), from: 100)])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                               options: .init(gutter: 0, minSide: 2, headerHeight: 0, cap: 2))
    #expect(l.rects.count == 2)
    #expect(src.reads == [0])
}
