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
    // node_modules inside Pictures is developer data, so media plus developer covers Pictures.
    #expect(t[.media, default: 0] + t[.developer, default: 0] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Pictures")))
    #expect(t[.developer] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Pictures/x/node_modules")))
    #expect(t[.apps] == Fixtures.sumAllocated(under: root.appending(path: "Applications")))
    #expect(t[.other] == Fixtures.allocatedSize(root.appending(path: "Users/u/loose.bin")))
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}

@Test func totalsReachNestedHigherPriorityKinds() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 2_000_000,
                                  "Users/u/Library/Containers/com.apple.Notes/n": 1_500_000])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let t = ContentKind.totals(in: idx)
    let base = "Users/u/Library/Containers/"
    #expect(t[.virtualMachines] == Fixtures.sumAllocated(under: root.appending(path: base + "com.docker.docker")))
    #expect(t[.appData] == Fixtures.sumAllocated(under: root.appending(path: base + "com.apple.Notes")))
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}

@Test func totalsCountNodeModulesUnderDocumentsAsDeveloper() async throws {
    let root = try Fixtures.tree(["Users/u/Documents/app/node_modules/m": 1_200_000])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let t = ContentKind.totals(in: idx)
    #expect(t[.developer] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Documents/app/node_modules")))
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}
