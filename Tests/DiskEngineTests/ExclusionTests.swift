import Foundation
import Testing
@testable import DiskEngine

@Test func scanSkipsExcludedFolders() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), exclusions: ["a/skip"])
    _ = try await live.open()
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root.appending(path: "a/keep")))
    try await live.close()
}

@Test func changingExclusionsRelistsWithoutAFullScan() async throws {
    let root = try Fixtures.tree(["a/keep/deep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    let deep = try await live.read { $0.folder(atRelativePath: "a/keep/deep") }
    try await live.setExclusions(["a/skip"])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root.appending(path: "a/keep")))
    try await live.setExclusions([])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } != nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    #expect(try await live.read { $0.folder(atRelativePath: "a/keep/deep") } == deep)
    try await live.close()
}

@Test func exclusionsReconcileOnReopen() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000]); let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store, exclusions: ["a/skip"])
    _ = try await first.open(); try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .snapshot)
    #expect(try await second.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await second.close()
}

@Test func eventsInsideExcludedFoldersAreIgnored() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 10, "a/skip/g.bin": 10])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), exclusions: ["a/skip"])
    _ = try await live.open()
    try Fixtures.write(root.appending(path: "a/skip/new.bin"), bytes: 2_000_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a/skip", id: next, rescanSubtree: false, historyLost: false)])
    #expect(await live.relistCount == 0)
    try await live.close()
}

@Test func exclusionChangeSurvivesACrashBeforeTheSnapshotSave() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000]); let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store)
    _ = try await first.open()
    try await first.setExclusions(["a/skip"])
    // No save() or close(): the app died here.
    let second = LiveIndex(volumeRoot: root, store: store, exclusions: ["a/skip"])
    #expect(try await second.open() == .snapshot)
    #expect(try await second.read { $0.folder(atRelativePath: "a/skip") } == nil)
    #expect(try await second.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root.appending(path: "a/keep")))
    try await second.close()
    try await first.close()
}

@Test func exclusionPathsAreNormalized() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000])
    for spelling in ["a/skip/", "/a/skip", "a//skip"] {
        let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), exclusions: [spelling, ""])
        _ = try await live.open()
        #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
        #expect(try await live.read { $0.folder(atRelativePath: "a/keep") } != nil)
        try await live.close()
    }
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    try await live.setExclusions(["/a//skip/", ""])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
    try await live.setExclusions([""])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } != nil)
    try await live.close()
}
