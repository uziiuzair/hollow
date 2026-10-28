import CoreGraphics
import Foundation
import Metal
import Testing
import DiskEngine
@testable import DiskApp

private func rect(_ ref: TreemapRef, _ size: UInt64, depth: Int, parent: Int) -> TreemapRect {
    TreemapRect(ref: ref, size: size, frame: CGRect(x: 0, y: 0, width: 100, height: 100), depth: depth, parent: parent, firstChild: 0, childCount: 0, hasHeader: false)
}

private func snap(_ rects: [TreemapRect], _ nodes: [MapNode], top: Int) -> MapSnapshot {
    MapSnapshot(path: "", rootPath: "/", crumbs: [], total: 0, period: 1,
                layout: TreemapLayout(rects: rects, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), topLevelCount: top), nodes: nodes, list: [])
}

@Test func instanceLayoutMatchesTheShader() { #expect(MemoryLayout<BlockInstance>.stride == 48) }

@Test func paletteHexMatchesTheSpec() {
    #expect(Palette.hex(.virtualMachines) == 0x2E9FC4)
    #expect(Palette.hex(.apps) == 0x4C7CE0)
    #expect(Palette.hex(.other) == 0x8E8E93)
}

@Test func colorsShadeByDepthAndBucketsAreGrey() {
    let s = snap([rect(.folder(1), 92_000_000_000, depth: 1, parent: -1), rect(.small(parent: 0, files: 3_912, folders: 0), 6_000_000_000, depth: 1, parent: -1),
                  rect(.file(0), 50_000_000_000, depth: 3, parent: 0)],
                 [MapNode(key: "d", name: "Docker", kind: .virtualMachines, growth: 8_100_000_000, isFolder: true),
                  MapNode(key: "#small", name: "3,912 small files", kind: nil, growth: 0, isFolder: false),
                  MapNode(key: "d/x/f", name: "f", kind: .virtualMachines, growth: 0, isFolder: false)], top: 2)
    let i = TreemapScene.instances(snapshot: s, dark: true)
    #expect(i[0].color == SIMD4<Float>(0x2E, 0x9F, 0xC4, 255) / 255 && i[0].flags & 1 == 1)
    #expect(i[1].color == SIMD4<Float>(1, 1, 1, 0.22) && i[1].flags & 2 == 2)
    #expect(abs(i[2].color.x - Float(0x2E) / 255 * 0.8) < 1e-6 && i[2].color.w == 1 && i[2].topLevel == 0)
    #expect(TreemapScene.instances(snapshot: s, dark: false)[1].color == SIMD4<Float>(0, 0, 0, 0.22))
    #expect(abs(i[0].stripe - 0.08804) < 0.0001 && i[2].stripe == 0)
}

@Test func instanceRectIsTheFrameInPoints() {
    var r = rect(.folder(1), 10, depth: 1, parent: -1)
    r.frame = CGRect(x: 3, y: 4, width: 50, height: 60)
    let s = snap([r], [MapNode(key: "a", name: "a", kind: .apps, growth: 0, isFolder: true)], top: 1)
    #expect(TreemapScene.instances(snapshot: s, dark: true)[0].rect == SIMD4<Float>(3, 4, 50, 60))
}

@Test func stripeRules() {
    #expect(TreemapScene.stripe(growth: 50_000_000, size: 1_000_000_000) == 0)
    #expect(TreemapScene.stripe(growth: -2_000_000_000, size: 9_000_000_000) == 0)
    #expect(TreemapScene.stripe(growth: 3_000_000_000, size: 2_000_000_000) == 1)
}

@Test func hoverDimsOthersAndOutlinesOne() {
    let top = BlockInstance(rect: .zero, color: .zero, stripe: 0, topLevel: 1, flags: 1)
    let child = BlockInstance(rect: .zero, color: .zero, stripe: 0, topLevel: 1, flags: 0)
    #expect(TreemapScene.appearance(top, hoveredTop: 1, outlinedTop: 1) == .init(dimmed: false, outline: 2))
    #expect(TreemapScene.appearance(top, hoveredTop: 0, outlinedTop: 0) == .init(dimmed: true, outline: 0))
    #expect(TreemapScene.appearance(top, hoveredTop: -1, outlinedTop: 1) == .init(dimmed: false, outline: 2))
    #expect(TreemapScene.appearance(child, hoveredTop: 1, outlinedTop: 1) == .init(dimmed: false, outline: 0))
}

@Test func shaderCompiles() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let lib = try device.makeLibrary(source: TreemapScene.shaderSource, options: nil)
    #expect(["blockVertex", "blockFragment", "labelVertex", "labelFragment"].allSatisfy { lib.makeFunction(name: $0) != nil })
}

@Test func uniformsLayoutMatchesTheShader() { #expect(MemoryLayout<TreemapUniforms>.stride == 40) }
