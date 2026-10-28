import CoreGraphics
import Foundation
import Testing
@testable import DiskApp
@testable import DiskEngine

/// Stands in for a DriveController: builds from a fixed index while ready, nil otherwise (cold).
@MainActor final class FakeMapSource: MapSource {
    var activity: DriveActivity = .ready; var period = 7; var holds = 0; var builds = 0; var delay: Duration = .zero
    let index: ScanIndex
    init(_ spec: [String: Int]) async throws { index = try await Fixtures.index(spec) }
    func hold() async { holds += 1 }
    func release() { holds -= 1 }
    func buildMap(_ r: MapRequest) async -> MapSnapshot? {
        builds += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return activity == .ready ? MapBuilder.build(index: index, request: r, baseline: nil) : nil
    }
}

@MainActor private func model(_ src: FakeMapSource, throttle: Duration = .seconds(1)) -> MapModel {
    let m = MapModel(source: src, driveName: "Test", reduceMotion: false, throttle: throttle)
    m.setSize(CGSize(width: 800, height: 600)); return m
}

@MainActor @Test func openHoldsAndCloseReleases() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: nil); await m.settle()
    #expect(src.holds == 1 && m.status == .ready && m.snapshot?.layout.topLevelCount == 2)
    m.close()
    #expect(src.holds == 0 && m.snapshot == nil)
}

@MainActor @Test func rapidRequestsCoalesceLatestWins() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src); src.delay = .milliseconds(50)
    await m.open(path: "", select: nil)
    for w in 600...619 { m.setSize(CGSize(width: w, height: 400)) }
    await m.settle()
    #expect(src.builds <= 3)
    #expect(m.snapshot?.layout.bounds.width == 619)
}

@MainActor @Test func zoomInOutAndBack() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "c/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: nil); await m.settle()
    let a = try #require(m.snapshot?.nodes.firstIndex { $0.key == "a" }); let frame = m.snapshot!.layout.rects[a].frame
    m.zoomIn(a); await m.settle()
    #expect(m.zoomPath == "a" && m.animation == .zoomIn(from: frame, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
    m.zoomOut(); await m.settle()
    #expect(m.zoomPath == "" && m.snapshot?.nodes[m.selected!].key == "a")
    let c = try #require(m.snapshot?.nodes.firstIndex { $0.key == "c" })
    m.reduceMotion = true; m.zoomIn(c); await m.settle()
    #expect(m.zoomPath == "c" && m.animation == nil)
}

@MainActor @Test func openAtFocusSelectsItem() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/b/g.bin": 1_500_000]); let m = model(src)
    await m.open(path: "a/b", select: "a/b/f.bin"); await m.settle()
    #expect(m.snapshot?.nodes[m.selected!].key == "a/b/f.bin")
}

// C19: a focus that is not a depth-1 rect at the opened level selects nothing, without error.
@MainActor @Test func openAtUnreachableFocusSelectsNothing() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "c/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: "a/b/f.bin"); await m.settle()
    #expect(m.status == .ready && m.selected == nil)
}

@MainActor @Test func selectionFollowsKeyAcrossRebuilds() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: "b"); await m.settle()
    m.setSize(CGSize(width: 300, height: 900)); await m.settle()
    #expect(m.snapshot?.nodes[m.selected!].key == "b")
}

@MainActor @Test func sourceChangesThrottle() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(300))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    for _ in 0..<10 { m.sourceChanged() }
    try await Task.sleep(for: .milliseconds(400)); await m.settle()
    #expect(src.builds == before + 2)
}

@MainActor @Test func offlineSourceShowsDisconnected() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle()
    src.activity = .offline; m.sourceChanged(); await m.settle()
    #expect(m.status == .offline && m.snapshot == nil)
    #expect(m.statusMessage == "Test was disconnected. Its map comes back when you plug it in.")
}

// C7: a drive still on its first scan says so instead of "Loading".
@MainActor @Test func scanningShowsMessage() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    src.activity = .scanning
    await m.open(path: "", select: nil); await m.settle()
    #expect(m.status == .scanning && m.snapshot == nil)
    #expect(m.statusMessage == "Scanning this drive for the first time. The map appears when the scan finishes.")
    src.activity = .ready; m.sourceChanged(); await m.settle()
    #expect(m.status == .ready && m.statusMessage == nil)
}

@MainActor @Test func emptyLevelShowsMessage() async throws {
    let src = try await FakeMapSource(["e/z": 0, "a/f.bin": 2_000_000]); let m = model(src)
    await m.open(path: "e", select: nil); await m.settle()
    #expect(m.status == .empty && m.statusMessage == "Nothing here takes up space.")
}

@MainActor @Test func hoverSurvivesALiveRebuildWhileItsItemExists() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle()
    let b = try #require(m.snapshot?.nodes.firstIndex { $0.key == "b" })
    m.hovered = b
    m.sourceChanged(); await m.settle()
    #expect(m.hovered.map { m.snapshot!.nodes[$0].key } == "b")
    // Hovering something that is gone after the rebuild clears the hover.
    let gone = MapSnapshot(path: "", rootPath: "/", crumbs: [], total: 0, period: 7,
                           layout: TreemapLayout(rects: [], bounds: .zero, topLevelCount: 0), nodes: [], list: [])
    #expect(MapModel.rehover(key: "b", in: gone) == nil)
    #expect(MapModel.rehover(key: nil, in: m.snapshot!) == nil)
}
