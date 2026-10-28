import Testing
@testable import DiskEngine

@Test func recordSizesStayCompact() {
    #expect(MemoryLayout<FolderRecord>.stride == 48)
    #expect(MemoryLayout<FileRecord>.stride == 24)
}

@Test func namePoolRoundTripsUnicodeAndEmpty() {
    var pool = NamePool()
    let a = pool.append("Photos Library.photoslibrary")
    let b = pool.append("Ünïcødé 写真 🗂")
    let c = pool.append("")
    #expect(pool.name(at: a) == "Photos Library.photoslibrary")
    #expect(pool.name(at: b) == "Ünïcødé 写真 🗂")
    #expect(pool.name(at: c) == "")
}

@Test func namePoolEntriesStraddleChunks() {
    var pool = NamePool()
    // Fill to one byte short of a chunk, so the next length prefix straddles it.
    let filler = String(repeating: "x", count: NamePool.chunkSize - 3)
    let a = pool.append(filler)
    let b = pool.append("across")
    #expect(pool.name(at: a) == filler)
    #expect(pool.name(at: b) == "across")
    // An empty name whose prefix ends exactly at a chunk boundary.
    var edge = NamePool()
    _ = edge.append(String(repeating: "y", count: NamePool.chunkSize - 4))
    let empty = edge.append("")
    #expect(edge.byteCount == NamePool.chunkSize)
    #expect(edge.name(at: empty) == "")
    // Rebuilt from its bytes (as a snapshot load does), the pool reads the same.
    var joined: [UInt8] = []
    pool.forEachChunk { joined += $0 }
    let loaded = NamePool(bytes: joined)
    #expect(loaded.byteCount == pool.byteCount)
    #expect(loaded.name(at: a) == filler)
    #expect(loaded.name(at: b) == "across")
}

@Test func namePoolClampsNamesToOneChunk() {
    var pool = NamePool()
    // The next entry starts at chunkSize - 3, so its body starts at the chunk's last byte.
    _ = pool.append(String(repeating: "x", count: NamePool.chunkSize - 5))
    #expect(pool.byteCount == NamePool.chunkSize - 3)
    let long = pool.append(String(repeating: "z", count: NamePool.chunkSize + 500))
    // Stored truncated to what fits in one chunk with its prefix, so it spans at most two.
    #expect(pool.name(at: long) == String(repeating: "z", count: NamePool.chunkSize - 2))
}

// Task 10d: a folder lookup reads names' bytes in place rather than building a String for every sibling.
@Test func namePoolComparesBytesInPlace() {
    var pool = NamePool()
    // "across" straddles a chunk boundary.
    let filler = String(repeating: "x", count: NamePool.chunkSize - 5)
    let a = pool.append(filler)
    let across = pool.append("across")
    let empty = pool.append("")
    #expect(pool.hasBytes(at: a, Array(filler.utf8)))
    #expect(pool.hasBytes(at: across, Array("across".utf8)))
    #expect(!pool.hasBytes(at: across, Array("acros".utf8)))
    #expect(!pool.hasBytes(at: across, Array("acrosz".utf8)))
    #expect(!pool.hasBytes(at: across, Array("acrosss".utf8)))
    #expect(pool.hasBytes(at: empty, []))
}

@Test func folderLookupsMatchASCIIBytesAndNonASCIIAsStrings() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    _ = try idx.integrate(DirectoryListing(folder: 0, outcome: .ok, entries: [.dir("d1"), .dir("caf\u{E9}"), .dir("tmp")]),
                          rootDevice: 1)
    #expect(idx.folder(atRelativePath: "tmp").map(idx.folderName) == "tmp")
    #expect(idx.folder(atRelativePath: "tm") == nil)
    // The decomposed spelling finds the composed name, as before.
    #expect(idx.folder(atRelativePath: "cafe\u{301}").map(idx.folderName) == "caf\u{E9}")
    #expect(idx.deepestFolder(onRelativePath: "tmp/new/deeper").folder == idx.folder(atRelativePath: "tmp"))
    #expect(idx.deepestFolder(onRelativePath: "tmp/new/deeper").whole == false)
    #expect(idx.deepestFolder(onRelativePath: "tmp") == (idx.folder(atRelativePath: "tmp")!, true))
    #expect(idx.deepestFolder(onRelativePath: "gone/x").folder == 0)
}

