// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where "did we register" lives. `UserDefaults` in the app, an in-memory store in tests.
public protocol FlagStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
}

extension UserDefaults: FlagStore {}

public enum LoginItemStatus: Sendable { case enabled, notRegistered, requiresApproval, notFound }

/// What the "Launch at login" switch shows.
public struct LoginToggle: Equatable, Sendable {
    public var isOn: Bool
    public var isEnabled: Bool
    public var note: String?

    public init(isOn: Bool, isEnabled: Bool, note: String?) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.note = note
    }
}

public enum LoginItem {
    static let key = "didRegisterLoginItem"

    /// Calls `register` once ever (launch at login is on by default after first run), then remembers it.
    /// If `register` throws, the flag stays unset so the next launch tries again.
    public static func registerOnFirstRun(defaults: some FlagStore, register: () throws -> Void) rethrows {
        guard !defaults.bool(forKey: key) else { return }
        try register()
        defaults.set(true, forKey: key)
    }

    public static func toggle(status: LoginItemStatus, installed: Bool) -> LoginToggle {
        let isOn = status == .enabled
        if !installed {
            return LoginToggle(isOn: isOn, isEnabled: false, note: "Move Hollow to Applications to launch it at login.")
        }
        if status == .requiresApproval {
            return LoginToggle(isOn: false, isEnabled: true,
                               note: "Allow Hollow in System Settings \u{203A} General \u{203A} Login Items.")
        }
        return LoginToggle(isOn: isOn, isEnabled: true, note: nil)
    }

    /// Only an installed copy (/Applications or ~/Applications) registers; dev builds never do.
    public static func shouldRegister(bundlePath: String, home: String) -> Bool {
        let dirs = ["/Applications/", home + "/Applications/"]
        return dirs.contains { bundlePath.hasPrefix($0) }
    }
}
