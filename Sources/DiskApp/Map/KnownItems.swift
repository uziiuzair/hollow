import Foundation

public enum KnownItems {
    private static let rules: [(pattern: [String], copy: String)] = [
        ("Users/*/Library/Containers/com.docker.docker",
         "The virtual disk Docker runs on. It grows but never shrinks by itself. Reclaim space in Docker \u{203A} Settings \u{203A} Resources."),
        ("Users/*/Library/Developer/Xcode/DerivedData", "Xcode build products. Safe to clear. Rebuilds itself."),
        ("Users/*/Library/Developer/CoreSimulator",
         "iOS simulators and their data. Remove old ones in Xcode \u{203A} Settings \u{203A} Components."),
        ("**/node_modules", "Packages for a JavaScript project. Safe to clear. Reinstall them with npm install."),
        ("Users/*/Library/Caches", "App caches. Apps rebuild what they need."),
        ("Users/*/.Trash", "Files in the Trash. Empty the Trash in Finder to get this space back."),
        ("Users/*/Library/Application Support/MobileSync/Backup",
         "iPhone and iPad backups. Manage them in Finder \u{203A} your device \u{203A} Manage Backups."),
        ("Users/*/Pictures/*.photoslibrary", "Your Photos library. Shrink it from inside Photos, not here."),
    ].map { (pattern: $0.0.lowercased().split(separator: "/").map(String.init), copy: $0.1) }

    /// What a well-known folder is, matched on lowercased path components. A rule covers its folder and everything below it.
    public static func explanation(for relativePath: String) -> String? {
        let parts = relativePath.lowercased().split(separator: "/").map(String.init)
        for rule in rules {
            var pattern = rule.pattern[...]
            let anyDepth = pattern.first == "**"
            if anyDepth { pattern = pattern.dropFirst() }
            let starts = anyDepth ? Array(0...parts.count) : [0]
            for start in starts where matches(Array(pattern), parts, from: start) { return rule.copy }
        }
        return nil
    }

    private static func matches(_ pattern: [String], _ parts: [String], from start: Int) -> Bool {
        guard start + pattern.count <= parts.count else { return false }
        for (i, p) in pattern.enumerated() {
            let part = parts[start + i]
            if p == "*" { continue }
            if p.contains("*") {
                if fnmatch(p, part, 0) != 0 { return false }
            } else if p != part {
                return false
            }
        }
        return true
    }
}
