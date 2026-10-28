# Menu Bar App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native menu bar app: a ring-and-number icon showing free space, and the flat dropdown from the approved mockup, with drive tabs, the disk bar by content type, "What changed" (Today / 7 days / 30 days), and external drives that come and go.

**Architecture:** One accessory process (`LSUIElement`). The menu bar number comes from `VolumeSpace` only. Each drive's `LiveIndex` is **warm while used and cold when idle**: it opens when the dropdown opens (or once a day for history) and closes 5 minutes after the dropdown was last shown. A small per-drive summary is cached on disk and shown instantly, then refreshed when the warm index catches up. FSEvents history replay (`since: lastEventID`) covers the time the index was closed. View models are plain Swift and unit-tested; AppKit hosts the status item and a borderless panel; SwiftUI draws the panel.

**Tech Stack:** Swift 6.3, AppKit (`NSStatusItem`, `NSPanel`), SwiftUI, `ServiceManagement` (`SMAppService`), Swift Testing. App bundle assembled by a shell script from the SwiftPM build; ad-hoc signed for local runs (Developer ID, notarization, and Sparkle are Plan 5).

**Spec:** `docs/superpowers/specs/2026-10-28-disk-inventory-design.md` (sections 3.1, 3.2, 4, 5, 6.3, 7). Builds on Plans 1 and 2 (`DiskEngine`, `LiveIndex`), merged to `main`.

## Decision this plan makes (founder to check)

Spec 7 asks for **under 40 MB idle** and spec 5 for **one process**. A loaded index of the internal disk is about 50 MB of tables alone (measured in Plan 2), so an always-loaded index cannot meet the idle target. This plan keeps the index cold when the dropdown hasn't been used for 5 minutes and catches up from FSEvents history when it warms. The cost: on opening the dropdown after a long idle, "What changed" first shows the cached summary, then updates within a few seconds. The footer says "Updating…" while that happens.

Plan 2 left about 85 MB of the scan's footprint unexplained. With a cold index the menu bar doesn't carry it while idle, so that investigation moves to Plan 4, where the full window keeps the index loaded against its 150 MB target.

## Global Constraints

- macOS 14 or newer. Swift 6 language mode. No third-party dependencies.
- Working app name: **Diskinventory**, bundle ID `com.ooozzy.diskinventory`, both defined once (`AppIdentity.swift` and the bundle script) so the founder's final name is a two-line change.
- Store: `~/Library/Application Support/Diskinventory/Volumes/<volume UUID>/` via `LiveIndex.storeDirectory(base:volume:)`.
- Internal disk root: `/System/Volumes/Data` (spec 6.1: scan via the Data volume).
- Menu bar: thin ring that fills as the disk fills, then free space (`82 GB`). Amber below 15% free, red below 5% (spec 3.1).
- Content-type colors (spec 4): Apps `#4C7CE0`, Virtual machines `#2E9FC4`, Developer `#7A5FD6`, Photos and video `#D45C7E`, Mail and documents `#D9893A`, App data `#3E9E7A`, Caches `#6B7183`. Growth `#E8805F`, freed `#3FA67F`.
- Drive tints (spec 4): internal `#8B7BFF`; externals in order `#0FA39B`, `#E0884F`, `#4C9BE0`, `#D2589A`, `#6BA34A`, `#B08A3E`, `#7E8796`.
- Shape (spec 4): 4px blocks, 5 to 6px controls, 10px dropdown corners, no gradients except the fine ruled reclaimable pattern.
- Sizes are decimal (1 GB = 1,000,000,000 bytes), one decimal place, true minus sign `−` (U+2212) for negatives.
- Dropdown width 340 pt. Dark and light follow the system.
- Nothing is deleted from the dropdown (spec 3.2).
- External drives are never scanned or woken on a timer (spec 6.3).

## Review Focus

1. **An external drive is ejected while its index is warm or mid-scan**: the eject must not be blocked; the index closes and saves first, and the tab shows the drive as offline. Pinned in Task 5 (`willUnmountClosesWarmIndex`).
2. **The very first launch** (no snapshot, no history, no Full Disk Access): the dropdown opens at once, shows free space, and says the scan is running; no crash and no "everything grew". Pinned in Task 6 (`firstLaunchState`).
3. **A drive with no FSEvents journal (exFAT)**: listed, but scanned only when its tab is selected (spec 6.3). Pinned in Task 5 (`exFATScansOnlyWhenSelected`).
4. **Two drives with the same name** (two "Untitled" SSDs): kept apart by volume UUID, each with its own tint and history. Pinned in Task 4 (`sameNameDifferentUUID`).
5. **The disk fills to under 5% while idle**: the menu bar turns red without opening the dropdown. Pinned in Task 3 (`labelLevels`).

