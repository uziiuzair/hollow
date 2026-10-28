import Darwin
import Foundation
import Testing
@testable import DiskEngine

// Important #1: a symlinked root must be resolved, and a non-directory root must fail loudly.
@Test func symlinkedRootIsResolved() async throws {
    let real = try Fixtures.tree(["a/big.bin": 2_000_000])
    let link = try Fixtures.tempDir().appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let r = try await DiskScanner(root: link, storage: try Fixtures.tempDir()).run()
    #expect(r.index.folders[0].totalAllocated == Fixtures.sumAllocated(under: real))
}

@Test func fileRootThrows() async throws {
    let root = try Fixtures.tree(["f.bin": 10])
    await #expect(throws: DiskEngineError.self) {
        _ = try await DiskScanner(root: root.appending(path: "f.bin"), storage: try Fixtures.tempDir()).run()
    }
}

// Important #2: a per-entry error is surfaced, not silently dropped.
@Test func entryWithErrorIsParsedAndReported() {
    // length, returned attribute_set_t, ATTR_CMN_ERROR, ATTR_CMN_NAME reference, name bytes
    var bytes: [UInt8] = []
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
    put(UInt32(0))
    put(attribute_set_t(commonattr: UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_NAME),
                        volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0))
    put(UInt32(EIO))
    put(attrreference_t(attr_dataoffset: 8, attr_length: 4))
    bytes.append(contentsOf: Array("bad".utf8) + [0])
    bytes.withUnsafeMutableBytes { $0.storeBytes(of: UInt32($0.count), as: UInt32.self) }
    let parsed = bytes.withUnsafeBytes { BulkDirectoryReader.parse($0) }
    #expect(parsed.error == UInt32(EIO))
    #expect(parsed.entry.name == "bad")
}

@Test func partialListingFlagsFolder() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [.file("x", allocated: 10)], partial: true), rootDevice: 1)
    #expect(idx.folders[0].flags.contains(.partial))
    #expect(idx.folders[0].totalAllocated == 10)
}

// Important #3: directory hard links (HFS+ Time Machine) are walked once.
@Test func directoryHardLinkWalkedOnce() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    var first = RawEntry.dir("Backup 1")
    first.inode = 77
    first.linkCount = 2
    var second = first
    second.name = "Backup 2"
    let toScan = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [first, second]), rootDevice: 1)
    #expect(toScan.count == 1)
}

// Important #4: folder table grows in fixed pages, never by copying the whole table.
@Test func pagedArrayAcrossPages() {
    var a = PagedArray<UInt64>()
    for n in 0..<200_000 { a.append(UInt64(n)) }
    #expect(a.count == 200_000)
    #expect(a[65_535] == 65_535 && a[65_536] == 65_536 && a[199_999] == 199_999)
    a[131_072] += 5
    #expect(a[131_072] == 131_077)
    let expected: UInt64 = (0..<200_000).reduce(0) { $0 + UInt64($1) } + 5
    let sum: UInt64 = a.reduce(0, +)
    #expect(sum == expected)
}
