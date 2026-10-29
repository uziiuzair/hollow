// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@Test func tempDirLivesInsideTheRunRoot() throws {
    let dir = try Fixtures.tempDir()
    let root = RunRoot.url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    #expect(dir.path.hasPrefix("/" + root + "/"))
    #expect(root.contains("/HollowTests/DiskEngineTests-\(getpid())-"))
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

@Test func removeTreeHandlesUnreadableFoldersAndLeavesSymlinkTargets() throws {
    let outside = try Fixtures.tempDir()
    let keep = outside.appending(path: "keep.txt")
    try Data([1]).write(to: keep)
    let victim = try Fixtures.tempDir().appending(path: "victim", directoryHint: .isDirectory)
    let locked = victim.appending(path: "locked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try Data([1]).write(to: locked.appending(path: "f"))
    try FileManager.default.createSymbolicLink(at: victim.appending(path: "link"), withDestinationURL: outside)
    chmod(locked.path, 0o000)

    RunRoot.removeTree(atPath: victim.path)

    #expect(!FileManager.default.fileExists(atPath: victim.path))
    #expect(FileManager.default.fileExists(atPath: keep.path))
}
