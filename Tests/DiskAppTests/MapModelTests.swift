// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
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

// Ejecting keeps the window: the model lets go of the drive and says it was disconnected.
@MainActor @Test func driveDisconnectedReleasesAndShowsOffline() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle()
    src.activity = .offline
    m.driveDisconnected()
    #expect(src.holds == 0 && m.status == .offline && m.snapshot == nil)
    #expect(m.statusMessage == "Test was disconnected. Its map comes back when you plug it in.")
    // Later changes build nothing, and closing the window does not release twice.
    let builds = src.builds
    m.sourceChanged(); m.setSize(CGSize(width: 500, height: 500)); await m.settle()
    m.close()
    #expect(src.builds == builds && src.holds == 0 && m.status == .offline)
}

// Reopening over a visible map keeps it ready instead of flashing "Loading".
@MainActor @Test func reopenOverAVisibleMapKeepsReady() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: nil); await m.settle()
    await m.open(path: "", select: "b")
    #expect(m.status == .ready)
    await m.settle()
    #expect(m.status == .ready && m.snapshot?.nodes[m.selected!].key == "b")
}

// An unchanged rebuild (a live update that moved nothing) publishes no new snapshot.
@MainActor @Test func unchangedRebuildDoesNotPublish() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle()
    var published = 0
    let sub = m.$snapshot.dropFirst().sink { _ in published += 1 }
    m.sourceChanged(); await m.settle()
    #expect(src.builds >= 2 && published == 0)
    // A real change still publishes.
    m.setSize(CGSize(width: 700, height: 600)); await m.settle()
    #expect(published == 1)
    sub.cancel()
}

@MainActor @Test func reattachAfterRefusedEjectShowsTheMapAgain() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/c.bin": 1_200_000]); let m = model(src)
    await m.open(path: "a", select: "a/b"); await m.settle()
    m.driveDisconnected()
    #expect(m.status == .offline && src.holds == 0)
    let fresh = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/c.bin": 1_200_000])
    await m.reattach(to: fresh); await m.settle()
    #expect(m.status == .ready && fresh.holds == 1 && m.zoomPath == "a" && m.snapshot?.nodes[m.selected!].key == "a/b")
    await m.reattach(to: src)
    #expect(src.holds == 0 && fresh.holds == 1)
}

@MainActor @Test func reattachDoesNothingUnlessDisconnected() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src)
    let other = try await FakeMapSource(["a/f.bin": 2_000_000])
    // Never opened, then open and ready, then closed by the window: none of these is a disconnect.
    await m.reattach(to: other)
    await m.open(path: "", select: nil); await m.settle()
    await m.reattach(to: other)
    m.close()
    await m.reattach(to: other)
    #expect(other.holds == 0 && other.builds == 0)
}

@Test func changesOutsideTheZoomedFolderAreInvisible() {
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["b": 5_000_000]), zoomPath: "a") == 0)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["a/x": -3_000_000, "ab": 9, "b": 9]), zoomPath: "a") == 3_000_000)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["": 1]), zoomPath: "a") == nil)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["b": 7]), zoomPath: "") == 7)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: nil), zoomPath: "a") == nil)
    #expect(MapModel.visibleDelta(nil, zoomPath: "") == nil)
}

// C16: two updates merged before the map reads them still count the change inside the zoomed folder.
@Test func mergedChangesKeepTheZoomedFolderDelta() {
    let merged = IndexChange(generation: 2, folders: ["b": 9_000_000]).merged(with: IndexChange(generation: 3, folders: ["a/x": 40_000]))
    #expect(MapModel.visibleDelta(merged, zoomPath: "a") == 40_000)
    #expect(MapModel.visibleDelta(merged, zoomPath: "a/x/y") == nil)
}

@MainActor @Test func tinyChangesWaitUntilTheyShow() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 10, height: 10))
    await m.open(path: "a", select: nil); await m.settle(); let before = src.builds
    m.sourceChanged(IndexChange(generation: 2, folders: ["a": 1_000])); await m.settle()
    #expect(src.builds == before)
    m.sourceChanged(IndexChange(generation: 3, folders: ["a": 30_000])); await m.settle()
    #expect(src.builds == before + 1)
    m.sourceChanged(IndexChange(generation: 4, folders: ["zzz": 9_000_000])); await m.settle()
    #expect(src.builds == before + 1)
}

