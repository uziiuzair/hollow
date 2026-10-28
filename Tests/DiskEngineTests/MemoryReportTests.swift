import Testing
@testable import DiskEngine

@Test func memoryReportCountsTables() async throws {
    let idx = try await DiskScanner(root: try Fixtures.tree(["a/f": 10, "b/g": 10]), storage: try Fixtures.tempDir()).run().index
    let m = MemoryReport.measure(idx)
    #expect(m.folderTableBytes >= 3 * MemoryLayout<FolderRecord>.stride)
    #expect(m.folderNameBytes > 0)
    #expect(m.processFootprint > 0)
}