## File map

```
Package.swift                                  + DiskApp library, Diskinventory executable, DiskAppTests
Sources/DiskEngine/ContentKind.swift           content-type classifier (new)
Sources/DiskEngine/DriveSummary.swift          DriveSummary + LiveIndex.summary(since:) (new)
Sources/DiskEngine/History.swift               Day uses noon (modify)
Sources/DiskApp/AppIdentity.swift              name, bundle ID, store base
Sources/DiskApp/Format.swift                   GB formatting, relative times
Sources/DiskApp/Palette.swift                  kind colors, drive tints
Sources/DiskApp/MenuBarLabel.swift             icon text and level
Sources/DiskApp/VolumeCatalog.swift            which mounted volumes count as drives
Sources/DiskApp/DriveRegistry.swift            known drives, tints, last seen (persisted)
Sources/DiskApp/DriveController.swift          one drive: warm/cold LiveIndex, cached summary
Sources/DiskApp/DropdownModel.swift            everything the dropdown shows, as values
Sources/Diskinventory/main.swift               NSApplication bootstrap
Sources/Diskinventory/AppDelegate.swift        status item, login item, mount notifications
Sources/Diskinventory/StatusIcon.swift         ring image
Sources/Diskinventory/DropdownPanel.swift      borderless NSPanel under the status item
Sources/Diskinventory/DropdownView.swift       SwiftUI views
scripts/make-app.sh                            assemble Diskinventory.app
Tests/DiskEngineTests/ContentKindTests.swift  Tests/DiskEngineTests/DriveSummaryTests.swift
Tests/DiskAppTests/*.swift
```

---

### Task 1: Content-type classifier

**Files:**
- Create: `Sources/DiskEngine/ContentKind.swift`
- Test: `Tests/DiskEngineTests/ContentKindTests.swift`

**Interfaces:**
- Produces:
  - `public enum ContentKind: String, CaseIterable, Codable, Sendable { case apps, virtualMachines, developer, media, documents, appData, caches, other }`
  - `public static func ContentKind.classify(_ relativePath: String) -> ContentKind?`: nil means "no rule matches here, look deeper".
  - `public static func ContentKind.totals(in index: ScanIndex) -> [ContentKind: UInt64]`: walks from the root. At each folder, if `classify(path)` matches, the whole subtree's `totalAllocated` goes to that kind and the walk stops there. Otherwise it adds the folder's direct bytes (small files plus its big files) to `.other` and descends.

Rules, with paths relative to the scanned root. Matching is case-insensitive on whole path components, and `*` matches one component. The **first** matching rule wins, in this order:
1. `developer`: `*/Library/Developer`, `Users/*/Library/Developer`, any component `node_modules`, `Users/*/.gradle`, `Users/*/.cargo`, `Users/*/.rustup`
2. `virtualMachines`: `Users/*/Library/Containers/com.docker.docker`, `Users/*/Library/Group Containers/group.com.docker`, `Users/*/.orbstack`, `Users/*/Parallels`, `Users/*/Virtual Machines.localized`, `Users/*/Library/Containers/com.utmapp.UTM`
3. `caches`: `Library/Caches`, `Users/*/Library/Caches`, `Users/*/.cache`, `private/var/folders`
4. `media`: `Users/*/Pictures`, `Users/*/Movies`, `Users/*/Music`
5. `documents`: `Users/*/Documents`, `Users/*/Desktop`, `Users/*/Downloads`, `Users/*/Library/Mail`
6. `apps`: `Applications`, `Users/*/Applications`
7. `appData`: `Users/*/Library/Application Support`, `Users/*/Library/Containers`, `Users/*/Library/Group Containers`, `Library/Application Support`

