// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// Tests only: counts the path comparisons (a prefix test, or a set lookup of one ancestor) the basket and the review
/// sheet make inside `PathChecks.$counter.withValue(…)`, so a test can assert the work grows linearly, not by the square.
public final class PathCheckCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)
    public init() {}
    public var count: Int { state.withLock { $0 } }
    func add(_ n: Int) { state.withLock { $0 += n } }
}

public enum PathChecks {
    @TaskLocal public static var counter: PathCheckCounter?
    static func tick(_ n: Int = 1) { counter?.add(n) }
}
