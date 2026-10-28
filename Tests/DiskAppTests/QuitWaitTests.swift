import Foundation
import Testing
@testable import DiskApp

// Final review M1: quitting mid-move waits for the move to end, but never longer than the cap.
@MainActor @Test func quitWaitEndsWhenTheMoveEnds() async {
    var polls = 0
    let clock = ContinuousClock()
    let started = clock.now
    let finished = await QuitWait.whileBusy(cap: .seconds(30), poll: .milliseconds(10)) {
        polls += 1
        return polls < 4
    }
    #expect(finished && polls == 4)
    #expect(clock.now - started < .seconds(2))
}

@MainActor @Test func quitWaitGivesUpAtTheCap() async {
    let clock = ContinuousClock()
    let started = clock.now
    let finished = await QuitWait.whileBusy(cap: .milliseconds(150), poll: .milliseconds(10)) { true }
    let waited = clock.now - started
    #expect(!finished && waited >= .milliseconds(150) && waited < .seconds(3))
}