`other` is never returned by `classify`; it collects everything unmatched. Its color is `#8E8E93`, a neutral grey distinct from Caches (the spec has no "other" color; this is this plan's call).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func rulesInOrder() {
    #expect(ContentKind.classify("Users/u/Library/Developer") == .developer)
    #expect(ContentKind.classify("Users/u/Documents/app/node_modules") == .developer)
    #expect(ContentKind.classify("Users/u/Library/Containers/com.docker.docker") == .virtualMachines)
    #expect(ContentKind.classify("Users/u/Library/Containers/com.apple.Notes") == .appData)
    #expect(ContentKind.classify("Users/u/library/caches") == .caches)
    #expect(ContentKind.classify("Users/u/Pictures") == .media)
    #expect(ContentKind.classify("Users/u/Downloads") == .documents)
    #expect(ContentKind.classify("Applications") == .apps)
    #expect(ContentKind.classify("Users/u") == nil)
    #expect(ContentKind.classify("") == nil)
}
@Test func totalsStopAtFirstMatchAndCollectOther() async throws {
    let root = try Fixtures.tree(["Users/u/Pictures/a.jpg": 2_000_000, "Users/u/Pictures/x/node_modules/m": 1_500_000,
                                  "Users/u/loose.bin": 1_200_000, "Applications/A.app/bin": 3_000_000])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let t = ContentKind.totals(in: idx)
    #expect(t[.media] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Pictures")))
    #expect(t[.apps] == Fixtures.sumAllocated(under: root.appending(path: "Applications")))
    #expect(t[.other] == Fixtures.allocatedSize(root.appending(path: "Users/u/loose.bin")))
    #expect(t.values.reduce(0, +) == idx.folders[0].totalAllocated)
}
```

- [ ] **Step 2: Run** `swift test --filter ContentKindTests`. Expected: build fails (`ContentKind` not defined).
- [ ] **Step 3: Implement** `ContentKind.swift`. Keep the rules as a static array of `(ContentKind, [String])` patterns, with path components split once.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: classify folders by content type`

---

### Task 2: Drive summary from LiveIndex

**Files:**
- Create: `Sources/DiskEngine/DriveSummary.swift`
- Modify: `Sources/DiskEngine/History.swift` (`Day.date(in:)` uses hour 12)
- Test: `Tests/DiskEngineTests/DriveSummaryTests.swift`

