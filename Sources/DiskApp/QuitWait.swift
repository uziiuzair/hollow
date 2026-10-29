// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Quitting while a move to the Trash runs: wait for the move to end before the indexes close, so every item it started
/// is moved and its outcome is kept, but never longer than a cap.
public enum QuitWait {
    public static let moveCap: Duration = .seconds(30)

    /// Polls `busy` until it is false (true) or `cap` has passed (false).
    @MainActor
    public static func whileBusy(cap: Duration = moveCap, poll: Duration = .milliseconds(100),
                                 _ busy: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + cap
        while busy() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: min(poll, deadline - clock.now))
        }
        return true
    }
}
