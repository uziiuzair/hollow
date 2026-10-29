// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum AppIdentity {
    public static let name = "Hollow"
    public static let bundleID = "com.uziiuzair.hollow"

    /// `~/Library/Application Support/<name>`, created if missing.
    public static func storeBase() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = support.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
