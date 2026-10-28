import Testing
import Foundation
@testable import DiskApp

@Test func sameNameDifferentUUID() throws {
    let reg = DriveRegistry(file: try Fixtures.tempDir().appending(path: "drives.json"))
    let a = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled"), uuid: "A", name: "Untitled", isInternalData: false, device: 10), space: nil, now: .now)
    let b = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled 1"), uuid: "B", name: "Untitled", isInternalData: false, device: 11), space: nil, now: .now)
    #expect(a.tintIndex == 1 && b.tintIndex == 2)
    #expect(reg.all().count == 2)
    let again = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled"), uuid: "A", name: "Renamed", isInternalData: false, device: 12), space: nil, now: .now)
    #expect(again.tintIndex == 1 && again.name == "Renamed")
}

@Test func registryPersists() throws {
    let file = try Fixtures.tempDir().appending(path: "drives.json")
    _ = try DriveRegistry(file: file).upsert(.init(url: URL(filePath: "/"), uuid: "I", name: "Macintosh HD", isInternalData: true, device: 1), space: nil, now: .now)
    #expect(DriveRegistry(file: file).all().first?.tintIndex == 0)
}
