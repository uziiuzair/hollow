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
    #expect(loaded.name(at: b) == "across")
}
