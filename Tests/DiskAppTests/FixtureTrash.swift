// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import DiskApp

/// A trash for tests: `rename(2)`s the item into `bin/<UUID>`. It refuses, with a `precondition`, anything whose resolved path is
/// not inside this run's fixture root, so a test can never move anything else.
struct FixtureTrash: TrashBackend {
    let bin: URL

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastCallWasOnMain: Bool?

    /// `Thread.isMainThread` of the last `trash` call.
    static var lastCallWasOnMain: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _lastCallWasOnMain
    }

    func trash(_ url: URL) throws {
        Self.lock.lock(); Self._lastCallWasOnMain = Thread.isMainThread; Self.lock.unlock()
        let fixtures = Fixtures.realPath(RunRoot.url)
        // Resolve the parent, not the item, so a symlink item stays the link itself.
        let source = Fixtures.realPath(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
        let binPath = Fixtures.realPath(bin)
        precondition(source.hasPrefix(fixtures + "/") && url.lastPathComponent != ".." && url.lastPathComponent != ".",
                     "FixtureTrash refused \(source): outside \(fixtures)")
        precondition(binPath.hasPrefix(fixtures + "/"), "FixtureTrash bin \(binPath) is outside \(fixtures)")
        guard rename(source, binPath + "/" + UUID().uuidString) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
