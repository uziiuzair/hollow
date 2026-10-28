import Testing
@testable import DiskEngine

@Test func fileTableRoundTripsAfterFlush() throws {
    let dir = try Fixtures.tempDir()
    let t = try FileTable(directory: dir)
    var r = FileRecord(allocated: 5_000_000, parent: 7, nameOffset: 0, logicalKiB: 4_800, flags: [.mayShareBlocks], kind: 1)
    let i = try t.append(name: "Docker.raw", record: r)
    r.allocated = 2_000_000
    let j = try t.append(name: "big.mov", record: r)
    #expect(t.count == 2)
    #expect(try t.record(i).allocated == 5_000_000)
    #expect(try t.record(i).flags == [.mayShareBlocks])
    #expect(try t.record(i).parent == 7)
    #expect(try t.name(i) == "Docker.raw")
    #expect(try t.name(j) == "big.mov")
}

@Test func readsSeeAppendsMadeAfterAnEarlierRead() throws {
    let t = try FileTable(directory: try Fixtures.tempDir())
    _ = try t.append(name: "a", record: .init(allocated: 1, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    _ = try t.record(0)
    let k = try t.append(name: "b", record: .init(allocated: 2, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    #expect(try t.record(k).allocated == 2)
    #expect(try t.name(k) == "b")
}

@Test func manyAppendsCrossTheWriteBuffer() throws {
    let t = try FileTable(directory: try Fixtures.tempDir())
    for n in 0..<100_000 {
        _ = try t.append(name: "file-\(n)", record: .init(allocated: UInt64(n), parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    }
    #expect(try t.record(99_999).allocated == 99_999)
    #expect(try t.name(54_321) == "file-54321")
}
