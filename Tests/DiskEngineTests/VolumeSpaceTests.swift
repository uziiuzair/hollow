import Foundation
import Testing
@testable import DiskEngine

@Test func volumeSpaceIsSane() throws {
    let v = try VolumeSpace.read(FileManager.default.temporaryDirectory)
    #expect(v.total > 0)
    #expect(v.available <= v.total)
    #expect(v.availableForImportantUsage >= v.available || v.reclaimable == 0)
}

@Test func reclaimableNeverUnderflows() {
    let v = VolumeSpace(total: 100, available: 50, availableForImportantUsage: 40)
    #expect(v.reclaimable == 0)
    #expect(VolumeSpace(total: 100, available: 50, availableForImportantUsage: 70).reclaimable == 20)
}
