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

@Test func corruptRegistryIsMovedAside() throws {
    let dir = try Fixtures.tempDir()
    let file = dir.appending(path: "drives.json")
    let garbage = Data("not json {{{".utf8)
    try garbage.write(to: file)
    let reg = DriveRegistry(file: file)
    _ = try reg.upsert(.init(url: URL(filePath: "/Volumes/X"), uuid: "X", name: "X", isInternalData: false, device: 5), space: nil, now: .now)
    let aside = dir.appending(path: "drives.json.corrupt")
    #expect(try Data(contentsOf: aside) == garbage)
    #expect(reg.all().count == 1)
}
