// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

// Final review M6: fixture entries made from parallel tests get distinct inodes (the counter was a racy global).
@Test func fixtureInodesAreUniqueAcrossThreads() async {
    let inodes = await withTaskGroup(of: [UInt64].self) { group in
        for _ in 0..<8 {
            group.addTask { (0..<20_000).map { _ in RawEntry.dir("d").inode } }
        }
        var all: [UInt64] = []
        for await chunk in group { all += chunk }
        return all
    }
    #expect(Set(inodes).count == inodes.count)
}
