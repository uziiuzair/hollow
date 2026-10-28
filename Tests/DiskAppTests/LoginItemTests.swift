import Foundation
import Testing
@testable import DiskApp

@Test func registersOnlyOnce() throws {
    let name = "test-\(UUID())"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    var calls = 0
    try LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    try LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    #expect(calls == 1)
}

@Test func registerOnlyFromApplicationsFolders() {
    let home = "/Users/someone"
    #expect(LoginItem.shouldRegister(bundlePath: "/Applications/Diskinventory.app", home: home))
    #expect(LoginItem.shouldRegister(bundlePath: "\(home)/Applications/Diskinventory.app", home: home))
    #expect(!LoginItem.shouldRegister(bundlePath: "/Users/someone/proj/.build/Diskinventory.app", home: home))
}
