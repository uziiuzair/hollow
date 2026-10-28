import Testing
import Foundation
import DiskEngine
@testable import DiskApp

@Suite struct DropdownModelTests {
    @Test func connectedInternalState() {
        let m = DropdownModel.make(drives: [Fixtures.internalDrive, Fixtures.t7(lastSeen: .now)], selected: "I", connected: ["I", "T7"],
            summary: Fixtures.summary(net: 14_200_000_000, changes: [.init(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", delta: 8_100_000_000),
                                                                   .init(path: ".Trash", delta: -600_000_000)]),
            space: Fixtures.space(totalGB: 994, freeGB: 82, reclaimableGB: 61), activity: .ready, period: 1, connectedSince: nil, now: .now)
        #expect(m.freeTitle == "82 GB free")
        #expect(m.freeDetail == "of 994 GB, 61 GB more reclaimable")
        #expect(m.rows.first == .init(kind: .virtualMachines, name: "Docker.raw", location: "Data", delta: "+8.1 GB", isGrowth: true))
        #expect(m.rows.last?.delta == "\u{2212}0.6 GB")
        #expect(m.netLabel == "Net today" && m.netValue == "\u{2212}14.2 GB free")
        #expect(abs(m.bar.map(\.fraction).reduce(0, +) - 1) < 0.001)
        #expect(m.tabs.map(\.name) == ["Macintosh HD", "Samsung T7"])
        #expect(m.footerRight == .settings)
    }
    @Test func firstLaunchState() {
        let m = DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: ["I"], summary: nil,
            space: Fixtures.space(totalGB: 994, freeGB: 82, reclaimableGB: 0), activity: .scanning, period: 1, connectedSince: nil, now: .now)
        #expect(m.freeTitle == "82 GB free")
        #expect(m.freeDetail == "of 994 GB")
        #expect(m.emptyMessage == "Scanning this drive for the first time. Free space is already up to date.")
        #expect(m.rows.isEmpty)
        #expect(m.footerLeft == "Updating\u{2026}")
    }
    @Test func offlineExternalState() {
        let seen = Date(timeIntervalSince1970: 1_792_500_000)
        let m = DropdownModel.make(drives: [Fixtures.internalDrive, Fixtures.t7(lastSeen: seen, lastFreeGB: 212)], selected: "T7", connected: ["I"],
            summary: nil, space: nil, activity: .offline, period: 7, connectedSince: nil, now: seen.addingTimeInterval(86_400 * 8))
        #expect(m.freeTitle == "Not connected")
        #expect(m.freeDetail == "Last seen \(Format.shortDate(seen)), 212 GB free then")
        #expect(m.tabs.last?.isOffline == true)
        #expect(m.footerRight == .none)
    }
    @Test func noHistoryYet() {
        let m = DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: ["I"], summary: Fixtures.summary(net: nil, changes: []),
            space: Fixtures.space(totalGB: 994, freeGB: 82, reclaimableGB: 0), activity: .ready, period: 1, connectedSince: nil, now: .now)
        #expect(m.emptyMessage == "No history yet. Changes show up from tomorrow.")
    }
}
