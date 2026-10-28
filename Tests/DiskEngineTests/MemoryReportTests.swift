import Testing
@testable import DiskEngine

@Test func memoryReportCountsTables() async throws {
    let idx = try await DiskScanner(root: try Fixtures.tree(["a/f": 10, "b/g": 10]), storage: try Fixtures.tempDir()).run().index
    let m = MemoryReport.measure(idx)
    #expect(m.folderTableBytes >= 3 * MemoryLayout<FolderRecord>.stride)
    #expect(m.folderNameBytes > 0)
    #expect(m.processFootprint > 0)
}

@Test func tablesBytesSumsTheFourTables() {
    let m = MemoryReport(folderTableBytes: 1, folderNameBytes: 20, hardLinkBytes: 300, pendingBytes: 4_000, processFootprint: 0)
    #expect(m.tablesBytes == 4_321)
}

/// Folder names used to live in one doubling [UInt8]. Each doubling copied the names
/// and freed the old buffer, which malloc kept dirty (19-30 MB on a 1.8M-folder
/// disk), and left up to half the final buffer unused. Names now grow in fixed
/// 64 KiB chunks, so the unused tail is under one chunk.
@Test func scanReleasesNameGrowth() async throws {
    // 2,000 folders of 5 files. Each name is 130 bytes, so each entry is 132 bytes and
    // the pool holds 2,001 entries, about 264 KB: just past 256 KiB, where a doubling
    // buffer would have ~512 KiB of capacity.
    var spec: [String: Int] = [:]
    for i in 0..<2_000 {
        let name = String(format: "%04d", i) + String(repeating: "n", count: 126)
        for f in 0..<5 { spec["\(name)/f\(f)"] = 1 }
    }
    let idx = try await DiskScanner(root: try Fixtures.tree(spec), storage: try Fixtures.tempDir()).run().index
    #expect(idx.folders.count == 2_001)
    let used = idx.folderNames.byteCount
    #expect(used >= 2_000 * 132)
    // Bound: what 2,001 names use, plus less than one 64 KiB chunk of slack.
    #expect(MemoryReport.measure(idx).folderNameBytes < used + 65_536)
    // Names that straddle a chunk boundary still read back whole.
    for id in 1..<idx.folders.count {
        #expect(idx.folderName(FolderID(id)).count == 130)
    }
}
