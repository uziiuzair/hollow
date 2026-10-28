import Foundation
import Testing
@testable import DiskApp

/// The paths `close` was called with, from any thread.
final class Closes: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ p: String) { lock.withLock { list.append(p) } }
    var paths: [String] { lock.withLock { list } }
}

/// Runs `body` on a global queue: `approve` blocks its thread and must not run on main.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: body()) } }
}

private func timed(_ body: @escaping @Sendable () -> UnmountHold) async -> (UnmountHold, Duration) {
    await offMain {
        let clock = ContinuousClock()
        var out = UnmountHold.notOpen
        let d = clock.measure { out = body() }
        return (out, d)
    }
}

// C15: outcomes and lower bounds only; upper bounds are at least the limit plus 1 s.

@Test func notOpenApprovesAtOnce() async {
    let closes = Closes()
    let g = UnmountGate(limit: .milliseconds(300)) { closes.add($0) }
    g.setOpen(["/Volumes/Other"])
    let (out, _) = await timed { g.approve(volumePath: "/Volumes/T7") }
    #expect(out == .notOpen && closes.paths.isEmpty)
}

@Test func openDriveIsHeldUntilItCloses() async {
    let closes = Closes()
    let g = UnmountGate(limit: .seconds(2)) { closes.add($0); try? await Task.sleep(for: .milliseconds(100)) }
    g.setOpen(["/Volumes/T7"])
    let (out, d) = await timed { g.approve(volumePath: "/Volumes/T7/") }
    #expect(out == .closed && d >= .milliseconds(100) && d < .seconds(3) && closes.paths == ["/Volumes/T7"])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .notOpen)
    #expect(closes.paths.count == 1)
}

@Test func slowCloseIsCutOffAtTheLimit() async {
    let g = UnmountGate(limit: .milliseconds(300)) { _ in try? await Task.sleep(for: .seconds(5)) }
    g.setOpen(["/Volumes/T7"])
    let (out, d) = await timed { g.approve(volumePath: "/Volumes/T7") }
    #expect(out == .timedOut && d >= .milliseconds(250) && d < .milliseconds(1_300))
}

@Test func concurrentApprovalsShareOneClose() async {
    let closes = Closes()
    let g = UnmountGate(limit: .seconds(2)) { closes.add($0); try? await Task.sleep(for: .milliseconds(150)) }
    g.setOpen(["/Volumes/T7"])
    async let a = timed { g.approve(volumePath: "/Volumes/T7") }
    async let b = timed { g.approve(volumePath: "/Volumes/T7") }
    let results = await [a.0, b.0]
    #expect(results == [.closed, .closed] && closes.paths.count == 1)
}

@Test func setOpenDropsTrailingSlashes() async {
    let closes = Closes()
    let g = UnmountGate(limit: .seconds(2)) { closes.add($0) }
    g.setOpen(["/Volumes/T7/"])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .closed)
    #expect(closes.paths == ["/Volumes/T7"])
}

@Test func aCloseThatNeverFinishesIsForgottenWhenTheDriveLeavesTheOpenSet() async {
    let closes = Closes()
    let g = UnmountGate(limit: .milliseconds(200)) { path in
        closes.add(path)
        // The first close hangs; later ones finish at once.
        if closes.paths.count == 1 { try? await Task.sleep(for: .seconds(30)) }
    }
    g.setOpen(["/Volumes/T7"])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .timedOut)
    // The drive went offline: its next unmount is not held by the hung close.
    g.setOpen([])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .notOpen)
    // Open again (a new index): a new close runs and answers.
    g.setOpen(["/Volumes/T7"])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .closed)
    #expect(closes.paths.count == 2)
}