**Interfaces:**
- Consumes: `LiveIndex` (locked work pattern from Plan 2), `ChangeReport`, `HistoryStore`, `ContentKind.totals`.
- Produces:
  - `public struct DriveSummary: Codable, Sendable, Equatable { var scannedBytes: UInt64; var kinds: [ContentKind: UInt64]; var changes: [Change]; var net: Int64?; var period: Int; var updatedAt: Date }`. `net` is the root's size change over the period, nil when there is no history. `changes` holds at most 5 entries. `Change` gains `Codable`.
  - `extension LiveIndex { public func summary(since days: Int, now: Date = .now) async throws -> DriveSummary }`: takes the lock, so it never sees a half-applied index (Plan 2 deferred minor).
  - `extension DriveSummary { static func load(from store: URL, period: Int) -> DriveSummary?; func save(to store: URL) throws }`. File: `summary-<period>.json`, written atomically.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func summaryHasKindsChangesAndNet() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/": 0]); let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
    #expect(try await live.summary(since: 1).net == nil)
    try await live.recordHistory(now: .now.addingTimeInterval(-86_400))
    try Fixtures.write(root.appending(path: "Users/u/Movies/clip.mov"), bytes: 600_000_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/Users/u/Movies", id: next, rescanSubtree: false, historyLost: false)])
    let s = try await live.summary(since: 1)
    #expect(s.kinds[.media] == Fixtures.sumAllocated(under: root.appending(path: "Users/u/Movies")))
    #expect(s.changes.first?.path == "Users/u/Movies/clip.mov")
    #expect((s.net ?? 0) > 400_000_000)
    try s.save(to: store)
    #expect(DriveSummary.load(from: store, period: 1) == s)
    try await live.close()
}
@Test func dayIsStableAcrossMidnightDST() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Santiago")!
    let d = Day(cal.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!, calendar: cal)
    #expect(d.adding(days: 1, calendar: cal) == Day(cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!, calendar: cal))
}
@Test func decomposedUnicodeFolderIsFoundFromEventPath() async throws {
    let name = "Cafe\u{301}"                       // "Café" in decomposed form
    let root = try Fixtures.tree(["\(name)/f": 10]); let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
    try Fixtures.write(root.appending(path: "\(name)/g.bin"), bytes: 1_200_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/Caf\u{E9}", id: next, rescanSubtree: false, historyLost: false)])
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
```

The last test pins one of Plan 2's declined-to-judge items. FSEvents may hand back either Unicode form. `ScanIndex.folder(atRelativePath:)` must compare names with Swift `String` equality, which treats canonically equivalent forms as equal, not with raw bytes.

- [ ] **Step 2: Run** `swift test --filter DriveSummaryTests`. Expected: build fails (`summary` not defined).
- [ ] **Step 3: Implement** `DriveSummary.swift` and the `Day` noon change. If the Unicode test fails, fix `folder(atRelativePath:)` and keep the test.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: per-drive summary for the dropdown`

---

### Task 3: App skeleton and menu bar label

**Files:**
- Modify: `Package.swift` (add the `DiskApp` library depending on `DiskEngine`, the `Diskinventory` executable depending on `DiskApp`, and the `DiskAppTests` test target)
- Create: `Sources/DiskApp/AppIdentity.swift`, `Sources/DiskApp/Format.swift`, `Sources/DiskApp/Palette.swift`, `Sources/DiskApp/MenuBarLabel.swift`, `Sources/Diskinventory/main.swift`, `Sources/Diskinventory/AppDelegate.swift`, `Sources/Diskinventory/StatusIcon.swift`, `scripts/make-app.sh`
- Test: `Tests/DiskAppTests/MenuBarLabelTests.swift`, `Tests/DiskAppTests/FormatTests.swift`

**Interfaces:**
- Produces:
  - `public enum AppIdentity { static let name = "Diskinventory"; static let bundleID = "com.ooozzy.diskinventory"; static func storeBase() throws -> URL }` (`~/Library/Application Support/Diskinventory`, created).
  - `public enum Format { static func gb(_ bytes: UInt64) -> String; static func signedGB(_ delta: Int64) -> String; static func ago(_ date: Date, now: Date) -> String; static func shortDate(_ date: Date) -> String }`
    - `gb(82_400_000_000) == "82 GB"` when ≥ 10 GB (no decimal), `gb(9_240_000_000) == "9.2 GB"`, `gb(600_000_000) == "0.6 GB"`.
    - `signedGB(8_100_000_000) == "+8.1 GB"`, `signedGB(-600_000_000) == "−0.6 GB"` (U+2212).
    - `ago`: `"just now"` under 60 s, `"2 min ago"`, `"3 h ago"`, `"yesterday"`, then `shortDate` (`"Oct 20"`).
  - `public enum LabelLevel: Sendable { case normal, low, critical }`
  - `public struct MenuBarLabel: Equatable, Sendable { let text: String; let level: LabelLevel; let fillFraction: Double; static func make(space: VolumeSpace, showNumber: Bool) -> MenuBarLabel }`. `fillFraction` = used / total. Free means `availableForImportantUsage`, the number Finder shows. `level` is `.critical` below 5% free and `.low` below 15%.
  - `Palette`: `static func color(_ kind: ContentKind) -> Color`, `static let growth`, `static let freed`, `static let tints: [Color]` (8, internal first), `static let other = Color(hex: 0x8E8E93)`.
  - `StatusIcon.image(fill: Double, level: LabelLevel) -> NSImage`: a 13 pt ring with a 2.5 pt stroke, filled clockwise from 12 o'clock. It is a template image at `.normal`, and amber `#E8A33D` or red `#E5484D` otherwise.
  - The `AppDelegate` creates the status item, sets image and title from `MenuBarLabel` for the internal Data volume, and refreshes every 60 s and on wake (`NSWorkspace.didWakeNotification`). A right-click menu has one item, "Quit Diskinventory" (⌘Q).
  - `scripts/make-app.sh [debug|release]`: builds the product and writes `.build/Diskinventory.app` with `Contents/MacOS/Diskinventory` and `Contents/Info.plist` (`CFBundleIdentifier`, `CFBundleName`, `LSUIElement` = true, `LSMinimumSystemVersion` = 14.0, `CFBundleShortVersionString` = 0.1). Then `codesign --force --sign - --deep`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func formatting() {
    #expect(Format.gb(82_400_000_000) == "82 GB")
    #expect(Format.gb(9_240_000_000) == "9.2 GB")
    #expect(Format.signedGB(8_100_000_000) == "+8.1 GB")
    #expect(Format.signedGB(-600_000_000) == "\u{2212}0.6 GB")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Format.ago(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(Format.ago(now.addingTimeInterval(-120), now: now) == "2 min ago")
}
@Test func labelLevels() {
    let gb: UInt64 = 1_000_000_000
    // 82 GB of 1000 GB free is 8.2%: below 15% (amber), not below 5% (red).
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 50*gb, availableForImportantUsage: 82*gb), showNumber: true)
        == MenuBarLabel(text: "82 GB", level: .low, fillFraction: 0.918))
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 30*gb, availableForImportantUsage: 40*gb), showNumber: true).level == .critical)
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 300*gb, availableForImportantUsage: 300*gb), showNumber: true).level == .normal)
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 300*gb, availableForImportantUsage: 300*gb), showNumber: false).text == "")
}
```

- [ ] **Step 2: Run** `swift test --filter "MenuBarLabelTests|FormatTests"`. Expected: build fails.
- [ ] **Step 3: Implement** the files listed. `main.swift` makes `NSApplication.shared`, sets the delegate, `setActivationPolicy(.accessory)`, and runs.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Verify by hand.** Run `scripts/make-app.sh debug && open .build/Diskinventory.app`. Expected: the ring and free-space number appear in the menu bar, there is no Dock icon, and right-click → Quit exits. Take `screencapture -R` of the menu bar area into the scratchpad and look at it.
- [ ] **Step 6: Commit** `feat: menu bar app skeleton with free-space ring`

---

### Task 4: Drives: catalog and registry

**Files:**
- Create: `Sources/DiskApp/VolumeCatalog.swift`, `Sources/DiskApp/DriveRegistry.swift`
- Test: `Tests/DiskAppTests/VolumeCatalogTests.swift`, `Tests/DiskAppTests/DriveRegistryTests.swift`

**Interfaces:**
- Produces:
  - `public struct VolumeInfo: Sendable, Equatable { let url: URL; let uuid: String; let name: String; let isInternalData: Bool; let device: dev_t }`
  - `public enum VolumeCatalog { static func isDrive(isInternal: Bool, isLocal: Bool, isBrowsable: Bool, isRootFileSystem: Bool, isReadOnly: Bool) -> Bool; static func current() -> [VolumeInfo] }`. `isDrive` is true for local, browsable, writable, non-root, non-internal volumes. The internal Data volume is always added first by `current()`, from `/System/Volumes/Data`. Read-only volumes such as mounted installers and disk images are excluded.
  - `public struct KnownDrive: Codable, Sendable, Equatable { let uuid: String; var name: String; var tintIndex: Int; var lastSeen: Date; var lastFree: UInt64?; var lastTotal: UInt64? }`
  - `public final class DriveRegistry { init(file: URL); func upsert(_ v: VolumeInfo, space: VolumeSpace?, now: Date) throws -> KnownDrive; func all() -> [KnownDrive]; func forget(uuid: String) throws }`. The internal drive always has `tintIndex` 0. Each new external takes the lowest unused index from 1 to 7, then wraps around. The file is `drives.json` under the store base, written atomically.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func catalogFilter() {
    #expect(VolumeCatalog.isDrive(isInternal: false, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
    #expect(!VolumeCatalog.isDrive(isInternal: false, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: true))
    #expect(!VolumeCatalog.isDrive(isInternal: false, isLocal: false, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
    #expect(!VolumeCatalog.isDrive(isInternal: true, isLocal: true, isBrowsable: true, isRootFileSystem: false, isReadOnly: false))
}
@Test func currentAlwaysStartsWithInternalData() {
    #expect(VolumeCatalog.current().first?.isInternalData == true)
}
@Test func sameNameDifferentUUID() throws {
    let reg = DriveRegistry(file: try Fixtures.tempDir().appending(path: "drives.json"))
    let a = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled"), uuid: "A", name: "Untitled", isInternalData: false, device: 10), space: nil, now: .now)
    let b = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled 1"), uuid: "B", name: "Untitled", isInternalData: false, device: 11), space: nil, now: .now)
    #expect(a.tintIndex == 1 && b.tintIndex == 2)
    #expect(reg.all().count == 2)
    let again = try reg.upsert(.init(url: URL(filePath: "/Volumes/Untitled"), uuid: "A", name: "Renamed", isInternalData: false, device: 12), space: nil, now: .now)
    #expect(again.tintIndex == 1 && again.name == "Renamed")
}
@Test func registryPersists() throws {
    let file = try Fixtures.tempDir().appending(path: "drives.json")
    _ = try DriveRegistry(file: file).upsert(.init(url: URL(filePath: "/"), uuid: "I", name: "Macintosh HD", isInternalData: true, device: 1), space: nil, now: .now)
    #expect(DriveRegistry(file: file).all().first?.tintIndex == 0)
}
```

