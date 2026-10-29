// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin

/// Where an index's RAM goes, plus the process footprint Activity Monitor shows.
public struct MemoryReport: Sendable {
    public var folderTableBytes: Int
    public var folderNameBytes: Int
    public var hardLinkBytes: Int
    public var pendingBytes: Int
    /// `phys_footprint`: dirty memory plus compressed memory, as in Activity Monitor.
    public var processFootprint: UInt64

    /// The four tables above, together.
    public var tablesBytes: Int { folderTableBytes + folderNameBytes + hardLinkBytes + pendingBytes }

    public static func measure(_ index: ScanIndex) -> MemoryReport {
        MemoryReport(
            folderTableBytes: index.folders.capacity * MemoryLayout<FolderRecord>.stride,
            folderNameBytes: index.folderNames.capacity,
            // Dictionary storage: key, value and roughly one byte of metadata per bucket.
            hardLinkBytes: index.hardLinkOwners.capacity * (MemoryLayout<UInt64>.stride + MemoryLayout<FolderID>.stride + 1),
            pendingBytes: index.pending.capacity * MemoryLayout<FolderID>.stride,
            processFootprint: footprint())
    }

    public static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
