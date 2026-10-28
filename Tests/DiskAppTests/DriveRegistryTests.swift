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

// Final review 3: a panel open marks connected drives seen without rewriting drives.json;
// the next real write carries it.
@Test func markSeenUpdatesMemoryWithoutWriting() throws {
    let file = try Fixtures.tempDir().appending(path: "drives.json")
    let reg = DriveRegistry(file: file)
    let v = VolumeInfo(url: URL(filePath: "/Volumes/T7"), uuid: "T7", name: "T7", isInternalData: false, device: 3)
    _ = try reg.upsert(v, space: nil, now: Date(timeIntervalSince1970: 1_000))
    let written = try Data(contentsOf: file)
    let later = Date(timeIntervalSince1970: 2_000)
    reg.markSeen("T7", now: later)
    #expect(reg.all().first?.lastSeen == later)
    #expect(try Data(contentsOf: file) == written)
    #expect(reg.needsWrite(for: v) == false)
    #expect(reg.needsWrite(for: VolumeInfo(url: v.url, uuid: "T7", name: "Renamed", isInternalData: false, device: 3)))
    #expect(reg.needsWrite(for: VolumeInfo(url: v.url, uuid: "New", name: "New", isInternalData: false, device: 4)))
}
