import Foundation

public enum AppIdentity {
    public static let name = "Diskinventory"
    public static let bundleID = "com.ooozzy.diskinventory"

    /// `~/Library/Application Support/<name>`, created if missing.
    public static func storeBase() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let base = support.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
