import Foundation
import Testing
@testable import DiskApp

@Test func defaultsMatchTheSpec() {
    let s = AppSettings()
    #expect(s.menuBarStyle == .ringAndNumber && s.lowPercent == 15 && s.criticalPercent == 5 && s.excludedFolders.isEmpty)
    #expect(AppSettings.decode(nil) == s && AppSettings.decode(Data("junk".utf8)) == s)
}

@MainActor @Test func storeSavesNormalized() {
    var saved: Data?
    let store = SettingsStore(read: { nil }, write: { saved = $0 })
    store.settings.lowPercent = 60; store.settings.criticalPercent = 70; store.settings.excludedFolders = ["/Volumes/T7/x/", "/Volumes/T7/x"]
    let back = AppSettings.decode(saved)
    #expect(back.lowPercent == 50 && back.criticalPercent == 49 && back.excludedFolders == ["/Volumes/T7/x"])
}

@Test func exclusionsMapOntoEachDrive() {
    var s = AppSettings(); s.excludedFolders = ["/Users/u/VMs", "/Volumes/T7/Renders", "/Volumes/T7", "/Library/Caches"]
    let data = "/System/Volumes/Data"
    #expect(s.exclusions(under: data, exists: { ["\(data)/Users/u/VMs", "\(data)/Library/Caches"].contains($0) }) == ["Users/u/VMs", "Library/Caches"])
    #expect(s.exclusions(under: "/Volumes/T7", exists: { _ in true }) == ["Renders"])
}

// Final review M2: a blob missing a key (written before that key existed) keeps every other value.
@Test func decodingMissingKeysKeepsTheOthers() {
    let old = Data(#"{"lowPercent": 20, "criticalPercent": 8, "excludedFolders": ["/Users/u/VMs"]}"#.utf8)
    let s = AppSettings.decode(old)
    #expect(s.lowPercent == 20 && s.criticalPercent == 8 && s.excludedFolders == ["/Users/u/VMs"])
    #expect(s.menuBarStyle == .ringAndNumber)
    let onlyFolders = AppSettings.decode(Data(#"{"excludedFolders": ["/a"], "futureKey": true}"#.utf8))
    #expect(onlyFolders.excludedFolders == ["/a"] && onlyFolders.lowPercent == 15 && onlyFolders.criticalPercent == 5)
}
