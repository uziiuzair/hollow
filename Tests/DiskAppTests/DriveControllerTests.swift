import Foundation
import Testing
@testable import DiskApp
@testable import DiskEngine

private func todayRecorded(_ store: URL) throws -> Bool {
    try HistoryStore(directory: store.appending(path: "history")).days().contains(Day(.now, calendar: .current))
}

@MainActor @Test func warmThenCoolReleasesIndex() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/m.mov": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir(), coolDown: .milliseconds(200))
    await c.warm()
    #expect(c.activity == .ready)
    #expect(c.summary?.kinds[.media] != nil)
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .idle)
}

@MainActor @Test func cachedSummaryShowsBeforeWarm() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let first = DriveController(volume: try Fixtures.volume(root), store: store)
    await first.warm(); await first.cool()
    let second = DriveController(volume: try Fixtures.volume(root), store: store)
    #expect(second.summary?.scannedBytes == first.summary?.scannedBytes)
    #expect(second.activity == .idle)
}

@MainActor @Test func willUnmountClosesWarmIndex() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.warm()
    await c.willUnmount()
    #expect(c.activity == .offline)
    #expect(try todayRecorded(store))
}

@MainActor @Test func exFATScansOnlyWhenSelected() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    c.refreshSpace()
    #expect(c.space != nil)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}

@MainActor @Test func willUnmountDuringWarmLeavesOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await Task.yield()  // let warm() start and suspend inside open()
    await c.willUnmount()
    await warming.value
    #expect(c.activity == .offline)
    await c.cool()
    #expect(c.activity == .offline)
    #expect(try todayRecorded(store))
}

@MainActor @Test func coolDuringWarmEndsIdle() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    let warming = Task { await c.warm() }
    await Task.yield()  // let warm() start and suspend inside open()
    await c.cool()
    await warming.value
    #expect(c.activity == .idle)
    #expect(try todayRecorded(store))
}
