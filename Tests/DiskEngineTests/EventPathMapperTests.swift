// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

// FSEvents device streams report paths relative to the device's mount point. The index root
// may be that mount point ("/System/Volumes/Data") or a firmlinked path into it ("/private/var/…").

@Test func mapsEventsUnderTheMountPointRoot() {
    let m = EventPathMapper(rootPath: "/System/Volumes/Data", mountPoint: "/System/Volumes/Data")
    #expect(m.absolute("Users/u/x") == "/System/Volumes/Data/Users/u/x")
    #expect(m.absolute("/Users//u/x/") == "/System/Volumes/Data/Users/u/x")
    // The volume root itself.
    #expect(m.absolute("") == "/System/Volumes/Data")
    #expect(m.absolute("/") == "/System/Volumes/Data")
}

@Test func mapsEventsUnderAFirmlinkedRoot() {
    let m = EventPathMapper(rootPath: "/private/var/folders/T/abc", mountPoint: "/System/Volumes/Data")
    #expect(m.absolute("private/var/folders/T/abc/d") == "/private/var/folders/T/abc/d")
    #expect(m.absolute("private/var/folders/T/abc") == "/private/var/folders/T/abc")
    #expect(m.absolute("private/var/folders/T/abcd/e") == nil)
    #expect(m.absolute("Users/u/x") == nil)
    #expect(m.absolute("") == nil)
}

@Test func mapsEventsUnderASubfolderOfTheMount() {
    let m = EventPathMapper(rootPath: "/Volumes/Ext/Projects", mountPoint: "/Volumes/Ext")
    #expect(m.absolute("Projects/a") == "/Volumes/Ext/Projects/a")
    #expect(m.absolute("Other/a") == nil)
}

@Test func aRootAtSlashTakesEverything() {
    let m = EventPathMapper(rootPath: "/", mountPoint: "/")
    #expect(m.absolute("Users/u") == "/Users/u")
    #expect(m.absolute("") == "/")
}

// A rescan reported on a folder above the root covers the root.
@Test func ancestorsOfTheRootAreKnown() {
    let m = EventPathMapper(rootPath: "/private/var/folders/T/abc", mountPoint: "/System/Volumes/Data")
    #expect(m.isAncestorOfRoot("private/var") && m.isAncestorOfRoot("") && m.isAncestorOfRoot("/private/var/folders/T/"))
    #expect(!m.isAncestorOfRoot("private/var/folders/T/abc") && !m.isAncestorOfRoot("Users"))
}

// End to end with the real watcher: a root named by its path under the Data volume's mount point
// (as the internal disk is, "/System/Volumes/Data") sees a new file without any synthetic apply.
@Test func watcherReachesARootUnderTheDataMountPoint() async throws {
    let tree = try Fixtures.tree(["a/f.bin": 10])
    let real = Fixtures.realPath(tree)
    let viaMount = URL(filePath: "/System/Volumes/Data" + real)
    try #require(FileManager.default.fileExists(atPath: viaMount.path))
    let live = LiveIndex(volumeRoot: viaMount, store: try Fixtures.tempDir())
    _ = try await live.open()
    let updates = await live.updates()
    try Fixtures.write(tree.appending(path: "a/g.bin"), bytes: 1_200_000)
    let changed = try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask { for await _ in updates { return true }; return false }
        group.addTask { try await Task.sleep(for: .seconds(15)); return false }
        let first = try await group.next() ?? false
        group.cancelAll()
        return first
    }
    #expect(changed)
    try await live.close()
}
