import Foundation

public enum LoginItem {
    static let key = "didRegisterLoginItem"

    /// Calls `register` once ever (launch at login is on by default after first run), then remembers it.
    /// If `register` throws, the flag stays unset so the next launch tries again.
    public static func registerOnFirstRun(defaults: UserDefaults, register: () throws -> Void) rethrows {
        guard !defaults.bool(forKey: key) else { return }
        try register()
        defaults.set(true, forKey: key)
    }

    /// Only an installed copy (/Applications or ~/Applications) registers; dev builds never do.
    public static func shouldRegister(bundlePath: String, home: String) -> Bool {
        let dirs = ["/Applications/", home + "/Applications/"]
        return dirs.contains { bundlePath.hasPrefix($0) }
    }
}
