// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

private let GB: UInt64 = 1_000_000_000

@Test func deltasReconstructAndKeysEveryWeek() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Karachi")!
    let dir = try Fixtures.tempDir()
    let store = HistoryStore(directory: dir, calendar: cal)
    let d0 = Day(Date(timeIntervalSince1970: 1_790_000_000), calendar: cal)
    for i in 0..<10 {
        try store.record(SizeSnapshot(sizes: ["": UInt64(i) * GB, "x\(i)": GB]), on: d0.adding(days: i, calendar: cal))
    }
    #expect(try store.snapshot(onOrBefore: d0.adding(days: 8, calendar: cal)) == SizeSnapshot(sizes: ["": 8 * GB, "x8": GB]))
    #expect(try store.snapshot(onOrBefore: d0.adding(days: 20, calendar: cal))?.sizes[""] == 9 * GB)
    #expect(try store.snapshot(onOrBefore: d0.adding(days: -1, calendar: cal)) == nil)
    #expect(try store.days().count == 10)
}

@Test func recordingTheSameDayReplacesIt() throws {
    let cal = Calendar(identifier: .gregorian)
    let store = HistoryStore(directory: try Fixtures.tempDir(), calendar: cal)
    let d = Day(Date(), calendar: cal)
    try store.record(SizeSnapshot(sizes: ["": 1]), on: d)
    try store.record(SizeSnapshot(sizes: ["": 2]), on: d)
    #expect(try store.days().count == 1)
    #expect(try store.snapshot(onOrBefore: d)?.sizes[""] == 2)
}

@Test func pruneKeepsNinetyDaysAndRekeys() throws {
    let cal = Calendar(identifier: .gregorian)
    let store = HistoryStore(directory: try Fixtures.tempDir(), calendar: cal)
    let start = Day(Date(timeIntervalSince1970: 1_780_000_000), calendar: cal)
    for i in 0..<100 { try store.record(SizeSnapshot(sizes: ["": UInt64(i)]), on: start.adding(days: i, calendar: cal)) }
    let today = start.adding(days: 99, calendar: cal)
    try store.prune(keeping: 90, today: today)
    #expect(try store.days().first == today.adding(days: -90, calendar: cal))
    #expect(try store.snapshot(onOrBefore: today.adding(days: -90, calendar: cal))?.sizes[""] == 9)
    #expect(try store.snapshot(onOrBefore: today)?.sizes[""] == 99)
}

@Test func captureUsesThresholds() throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [.file("huge", allocated: 600_000_000), .dir("small")]), rootDevice: 1)
    #expect(try SizeSnapshot.capture(idx).sizes == ["": 600_000_000, "huge": 600_000_000])
}

@Test func liveIndexReportsGrowthSinceYesterday() async throws {
    let root = try Fixtures.tree(["keep/": 0])
    let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store)
    _ = try await live.open()
    try await live.recordHistory(now: Date.now.addingTimeInterval(-86_400))
    try Fixtures.write(root.appending(path: "keep/big.bin"), bytes: 600_000_000)
    let base = Fixtures.realPath(root)
    let next = await live.withIndex { $0.lastEventID } + 1
    try await live.apply([FSChange(path: base + "/keep", id: next, rescanSubtree: false, historyLost: false)])
    let changes = try await live.changes(since: 1)
    #expect(changes.first?.path == "keep/big.bin")
    try await live.close()
}
