import Darwin
import Foundation
import Testing
@testable import DiskApp

@Test func probeOrderAndVerdicts() {
    func status(_ results: [String: Int32]) -> FDAStatus { FullDiskAccess.status(home: "/Users/u") { results[$0] ?? ENOENT } }
    #expect(status(["/Library/Application Support/com.apple.TCC/TCC.db": 0]) == .granted)
    #expect(status(["/Library/Application Support/com.apple.TCC/TCC.db": EPERM]) == .denied)
    #expect(status(["/Users/u/Library/Safari": EACCES]) == .denied)
    #expect(status(["/Users/u/Library/Mail": 0]) == .granted)
    #expect(status([:]) == .unknown)
}

@Test func probesAreTheThreePrivatePaths() {
    #expect(FullDiskAccess.probes(home: "/Users/u") == [
        "/Library/Application Support/com.apple.TCC/TCC.db", "/Users/u/Library/Safari", "/Users/u/Library/Mail"])
}

@Test func firstAnsweringProbeWins() {
    // An absent first probe is skipped; the first one that answers decides.
    var asked: [String] = []
    let s = FullDiskAccess.status(home: "/h") { path in asked.append(path); return path.hasSuffix("Safari") ? EPERM : ENOENT }
    #expect(s == .denied)
    #expect(asked == ["/Library/Application Support/com.apple.TCC/TCC.db", "/h/Library/Safari"])
}

@Test func openErrnoReportsMissingAndReadable() throws {
    let dir = try Fixtures.tempDir()
    #expect(FullDiskAccess.openErrno(dir.path) == 0)
    #expect(FullDiskAccess.openErrno(dir.appending(path: "nope").path) == ENOENT)
}