`DiskAppTests` gets its own `Fixtures.tempDir()` helper. It is the same few lines as the engine tests' version.

- [ ] **Step 2: Run** `swift test --filter "VolumeCatalogTests|DriveRegistryTests"`. Expected: build fails.
- [ ] **Step 3: Implement** both files. `current()` uses `FileManager.mountedVolumeURLs(includingResourceValuesForKeys:options: .skipHiddenVolumes)` with `volumeIsInternal`, `volumeIsLocal`, `volumeIsBrowsable`, `volumeIsRootFileSystem`, `volumeIsReadOnly`, `volumeUUIDString` and `volumeName`. Volumes without a UUID are skipped.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: drive catalog and registry`

---

### Task 5: DriveController: warm and cold index

**Files:**
- Create: `Sources/DiskApp/DriveController.swift`
- Test: `Tests/DiskAppTests/DriveControllerTests.swift`

**Interfaces:**
- Consumes: `LiveIndex`, `DriveSummary`, `VolumeInfo`, `VolumeSpace`, `EventWatcher.journalUUID`.
- Produces:
  - `public enum DriveActivity: Equatable, Sendable { case idle, opening, scanning, ready, offline }`
  - `@MainActor public final class DriveController: ObservableObject`:
    - `init(volume: VolumeInfo, store: URL, coolDown: Duration = .seconds(300))`
    - `@Published private(set) var summary: DriveSummary?`. It is loaded from the cache in `init`, so it can be shown at once.
    - `@Published private(set) var space: VolumeSpace?`, `@Published private(set) var activity: DriveActivity`
    - `@Published var period: Int` (1, 7 or 30). Changing it loads that period's cached summary and, if warm, refreshes.
    - `var hasJournal: Bool` (`journalUUID(device:) != nil`).
    - `func warm() async`: opens the `LiveIndex` if needed, shows `.scanning` when it opens with `.fullScan`, refreshes `summary` and `space`, saves the summary cache, and restarts the cool-down timer. Calling it again while warm only refreshes.
    - `func cool() async`: records history if today's day is missing, closes the index, and sets `.idle`.
    - `func recordDailyHistoryIfNeeded() async`: on the internal drive, warms briefly to record today's history, then cools.
    - `func willUnmount() async`: cancels the timer, closes the index **before returning**, and sets `.offline`.
    - `func refreshSpace()`: reads `VolumeSpace` only and never warms the index.
    - The cool-down fires `coolDown` after the last `warm()`. Externals only warm when `warm()` is called (spec 6.3). Nothing calls `warm()` on a timer.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func warmThenCoolReleasesIndex() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/m.mov": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir(), coolDown: .milliseconds(200))
    await c.warm()
    #expect(c.activity == .ready)
    #expect(c.summary?.kinds[.media] != nil)
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .idle)
}
@MainActor @Test func cachedSummaryShowsBeforeWarm() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let first = DriveController(volume: try Fixtures.volume(root), store: store)
    await first.warm(); await first.cool()
    let second = DriveController(volume: try Fixtures.volume(root), store: store)
    #expect(second.summary?.scannedBytes == first.summary?.scannedBytes)
    #expect(second.activity == .idle)
}
@MainActor @Test func willUnmountClosesWarmIndex() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.warm()
    await c.willUnmount()
    #expect(c.activity == .offline)
    #expect(FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}
@MainActor @Test func exFATScansOnlyWhenSelected() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    c.refreshSpace()
    #expect(c.space != nil)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}
```

