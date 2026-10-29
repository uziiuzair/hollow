// SPDX-License-Identifier: GPL-3.0-or-later

import DiskArbitration
import Foundation

/// Whether a mounted volume lives on a disk image. A DiskArbitration round trip, so it is called off the main thread.
enum DiskImageProbe {
    static func isDiskImage(volume url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [CFString: Any] else { return false }
        let model = (description[kDADiskDescriptionDeviceModelKey] as? String)?.trimmingCharacters(in: .whitespaces)
        return model == "Disk Image"
    }
}
