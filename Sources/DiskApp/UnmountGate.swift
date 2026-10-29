// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How an unmount approval ended.
public enum UnmountHold: Equatable, Sendable {
    /// No index was open on that drive: approved at once.
    case notOpen
    /// The index closed within the limit.
    case closed
    /// The limit passed first; the close carries on, and the unmount goes ahead anyway.
    case timedOut
}

/// Holds an unmount (a Finder eject, `diskutil unmount`) for at most `limit` while the drive's open index closes, so
/// its snapshot is saved before the volume goes. The caller always approves afterwards: the app is never the reason
/// an eject fails.
public final class UnmountGate: @unchecked Sendable {
    private let limit: Duration
    private let close: @Sendable (String) async -> Void
    private let lock = NSLock()
    /// Real paths of the external drives whose index is opening, scanning or ready.
    private var open: Set<String> = []
    /// One close per path; every approver of that path waits on its group (C13: a semaphore would wake only one).
    private var closing: [String: DispatchGroup] = [:]

    public init(limit: Duration = .seconds(2), close: @escaping @Sendable (String) async -> Void) {
        self.limit = limit
        self.close = close
    }

    /// The drives with an open index. A trailing `/` is dropped. A path no longer listed forgets its close, so a close
    /// that never finishes cannot hold that drive's later unmounts.
    public func setOpen(_ volumePaths: Set<String>) {
        let paths = Set(volumePaths.map(Self.trimmed))
        lock.withLock {
            open = paths
            closing = closing.filter { paths.contains($0.key) }
        }
    }

    /// Blocks the calling thread (never main) until the drive's index closes, or at most `limit`.
    public func approve(volumePath: String) -> UnmountHold {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let path = Self.trimmed(volumePath)
        let group: DispatchGroup? = lock.withLock {
            if let running = closing[path] { return running }
            guard open.contains(path) else { return nil }
            let group = DispatchGroup()
            group.enter()
            closing[path] = group
            let close = self.close
            Task.detached(priority: .userInitiated) {
                await close(path)
                self.closed(path, group)
            }
            return group
        }
        guard let group else { return .notOpen }
        return group.wait(timeout: .now() + Self.interval(limit)) == .success ? .closed : .timedOut
    }

    private func closed(_ path: String, _ group: DispatchGroup) {
        lock.withLock {
            // A close the gate already forgot (setOpen dropped the path) changes nothing: the drive may be open again.
            guard closing[path] === group else { return }
            closing[path] = nil
            open.remove(path)
        }
        group.leave()
    }

    static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func interval(_ d: Duration) -> DispatchTimeInterval {
        let (seconds, attoseconds) = d.components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
