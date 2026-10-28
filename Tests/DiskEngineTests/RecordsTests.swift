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
