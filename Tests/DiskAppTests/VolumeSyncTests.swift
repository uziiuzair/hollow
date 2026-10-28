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

@Test func mapWindowReattachesOnlyAfterARefusedEject() {
    // Refused: the spent controller was replaced while the drive stayed mounted.
    #expect(VolumeSync.shouldReattach(windowDrive: "T7", holdsCurrentController: false, unmounting: false, refused: ["T7"]))
    // A real unmount and a remount: the basket was dropped, so no reattach (the next open makes a fresh window).
    #expect(!VolumeSync.shouldReattach(windowDrive: "T7", holdsCurrentController: false, unmounting: false, refused: []))
    // Already on the current controller, or the new one is unmounting too.
    #expect(!VolumeSync.shouldReattach(windowDrive: "T7", holdsCurrentController: true, unmounting: false, refused: ["T7"]))
    #expect(!VolumeSync.shouldReattach(windowDrive: "T7", holdsCurrentController: false, unmounting: true, refused: ["T7"]))
    // Another drive's refused eject.
    #expect(!VolumeSync.shouldReattach(windowDrive: "T7", holdsCurrentController: false, unmounting: false, refused: ["X"]))
}
