import Testing
@testable import DiskEngine

private let GB: UInt64 = 1_000_000_000

@Test func deepestExplainingItemIsReported() {
    let old = SizeSnapshot(sizes: ["": 500 * GB, "Library": 300 * GB, "Library/Docker": 84 * GB, "Library/Docker/Docker.raw": 84 * GB,
                                   "Developer": 40 * GB, "Developer/DerivedData": 10 * GB])
    let new = SizeSnapshot(sizes: ["": 514 * GB, "Library": 308 * GB, "Library/Docker": 92 * GB, "Library/Docker/Docker.raw": 92 * GB,
                                   "Developer": 46 * GB, "Developer/DerivedData": 16 * GB])
    #expect(ChangeReport.changes(from: old, to: new) == [
        Change(path: "Library/Docker/Docker.raw", delta: 8_000_000_000),
        Change(path: "Developer/DerivedData", delta: 6_000_000_000),
    ])
}

@Test func spreadOutGrowthReportsTheFolder() {
    let old = SizeSnapshot(sizes: ["": 100 * GB, "Downloads": 10 * GB, "Downloads/a": 200_000_000])
    let new = SizeSnapshot(sizes: ["": 103 * GB, "Downloads": 13 * GB, "Downloads/a": 300_000_000])
    #expect(ChangeReport.changes(from: old, to: new).first == Change(path: "Downloads", delta: 3_000_000_000))
}

@Test func freedSpaceIsNegative() {
    let old = SizeSnapshot(sizes: ["": 100 * GB, "Trash": 2 * GB])
    let new = SizeSnapshot(sizes: ["": 98 * GB])
    // Gone from the new snapshot means "below 100 MB", so the reported drop is conservative.
    #expect(ChangeReport.changes(from: old, to: new) == [Change(path: "Trash", delta: -1_900_000_001)])
}

@Test func noChangeNoReport() {
    let s = SizeSnapshot(sizes: ["": 100 * GB, "a": 10 * GB])
    #expect(ChangeReport.changes(from: s, to: s).isEmpty)
}
