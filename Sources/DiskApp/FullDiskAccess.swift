// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

public enum FDAStatus: Equatable, Sendable { case granted, denied, unknown }

/// Whether macOS lets this app read its private folders. Only reads: it opens a few protected paths and looks at
/// the error. It never touches System Settings or the privacy database's contents.
public enum FullDiskAccess {
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public static func probes(home: String) -> [String] {
        ["/Library/Application Support/com.apple.TCC/TCC.db", home + "/Library/Safari", home + "/Library/Mail"]
    }

    /// Tries the probes in order: 0 is granted, EPERM or EACCES is denied, anything else (usually ENOENT) moves on.
    public static func status(home: String = NSHomeDirectory(), probe: (String) -> Int32 = FullDiskAccess.openErrno) -> FDAStatus {
        for path in probes(home: home) {
            let result = probe(path)
            if result == 0 { return .granted }
            if result == EPERM || result == EACCES { return .denied }
        }
        return .unknown
    }

    /// `open(O_RDONLY)`, and for a directory one `readdir` as well (listing is what the privacy check guards).
    /// Returns the first errno, or 0.
    public static func openErrno(_ path: String) -> Int32 {
        let fd = open(path, O_RDONLY)
        if fd < 0 { return errno }
        var info = stat()
        if fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = fdopendir(fd) else { let e = errno; close(fd); return e }
            defer { closedir(dir) }
            errno = 0
            _ = readdir(dir)
            return errno
        }
        close(fd)
        return 0
    }

    /// The probe is about a millisecond, but it still runs off the main thread.
    public static func currentStatus() async -> FDAStatus {
        await Task.detached(priority: .utility) { status() }.value
    }
}
