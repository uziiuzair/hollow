// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Capacity numbers for the volume holding a URL. "Reclaimable" is space macOS can
/// free on its own (purgeable files, local snapshots) when something important needs it.
public struct VolumeSpace: Sendable {
    public var total: UInt64
    public var available: UInt64
    public var availableForImportantUsage: UInt64

    public init(total: UInt64, available: UInt64, availableForImportantUsage: UInt64) {
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    public var reclaimable: UInt64 {
        availableForImportantUsage > available ? availableForImportantUsage - available : 0
    }

    public static func read(_ url: URL) throws -> VolumeSpace {
        let v = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        return VolumeSpace(
            total: UInt64(v.volumeTotalCapacity ?? 0),
            available: UInt64(v.volumeAvailableCapacity ?? 0),
            availableForImportantUsage: UInt64(max(v.volumeAvailableCapacityForImportantUsage ?? 0, 0)))
    }
}