@MainActor @Test func hiddenWindowBuildsOnceWhenShown() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    m.isVisible = false
    for _ in 0..<3 { m.sourceChanged() }; await m.settle()
    #expect(src.builds == before)
    m.isVisible = true; await m.settle()
    #expect(src.builds == before + 1)
    // Shown again with nothing new: no build.
    m.isVisible = false; m.isVisible = true; await m.settle()
    #expect(src.builds == before + 1)
}

// C22: a reattach builds at once, and what was pending before the disconnect (a tiny sum, a hidden window's dirty
// flag) is dropped rather than carried onto the new controller.
@MainActor @Test func reattachBuildsEvenWithPendingTinyChanges() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 10, height: 10))
    await m.open(path: "a", select: nil); await m.settle()
    m.sourceChanged(IndexChange(generation: 2, folders: ["a": 15_000])); await m.settle()
    m.isVisible = false; m.sourceChanged(); await m.settle()
    m.driveDisconnected()
    m.isVisible = true
    let fresh = try await FakeMapSource(["a/f.bin": 2_000_000])
    await m.reattach(to: fresh); await m.settle()
    #expect(fresh.builds == 1 && m.status == .ready)
    m.sourceChanged(IndexChange(generation: 3, folders: ["a": 10_000])); await m.settle()
    #expect(fresh.builds == 1)
}

// Fix round 1: what moved, not the net, decides; a block renamed at the zoom level or one below always shows.
@Test func movesAndRenamesUnderTheZoomAreVisible() {
    let move = IndexChange(generation: 2, folders: ["a": 0], moved: ["a": 4_000_000], renamed: ["a", "a/d"])
    #expect(MapModel.visibleDelta(move, zoomPath: "a") == nil)
    #expect(MapModel.visibleDelta(move, zoomPath: "") == nil)
    let deep = IndexChange(generation: 2, folders: ["a/b/c": 0], moved: ["a/b/c": 6], renamed: ["a/b/c"])
    #expect(MapModel.visibleDelta(deep, zoomPath: "a") == 6)
    #expect(MapModel.visibleDelta(deep, zoomPath: "a/b") == nil)
    let quiet = IndexChange(generation: 2, folders: ["a/x": 0], moved: ["a/x": 3_000])
    #expect(MapModel.visibleDelta(quiet, zoomPath: "a") == 3_000)
}

@MainActor @Test func aMoveIntoAChildOfTheZoomBuilds() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 10, height: 10))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    // Deeper than one level below the zoom, so only the moved bytes (2 × 1 MB) can make it show.
    m.sourceChanged(IndexChange(generation: 2, folders: ["a/x": 0], moved: ["a/x": 2_000_000], renamed: ["a/x", "a/x/d"]))
    await m.settle()
    #expect(src.builds == before + 1)
}

@MainActor @Test func aCrossGenerationMoveStillBuilds() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 10, height: 10))
    await m.open(path: "a", select: nil); await m.settle(); let before = src.builds
    let out = IndexChange(generation: 2, folders: ["a/x/y": 400_000], moved: ["a/x/y": 400_000])
    let back = IndexChange(generation: 3, folders: ["a/x": -400_000], moved: ["a/x": 400_000])
    m.sourceChanged(out.merged(with: back)); await m.settle()
    #expect(src.builds == before + 1)
}

@MainActor @Test func aSameSizeRenameDirectlyUnderTheZoomBuilds() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    m.sourceChanged(IndexChange(generation: 2, folders: ["a": 0], moved: ["a": 0], renamed: ["a"])); await m.settle()
    #expect(src.builds == before + 1)
}

@MainActor @Test func hidingDropsAScheduledBuildUntilShown() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(300))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    m.sourceChanged()   // builds at once
    m.sourceChanged()   // scheduled for the end of the throttle window
    m.isVisible = false
    try await Task.sleep(for: .milliseconds(400)); await m.settle()
    #expect(src.builds == before + 1)
    m.isVisible = true; await m.settle()
    #expect(src.builds == before + 2)
}
