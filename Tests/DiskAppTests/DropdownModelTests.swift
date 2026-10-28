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
        #expect(m.rows.first == .init(kind: .virtualMachines, name: "Docker.raw", location: "Data", delta: "+8.1 GB", isGrowth: true,
                              path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", opensMap: true))
        #expect(m.canOpenMap)
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
    @Test func offlineShowsLastData() {
        let seen = Date(timeIntervalSince1970: 1_792_500_000)
        let cached = DriveSummary(scannedBytes: 600_000_000_000, kinds: [.media: 600_000_000_000],
                                  changes: [.init(path: "Footage/2026", delta: 74_000_000_000)], net: 74_000_000_000, period: 7, updatedAt: seen)
        let m = DropdownModel.make(drives: [Fixtures.internalDrive, Fixtures.t7(lastSeen: seen, lastFreeGB: 212)], selected: "T7", connected: ["I"],
            summary: cached, space: nil, activity: .offline, period: 7, connectedSince: nil, now: seen.addingTimeInterval(86_400 * 8))
        #expect(m.freeTitle == "Not connected")
        #expect(m.bar.map(\.kind) == [.content(.media), .content(.other), .free])
        #expect(zip(m.bar.map(\.fraction), [0.6, 0.188, 0.212]).allSatisfy { abs($0 - $1) < 0.001 })
        #expect(m.rows == [.init(kind: .other, name: "2026", location: "Footage", delta: "+74 GB", isGrowth: true, path: "Footage/2026", opensMap: false)])
        #expect(m.footerLeft == "Data from \(Format.shortDate(seen))")
        #expect(!m.canOpenMap && m.emptyMessage == nil)
    }
    @Test func offlineWithoutDataSaysSo() {
        let m = DropdownModel.make(drives: [Fixtures.internalDrive, Fixtures.t7(lastSeen: .now)], selected: "T7", connected: ["I"],
            summary: nil, space: nil, activity: .offline, period: 7, connectedSince: nil, now: .now)
        #expect(m.emptyMessage == "Nothing saved for this drive yet." && m.rows.isEmpty && m.footerLeft == "Offline")
    }
    @Test func rootChangeDoesNotOpenMap() {
        let m = DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: ["I"],
            summary: Fixtures.summary(net: 1, changes: [.init(path: "", delta: 5_000_000_000)]),
            space: Fixtures.space(totalGB: 994, freeGB: 82, reclaimableGB: 0), activity: .ready, period: 1, connectedSince: nil, now: .now)
        #expect(m.rows.first?.opensMap == false)
    }

    @Test func reviewButtonShowsClearableSpace() {
        func title(_ clearable: UInt64?, connected: Set<String> = ["I"]) -> String? {
            DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: connected, summary: nil,
                               space: Fixtures.space(totalGB: 1000, freeGB: 82, reclaimableGB: 0), activity: .ready, period: 7,
                               connectedSince: nil, now: .now, clearable: clearable).reviewTitle
        }
        #expect(title(6_200_000_000) == "Review 6.2 GB to clear")
        #expect(title(100_000_000) == "Review 0.1 GB to clear")
        #expect(title(99_999_999) == nil && title(50_000_000) == nil && title(nil) == nil)
        #expect(title(6_200_000_000, connected: []) == nil)
    }
}

@Test func anyTintCanBeTheInternalDrive() {
    let violetExternal = KnownDrive(uuid: "T7", name: "Samsung T7", tintIndex: 0, lastSeen: .now, isInternal: false)
    let tealInternal = KnownDrive(uuid: "I", name: "Macintosh HD", tintIndex: 1, lastSeen: .now, isInternal: true)
    let m = DropdownModel.make(drives: [violetExternal, tealInternal], selected: "T7", connected: ["I", "T7"], summary: nil,
                               space: nil, activity: .ready, period: 7, connectedSince: nil, now: .now)
    #expect(m.tabs.map(\.uuid) == ["I", "T7"] && m.footerRight == .eject)
}

@Test func deniedAccessShowsANote() {
    func note(_ s: FDAStatus) -> String? {
        DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: ["I"], summary: nil, space: nil,
                           activity: .ready, period: 7, connectedSince: nil, now: .now, fullDiskAccess: s).accessNote
    }
    #expect(note(.denied) == "Some folders can't be read without Full Disk Access.")
    #expect(note(.unknown) == nil && note(.granted) == nil)
}