`Fixtures.volume(_ root: URL) -> VolumeInfo` builds a `VolumeInfo` for a temp folder (real device, UUID `"test-" + UUID`, `isInternalData` false). The exFAT test pins the rule "nothing scans until `warm()`": the controller must not open the index from `init` or `refreshSpace()`.

- [ ] **Step 2: Run** `swift test --filter DriveControllerTests`. Expected: build fails.
- [ ] **Step 3: Implement** `DriveController.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: drive controller keeps the index warm only while used`

---

### Task 6: Dropdown model

**Files:**
- Create: `Sources/DiskApp/DropdownModel.swift`
- Test: `Tests/DiskAppTests/DropdownModelTests.swift`

**Interfaces:**
- Consumes: `KnownDrive`, `DriveSummary`, `VolumeSpace`, `DriveActivity`, `Format`, `ContentKind`.
- Produces: pure values the view draws, built by `static func DropdownModel.make(drives: [KnownDrive], selected: String, connected: Set<String>, summary: DriveSummary?, space: VolumeSpace?, activity: DriveActivity, period: Int, connectedSince: Date?, now: Date) -> DropdownModel`:
  - `tabs: [Tab]` where `Tab { uuid; name; tintIndex; isSelected; isOffline }`. The internal drive comes first, then the others by `lastSeen`, newest first.
  - `freeTitle: String`. When connected: `"82 GB free"`. When offline: `"Not connected"`.
  - `freeDetail: String`: `"of 994 GB, 61 GB more reclaimable"`. The second clause is left out when reclaimable is under 1 GB. When offline: `"Last seen Oct 20, 212 GB free then"`.
  - `bar: [BarSegment]`. A `BarSegment` is `{ kind: SegmentKind; fraction: Double }`, and `SegmentKind` is `.content(ContentKind)`, `.reclaimable`, or `.free`. The segments are, in order: each `ContentKind` with bytes in this order (`appData, virtualMachines, developer, media, apps, documents, caches, other`), then reclaimable, then free. `other` also absorbs used space the index did not see: `used − Σkinds − reclaimable`, floored at 0. The fractions sum to 1 (±0.001).
  - `legend: [ContentKind]`: the kinds present, in bar order. Reclaimable is shown separately, with its ruled swatch, when it is above 0.
  - `rows: [Row]` where `Row { kind: ContentKind; name: String; location: String; delta: String; isGrowth: Bool }`. `name` is the last path component. `location` is the parent's last component, or `""` at the root. `kind` comes from `ContentKind.classify` on the deepest matching prefix (`.other` if none). At most 5 rows.
  - `netLabel: String`: `"Net today"`, `"Net this week"` or `"Net this month"`, matching period 1, 7 or 30.
  - `netValue: String`: free space moves opposite to size. A net of +14.2 GB gives `"−14.2 GB free"` and is shown as growth.
  - `emptyMessage: String?`:
    - activity `.scanning` with no summary: `"Scanning this drive for the first time. Free space is already up to date."`
    - a summary with `net == nil`: `"No history yet. Changes show up from tomorrow."`
    - `rows` empty: `"Nothing changed by more than 0.1 GB."`
  - `footerLeft: String`:
    - internal: `"Updated " + Format.ago(updatedAt)`
    - `.opening` or `.scanning`: `"Updating…"`
    - external: `"Connected " + Format.ago(connectedSince)`
  - `footerRight: FooterAction`: `.settings` on the internal drive, `.eject` on a connected external, `.none` offline.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

