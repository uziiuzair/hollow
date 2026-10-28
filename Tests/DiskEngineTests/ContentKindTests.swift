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

/// The original walk: re-splits every path and reads every big-file record.
private func referenceTotals(in index: ScanIndex) -> [ContentKind: UInt64] {
    var result: [ContentKind: UInt64] = [:]
    var stack: [(id: FolderID, path: String, inherited: ContentKind)] = [(0, "", .other)]
    while let (id, path, inherited) = stack.popLast() {
        let folder = index.folders[Int(id)]
        let kind = ContentKind.classify(path) ?? inherited
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let mayGoDeeper = kind == .other || ContentKind.higherPriorityMayMatchDeeper(than: kind, parts)
        if !mayGoDeeper {
            result[kind, default: 0] += folder.totalAllocated
            continue
        }
        var direct = folder.smallAllocated
        for i in 0..<folder.bigFileCount {
            if let rec = try? index.files.record(folder.firstFile + FileIndex(i)) { direct += rec.allocated }
        }
        if direct > 0 { result[kind, default: 0] += direct }
        var child = folder.firstChildFolder
        while child != noFolder {
            let name = index.folderName(child)
            stack.append((child, path.isEmpty ? name : path + "/" + name, kind))
            child = index.folders[Int(child)].nextSibling
        }
    }
    return result
}

// Final review 4: totals give the same answer without reading any file record.
@Test func totalsMatchReferenceWithoutReadingFileRecords() async throws {
    let root = try Fixtures.tree([
        "Users/u/Pictures/a.jpg": 2_000_000, "Users/u/Pictures/small.txt": 300,
        "Users/u/Pictures/x/node_modules/m.bin": 1_500_000, "Users/u/Pictures/x/y/z/node_modules/n.bin": 1_100_000,
        "Users/u/Documents/proj/deep/er/node_modules/pkg/lib.bin": 1_300_000, "Users/u/Documents/d.bin": 1_200_000,
        "Users/u/loose.bin": 1_200_000, "Users/u/tiny": 50, "big-at-root.bin": 1_050_000,
        "Applications/A.app/bin": 3_000_000, "Users/u/Library/Caches/c.bin": 1_400_000,
        "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 2_000_000,
        "Users/u/Library/Containers/com.apple.Notes/n": 1_500_000,
    ])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let expected = referenceTotals(in: idx)
    let before = idx.files.recordReads
    let t = ContentKind.totals(in: idx)
    #expect(idx.files.recordReads == before)
    #expect(t == expected)
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}
