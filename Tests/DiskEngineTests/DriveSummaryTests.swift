// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

@Suite struct DriveSummaryTests {
    @Test func summaryHasKindsChangesAndNet() async throws {
        let root = try Fixtures.tree(["Users/u/Movies/": 0]); let store = try Fixtures.tempDir()
        let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
        #expect(try await live.summary(since: 1).net == nil)
        try await live.recordHistory(now: .now.addingTimeInterval(-86_400))
        try Fixtures.write(root.appending(path: "Users/u/Movies/clip.mov"), bytes: 600_000_000)
        let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
        try await live.apply([FSChange(path: Fixtures.realPath(root) + "/Users/u/Movies", id: next, rescanSubtree: false, historyLost: false)])
        let s = try await live.summary(since: 1)
        #expect(s.kinds[.media] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Movies")))
        #expect(s.changes.first?.path == "Users/u/Movies/clip.mov")
        #expect((s.net ?? 0) > 400_000_000)
        try s.save(to: store)
        #expect(DriveSummary.load(from: store, period: 1) == s)
        try await live.close()
    }

    // Final review 4: with no history a summary reads no file records, kinds are worked
    // out once per index state, and an apply that changes the index refreshes them.
    @Test func summaryCachesKindsAndSkipsSnapshotWithoutHistory() async throws {
        let root = try Fixtures.tree(["Users/u/Movies/a.mov": 2_000_000, "Users/u/Documents/d.bin": 1_500_000, "top.bin": 1_100_000])
        let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir()); _ = try await live.open()
        let reads = await live.withIndex { $0.files.recordReads }
        let first = try await live.summary(since: 7)
        let second = try await live.summary(since: 30)
        #expect(await live.withIndex { $0.files.recordReads } == reads)
        #expect(second.kinds == first.kinds)
        #expect(await live.kindsComputations == 1)

        try Fixtures.write(root.appending(path: "Users/u/Movies/b.mov"), bytes: 1_200_000)
        let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
        try await live.apply([FSChange(path: Fixtures.realPath(root) + "/Users/u/Movies", id: next, rescanSubtree: false, historyLost: false)])
        let third = try await live.summary(since: 7)
        #expect(third.kinds[.media] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Movies")))
        #expect(await live.kindsComputations == 2)
        try await live.close()
    }

    @Test func dayIsStableAcrossMidnightDST() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Santiago")!
        let d = Day(cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!, calendar: cal)
        #expect(d.adding(days: 1, calendar: cal) == Day(cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!, calendar: cal))
    }

    @Test func decomposedUnicodeFolderIsFoundFromEventPath() async throws {
        let name = "Cafe\u{301}"
        let root = try Fixtures.tree(["\(name)/f": 10]); let store = try Fixtures.tempDir()
        let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
        try Fixtures.write(root.appending(path: "\(name)/g.bin"), bytes: 1_200_000)
        let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
        try await live.apply([FSChange(path: Fixtures.realPath(root) + "/Caf\u{E9}", id: next, rescanSubtree: false, historyLost: false)])
        #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
        try await live.close()
    }
}