Add these helpers to the `DiskAppTests` `Fixtures`: `internalDrive` (uuid `"I"`, "Macintosh HD", tint 0), `t7(lastSeen:lastFreeGB:)` (uuid `"T7"`, "Samsung T7", tint 1), `summary(net:changes:)`, and `space(totalGB:freeGB:reclaimableGB:)`. `space` builds a `VolumeSpace` where `availableForImportantUsage` = free and `available` = free − reclaimable.

- [ ] **Step 2: Run** `swift test --filter DropdownModelTests`. Expected: build fails.
- [ ] **Step 3: Implement** `DropdownModel.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: dropdown model`

---

### Task 7: Dropdown panel and view

**Files:**
- Create: `Sources/Diskinventory/DropdownPanel.swift`, `Sources/Diskinventory/DropdownView.swift`
- Modify: `Sources/Diskinventory/AppDelegate.swift`

**Interfaces:**
- Consumes: `DropdownModel`, `DriveController`, `DriveRegistry`, `VolumeCatalog`, `Palette`.
- Produces:
  - `final class DropdownPanel: NSPanel`: borderless, `.nonactivatingPanel`, `hidesOnDeactivate`, `level = .popUpMenu`, 10 pt corner radius, and a shadow. It sits right below the status item button, with its right edge aligned to the button and clamped to the screen. It closes when it resigns key or on Esc.
  - `struct DropdownView: View` takes `model: DropdownModel` plus callbacks `select(uuid)`, `setPeriod(Int)` and `eject()`. Layout, colors and copy match `docs/superpowers/specs/2026-10-28-mockups/dropdown-flat.html` section by section: tabs, free space, disk bar with key, what changed with the segmented control, footer. The actions row (Open map, Review to clear) is **not** in this plan, because the window and basket come in Plans 4 and 5.
  - The AppDelegate wires it together:
    - **Left click** toggles the panel. Opening it calls `warm()` on the selected drive.
    - **Mounts:** `didMountNotification` and `didUnmountNotification` refresh the catalog and registry. `willUnmountNotification` calls `willUnmount()` and waits for it.
    - **Eject:** `NSWorkspace.shared.unmountAndEjectDevice(at:)`, after `willUnmount()`.
    - **History timer:** an hourly `Timer` on the internal controller calls `recordDailyHistoryIfNeeded()`.
  - Reclaimable bar segment: a ruled pattern drawn with SwiftUI `Canvas`, using 1 pt lines every 3 pt in the secondary label color at 55% opacity.

