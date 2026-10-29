// SPDX-License-Identifier: GPL-3.0-or-later

import DiskApp
import Foundation
import os

/// Logs main-thread stalls: a utility-QoS thread posts a block to the main queue every 8 ms
/// and logs `main thread stalled N ms` to the `map` Logger when one runs more than
/// `threshold` late. It waits for each block before posting the next, so one stall logs once
/// with its full length. Runs in any build, started only with `--watchdog`.
final class MainThreadWatchdog: Sendable {
    private let threshold: Duration
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "map")

    init(threshold: Duration = .milliseconds(16)) {
        self.threshold = threshold
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func run() {
        let clock = ContinuousClock()
        let ran = DispatchSemaphore(value: 0)
        while true {
            let posted = clock.now
            DispatchQueue.main.async {
                let late = clock.now - posted
                if late > self.threshold {
                    self.log.info("main thread stalled \(Int(late / .milliseconds(1))) ms")
                }
                ran.signal()
            }
            ran.wait()
            Thread.sleep(forTimeInterval: 0.008)
        }
    }
}
