import Foundation
import Testing
@testable import DiskApp

final class MemoryFlags: FlagStore {
    private var flags: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { flags[key] ?? false }
    func set(_ value: Bool, forKey key: String) { flags[key] = value }
}

@Test func registersOnlyOnce() throws {
    let d = MemoryFlags()
    var calls = 0
    LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    #expect(calls == 1)
}

@Test func registerOnlyFromApplicationsFolders() {
    let home = "/Users/someone"
    #expect(LoginItem.shouldRegister(bundlePath: "/Applications/Hollow.app", home: home))
    #expect(LoginItem.shouldRegister(bundlePath: "\(home)/Applications/Hollow.app", home: home))
    #expect(!LoginItem.shouldRegister(bundlePath: "/Users/someone/proj/.build/Hollow.app", home: home))
}

@Test func loginToggleFollowsServiceStatus() {
    #expect(LoginItem.toggle(status: .enabled, installed: true) == LoginToggle(isOn: true, isEnabled: true, note: nil))
    #expect(LoginItem.toggle(status: .enabled, installed: false)
        == LoginToggle(isOn: true, isEnabled: false, note: "Move Hollow to Applications to launch it at login."))
    #expect(LoginItem.toggle(status: .requiresApproval, installed: true)
        == LoginToggle(isOn: false, isEnabled: true, note: "Allow Hollow in System Settings \u{203A} General \u{203A} Login Items."))
}