- [ ] **Step 1: Verify the panel by hand.** No unit test fits pixel layout. The model is what the tests cover.

Run: `scripts/make-app.sh debug && open .build/Diskinventory.app`, then click the icon.
Expected:
- The panel opens under the icon within 100 ms, showing cached data or the first-scan message.
- In light and dark mode (switch with System Settings › Appearance), a `screencapture -l <windowid>` of the panel placed next to the mockup shows the same sections, order and copy.
- Pressing Esc closes it, and so does clicking elsewhere.
- Plug in a USB drive: a new tab appears. Select it: it scans (journaled) or shows the first-scan message. Click Eject: the drive ejects without a "disk in use" alert, and the tab turns dimmed.

Save the screenshots in the scratchpad and compare them visually.
- [ ] **Step 2: Run** `swift test`. Expected: all still pass.
- [ ] **Step 3: Commit** `feat: dropdown panel`

---

### Task 8: Launch at login, idle memory, and end-to-end check

**Files:**
- Modify: `Sources/Diskinventory/AppDelegate.swift`
- Test: `Tests/DiskAppTests/LoginItemTests.swift`

**Interfaces:**
- Produces:
  - `enum LoginItem { static func registerOnFirstRun(defaults: UserDefaults, register: () throws -> Void) rethrows }`: calls `register` once (spec 5: on by default after first run), then sets `didRegisterLoginItem`. The app passes `{ try SMAppService.mainApp.register() }`. An error is logged and does not crash the app (ad-hoc builds may be refused).

- [ ] **Step 1: Write the failing test**

```swift
@Test func registersOnlyOnce() throws {
    let d = UserDefaults(suiteName: "test-\(UUID())")!
    var calls = 0
    try LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    try LoginItem.registerOnFirstRun(defaults: d) { calls += 1 }
    #expect(calls == 1)
}
```

- [ ] **Step 2: Run** `swift test --filter LoginItemTests`. Expected: build fails.
- [ ] **Step 3: Implement** and call it from `applicationDidFinishLaunching`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Measure end to end.**

Run: `scripts/make-app.sh release && open .build/Diskinventory.app`. Open the dropdown once, close it, wait 6 minutes, then run `footprint -p $(pgrep -x Diskinventory)`.
Expected:
- Idle footprint is **under 40 MB** (spec 7).
- Opening the dropdown again shows content within 100 ms (watch the "Updating…" footer), and the rows refresh within a few seconds.

Record both numbers in the commit body. If idle is over 40 MB, run `heap $(pgrep -x Diskinventory) | head -40`, record the top allocations, and stop and report. Don't tune blindly.
- [ ] **Step 6: Commit** `feat: launch at login, measured idle memory`
