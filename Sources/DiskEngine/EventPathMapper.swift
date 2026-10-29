// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Turns the paths of an FSEvents device stream, which are relative to the device's mount point,
/// into absolute paths under the index root. The root may be the mount point itself (the internal
/// disk: "/System/Volumes/Data"), a folder below it, or a path that reaches the device through a
/// firmlink ("/private/var/…" or "/Users/…" on the Data volume).
public struct EventPathMapper: Sendable, Equatable {
    public let rootPath: String
    /// The root relative to the device's mount point, normalized; "" when the root is the mount point.
    public let rootRelative: String

    /// `mountPoint` is the device's real mount point (`statfs(…).f_mntonname`).
    public init(rootPath: String, mountPoint: String) {
        let root = rootPath.count > 1 && rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let mount = Self.normalize(mountPoint)
        let rootNormalized = Self.normalize(root)
        self.rootPath = root
        if mount.isEmpty {
            rootRelative = rootNormalized
        } else if rootNormalized == mount {
            rootRelative = ""
        } else if rootNormalized.hasPrefix(mount + "/") {
            rootRelative = String(rootNormalized.dropFirst(mount.count + 1))
        } else {
            // Not under the mount point's path: reached through a firmlink, whose path is the
            // same relative to the device.
            rootRelative = rootNormalized
        }
    }

    /// The absolute path under the root, or nil when the event is outside it.
    public func absolute(_ deviceRelative: String) -> String? {
        let path = Self.normalize(deviceRelative)
        if path == rootRelative { return rootPath }
        let rest: Substring
        if rootRelative.isEmpty {
            rest = Substring(path)
        } else if path.hasPrefix(rootRelative + "/") {
            rest = path.dropFirst(rootRelative.count + 1)
        } else {
            return nil
        }
        return rootPath == "/" ? "/" + rest : rootPath + "/" + rest
    }

    /// True for a folder strictly above the root (a rescan there covers the root).
    public func isAncestorOfRoot(_ deviceRelative: String) -> Bool {
        let path = Self.normalize(deviceRelative)
        guard path != rootRelative else { return false }
        return path.isEmpty ? !rootRelative.isEmpty : rootRelative.hasPrefix(path + "/")
    }

    /// No leading or trailing "/", no "//".
    static func normalize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    /// The mount point of the device holding `path`, or nil when statfs fails.
    public static func mountPoint(of path: String) -> String? {
        try? requireMountPoint(of: path)
    }

    /// The mount point of the device holding `path`; throws statfs's own errno when it fails.
    public static func requireMountPoint(of path: String) throws -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw DiskEngineError.posix("statfs \(path)", errno) }
        return withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
