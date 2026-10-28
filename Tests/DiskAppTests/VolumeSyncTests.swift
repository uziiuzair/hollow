import Foundation
import Testing
@testable import DiskApp

// Final review 2: a refused unmount leaves the drive mounted with a spent controller.
@Test func refusedUnmountIsReplacedAfterGrace() {
    let now = Date()
    let finished: [String: Date] = [
        "refused": now.addingTimeInterval(-10),      // finished long ago, still mounted
        "justNow": now.addingTimeInterval(-1),       // the system may still be unmounting it
        "gone": now.addingTimeInterval(-10),         // really unmounted
        "ejecting": now.addingTimeInterval(-10),     // the app's own eject is in progress
    ]
    let replace = VolumeSync.spentControllersToReplace(
        mounted: ["refused", "justNow", "ejecting", "neverUnmounted"], unmountFinished: finished,
        ejecting: ["ejecting"], now: now, grace: 5)
    #expect(replace == ["refused"])
}
