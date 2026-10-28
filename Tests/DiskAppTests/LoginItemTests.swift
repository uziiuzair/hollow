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
