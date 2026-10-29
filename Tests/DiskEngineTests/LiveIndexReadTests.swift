// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

@Test func readSeesTheOpenIndex() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
@Test func updatesYieldAfterApplyAndFinishOnClose() async throws {
    let root = try Fixtures.tree(["a/f.bin": 10]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    var updates = await live.updates().makeAsyncIterator()
    let drain = await live.updates()
    try Fixtures.write(root.appending(path: "a/g.bin"), bytes: 1_200_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a", id: next, rescanSubtree: false, historyLost: false)])
    #expect((await updates.next()?.generation ?? 0) >= 1)
    try await live.close()
    // The live watcher and compaction may buffer further values; the stream must still end.
    let ended = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in drain {}; return true }
        group.addTask { try await Task.sleep(for: .seconds(10)); return false }
        let first = try await group.next() ?? false
        group.cancelAll()
        return first
    }
    #expect(ended)
}
@Test func baselineIsTheSnapshotAtThePeriodStart() async throws {
    let root = try Fixtures.tree(["a/f.bin": 10]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    let now = Date.now
    try await live.recordHistory(now: now.addingTimeInterval(-7 * 86_400))
    #expect(try await live.baseline(days: 7, now: now) != nil)
    #expect(try await live.baseline(days: 30, now: now) == nil)
    try await live.close()
}
@Test func estimatedSizeFollowsChangeReportRules() {
    let s = SizeSnapshot(sizes: ["": 5_000_000_000, "a": 300_000_000])
    #expect(s.estimatedSize(of: "a", isFile: false) == 300_000_000)
    #expect(s.estimatedSize(of: "a/b", isFile: false) == 99_999_999)
    #expect(s.estimatedSize(of: "a/big.mov", isFile: true) == 300_000_000)
    #expect(SizeSnapshot(sizes: [:]).estimatedSize(of: "", isFile: false) == 0)
}
@Test func storeDirectoryByUUID() {
    #expect(LiveIndex.storeDirectory(base: URL(filePath: "/x"), uuid: "U").path == "/x/Volumes/U")
}