// A folder with many subfolders is looked up by name through a table that follows every change to its children.
@Test func lookupsInABigFolderFollowItsRelists() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    let names = (0..<3000).map { "d\($0)" }
    _ = try idx.integrate(DirectoryListing(folder: 0, outcome: .ok, entries: names.map { .dir($0) }), rootDevice: 1)
    #expect(idx.folder(atRelativePath: "nope") == nil)
    #expect(idx.childLookupTables == 1)
    // A hit far down the siblings tables them too.
    idx.resetContents(of: 0)
    _ = try idx.integrate(DirectoryListing(folder: 0, outcome: .ok, entries: names.map { .dir($0) }), rootDevice: 1)
    #expect(idx.childLookupTables == 0)
    let kept = try #require(idx.folder(atRelativePath: "d2999"))
    #expect(idx.folderName(kept) == "d2999")
    #expect(idx.childLookupTables == 1)
    // d0 goes, "new" comes: both lookups see it at once.
    let after = names.dropFirst() + ["new"]
    _ = try idx.relist(DirectoryListing(folder: 0, outcome: .ok, entries: after.map { .dir($0) }))
    #expect(idx.folder(atRelativePath: "d0") == nil)
    #expect(idx.folder(atRelativePath: "new").map(idx.folderName) == "new")
    #expect(idx.folder(atRelativePath: "d2999") == kept)
    #expect(idx.deepestFolder(onRelativePath: "d0/x").folder == 0)
    idx.resetContents(of: 0)
    #expect(idx.folder(atRelativePath: "new") == nil)
    #expect(idx.childLookupTables == 0)
}

/// A root with `count` subfolders `<prefix>0`… under folder 0, or under `parent` once listed.
private func bigFolder(_ idx: ScanIndex, _ prefix: String, _ count: Int, under parent: FolderID = 0) throws {
    let entries = (0..<count).map { RawEntry.dir("\(prefix)\($0)") }
    _ = try idx.integrate(DirectoryListing(folder: parent, outcome: .ok, entries: entries), rootDevice: 1)
}

// Fix round 1 (I1): a folder over the table cap is counted once, not rebuilt on every lookup, until its children change.
@Test func aFolderTooBigToTableIsCountedOnce() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    idx.tableAbove = 10
    idx.tableLimit = 100
    try bigFolder(idx, "d", 300)
    #expect(idx.folder(atRelativePath: "nope") == nil)
    #expect(idx.folder(atRelativePath: "d299") != nil)
    #expect(idx.folder(atRelativePath: "nope") == nil)
    #expect(idx.childTablePasses == 1)
    #expect(idx.childLookupTables == 0)
    // Its children change: it is counted again.
    _ = try idx.relist(DirectoryListing(folder: 0, outcome: .ok, entries: (0..<5).map { .dir("d\($0)") }))
    _ = try idx.relist(DirectoryListing(folder: 0, outcome: .ok, entries: (0..<300).map { .dir("d\($0)") }))
    #expect(idx.folder(atRelativePath: "nope") == nil)
    #expect(idx.childTablePasses == 2)
}

// Fix round 1 (I1): past the cap, the oldest table goes, not all of them.
@Test func aNewTableEvictsOnlyTheOldest() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    idx.tableAbove = 10
    idx.tableLimit = 100
    try bigFolder(idx, "f", 3)
    for (i, name) in ["f0", "f1", "f2"].enumerated() {
        try bigFolder(idx, "\(name)-", 40, under: try #require(idx.folder(atRelativePath: name)))
        #expect(idx.folder(atRelativePath: "\(name)/missing") == nil)
        #expect(idx.childLookupTables == min(i + 1, 2))
    }
    // f0's table went; f1's and f2's are still there, so lookups in them build nothing.
    let passes = idx.childTablePasses
    #expect(idx.folder(atRelativePath: "f1/f1-39") != nil && idx.folder(atRelativePath: "f2/f2-39") != nil)
    #expect(idx.childTablePasses == passes)
}

// Fix round 1 (M3): an ASCII name is matched on bytes, a non-ASCII one as a String, whether or not the folder is tabled.
@Test func lookupsMeanTheSameTabledOrNot() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    idx.rootDevice = 1
    idx.tableAbove = 10
    var entries = (0..<50).map { RawEntry.dir("d\($0)") }
    entries += [.dir("\u{212A}"), .dir("caf\u{E9}")]
    _ = try idx.integrate(DirectoryListing(folder: 0, outcome: .ok, entries: entries), rootDevice: 1)
    func probe() -> [FolderID?] {
        ["K", "\u{212A}", "cafe\u{301}", "caf\u{E9}", "d49"].map { idx.folder(atRelativePath: $0) }
    }
    let before = probe()
    #expect(idx.childLookupTables == 1)
    #expect(probe() == before)
    #expect(before[0] == nil && before[1] != nil && before[2] == before[3] && before[3] != nil && before[4] != nil)
}
