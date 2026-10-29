// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct VolumeInfo: Sendable, Equatable {
    public let url: URL
    public let uuid: String
    public let name: String
    public let isInternalData: Bool
    public let device: dev_t
    /// A mounted disk image (a sparse bundle, a dev image): shown while mounted, never remembered or given a lasting store.
    public let isDiskImage: Bool

    public init(url: URL, uuid: String, name: String, isInternalData: Bool, device: dev_t, isDiskImage: Bool = false) {
        self.url = url
        self.uuid = uuid
        self.name = name
        self.isInternalData = isInternalData
        self.device = device
        self.isDiskImage = isDiskImage
    }

    /// The same volume, marked as a disk image or not.
    public func markingDiskImage(_ isDiskImage: Bool) -> VolumeInfo {
        VolumeInfo(url: url, uuid: uuid, name: name, isInternalData: isInternalData, device: device, isDiskImage: isDiskImage)
    }
}

public enum VolumeCatalog {
    static let internalDataPath = "/System/Volumes/Data"

    /// True for local, browsable, writable, non-root, non-internal volumes.
    public static func isDrive(isInternal: Bool, isLocal: Bool, isBrowsable: Bool,
                               isRootFileSystem: Bool, isReadOnly: Bool) -> Bool {
        isLocal && isBrowsable && !isRootFileSystem && !isInternal && !isReadOnly
    }

    /// The internal Data volume first, then every qualifying external drive.
    public static func current() -> [VolumeInfo] {
        var result: [VolumeInfo] = []
        let dataURL = URL(filePath: internalDataPath, directoryHint: .isDirectory)
        if let internalVolume = info(for: dataURL, isInternalData: true) {
            result.append(internalVolume)
        }

        let keys: [URLResourceKey] = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
            .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey,
            .volumeUUIDStringKey, .volumeNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: .skipHiddenVolumes) ?? []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  isDrive(isInternal: v.volumeIsInternal ?? false,
                          isLocal: v.volumeIsLocal ?? false,
                          isBrowsable: v.volumeIsBrowsable ?? false,
                          isRootFileSystem: v.volumeIsRootFileSystem ?? false,
                          isReadOnly: v.volumeIsReadOnly ?? true),
                  let drive = info(for: url, isInternalData: false) else { continue }
            if result.contains(where: { $0.uuid == drive.uuid }) { continue }
            result.append(drive)
        }
        return result
    }

    private static func info(for url: URL, isInternalData: Bool) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey]),
              let uuid = v.volumeUUIDString else { return nil }
        var st = stat()
        guard stat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return VolumeInfo(url: url, uuid: uuid, name: v.volumeName ?? url.lastPathComponent,
                          isInternalData: isInternalData, device: st.st_dev)
    }
}
