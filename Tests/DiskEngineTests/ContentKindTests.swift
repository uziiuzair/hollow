import Testing
@testable import DiskEngine

@Test func rulesInOrder() {
    #expect(ContentKind.classify("Users/u/Library/Developer") == .developer)
    #expect(ContentKind.classify("Users/u/Documents/app/node_modules") == .developer)
    #expect(ContentKind.classify("Users/u/Library/Containers/com.docker.docker") == .virtualMachines)
    #expect(ContentKind.classify("Users/u/Library/Containers/com.apple.Notes") == .appData)
    #expect(ContentKind.classify("Users/u/library/caches") == .caches)
    #expect(ContentKind.classify("Users/u/Pictures") == .media)
    #expect(ContentKind.classify("Users/u/Downloads") == .documents)
    #expect(ContentKind.classify("Applications") == .apps)
    #expect(ContentKind.classify("Users/u") == nil)
    #expect(ContentKind.classify("") == nil)
}

@Test func totalsStopAtFirstMatchAndCollectOther() async throws {
    let root = try Fixtures.tree(["Users/u/Pictures/a.jpg": 2_000_000, "Users/u/Pictures/x/node_modules/m": 1_500_000,
                                  "Users/u/loose.bin": 1_200_000, "Applications/A.app/bin": 3_000_000])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let t = ContentKind.totals(in: idx)
    #expect(t[.media] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Pictures")))
    #expect(t[.apps] == Fixtures.sumAllocated(under: root.appending(path: "Applications")))
    #expect(t[.other] == Fixtures.allocatedSize(root.appending(path: "Users/u/loose.bin")))
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}
