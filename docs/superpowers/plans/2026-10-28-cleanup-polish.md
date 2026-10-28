# Cleanup and Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safe cleanup and a shippable app. Junk lenses find space that is safe to clear. A basket and a review sheet move what the user picks to the Trash and nothing else. The plan also adds Full Disk Access onboarding, a Settings window, an eject that waits for the index to close, a quieter idle CPU with the map open, and a release script for signing and notarization.

**Architecture:** Lens rules are bundled JSON. `LensMatcher` walks one drive's index under the `LiveIndex` lock, so it runs off the main thread. It matches each folder name with a small state machine per rule and stops at the outermost hit, so no byte counts twice. `Basket`, `ReviewSheet` and `Trasher` are plain `DiskApp` types, tested with a fixture trash backend. The only call to `FileManager.trashItem` lives in the `Diskinventory` executable target, so no test can reach it. `DriveController` owns the lens report and the trash-then-relist step. The map window and the dropdown only display them. The engine gains folder exclusions, a retry of unreadable folders, per-folder coalescing of FSEvents churn, and an `IndexChange` stream that says which folders moved by how much. The map uses that stream to skip builds nobody would see. A DiskArbitration approval callback holds a Finder eject for at most 2 s while the index closes.

**Tech Stack:** Swift 6.3, AppKit, SwiftUI, DiskArbitration, ServiceManagement (`SMAppService`), Swift Testing, `codesign`, `xcrun notarytool`, `xcrun stapler`.

**Spec:** `docs/superpowers/specs/2026-10-28-disk-inventory-design.md`. This plan covers sections 3.4 and 3.5, the parts of 3.2 and 3.3 tied to them ("Review N GB to clear", "Add to basket ⌫", drag), 4 (user-chosen drive tints) and 5 (Full Disk Access, settings, distribution). Visual targets: `docs/superpowers/specs/2026-10-28-mockups/main-window-flat.html` (basket bar) and `dropdown-flat.html` (actions row). It builds on Plans 1 to 4, which are merged to `main`. The previous plan is `docs/superpowers/plans/2026-10-28-full-window.md`; its Decisions still hold unless one below replaces them.

## Decisions this plan makes (founder to check)

1. **Lens rules ship as `Sources/DiskApp/Resources/lenses.json`.** `make-app.sh` copies the file to `Contents/Resources/`. The loader reads `Bundle.main` first and falls back to `Bundle.module` for `swift test`. SwiftPM's own accessor looks for its bundle at the `.app` root, where code signing does not allow it.
2. **Pattern language:** lowercased path components relative to the drive root. `*` matches one component, a glob such as `*.fcpbundle` matches within one component, and `**` matches any number of components, anywhere. When rules match the same folder, the one with more literal components wins, then the one listed first. Walking from the root, the first folder that matches a rule is the hit, and the walk does not go below it, so nothing is counted twice.
3. **Safety levels beyond the spec:** Xcode archives, old installers and Final Cut proxies are `review`. Simulators, the Photos library, `~/.Trash` and a drive's `.Trashes` are `app-managed`, because the Trash is shown and never trashed. Everything else in the spec's set is `regenerates`.
4. **Old installers** are stored files in `~/Downloads` matching `*.dmg` or `*.pkg`, last modified more than 30 days ago. The matcher reads the modification time with `lstat` at match time, because the index does not store it. File rules get no hover note, since a hover cannot check the age.
5. **Hits under 1 MB are dropped,** and each drive keeps at most its 2,000 largest hits. Totals add up only the hits that are kept, so "Review N GB" always equals what the pre-fill adds.
6. **`KnownItems` is deleted.** Hover-card explanations come from the lens rules: the explanation, then the instruction when there is one. A contents rule such as `Users/*/Library/Caches/*` also explains its parent folder.
7. **The lens report is cached per index generation.** It is recomputed when the drive warms, and right after a move to the Trash.
8. **"Review N GB to clear" appears only for a connected drive with at least 0.1 GB of `regenerates` hits.** It opens the map window with the review sheet already showing, pre-filled with those hits.
9. **One basket per drive, in memory only.** It is cleared when the drive disconnects and lost at quit.
10. **A folder in the basket swallows anything inside it.** Small-file and "more" buckets, and the drive root, can't be added.
11. **Drag is in-window only.** The window tracks the mouse itself, with no `NSDraggingSession` and no pasteboard, so a block can never be dropped on Finder or on the Dock's Trash. It starts after 4 pt of movement.
12. **Every trashable item starts checked.** App-managed items show their instruction instead of a checkbox, and `Trasher` refuses them even when called directly.
13. **After a move the sheet says "Freed X GB",** with the line "It stays in the Trash until you empty it." That keeps the number honest (spec 2, anti-goals).
14. **`Trasher` refuses any item whose parent folder no longer resolves inside the drive root.** For example, a folder swapped for a symlink. A symlink item is trashed as a link and never followed.
15. **After a move, the moved items' parent folders are relisted at once,** rather than waiting for FSEvents, so every view updates immediately (spec 3.4).
16. **Full Disk Access probe:** open `/Library/Application Support/com.apple.TCC/TCC.db`, then `~/Library/Safari`, then `~/Library/Mail`. `EPERM` or `EACCES` means denied, and success means granted. If no probe gives an answer, the status is `unknown`, which is treated as granted so the app never nags.
17. **The Full Disk Access explainer shows once,** at the first launch where access is denied. While access stays denied, the dropdown keeps a one-line note with an "Allow" button.
18. **Unreadable folders have no size,** so the Metal map cannot draw them. The side list shows them as "Can't read" rows after the sized rows, and a line under the list header counts them. They are retried each time a drive's index opens while access is not denied.
19. **Settings is one window with four sections:** Menu bar, Warnings, Drives, Skipped folders. Values are stored as JSON in `UserDefaults` under `settings.v1`. Tints stay in `drives.json`. `KnownDrive` gains `isInternal`, so any drive can take any of the 8 tints.
20. **Thresholds:** amber can be set from 2% to 50%, and red from 1% to one less than amber. The defaults are 15% and 5% (spec 3.1).
21. **Skipped folders are absolute paths in settings,** mapped onto each drive. On the Data volume, a firmlinked path such as `/Users/u/VMs` maps to `Users/u/VMs`. A change relists only the affected parents and never runs a full scan. FSEvents inside a skipped folder are dropped, and its space counts as Other.
22. **The Settings window, like the map window, makes the app regular** (Dock icon) while it is open.
23. **Eject hold:** a DiskArbitration unmount-approval callback blocks for at most 2 s while the drive's index closes, then always approves. It never dissents, so the app can never be the reason an eject fails.
24. **A refused eject:** the map window reattaches to the replacement controller when the window next becomes key, or at once when the app's own eject fails. Nothing runs on a timer.
25. **Idle CPU:** the watcher latency goes from 2 s to 3 s. A folder is relisted at once on its first event, then at most once per 10 s. The stored event ID stays below the oldest deferred change, so quitting loses nothing (spec 6.6).
26. **Map builds are skipped for changes outside the zoomed folder** and for changes worth less than 1 pt² of map area (they add up until one is due). Builds also wait while the window is occluded.
27. **CPU targets with the map open and the machine idle:** at most 3% averaged over 120 s in a debug build (11.7% today), and at most 1.5% in a release build.
28. **Sparkle stays out.** The constraint is no third-party dependencies, and a feed URL and EdDSA keys are needed. `docs/release.md` lists the integration steps for when the founder supplies them.
29. **`scripts/release.sh` reads `DEVELOPER_ID_APPLICATION`, `TEAM_ID` and `NOTARY_PROFILE`,** plus optional `VERSION`, `BUILD_NUMBER` and `DRY_RUN`. If one of the required three is missing, it exits 64 and names it.
30. **No entitlements are needed:** hardened runtime, not sandboxed (Full Disk Access needs that), no exceptions. Dev builds are also signed ad hoc with the hardened runtime and the same file, so a runtime difference shows up before release.
31. **Deferred fixes are folded into the tasks that touch the same code.** A failed `statfs` now fails `open()` (Task 9). `reportsAFolderThatChanged` starts from a concrete event ID and matches exact paths (Task 9). A refused eject reattaches the map window (Task 8).

## Global Constraints

From the full-window plan, still in force:
- Every public struct in `DiskApp` that this plan adds has a public memberwise init, because the tests build them by hand.
- macOS 14 or newer. Swift 6 language mode. No third-party dependencies.
- Working app name: **Diskinventory**, bundle ID `com.ooozzy.diskinventory`, both defined once (`AppIdentity.swift` and `scripts/make-app.sh`).
- Store: `~/Library/Application Support/Diskinventory/Volumes/<volume UUID>/`. Internal disk root: `/System/Volumes/Data`.
- Content-type colors (spec 4): Apps `#4C7CE0`, Virtual machines `#2E9FC4`, Developer `#7A5FD6`, Photos and video `#D45C7E`, Mail and documents `#D9893A`, App data `#3E9E7A`, Caches `#6B7183`, other `#8E8E93`. Small files: the label color at 22% opacity. Growth `#E8805F`, freed `#3FA67F`.
- Drive tints: internal `#8B7BFF`; externals in order `#0FA39B`, `#E0884F`, `#4C9BE0`, `#D2589A`, `#6BA34A`, `#B08A3E`, `#7E8796`. They are used on the drive chip and the selection highlight.
- Shape (spec 4): 4 pt block corners, 2 pt gutters, 5 to 6 pt controls, 10 pt window. No gradients, glow or scale. The only pattern is the fine ruled one, for reclaimable space and growth.
- Sizes are decimal (1 GB = 1,000,000,000 bytes) via `Format.gb`, and negatives use the true minus `−` (U+2212).
- Native macOS window chrome. Dark and light follow the system.
- Nothing warms on a timer. External drives are never scanned or woken on a timer (spec 6.3). The window keeps an index warm by holding it, never by polling.
- **The main thread is never blocked by app work for more than 16 ms** (spec 7). Layout, index reads, snapshot building, instance building and label rasterization all run off main.
- **Zoom runs at display refresh rate with no dropped frames on Apple silicon** (spec 7). Frame to frame, only a uniform changes. It takes about 200 ms and is off when Reduce Motion is on.
- Window open on a 5-million-file disk: **under 150 MB resident** (spec 7). On close, the window and its map data are released, and the Dock icon shows only while a window is open (spec 5).
- Layout (spec 6.5): squarified, children sorted by size descending, current zoom level only. Anything under 2 pt folds into the parent's small-files block. At most 50,000 rectangles; past that, the smallest siblings merge into "N more items".
- Metal draws only the treemap: blocks, labels, hover outline, dimming, growth strip. Everything else is SwiftUI/AppKit.

New in this plan:
- **Nothing is ever deleted except by "Move N items to Trash" in the review sheet, after explicit review.** The only deletion is `FileManager.trashItem`, called only from `SystemTrash` in the `Diskinventory` target. The dropdown never deletes anything (spec 3.2).
- **The app never empties the Trash** (spec 3.4).
- **Tests only touch fixtures under `$TMPDIR/DiskinventoryTests`** (see `Tests/*/RunRoot.swift`). No test calls `FileManager.trashItem`, writes `UserDefaults(suiteName:)` (that writes to `~/Library/Preferences`), or reads or writes anything else in the user's home.
- **Our code never blocks the main thread for more than 16 ms.** The lens walk, the trash moves, the Full Disk Access probe, exclusion relists and the unmount hold all run off main.
- Voice (spec 4): plain, short, a little dry. Explain what a thing is and what to do. The exact copy is fixed in the tasks below.

## Review Focus

1. **A basket item changes on disk between review and "Move to Trash".** It was deleted already, or a folder above it was swapped for a symlink that points somewhere else. Expected: the row reports "already gone" or "no longer on this drive", and nothing outside the drive is touched. Pinned in Task 2 (`itemGoneOrSwappedForSymlinkIsNotFollowed`).
2. **Some items can't be moved** (a root-owned cache folder, a parent without write permission). Expected: the others still move, each failure is listed with its reason, "Freed" counts only what moved, and the failed items stay in the basket. Pinned in Task 2 (`partialFailureReportsEachItem`).
3. **A folder and something inside it both end up in the basket** (the dropdown pre-fill, then ⌫ on a child, or the other way round). Expected: counted once, trashed once, and no false "already gone". Pinned in Task 2 (`nestedItemsCollapseIntoTheirFolder`).
4. **Lens rules overlap:** Yarn's cache inside `~/Library/Caches`, `node_modules` inside `node_modules` or inside DerivedData. Expected: each byte counts once in "Review N GB to clear", and the most specific rule names the item. Pinned in Task 1 (`overlappingRulesCountEachByteOnce`, `reportFindsHitsAndStopsAtTheOuterOne`).
5. **The drive is unplugged while the review sheet is open, or just before the move.** Expected: the button is disabled and a notice says so, and a move that starts after the unmount touches nothing. Pinned in Task 2 (`disconnectedDriveCannotTrash`) and Task 3 (`trashAfterUnmountTouchesNothing`).

## File map

```
Package.swift                                   DiskApp resources; DiskArbitration for the app (modify)
Sources/DiskApp/Resources/lenses.json           the rule list
Sources/DiskApp/Lens/LensRules.swift            LensSafety, LensRule, LensPattern, LensRules
Sources/DiskApp/Lens/LensMatcher.swift          LensHit, LensReport, LensMatcher
Sources/DiskApp/Basket/Basket.swift             BasketItem, Basket, BasketStore
Sources/DiskApp/Basket/BasketDrag.swift         in-window drag state
Sources/DiskApp/Basket/ReviewSheet.swift        ReviewRow, ReviewSheet
Sources/DiskApp/Basket/Trasher.swift            TrashBackend, TrashFailure, TrashOutcome, Trasher
Sources/DiskApp/Settings/AppSettings.swift      MenuBarStyle, AppSettings, SettingsStore
Sources/DiskApp/FullDiskAccess.swift            FDAStatus, probe, settings link
Sources/DiskApp/UnmountGate.swift               bounded unmount hold
Sources/DiskApp/Map/KnownItems.swift            (delete)
Sources/DiskApp/Map/HoverCard.swift, MapCommands.swift, MapSnapshot.swift, MapBuilder.swift, MapModel.swift (modify)
Sources/DiskApp/DriveController.swift, DropdownModel.swift, DriveRegistry.swift, LoginItem.swift,
    MenuBarLabel.swift, MainMenuSpec.swift      (modify)
Sources/DiskEngine/ScanIndex.swift              exclusions, relativePath(of:) (modify)
Sources/DiskEngine/LiveIndex.swift              exclusions, retryUnreadable, coalescing, IndexChange, stats (modify)
Sources/DiskEngine/EventWatcher.swift           latency 3 s (modify)
Sources/Diskinventory/SystemTrash.swift         the one FileManager.trashItem call
Sources/Diskinventory/UnmountApprover.swift     DiskArbitration approval callback
Sources/Diskinventory/AccessExplainer.swift     first-run Full Disk Access window
Sources/Diskinventory/Map/BasketBar.swift, ReviewSheetView.swift
Sources/Diskinventory/Settings/SettingsWindowController.swift, SettingsView.swift
Sources/Diskinventory/AppDelegate.swift, DropdownView.swift, DropdownPanel.swift,
    Map/MapWindowController.swift, Map/MapWindowView.swift, Map/TreemapMTKView.swift, Map/TreemapView.swift (modify)
scripts/make-app.sh (modify), scripts/release.sh, scripts/Diskinventory.entitlements
docs/release.md
Tests/DiskAppTests/LensTests.swift  BasketTests.swift  TrasherTests.swift  FixtureTrash.swift  SettingsTests.swift
    FullDiskAccessTests.swift  UnmountGateTests.swift  (MapText, MapModel, MapBuilder, DriveController, DropdownModel,
    DriveRegistry, LoginItem, MenuBarLabel, MainMenu tests and Fixtures.swift: modify)
Tests/DiskEngineTests/ExclusionTests.swift  CoalesceTests.swift  (LiveIndex, LiveIndexRead, EventWatcher tests: modify)
```

---

### Task 1: Junk lens rules and the matcher

**Files:**
- Create: `Sources/DiskApp/Resources/lenses.json`, `Sources/DiskApp/Lens/LensRules.swift`, `Sources/DiskApp/Lens/LensMatcher.swift`
- Modify: `Package.swift`, `Sources/DiskApp/Map/HoverCard.swift`, `scripts/make-app.sh`
- Delete: `Sources/DiskApp/Map/KnownItems.swift`
- Test: `Tests/DiskAppTests/LensTests.swift`, `Tests/DiskAppTests/MapTextTests.swift` (replace `knownItemsExplainThemselves`)

**Interfaces:**
- Produces:
  - `public enum LensSafety: String, Codable, Sendable, CaseIterable { case regenerates, review, appManaged = "app-managed" }`
  - `public struct LensRule: Codable, Equatable, Sendable { var id: String; var name: String; var pattern: String; var safety: LensSafety; var explanation: String; var instruction: String?; var files: [String]?; var minAgeDays: Int?; var hoverText: String }`. `hoverText` is `explanation`, plus `" " + instruction` when there is one. A rule with `files` is a **file rule**: its pattern names a folder, and the hits are that folder's stored files whose lowercased name matches one of the `files` globs. Every other rule is a **folder rule**, and the matched folder is the hit.
  - `public struct LensPattern: Equatable, Sendable { init(_ pattern: String); var literalCount: Int; func matches(_ relativePath: String) -> Bool }`. It has internal `start: UInt64`, `step(_ mask: UInt64, _ lowercasedName: String) -> UInt64` and `accepts(_ mask: UInt64) -> Bool` (the algorithm is below). Patterns over 63 components are rejected when the rules load.
  - `public struct LensRules: Sendable { let rules: [LensRule]; init(rules:); init(json: Data) throws; static let bundled: LensRules; func rule(id: String) -> LensRule?; func rule(covering relativePath: String) -> LensRule?; func explanation(for relativePath: String) -> String? }`.
    - `init(json:)` reads `{"version": 1, "rules": [...]}` and throws when the version is not 1.
    - `bundled` loads `Bundle.main.url(forResource: "lenses", withExtension: "json")`, falling back to `Bundle.module`. If both fail it is empty and logs once. A test guarantees that it loads.
    - `rule(covering:)` considers folder rules only. It walks the path's prefixes, shortest first, and returns the best rule (Decision 2) at the first prefix a rule accepts. If no prefix is accepted, it returns the best rule that would accept one more arbitrary component (`accepts(step(mask, "\u{1}"))`), which is how a contents rule's parent is covered.
    - `explanation(for:)` is `rule(covering:)?.hoverText`.
  - `public struct LensHit: Equatable, Sendable { var ruleID: String; var path: String; var name: String; var size: UInt64; var isFolder: Bool; var safety: LensSafety }`. `path` is relative to the drive root.
  - `public struct LensReport: Equatable, Sendable { var hits: [LensHit]; var generation: Int; func total(_ safety: LensSafety) -> UInt64 }`. `hits` are largest first.
  - `public enum LensMatcher { static func report(index: ScanIndex, rules: LensRules, generation: Int = 0, now: Date = .now, minBytes: UInt64 = 1_000_000, limit: Int = 2_000, modified: (String) -> Date? = LensMatcher.modificationDate) -> LensReport; static func modificationDate(_ absolutePath: String) -> Date? }`. `modificationDate` uses `lstat`'s `st_mtimespec`. `modified` receives `index.rootPath + "/" + relativePath`.
  - `HoverCard.make(node:size:period:rules: LensRules = .bundled)`. It uses `rules.explanation(for: node.key)` where it used `KnownItems`.

The rules file is exact copy (spec 3.5, plus `KnownItems`' Photos entry):

```json
{ "version": 1, "rules": [
  {"id": "xcode-derived-data", "name": "Xcode DerivedData", "pattern": "Users/*/Library/Developer/Xcode/DerivedData", "safety": "regenerates",
   "explanation": "Xcode build products. Safe to clear. Rebuilds itself."},
  {"id": "xcode-archives", "name": "Xcode archive", "pattern": "Users/*/Library/Developer/Xcode/Archives/*", "safety": "review",
   "explanation": "Builds you archived for release. Keep the ones you may need to read crash reports."},
  {"id": "simulator-devices", "name": "Simulators", "pattern": "Users/*/Library/Developer/CoreSimulator", "safety": "app-managed",
   "explanation": "iOS simulators and their data.", "instruction": "Remove old ones in Xcode › Settings › Components."},
  {"id": "simulator-runtimes", "name": "Simulator runtimes", "pattern": "Library/Developer/CoreSimulator", "safety": "app-managed",
   "explanation": "Simulator runtimes Xcode downloaded.", "instruction": "Remove them in Xcode › Settings › Components."},
  {"id": "node-modules", "name": "node_modules", "pattern": "**/node_modules", "safety": "regenerates",
   "explanation": "Packages for a JavaScript project. Safe to clear. Reinstall them with npm install."},
  {"id": "npm-cache", "name": "npm cache", "pattern": "Users/*/.npm/_cacache", "safety": "regenerates",
   "explanation": "npm's download cache. Safe to clear. npm fetches what it needs again."},
  {"id": "yarn-cache", "name": "Yarn cache", "pattern": "Users/*/Library/Caches/Yarn", "safety": "regenerates",
   "explanation": "Yarn's download cache. Safe to clear. Yarn fetches what it needs again."},
  {"id": "pnpm-store", "name": "pnpm store", "pattern": "Users/*/Library/pnpm/store", "safety": "regenerates",
   "explanation": "pnpm's package store. Safe to clear. pnpm fetches what it needs again."},
  {"id": "pip-cache", "name": "pip cache", "pattern": "Users/*/Library/Caches/pip", "safety": "regenerates",
   "explanation": "pip's download cache. Safe to clear. pip fetches what it needs again."},
  {"id": "homebrew-cache", "name": "Homebrew cache", "pattern": "Users/*/Library/Caches/Homebrew", "safety": "regenerates",
   "explanation": "Downloads Homebrew kept after installing. Safe to clear. brew cleanup does the same."},
  {"id": "cargo-registry", "name": "Cargo registry", "pattern": "Users/*/.cargo/registry", "safety": "regenerates",
   "explanation": "Rust crates Cargo downloaded. Safe to clear. Cargo fetches what it needs again."},
  {"id": "gradle-caches", "name": "Gradle caches", "pattern": "Users/*/.gradle/caches", "safety": "regenerates",
   "explanation": "Gradle's build and download cache. Safe to clear. Gradle rebuilds it."},
  {"id": "user-caches", "name": "App cache", "pattern": "Users/*/Library/Caches/*", "safety": "regenerates",
   "explanation": "App caches. Safe to clear. Apps rebuild what they need."},
  {"id": "old-installers", "name": "Old installer", "pattern": "Users/*/Downloads", "files": ["*.dmg", "*.pkg"], "minAgeDays": 30, "safety": "review",
   "explanation": "An installer you downloaded over a month ago. Once the app is installed, you don't need it."},
  {"id": "final-cut-render", "name": "Final Cut render files", "pattern": "**/*.fcpbundle/**/Render Files", "safety": "regenerates",
   "explanation": "Final Cut Pro renders. Safe to clear. Final Cut renders them again."},
  {"id": "final-cut-proxies", "name": "Final Cut proxies", "pattern": "**/*.fcpbundle/**/Transcoded Media", "safety": "review",
   "explanation": "Proxy and optimized media. Final Cut can make them again from the originals, but it takes a while."},
  {"id": "premiere-cache", "name": "Premiere media cache", "pattern": "Users/*/Library/Application Support/Adobe/Common/Media Cache Files", "safety": "regenerates",
   "explanation": "Premiere Pro's media cache. Safe to clear. Premiere rebuilds it."},
  {"id": "davinci-cache", "name": "DaVinci Resolve cache", "pattern": "**/CacheClip", "safety": "regenerates",
   "explanation": "DaVinci Resolve's render cache. Safe to clear. Resolve renders it again."},
  {"id": "docker", "name": "Docker", "pattern": "Users/*/Library/Containers/com.docker.docker", "safety": "app-managed",
   "explanation": "The virtual disk Docker runs on. It grows but never shrinks by itself.", "instruction": "Reclaim space in Docker › Settings › Resources."},
  {"id": "ios-backups", "name": "iPhone and iPad backups", "pattern": "Users/*/Library/Application Support/MobileSync/Backup", "safety": "app-managed",
   "explanation": "iPhone and iPad backups.", "instruction": "Manage them in Finder › your device › Manage Backups."},
  {"id": "photos-library", "name": "Photos library", "pattern": "Users/*/Pictures/*.photoslibrary", "safety": "app-managed",
   "explanation": "Your Photos library.", "instruction": "Shrink it from inside Photos, not here."},
  {"id": "trash", "name": "Trash", "pattern": "Users/*/.Trash", "safety": "app-managed",
   "explanation": "Files in the Trash.", "instruction": "Empty the Trash in Finder to get this space back."},
  {"id": "volume-trash", "name": "Trash", "pattern": ".Trashes", "safety": "app-managed",
   "explanation": "Files in this drive's Trash.", "instruction": "Empty the Trash in Finder to get this space back."}
] }
```

The pattern state machine and the walk. These are the two algorithms the signatures leave open:

```swift
// LensPattern. Parts: .literal(String), .glob(String) (contains * ? or [), .one ("*"), .anyDepth ("**"), all lowercased.
// Bit i of a mask: "the path so far matched the first i parts".
func closure(_ m: UInt64) -> UInt64 {
    var m = m
    for (i, p) in parts.enumerated() where p == .anyDepth && m & (1 << i) != 0 { m |= 1 << (i + 1) }
    return m
}
var start: UInt64 { closure(1) }
func step(_ m: UInt64, _ name: String) -> UInt64 {
    var out: UInt64 = 0
    for (i, p) in parts.enumerated() where m & (1 << i) != 0 {
        switch p {
        case .anyDepth: out |= 1 << i
        case .one: out |= 1 << (i + 1)
        case .literal(let s): if s == name { out |= 1 << (i + 1) }
        case .glob(let g): if fnmatch(g, name, 0) == 0 { out |= 1 << (i + 1) }
        }
    }
    return closure(out)
}
func accepts(_ m: UInt64) -> Bool { m & (1 << parts.count) != 0 }

// LensMatcher.report: depth first from the root (path ""), one mask per rule.
var stack: [(folder: FolderID, path: String, masks: [UInt64])] = [(0, "", patterns.map(\.start))]
while let (folder, path, masks) = stack.popLast() {
    for r in fileRules where patterns[r].accepts(masks[r]) {
        // stored files of `folder` whose lowercased name matches one of rules[r].files,
        // with modified(abs) at least minAgeDays before `now`: one hit each (isFolder false)
    }
    var child = index.folders[Int(folder)].firstChildFolder
    while child != noFolder {
        let name = index.folderName(child), lower = name.lowercased()
        let next = masks.indices.map { masks[$0] == 0 ? 0 : patterns[$0].step(masks[$0], lower) }
        let childPath = path.isEmpty ? name : path + "/" + name
        if let r = best(folderRules.filter { patterns[$0].accepts(next[$0]) }) {      // Decision 2
            let size = index.folders[Int(child)].totalAllocated
            if size >= minBytes { hits.append(LensHit(ruleID: rules[r].id, path: childPath, name: name, size: size, isFolder: true, safety: rules[r].safety)) }
            // a hit is never descended into, even when it is too small to report
        } else if next.contains(where: { $0 != 0 }) {
            stack.append((child, childPath, next))
        }
        child = index.folders[Int(child)].nextSibling
    }
}
// hits: sorted by size descending, then prefix(limit)
```

- [ ] **Step 1: Write the failing tests** in `LensTests.swift`. In `MapTextTests.swift`, replace `knownItemsExplainThemselves` with `hoverExplanationsComeFromTheRules` (below). `hoverCards` stays as it is.

```swift
@Test func bundledRulesLoadAndCoverTheSpecSet() {
    let ids = Set(LensRules.bundled.rules.map(\.id))
    #expect(ids.isSuperset(of: ["xcode-derived-data", "xcode-archives", "simulator-devices", "simulator-runtimes", "node-modules",
                                "npm-cache", "yarn-cache", "pnpm-store", "pip-cache", "homebrew-cache", "cargo-registry",
                                "gradle-caches", "user-caches", "old-installers", "final-cut-render", "final-cut-proxies",
                                "premiere-cache", "davinci-cache", "docker", "ios-backups", "trash"]))
    #expect(LensRules.bundled.rules.allSatisfy { ($0.safety == .appManaged) == ($0.instruction != nil) })
}
@Test func patternsMatchComponents() {
    let render = LensPattern("**/*.fcpbundle/**/Render Files")
    #expect(render.matches("Users/u/Movies/Trip.fcpbundle/Day 1/Render Files"))
    #expect(render.matches("Trip.fcpbundle/Render Files"))
    #expect(!render.matches("Users/u/Movies/Render Files"))
    #expect(LensPattern("Users/*/Library/Caches/*").matches("users/U/library/caches/com.foo"))
    #expect(!LensPattern("Users/*/Library/Caches/*").matches("Users/u/Library/Caches"))
    #expect(LensPattern("Users/*/Library/Caches/Yarn").literalCount == 4)
}
@Test func reportFindsHitsAndStopsAtTheOuterOne() async throws {
    let idx = try await Fixtures.index([
        "Users/u/Library/Developer/Xcode/DerivedData/App-abc/Build/x.bin": 3_000_000,
        "Users/u/Library/Developer/Xcode/DerivedData/App-abc/node_modules/y.bin": 2_000_000,
        "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 4_000_000,
        "Users/u/code/web/node_modules/left-pad/z.bin": 1_500_000,
        "Users/u/code/web/node_modules/left-pad/node_modules/w.bin": 1_200_000,
        "Users/u/code/tiny/node_modules/t.txt": 10,
    ])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(r.hits.map(\.path) == ["Users/u/Library/Developer/Xcode/DerivedData",
                                   "Users/u/Library/Containers/com.docker.docker", "Users/u/code/web/node_modules"])
    #expect(r.hits.map(\.safety) == [.regenerates, .appManaged, .regenerates])
    #expect(r.total(.regenerates) == r.hits[0].size + r.hits[2].size && r.total(.appManaged) == r.hits[1].size)
}
@Test func overlappingRulesCountEachByteOnce() async throws {
    let idx = try await Fixtures.index(["Users/u/Library/Caches/Yarn/v6/a.bin": 2_000_000,
                                        "Users/u/Library/Caches/Yarn/node_modules/c.bin": 1_100_000,
                                        "Users/u/Library/Caches/com.app/b.bin": 1_500_000])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(Dictionary(uniqueKeysWithValues: r.hits.map { ($0.path, $0.ruleID) })
        == ["Users/u/Library/Caches/Yarn": "yarn-cache", "Users/u/Library/Caches/com.app": "user-caches"])
    let caches = try #require(idx.folder(atRelativePath: "Users/u/Library/Caches"))
    #expect(r.total(.regenerates) == idx.folders[Int(caches)].totalAllocated)
}
@Test func oldInstallersNeedThirtyDays() async throws {
    let idx = try await Fixtures.index(["Users/u/Downloads/Old.dmg": 2_000_000, "Users/u/Downloads/New.pkg": 2_000_000,
                                        "Users/u/Downloads/notes.pdf": 2_000_000])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let r = LensMatcher.report(index: idx, rules: .bundled, now: now) {
        $0.hasSuffix("Old.dmg") ? now.addingTimeInterval(-31 * 86_400) : now.addingTimeInterval(-29 * 86_400)
    }
    #expect(r.hits.map(\.path) == ["Users/u/Downloads/Old.dmg"])
    #expect(r.hits[0].isFolder == false && r.hits[0].safety == .review && r.hits[0].ruleID == "old-installers")
}
@Test func reportKeepsTheLargestHits() async throws {
    let idx = try await Fixtures.index(["a/node_modules/x.bin": 3_000_000, "b/node_modules/x.bin": 2_000_000, "c/node_modules/x.bin": 1_500_000])
    let r = LensMatcher.report(index: idx, rules: .bundled, limit: 2)
    #expect(r.hits.map(\.path) == ["a/node_modules", "b/node_modules"] && r.total(.regenerates) == r.hits[0].size + r.hits[1].size)
}
```

```swift
// MapTextTests.swift
@Test func hoverExplanationsComeFromTheRules() {
    let rules = LensRules.bundled
    #expect(rules.explanation(for: "Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        == "The virtual disk Docker runs on. It grows but never shrinks by itself. Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(rules.explanation(for: "Users/u/Library/Developer/Xcode/DerivedData") == "Xcode build products. Safe to clear. Rebuilds itself.")
    #expect(rules.explanation(for: "Users/u/code/site/node_modules") == "Packages for a JavaScript project. Safe to clear. Reinstall them with npm install.")
    #expect(rules.explanation(for: "Users/u/Pictures/Photos Library.photoslibrary") == "Your Photos library. Shrink it from inside Photos, not here.")
    #expect(rules.explanation(for: "Users/u/Library/Caches") == "App caches. Safe to clear. Apps rebuild what they need.")
    #expect(rules.explanation(for: "Users/u/Library/Caches/Yarn/v6") == "Yarn's download cache. Safe to clear. Yarn fetches what it needs again.")
    #expect(rules.explanation(for: "Users/u/Downloads/Old.dmg") == nil)
    #expect(rules.explanation(for: "Users/u/Documents") == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter "bundledRulesLoad|patternsMatchComponents|reportFindsHits|overlappingRules|oldInstallers|reportKeepsTheLargest|hoverExplanations"`. Expected: build fails (`LensRules` not defined).
- [ ] **Step 3: Implement.**
  - In `Package.swift`, give the DiskApp target `resources: [.copy("Resources/lenses.json")]`.
  - Add the rules file and the two Swift files. Delete `KnownItems.swift` and switch `HoverCard` to the rules.
  - In `make-app.sh`, `mkdir -p "$APP/Contents/Resources"` and copy `Sources/DiskApp/Resources/lenses.json` into it before signing.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Check the bundled copy.** Run `scripts/make-app.sh debug && ls .build/Diskinventory.app/Contents/Resources/`. Expected: `lenses.json`. Then `codesign --verify --strict .build/Diskinventory.app && echo ok` prints `ok`.
- [ ] **Step 6: Commit** `feat: junk lens rules as bundled JSON, and a matcher that counts each byte once`

---

### Task 2: Basket, review sheet and the trash mover

**Files:**
- Create: `Sources/DiskApp/Basket/Basket.swift`, `Sources/DiskApp/Basket/ReviewSheet.swift`, `Sources/DiskApp/Basket/Trasher.swift`
- Create: `Tests/DiskAppTests/BasketTests.swift`, `Tests/DiskAppTests/TrasherTests.swift`, `Tests/DiskAppTests/FixtureTrash.swift`
- Modify: `Tests/DiskAppTests/Fixtures.swift` (add `realPath(_:)` and `allocatedSize(_:)`, copied from DiskEngineTests' `Fixtures`)

**Interfaces:**
- Consumes: `LensRules`, `LensHit`, `LensSafety` (Task 1); `MapNode`; `ContentKind.classify(_:)`; `Format.gb`.
- Produces:
  - `public struct BasketItem: Equatable, Sendable, Identifiable { var path: String; var name: String; var size: UInt64; var kind: ContentKind?; var isFolder: Bool; var ruleID: String?; var safety: LensSafety?; var id: String { path } }`
    - `static func from(node: MapNode, size: UInt64, rules: LensRules = .bundled) -> BasketItem?`: nil for buckets (`kind == nil`) and for the root key `""`. `ruleID` and `safety` come from `rules.rule(covering: node.key)`.
    - `static func from(hit: LensHit) -> BasketItem`: `kind` is `ContentKind.classify(hit.path) ?? .other`.
  - `@MainActor public final class Basket: ObservableObject`:
    - `@Published private(set) var items: [BasketItem]`, in the order they were added.
    - `var total: UInt64`, `var chips: [ContentKind?]` (the first 6 items' kinds) and `var moreCount: Int` (`max(0, items.count − 6)`).
    - `@discardableResult func add(_ item: BasketItem) -> Bool`. It returns false for the root, a key containing `#`, a path already in the basket, or a path under a folder already in the basket (prefix `folder.path + "/"`). Adding a folder removes the items under it.
    - `func add(contentsOf: [BasketItem])`, `func remove(paths: Set<String>)`, `func clear()`.
  - `@MainActor public final class BasketStore { init(); func basket(for uuid: String) -> Basket; func drop(_ uuid: String) }`. `drop` clears that basket, then forgets it.
  - `public struct ReviewRow: Equatable, Sendable { var path: String; var name: String; var location: String; var size: String; var explanation: String; var instruction: String?; var isChecked: Bool; var isCheckable: Bool { instruction == nil } }`. `location` is the parent path; `""` shows as "Drive root".
  - `public struct ReviewSheet: Equatable, Sendable`:
    - Fields: `var rows: [ReviewRow]; var selectedTotal: UInt64; var selectedLabel: String; var buttonTitle: String; var canTrash: Bool; var notice: String?`
    - `static let title = "Review before moving to Trash"` and `static let subtitle = "Nothing is deleted. Items go to the Trash, and you can put them back from there."`
    - `static func make(items: [BasketItem], unchecked: Set<String>, rules: LensRules = .bundled, driveName: String, driveConnected: Bool) -> ReviewSheet`:
      - Each row's `explanation` is the rule's `explanation`, or `"Not a known item. Make sure you don't need it."` when no rule covers the item.
      - `instruction` is the rule's instruction for app-managed items, and nil otherwise.
      - `isChecked` is true when `isCheckable` and the item is not in `unchecked`.
    - `static func trashable(_ items: [BasketItem], unchecked: Set<String>) -> [BasketItem]`: the checked, non-app-managed items.
    - `selectedLabel` is `Format.gb(selectedTotal) + " selected"`.
    - `buttonTitle` is `"Move 1 item to Trash"` or `"Move N items to Trash"`, and `"Move to Trash"` when N is 0.
    - `canTrash` is `N > 0 && driveConnected`.
    - `notice` is `"<driveName> is disconnected. Plug it back in to move these items."` when the drive is not connected.
  - `public protocol TrashBackend: Sendable { func trash(_ url: URL) throws }`
  - `public enum TrashFailure: Equatable, Sendable { case alreadyGone, permissionDenied, outsideDrive, driveGone, failed(String) }`
  - `public struct TrashFailureItem: Equatable, Sendable { var path: String; var name: String; var reason: TrashFailure }`
  - `public struct TrashOutcome: Equatable, Sendable`:
    - Fields: `var moved: [String]; var failures: [TrashFailureItem]; var freed: UInt64`
    - `var cleared: Set<String>`: the moved paths plus the already-gone ones. These leave the basket.
    - `var title: String`: `"Freed " + Format.gb(freed)`, or `"Nothing moved to the Trash"` when `moved` is empty.
    - `var detail: String?`: `"It stays in the Trash until you empty it."` when something moved.
    - `var failureHeader: String?`: `"1 item wasn't moved."` or `"N items weren't moved."`
    - `var failureLines: [String]`: `"<name>: already gone."`, `"<name>: you don't have permission to move it. Try it in Finder."`, `"<name>: no longer on this drive."`, `"<name>: the drive was disconnected."`, `"<name>: <message>"`
    - `static func driveGone(_ items: [BasketItem]) -> TrashOutcome`
  - `public enum Trasher { static func moveToTrash(_ items: [BasketItem], root: String, backend: some TrashBackend) async -> TrashOutcome }`:
    - It runs the moves in a detached utility-QoS task, never on main.
    - App-managed items are skipped silently: they are neither moved nor failed.
    - For each other item, with `url = root + "/" + path`:
      - `lstat` reports `ENOENT`: `.alreadyGone`.
      - `realpath` of the parent folder is not `root` and does not start with `root + "/"`: `.outsideDrive`.
      - Otherwise `backend.trash(url)`. Errors map as follows: `CocoaError.fileWriteNoPermission` and POSIX `EACCES` or `EPERM` become `.permissionDenied`; `CocoaError.fileNoSuchFile` and `ENOENT` become `.alreadyGone`; anything else becomes `.failed(localizedDescription)`.
    - `freed` is the sum of the moved items' `size`.
  - Test helper `struct FixtureTrash: TrashBackend { let bin: URL }` in `FixtureTrash.swift`. It `rename(2)`s the item into `bin/<UUID>` and throws `POSIXError` with the errno. It first checks with `precondition` that the resolved path is inside `Fixtures.realPath(RunRoot.url)`, so a test can never move anything else.

- [ ] **Step 1: Write the failing tests**

```swift
// BasketTests.swift
func item(_ path: String, _ size: UInt64, folder: Bool = false, safety: LensSafety? = nil) -> BasketItem {
    BasketItem(path: path, name: String(path.split(separator: "/").last ?? ""), size: size, kind: .other, isFolder: folder, ruleID: nil, safety: safety)
}
@MainActor @Test func nestedItemsCollapseIntoTheirFolder() {
    let b = Basket()
    #expect(b.add(item("a/b/c.bin", 2_000_000_000)))
    #expect(b.add(item("a/b", 5_000_000_000, folder: true)))
    #expect(!b.add(item("a/b/d.bin", 1_000_000_000)))
    #expect(!b.add(item("a/b", 5_000_000_000, folder: true)))
    #expect(!b.add(item("", 9, folder: true)) && !b.add(item("a#small", 9)))
    #expect(b.add(item("a/bc", 1_000_000_000, folder: true)))
    #expect(b.items.map(\.path) == ["a/b", "a/bc"] && b.total == 6_000_000_000)
}
@MainActor @Test func chipsShowSixThenACount() {
    let b = Basket()
    for i in 0..<8 { b.add(item("f\(i)", 1)) }
    #expect(b.chips.count == 6 && b.moreCount == 2)
    b.remove(paths: ["f0", "f1"]); #expect(b.moreCount == 0)
}
@Test func basketItemsFromNodesAndHits() {
    let docker = MapNode(key: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", kind: .virtualMachines, growth: 0, isFolder: false)
    #expect(BasketItem.from(node: docker, size: 59_000_000_000)?.safety == .appManaged)
    #expect(BasketItem.from(node: MapNode(key: "a#small", name: "3 small files", kind: nil, growth: 0, isFolder: false), size: 9) == nil)
    let hit = LensHit(ruleID: "node-modules", path: "Users/u/web/node_modules", name: "node_modules", size: 2_700_000, isFolder: true, safety: .regenerates)
    #expect(BasketItem.from(hit: hit) == BasketItem(path: "Users/u/web/node_modules", name: "node_modules", size: 2_700_000,
                                                    kind: .developer, isFolder: true, ruleID: "node-modules", safety: .regenerates))
}
@Test func reviewRowsShowCheckboxesExceptForAppManaged() {
    let items = [
        BasketItem(path: "Users/u/Library/Developer/Xcode/DerivedData", name: "DerivedData", size: 6_200_000_000, kind: .developer, isFolder: true, ruleID: "xcode-derived-data", safety: .regenerates),
        BasketItem(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", size: 59_000_000_000, kind: .virtualMachines, isFolder: false, ruleID: "docker", safety: .appManaged),
        BasketItem(path: "Users/u/Movies/old.mov", name: "old.mov", size: 2_000_000_000, kind: .media, isFolder: false, ruleID: nil, safety: nil),
    ]
    let s = ReviewSheet.make(items: items, unchecked: ["Users/u/Movies/old.mov"], driveName: "Macintosh HD", driveConnected: true)
    #expect(s.rows.map(\.isCheckable) == [true, false, true] && s.rows.map(\.isChecked) == [true, false, false])
    #expect(s.rows[0].explanation == "Xcode build products. Safe to clear. Rebuilds itself." && s.rows[0].location == "Users/u/Library/Developer/Xcode")
    #expect(s.rows[1].instruction == "Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(s.rows[2].explanation == "Not a known item. Make sure you don't need it.")
    #expect(s.buttonTitle == "Move 1 item to Trash" && s.canTrash && s.selectedTotal == 6_200_000_000 && s.selectedLabel == "6.2 GB selected")
    #expect(ReviewSheet.trashable(items, unchecked: []).map(\.name) == ["DerivedData", "old.mov"])
}
@Test func disconnectedDriveCannotTrash() {
    let s = ReviewSheet.make(items: [item("a.bin", 5)], unchecked: [], driveName: "Samsung T7", driveConnected: false)
    #expect(!s.canTrash && s.notice == "Samsung T7 is disconnected. Plug it back in to move these items.")
    #expect(ReviewSheet.make(items: [item("a.bin", 5)], unchecked: ["a.bin"], driveName: "T7", driveConnected: true).buttonTitle == "Move to Trash")
}
```

```swift
// TrasherTests.swift
func trash(_ items: [BasketItem], in root: URL) async throws -> (TrashOutcome, URL) {
    let bin = try Fixtures.tempDir()
    return (await Trasher.moveToTrash(items, root: Fixtures.realPath(root), backend: FixtureTrash(bin: bin)), bin)
}
@MainActor @Test func movesItemsOffMainAndReportsFreed() async throws {
    let root = try Fixtures.tree(["a/big.bin": 3_000_000, "b/keep.bin": 2_000_000])
    let (out, bin) = try await trash([item("a/big.bin", 2_500_000_000)], in: root)
    #expect(out.moved == ["a/big.bin"] && out.failures.isEmpty && out.freed == 2_500_000_000)
    #expect(out.title == "Freed 2.5 GB" && out.detail == "It stays in the Trash until you empty it." && out.failureHeader == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "a/big.bin").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1)
    #expect(FixtureTrash.lastCallWasOnMain == false)
}
@Test func partialFailureReportsEachItem() async throws {
    let root = try Fixtures.tree(["locked/a.bin": 2_000_000, "free/b.bin": 2_000_000])
    let locked = root.appending(path: "locked").path
    chmod(locked, 0o555); defer { chmod(locked, 0o755) }
    let (out, _) = try await trash([item("locked/a.bin", 2), item("free/b.bin", 3), item("gone/c.bin", 4)], in: root)
    #expect(out.moved == ["free/b.bin"] && out.freed == 3)
    #expect(out.failures == [.init(path: "locked/a.bin", name: "a.bin", reason: .permissionDenied),
                             .init(path: "gone/c.bin", name: "c.bin", reason: .alreadyGone)])
    #expect(out.failureHeader == "2 items weren't moved.")
    #expect(out.failureLines == ["a.bin: you don't have permission to move it. Try it in Finder.", "c.bin: already gone."])
    #expect(out.cleared == ["free/b.bin", "gone/c.bin"])
    #expect(FileManager.default.fileExists(atPath: locked + "/a.bin"))
}
@Test func itemGoneOrSwappedForSymlinkIsNotFollowed() async throws {
    let outside = try Fixtures.tree(["victim.bin": 2_000_000])
    let root = try Fixtures.tree(["d/victim.bin": 2_000_000])
    try FileManager.default.removeItem(at: root.appending(path: "d"))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "d"), withDestinationURL: outside)
    let (out, _) = try await trash([item("d/victim.bin", 2)], in: root)
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == [.outsideDrive])
    #expect(FileManager.default.fileExists(atPath: outside.appending(path: "victim.bin").path))
    try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside.appending(path: "victim.bin"))
    let (asLink, _) = try await trash([item("link", 1)], in: root)
    #expect(asLink.moved == ["link"] && FileManager.default.fileExists(atPath: outside.appending(path: "victim.bin").path))
}
@Test func appManagedItemsAreNeverTrashed() async throws {
    let root = try Fixtures.tree(["Docker.raw": 2_000_000])
    let (out, _) = try await trash([item("Docker.raw", 2, safety: .appManaged)], in: root)
    #expect(out.moved.isEmpty && out.failures.isEmpty && out.title == "Nothing moved to the Trash")
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Docker.raw").path))
}
```

`FixtureTrash` records `Thread.isMainThread` of its last call in a lock-protected `static var lastCallWasOnMain: Bool?`.

- [ ] **Step 2: Run** `swift test --filter "nestedItems|chipsShowSix|basketItemsFrom|reviewRows|disconnectedDrive|movesItemsOffMain|partialFailure|itemGoneOrSwapped|appManagedItems"`. Expected: build fails (`Basket` not defined).
- [ ] **Step 3: Implement** the three source files and the test helper.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Check the guarantee.** Run `grep -rn "trashItem" Sources Tests`. Expected: no match yet. Task 4 adds exactly one, in `Sources/Diskinventory/SystemTrash.swift`.
- [ ] **Step 6: Commit** `feat: basket, review sheet and a trash mover that only moves what was reviewed`

---

### Task 3: The drive owns its lens report and its trash moves

**Files:**
- Modify: `Sources/DiskApp/DriveController.swift`, `Sources/DiskApp/DropdownModel.swift`
- Test: `Tests/DiskAppTests/DriveControllerTests.swift`, `Tests/DiskAppTests/DropdownModelTests.swift`

**Interfaces:**
- Consumes: `LensMatcher`, `LensReport` (Task 1); `BasketItem`, `TrashBackend`, `TrashOutcome`, `Trasher` (Task 2); `LiveIndex.read(_:)`, `LiveIndex.apply(_:)`.
- Produces:
  - `DriveController`:
    - `@Published public private(set) var lens: LensReport?`
    - `public var clearable: UInt64? { lens?.total(.regenerates) }`
    - `private func refreshLens(force: Bool = false) async`: when `force` is set, or `lens?.generation != generation`, it runs `index.read { LensMatcher.report(index: $0, rules: .bundled, generation: gen) }`. It logs `lens report: N hits in X ms` with `Logger(subsystem: AppIdentity.bundleID, category: "index")`. `warmBody` calls it after `refresh()`. `coolBody` keeps the last report, so the dropdown still has it.
    - `public func trash(_ items: [BasketItem], backend: some TrashBackend) async -> TrashOutcome`:
      - It runs on the lifecycle chain (`run`), so it never races a cool or an unmount.
      - When the drive is unmounting or has no open index, it returns `.driveGone(items)` and touches nothing.
      - Otherwise it calls `Trasher.moveToTrash(items, root: index.rootPath)`.
      - Then it applies `FSChange(path: rootPath + "/" + parent, id: 0, rescanSubtree: false, historyLost: false)` for each distinct parent of `outcome.cleared` (the root's own path when the parent is `""`).
      - Then `refresh()`, then `refreshLens(force: true)`.
  - `DropdownModel.make(..., clearable: UInt64? = nil)` adds `public var reviewTitle: String?`. It is `"Review " + Format.gb(c) + " to clear"` when the drive is connected and `c >= 100_000_000`, and nil otherwise.

- [ ] **Step 1: Write the failing tests**

```swift
// DriveControllerTests.swift
@MainActor @Test func lensReportFollowsTheIndex() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000, "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    #expect(c.lens?.hits.map(\.ruleID) == ["xcode-derived-data"])
    #expect(c.clearable == Fixtures.allocatedSize(root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin")))
    await c.cool()
    #expect(c.lens != nil)
}
@MainActor @Test func trashMovesUpdatesAndRecounts() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000, "Users/u/Documents/d.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    let before = try #require(c.summary?.scannedBytes)
    let out = await c.trash(c.lens!.hits.map(BasketItem.from(hit:)), backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved == ["Users/u/Library/Developer/Xcode/DerivedData"])
    #expect(c.summary?.scannedBytes == before - out.freed)
    #expect(c.clearable == 0)
    await c.cool()
}
@MainActor @Test func trashAfterUnmountTouchesNothing() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Developer/Xcode/DerivedData/App/x.bin": 3_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    let items = c.lens!.hits.map(BasketItem.from(hit:))
    await c.willUnmount()
    let out = await c.trash(items, backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == [.driveGone])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Developer/Xcode/DerivedData/App/x.bin").path))
}
```

```swift
// DropdownModelTests.swift
@Test func reviewButtonShowsClearableSpace() {
    func title(_ clearable: UInt64?, connected: Set<String> = ["I"]) -> String? {
        DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: connected, summary: nil,
                           space: Fixtures.space(totalGB: 1000, freeGB: 82, reclaimableGB: 0), activity: .ready, period: 7,
                           connectedSince: nil, now: .now, clearable: clearable).reviewTitle
    }
    #expect(title(6_200_000_000) == "Review 6.2 GB to clear")
    #expect(title(50_000_000) == nil && title(nil) == nil)
    #expect(title(6_200_000_000, connected: []) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter "lensReportFollows|trashMovesUpdates|trashAfterUnmount|reviewButtonShows"`. Expected: build fails (`lens` is not a member of `DriveController`).
- [ ] **Step 3: Implement** the listed members.
- [ ] **Step 4: Run** `swift test`. Expected: all pass, including the existing `DriveControllerTests`.
- [ ] **Step 5: Commit** `feat: drives keep a lens report, and a move to Trash updates the index at once`

---

### Task 4: Basket in the map window, the review sheet, and "Review N GB to clear"

**Files:**
- Create: `Sources/DiskApp/Basket/BasketDrag.swift`, `Sources/Diskinventory/SystemTrash.swift`, `Sources/Diskinventory/Map/BasketBar.swift`, `Sources/Diskinventory/Map/ReviewSheetView.swift`
- Modify: `Sources/DiskApp/Map/MapCommands.swift`, `Sources/Diskinventory/Map/MapWindowView.swift`, `MapWindowController.swift`, `TreemapMTKView.swift`, `TreemapView.swift`, `Sources/Diskinventory/DropdownView.swift`, `Sources/Diskinventory/AppDelegate.swift`
- Test: `Tests/DiskAppTests/MapTextTests.swift`, `Tests/DiskAppTests/BasketTests.swift`

**Interfaces:**
- Consumes: `Basket`, `BasketStore`, `BasketItem.from(node:size:)`, `BasketItem.from(hit:)`, `ReviewSheet`, `TrashOutcome` (Task 2); `DriveController.lens`, `.clearable`, `.trash(_:backend:)`, `DropdownModel.reviewTitle` (Task 3).
- Produces:
  - `MapAction.addToBasket` and `MapKeyCommand.addToBasket`. `MapKey.command` maps keyCode 51 (⌫) with no modifiers to `.addToBasket`, but only while the search field is not focused.
  - `MapCommands.items(query:hasSelection:canZoomOut:children:canAddToBasket: Bool = false)`. When `canAddToBasket` is true, the first item is `CommandItem(title: "Add to Basket", shortcut: "⌫", action: .addToBasket)`. The query filters it like the others.
  - `public struct BasketDrag: Equatable, Sendable { static let threshold: CGFloat = 4; init(at: CGPoint, item: Int); var item: Int; var location: CGPoint; var isActive: Bool; mutating func move(to: CGPoint); func dropsOnBasket(_ frame: CGRect) -> Bool }`. It becomes active once the pointer is 4 pt or more from the origin, and stays active. `dropsOnBasket` is `isActive && frame.contains(location)`.
  - `struct SystemTrash: TrashBackend` in the `Diskinventory` target. It is the only `FileManager.default.trashItem(at:resultingItemURL: nil)` call in the repo.
  - `TreemapMTKView`:
    - `mouseDown` starts a `BasketDrag` on the hit block's top-level rect, and does nothing when it hits no block.
    - `mouseDragged` moves it and calls `onDrag(BasketDrag)`.
    - On `mouseUp`, an active drag calls `onDrop(BasketDrag)`. An inactive one is a click, which keeps today's click behavior.
  - Side list rows use a SwiftUI `DragGesture(minimumDistance: 4, coordinateSpace: .named("mapWindow"))` that feeds the same state.
  - `BasketBar` (SwiftUI), floating over the bottom of the map area:
    - Placement: 12 pt from the bottom, centered, at most 560 pt wide, 44 pt tall.
    - Look: fill `Color(white: 0.11)` in both appearances, 6 pt corners, a 1 pt stroke of white at 8%.
    - Content: up to 6 kind-colored 12 pt squares with 2 pt corners (buckets grey), then `"+N"`, then `"1 item"` or `"N items"` in white, `Format.gb(total)` in white at 60%, a plain "Clear" button, and a primary "Review" button (white fill, black text, 26 pt tall, 5 pt corners).
    - It shows when the basket is non-empty, or during an active drag. With an empty basket during a drag it reads "Drop here to add to the basket". During a drag over it, its stroke turns white at 60%.
  - `ReviewSheetView` (SwiftUI `.sheet` on the map window, 560 pt wide, rows scroll past 420 pt):
    - It shows `ReviewSheet.title` and `.subtitle`.
    - Each row has a checkbox, or for an app-managed row the instruction with an `arrow.up.forward.app` symbol. Then the name (semibold), the location (secondary, truncated in the middle), the explanation (secondary, at most 2 lines), and the size on the right. A trailing × removes the item from the basket.
    - The footer has `selectedLabel` on the left, and "Cancel" plus a primary `buttonTitle` on the right, disabled unless `canTrash`. `notice` shows above the footer.
    - While moving it shows "Moving to Trash…" with a `ProgressView`, and every control is disabled.
    - After the move it shows `title` (24 pt semibold), `detail`, `failureHeader` and the `failureLines`, plus a "Done" button. Then `basket.remove(paths: outcome.cleared)`, so failed items stay in the basket.
  - `MapWindowController`:
    - `init(controller:drive:path:select:basket: Basket)` and `func presentReview()`.
    - ⌫ and ⌘K "Add to Basket" call `addSelectionToBasket()`, which adds `BasketItem.from(node: snapshot.nodes[selected], size: rect.size)`.
    - A drop on the bar adds the dragged rect's item.
    - The move runs `controller.trash(ReviewSheet.trashable(...), backend: SystemTrash())`.
    - The key bar gains "Add to basket ⌫" between Quick Look and Actions. It is dimmed when the selection can't be added.
  - `DropdownView`: the actions row becomes "Open map" (chip) and a primary `reviewTitle` button (drive tint fill, white text, 30 pt, 6 pt corners) side by side, with 8 pt between them. With no `reviewTitle`, "Open map" stays full width. `DropdownHost` gains `reviewClearable: () -> Void`.
  - `AppDelegate`:
    - `private let baskets = BasketStore()` and `func reviewClearable(uuid: String)`. That method dismisses the panel, adds the controller's `regenerates` hits to `baskets.basket(for: uuid)`, opens the map at the root, and calls `presentReview()`.
    - `beginUnmount` calls `baskets.drop(uuid)`.
    - It passes `clearable: c?.clearable` to `DropdownModel.make`.

- [ ] **Step 1: Write the failing tests**

```swift
// MapTextTests.swift
@Test func deleteAddsToBasketUnlessTyping() {
    #expect(MapKey.command(keyCode: 51, modifiers: [], searchFocused: false) == .addToBasket)
    #expect(MapKey.command(keyCode: 51, modifiers: [], searchFocused: true) == nil)
    #expect(MapKey.command(keyCode: 51, modifiers: .command, searchFocused: false) == nil)
}
@Test func commandBarOffersAddToBasket() {
    let add = CommandItem(title: "Add to Basket", shortcut: "⌫", action: .addToBasket)
    #expect(MapCommands.items(query: "", hasSelection: true, canZoomOut: false, children: [], canAddToBasket: true).first == add)
    #expect(MapCommands.items(query: "bask", hasSelection: true, canZoomOut: false, children: [], canAddToBasket: true) == [add])
    #expect(!MapCommands.items(query: "", hasSelection: true, canZoomOut: false, children: []).contains(add))
}
// BasketTests.swift
@Test func dragStartsAfterFourPointsAndDropsOnTheBar() {
    var d = BasketDrag(at: CGPoint(x: 100, y: 100), item: 3)
    d.move(to: CGPoint(x: 103, y: 100)); #expect(!d.isActive)
    d.move(to: CGPoint(x: 104, y: 101)); #expect(d.isActive)
    d.move(to: CGPoint(x: 100, y: 100)); #expect(d.isActive)
    #expect(d.dropsOnBasket(CGRect(x: 90, y: 90, width: 30, height: 30)) && !d.dropsOnBasket(CGRect(x: 0, y: 0, width: 50, height: 50)))
    var tap = BasketDrag(at: .zero, item: 1); tap.move(to: CGPoint(x: 2, y: 2))
    #expect(!tap.dropsOnBasket(CGRect(x: -10, y: -10, width: 20, height: 20)))
}
```

- [ ] **Step 2: Run** `swift test --filter "deleteAddsToBasket|commandBarOffersAdd|dragStartsAfterFour"`. Expected: build fails (`.addToBasket` not defined).
- [ ] **Step 3: Implement** `MapCommands` and `BasketDrag`, then run the same filter. Expected: PASS.
- [ ] **Step 4: Implement** the `Diskinventory` views, the controller changes and the `AppDelegate` wiring.
- [ ] **Step 5: Run** `swift test && swift build --product Diskinventory && grep -rn "trashItem" Sources Tests`. Expected: all pass, the build succeeds, and grep prints exactly one line, in `Sources/Diskinventory/SystemTrash.swift`.
- [ ] **Step 6: Verify by hand on a scratch disk image** (`S` is the session scratchpad directory). This keeps real files out of it:

```bash
hdiutil create -size 400m -fs APFS -volname DITrash "$S/ditrash.dmg" && hdiutil attach "$S/ditrash.dmg"
V=/Volumes/DITrash
mkdir -p "$V/Users/u/Library/Developer/Xcode/DerivedData/App" "$V/Users/u/web/node_modules/x" "$V/Users/u/Library/Containers/com.docker.docker/Data"
mkfile 150m "$V/Users/u/Library/Developer/Xcode/DerivedData/App/x.bin"; mkfile 60m "$V/Users/u/web/node_modules/x/y.bin"
mkfile 80m "$V/Users/u/Library/Containers/com.docker.docker/Data/Docker.raw"; mkfile 40m "$V/Users/u/movie.mov"
scripts/make-app.sh debug && open .build/Diskinventory.app
```
Expected:
  - The dropdown's DITrash tab shows "Open map" and "Review 0.2 GB to clear". Clicking it opens the map with the sheet listing DerivedData and node_modules, both checked.
  - "Move 2 items to Trash" shows "Freed 0.2 GB" and "It stays in the Trash until you empty it." The items are now in `/Volumes/DITrash/.Trashes/<uid>/`. The map, the side list and the dropdown's free space and bar update within 1 s, without waiting for FSEvents.
  - Select `movie.mov` and press ⌫: the bar appears with one chip, "1 item" and "0.0 GB". ⌘K → "Add to Basket" on `Docker.raw` adds a second chip, and the count reads "2 items". Dragging the `Users` block 4 pt or more shows the bar as a drop target, and dropping adds it, swallowing the other two. A 2 pt drag is a click.
  - In Review, Docker's row has no checkbox and reads "Reclaim space in Docker › Settings › Resources."
  - Dragging a block onto Finder or onto the Dock's Trash does nothing.
  - `log show --predicate 'subsystem == "com.ooozzy.diskinventory" AND category == "index"' --last 5m | grep "lens report"` shows the DITrash report. Run it once on the internal disk too (open its dropdown): under 2 s in a release build. Record the number.
  - Finish with `hdiutil detach /Volumes/DITrash && rm "$S/ditrash.dmg"`.
- [ ] **Step 7: Commit** `feat: basket bar, ⌫ and drag in the map, review sheet, and Review N GB to clear`

---

### Task 5: Excluded folders in the engine

**Files:**
- Modify: `Sources/DiskEngine/ScanIndex.swift`, `Sources/DiskEngine/LiveIndex.swift`, `Sources/DiskApp/DriveController.swift`
- Test: `Tests/DiskEngineTests/ExclusionTests.swift`, `Tests/DiskAppTests/DriveControllerTests.swift`

**Interfaces:**
- Produces:
  - `ScanIndex.exclusions: Set<String>`: relative paths with no leading or trailing `/`. `integrate` and `relist` skip a directory entry whose relative path is in the set, so the scanner skips it too. Setting the property precomputes `[parentRelativePath: Set<childName>]`. A listing pays one `relativePath(of:)` only when that map is non-empty.
  - `public func relativePath(of folder: FolderID) -> String` on `ScanIndex` (`""` for the root).
  - `LiveIndex.init(volumeRoot:store:saveDebounce:compactAbove:exclusions: Set<String> = [])`.
    - `open()` sets `index.exclusions` before any scan.
    - The set that was last applied is written atomically to `store/exclusions.json` (a sorted JSON array). When a snapshot loads, `open()` reconciles it against the set passed in, exactly as `setExclusions` does.
  - `public func setExclusions(_ paths: Set<String>) async throws`. It runs under the lock and does nothing if the set is unchanged. Otherwise:
    - It sets the new set, then relists the parent of every added or removed path whose parent exists in the index, and scans any folders that brings back.
    - It writes `exclusions.json`, calls `indexChanged()` and schedules a save.
    - It never runs a full scan.
  - `apply(_:)` drops changes whose relative path equals an excluded path or lies under one.
  - Internal `var relistCount = 0`, counting folders relisted by `apply`. Task 9 builds `stats()` on it.
  - `DriveController.init(volume:store:coolDown:exclusions: Set<String> = [])` and `public func setExclusions(_ paths: Set<String>) async`. It stores the set. If the index is open, it calls `index.setExclusions`, then `refresh()` and `refreshLens(force: true)`, all on the run chain. Otherwise the next open uses the set.

- [ ] **Step 1: Write the failing tests**

```swift
// ExclusionTests.swift
@Test func scanSkipsExcludedFolders() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), exclusions: ["a/skip"])
    _ = try await live.open()
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root.appending(path: "a/keep")))
    try await live.close()
}
@Test func changingExclusionsRelistsWithoutAFullScan() async throws {
    let root = try Fixtures.tree(["a/keep/deep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    let deep = try await live.read { $0.folder(atRelativePath: "a/keep/deep") }
    try await live.setExclusions(["a/skip"])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } == nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root.appending(path: "a/keep")))
    try await live.setExclusions([])
    #expect(try await live.read { $0.folder(atRelativePath: "a/skip") } != nil)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    #expect(try await live.read { $0.folder(atRelativePath: "a/keep/deep") } == deep)
    try await live.close()
}
@Test func exclusionsReconcileOnReopen() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/skip/g.bin": 3_000_000]); let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store, exclusions: ["a/skip"])
    _ = try await first.open(); try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .snapshot)
    #expect(try await second.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await second.close()
}
@Test func eventsInsideExcludedFoldersAreIgnored() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 10, "a/skip/g.bin": 10])
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), exclusions: ["a/skip"])
    _ = try await live.open()
    try Fixtures.write(root.appending(path: "a/skip/new.bin"), bytes: 2_000_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a/skip", id: next, rescanSubtree: false, historyLost: false)])
    #expect(await live.relistCount == 0)
    try await live.close()
}
```

```swift
// DriveControllerTests.swift
@MainActor @Test func exclusionsChangeTheSummary() async throws {
    let root = try Fixtures.tree(["Users/u/Movies/m.mov": 3_000_000, "Users/u/VMs/v.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.warm()
    await c.setExclusions(["Users/u/VMs"])
    #expect(c.summary?.scannedBytes == Fixtures.allocatedSize(root.appending(path: "Users/u/Movies/m.mov")))
    await c.cool()
}
```

- [ ] **Step 2: Run** `swift test --filter "scanSkipsExcluded|changingExclusions|exclusionsReconcile|eventsInsideExcluded|exclusionsChangeTheSummary"`. Expected: build fails (no `exclusions:` argument).
- [ ] **Step 3: Implement** the listed members.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: skipped folders: the scan, relists and events leave them out`

---

### Task 6: The Settings window

**Files:**
- Create: `Sources/DiskApp/Settings/AppSettings.swift`, `Sources/Diskinventory/Settings/SettingsWindowController.swift`, `Sources/Diskinventory/Settings/SettingsView.swift`
- Modify: `Sources/DiskApp/LoginItem.swift`, `MenuBarLabel.swift`, `DriveRegistry.swift`, `DropdownModel.swift`, `MainMenuSpec.swift`, `Sources/Diskinventory/AppDelegate.swift`, `DropdownView.swift`, `DropdownPanel.swift`, `Map/MapWindowController.swift`
- Test: `Tests/DiskAppTests/SettingsTests.swift`, plus modifications to `LoginItemTests`, `MenuBarLabelTests`, `DriveRegistryTests`, `MainMenuTests` and `DropdownModelTests`

**Interfaces:**
- Consumes: `DriveController.setExclusions(_:)` (Task 5).
- Produces:
  - `public enum MenuBarStyle: String, Codable, Sendable { case ringAndNumber, iconOnly }`
  - `public struct AppSettings: Codable, Equatable, Sendable`:
    - Fields and defaults: `var menuBarStyle: MenuBarStyle = .ringAndNumber; var lowPercent = 15; var criticalPercent = 5; var excludedFolders: [String] = []`
    - `init()` and `func normalized() -> AppSettings`. `normalized` clamps `lowPercent` to 2...50 and `criticalPercent` to 1...(lowPercent − 1). It drops trailing `/` from the excluded folders, dedupes them and sorts them.
    - `func exclusions(under root: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String>`:
      - A folder strictly under `root` becomes its relative path. `root` itself is never excluded.
      - Only when `root == "/System/Volumes/Data"`: a folder outside it maps to `String(path.dropFirst())` when `exists(root + path)` (firmlinks).
    - `static func decode(_ data: Data?) -> AppSettings` (falls back to `AppSettings()`) and `func encoded() -> Data`.
  - `@MainActor public final class SettingsStore: ObservableObject`:
    - `@Published var settings: AppSettings`, saved (normalized) on every set.
    - `init(read: @escaping () -> Data?, write: @escaping (Data) -> Void)` and `convenience init(defaults: UserDefaults = .standard)`, which uses the key `"settings.v1"`.
  - `MenuBarLabel.make(space:showNumber:lowFraction: Double = 0.15, criticalFraction: Double = 0.05)`.
  - `LoginItem`:
    - `public enum LoginItemStatus: Sendable { case enabled, notRegistered, requiresApproval, notFound }`
    - `public struct LoginToggle: Equatable, Sendable { var isOn: Bool; var isEnabled: Bool; var note: String? }`
    - `static func toggle(status: LoginItemStatus, installed: Bool) -> LoginToggle`:
      - not installed: `isEnabled` false, note `"Move Diskinventory to Applications to launch it at login."`
      - `.requiresApproval`: `isOn` false, note `"Allow Diskinventory in System Settings › General › Login Items."`
      - otherwise: `isOn` is `status == .enabled`, and there is no note.
    - `registerOnFirstRun(defaults:register:)` takes `some FlagStore` (`protocol FlagStore: AnyObject { func bool(forKey: String) -> Bool; func set(_ value: Bool, forKey: String) }`, and `UserDefaults` conforms). `registersOnlyOnce` then uses an in-memory `FlagStore` instead of `UserDefaults(suiteName:)`, which wrote to `~/Library/Preferences`.
  - `KnownDrive.isInternal: Bool`. The init gains `isInternal: Bool? = nil`, which defaults to `tintIndex == 0`. Decoding a file without the key uses `tintIndex == 0`. `DropdownModel` uses `isInternal` wherever it tested `tintIndex == 0`.
  - `DriveRegistry.setTint(uuid: String, index: Int) throws` (`RegistryError.unknownDrive` or `.tintOutOfRange` outside 0...7). New drives get the lowest index in 1...7 that no known drive uses, else they wrap by count.
  - `MainMenuSpec`: the app menu gains `Settings…`, key `,`, selector `openSettings:`, after About and a separator.
  - `SettingsWindowController` (460 pt wide, not resizable, title "Settings", `setFrameAutosaveName("Settings")`) hosting `SettingsView`, a grouped SwiftUI `Form`:
    - **Menu bar.** Picker "Show": "Ring and free space" or "Ring only". Toggle "Launch at login" from `LoginItem.toggle(...)` and `SMAppService.mainApp.status`, registering or unregistering on change. The note shows under it.
    - **Warnings.** Steppers "Amber below" (`"15% free"`) and "Red below" (`"5% free"`).
    - **Drives.** One row per known drive: its name, then 8 swatches (16 pt, 4 pt corners, the selected one with a 2 pt outline in the label color).
    - **Skipped folders.** A list, "+" (an `NSOpenPanel` for directories, multiple selection) and "−". Footnote: "Skipped folders don't appear in the map. Their space counts as Other."
  - `AppDelegate`:
    - `@objc func openSettings(_:)`. It opens or fronts the window, sets the activation policy to `.regular`, and goes back to `.accessory` when no window is left open (shared with the map window through one `updateActivationPolicy()`).
    - On a settings change: `refresh()` for the menu bar label (style and thresholds); `registry.setTint` then `rebuild()` and the open map window's chip tint; `setExclusions(settings.exclusions(under: realpath(volume.url)))` for every controller.
    - New controllers get their exclusions at creation.
  - The dropdown footer's "Settings ⌘," becomes a button that calls `DropdownHost.openSettings`. `DropdownPanel` overrides `performKeyEquivalent` so ⌘, works while the panel is open.

- [ ] **Step 1: Write the failing tests**

```swift
// SettingsTests.swift
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
// MenuBarLabelTests.swift
@Test func labelUsesChosenThresholds() {
    let gb: UInt64 = 1_000_000_000
    let s = VolumeSpace(total: 1000 * gb, available: 50 * gb, availableForImportantUsage: 82 * gb)
    #expect(MenuBarLabel.make(space: s, showNumber: true, lowFraction: 0.08, criticalFraction: 0.05).level == .normal)
    #expect(MenuBarLabel.make(space: s, showNumber: true, lowFraction: 0.20, criticalFraction: 0.09).level == .critical)
}
// LoginItemTests.swift
@Test func loginToggleFollowsServiceStatus() {
    #expect(LoginItem.toggle(status: .enabled, installed: true) == LoginToggle(isOn: true, isEnabled: true, note: nil))
    #expect(LoginItem.toggle(status: .enabled, installed: false)
        == LoginToggle(isOn: true, isEnabled: false, note: "Move Diskinventory to Applications to launch it at login."))
    #expect(LoginItem.toggle(status: .requiresApproval, installed: true)
        == LoginToggle(isOn: false, isEnabled: true, note: "Allow Diskinventory in System Settings \u{203A} General \u{203A} Login Items."))
}
// DriveRegistryTests.swift
@Test func tintChoiceSticksAndNewDrivesAvoidIt() throws {
    let file = try Fixtures.tempDir().appending(path: "drives.json"); let reg = DriveRegistry(file: file)
    _ = try reg.upsert(.init(url: URL(filePath: "/"), uuid: "I", name: "Macintosh HD", isInternalData: true, device: 1), space: nil, now: .now)
    _ = try reg.upsert(.init(url: URL(filePath: "/Volumes/A"), uuid: "A", name: "A", isInternalData: false, device: 2), space: nil, now: .now)
    try reg.setTint(uuid: "A", index: 5); try reg.setTint(uuid: "I", index: 1)
    let b = try reg.upsert(.init(url: URL(filePath: "/Volumes/B"), uuid: "B", name: "B", isInternalData: false, device: 3), space: nil, now: .now)
    #expect(b.tintIndex == 2)
    let reloaded = DriveRegistry(file: file).all()
    #expect(reloaded.map(\.tintIndex) == [1, 5, 2] && reloaded.map(\.isInternal) == [true, false, false])
    #expect(throws: RegistryError.tintOutOfRange) { try reg.setTint(uuid: "A", index: 8) }
}
@Test func oldRegistryFilesKeepTheirInternalDrive() throws {
    let file = try Fixtures.tempDir().appending(path: "drives.json")
    try Data(#"[{"uuid":"I","name":"Macintosh HD","tintIndex":0,"lastSeen":"2026-10-01T00:00:00Z"},{"uuid":"T7","name":"T7","tintIndex":1,"lastSeen":"2026-10-01T00:00:00Z"}]"#.utf8).write(to: file)
    #expect(DriveRegistry(file: file).all().map(\.isInternal) == [true, false])
}
// MainMenuTests.swift, inside mainMenuHasAppEditAndWindowMenus:
#expect(item(0, "Settings…") == .init(title: "Settings…", key: ",", selector: "openSettings:"))
// DropdownModelTests.swift
@Test func anyTintCanBeTheInternalDrive() {
    let violetExternal = KnownDrive(uuid: "T7", name: "Samsung T7", tintIndex: 0, lastSeen: .now, isInternal: false)
    let tealInternal = KnownDrive(uuid: "I", name: "Macintosh HD", tintIndex: 1, lastSeen: .now, isInternal: true)
    let m = DropdownModel.make(drives: [violetExternal, tealInternal], selected: "T7", connected: ["I", "T7"], summary: nil,
                               space: nil, activity: .ready, period: 7, connectedSince: nil, now: .now)
    #expect(m.tabs.map(\.uuid) == ["I", "T7"] && m.footerRight == .eject)
}
```

- [ ] **Step 2: Run** `swift test --filter "defaultsMatchTheSpec|storeSavesNormalized|exclusionsMapOnto|labelUsesChosen|loginToggleFollows|tintChoiceSticks|oldRegistryFiles|mainMenuHas|anyTintCanBe|registersOnlyOnce"`. Expected: build fails (`AppSettings` not defined).
- [ ] **Step 3: Implement** the `DiskApp` changes, then run the same filter. Expected: PASS.
- [ ] **Step 4: Implement** the window, the view and the `AppDelegate`, dropdown and panel wiring.
- [ ] **Step 5: Run** `swift test && swift build --product Diskinventory`. Expected: all pass, and the build succeeds.
- [ ] **Step 6: Verify by hand.** Run `scripts/make-app.sh debug && open .build/Diskinventory.app`. Expected:
  - ⌘, with the dropdown open, and the footer's "Settings ⌘,", both open Settings with a Dock icon. Closing it removes the icon unless the map window is open.
  - "Ring only" removes the number from the menu bar at once.
  - Setting amber to 50% turns the ring amber on a disk with less than 50% free.
  - Picking a tint for a drive changes its dropdown tab dot and its map chip.
  - "Launch at login" is disabled with the Applications note in a `.build` copy.
  - Adding `~/Library/Caches` as a skipped folder lowers the internal drive's map total and grows Other in the dropdown bar within a few seconds, with no "Scanning…". Removing it brings it back.
- [ ] **Step 7: Commit** `feat: Settings window: menu bar style, launch at login, thresholds, drive tints, skipped folders`

---

### Task 7: Full Disk Access onboarding and unreadable folders

**Files:**
- Create: `Sources/DiskApp/FullDiskAccess.swift`, `Sources/Diskinventory/AccessExplainer.swift`, `Tests/DiskAppTests/FullDiskAccessTests.swift`
- Modify: `Sources/DiskEngine/LiveIndex.swift`, `Sources/DiskApp/DriveController.swift`, `Map/MapSnapshot.swift`, `Map/MapBuilder.swift`, `DropdownModel.swift`, `Sources/Diskinventory/Map/MapWindowView.swift`, `DropdownView.swift`, `AppDelegate.swift`
- Test: `Tests/DiskEngineTests/LiveIndexTests.swift`, `Tests/DiskAppTests/MapBuilderTests.swift`, `Tests/DiskAppTests/DropdownModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum FDAStatus: Equatable, Sendable { case granted, denied, unknown }`
  - `public enum FullDiskAccess`:
    - `static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!`
    - `static func probes(home: String) -> [String]`: `["/Library/Application Support/com.apple.TCC/TCC.db", home + "/Library/Safari", home + "/Library/Mail"]`.
    - `static func status(home: String = NSHomeDirectory(), probe: (String) -> Int32 = FullDiskAccess.openErrno) -> FDAStatus`. It tries the probes in order: 0 means `.granted`, `EPERM` or `EACCES` means `.denied`, and anything else moves to the next probe. If none answers, the result is `.unknown`.
    - `static func openErrno(_ path: String) -> Int32`: `open(O_RDONLY)`, and for a directory also `fdopendir` plus one `readdir`. It returns the first errno, or 0.
    - The probe takes about 1 ms but still runs off main (`Task.detached`).
  - `LiveIndex.retryUnreadable() async throws -> Int`. Under the lock it finds non-garbage folders flagged `.unreadable` and relists each one. It scans the new subfolders and returns how many folders are now readable. When that is more than 0 it calls `indexChanged()`.
  - `DriveController.init(..., fullDiskAccess: @escaping @Sendable () -> Bool = { FullDiskAccess.status() != .denied })`. `warmBody` calls `retryUnreadable()` right after a successful `open()` when the closure returns true.
  - `ListRow.isUnreadable: Bool`, with `= false` in the init. `MapSnapshot.unreadableCount: Int`, with `= 0` in the init. `MapSnapshot.unreadableNote: String?` is `"1 folder here can't be read."` or `"N folders here can't be read."`, and nil at 0.
  - `MapBuilder.build` appends one `ListRow(node: nil, name: <name>, size: 0, fraction: 0, kind: nil, isUnreadable: true)` per direct child folder of the zoom folder flagged `.unreadable`. These come after every sized row, including the remainder row, in sibling order, at most 50 of them. `unreadableCount` counts them all.
  - `DropdownModel.make(..., fullDiskAccess: FDAStatus = .granted)` adds `public var accessNote: String?`: `"Some folders can't be read without Full Disk Access."` when the status is `.denied`.
  - `AccessExplainer`: a 420 pt titled window.
    - Title: "Let Diskinventory see the whole disk"
    - Body: "macOS keeps Mail, Messages, Safari and some app data private until you allow Full Disk Access. Without it, Diskinventory still works, but those folders show as \"Can't read\" and their space counts as Other."
    - Steps: "Open System Settings, turn on Diskinventory under Full Disk Access, then reopen the app."
    - Buttons: primary "Open System Settings" (`NSWorkspace.shared.open(FullDiskAccess.settingsURL)`) and "Not Now".
    - `AppDelegate` shows it at launch when the status is `.denied` and the defaults key `"didExplainFullDiskAccess"` is not set, then sets that key.
  - `DropdownView` shows `accessNote` as a row above the footer, with an "Allow" button that opens `settingsURL`. `AppDelegate` re-probes off main on every panel open.
  - `MapWindowView` draws an unreadable row as a `lock` symbol, the name in secondary, and "Can't read" where the size goes, with `.help("Allow Full Disk Access in System Settings to see inside.")`. Hovering or clicking it does nothing. `unreadableNote` sits under the list header in secondary.

- [ ] **Step 1: Write the failing tests**

```swift
// FullDiskAccessTests.swift
@Test func probeOrderAndVerdicts() {
    func status(_ results: [String: Int32]) -> FDAStatus { FullDiskAccess.status(home: "/Users/u") { results[$0] ?? ENOENT } }
    #expect(status(["/Library/Application Support/com.apple.TCC/TCC.db": 0]) == .granted)
    #expect(status(["/Library/Application Support/com.apple.TCC/TCC.db": EPERM]) == .denied)
    #expect(status(["/Users/u/Library/Safari": EACCES]) == .denied)
    #expect(status(["/Users/u/Library/Mail": 0]) == .granted)
    #expect(status([:]) == .unknown)
}
@Test func settingsLinkOpensFullDiskAccess() {
    #expect(FullDiskAccess.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
}
// LiveIndexTests.swift
@Test func unreadableFoldersAreReadOnRetry() async throws {
    let root = try Fixtures.tree(["a/locked/f.bin": 2_000_000, "a/open.bin": 1_200_000])
    let locked = root.appending(path: "a/locked").path
    chmod(locked, 0); defer { chmod(locked, 0o755) }
    let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    #expect(try await live.read { $0.folders[Int($0.folder(atRelativePath: "a/locked")!)].flags.contains(.unreadable) })
    #expect(try await live.retryUnreadable() == 0)
    chmod(locked, 0o755)
    #expect(try await live.retryUnreadable() == 1)
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
// MapBuilderTests.swift
@Test func unreadableChildrenAreListedLast() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000, "locked/g.bin": 1_200_000])
    let locked = root.appending(path: "locked").path
    chmod(locked, 0); defer { chmod(locked, 0o755) }
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    let s = MapBuilder.build(index: idx, request: MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7), baseline: nil)
    #expect(s.list.last == ListRow(node: nil, name: "locked", size: 0, fraction: 0, kind: nil, isUnreadable: true))
    #expect(s.unreadableCount == 1 && s.unreadableNote == "1 folder here can't be read.")
}
// DropdownModelTests.swift
@Test func deniedAccessShowsANote() {
    func note(_ s: FDAStatus) -> String? {
        DropdownModel.make(drives: [Fixtures.internalDrive], selected: "I", connected: ["I"], summary: nil, space: nil,
                           activity: .ready, period: 7, connectedSince: nil, now: .now, fullDiskAccess: s).accessNote
    }
    #expect(note(.denied) == "Some folders can't be read without Full Disk Access.")
    #expect(note(.unknown) == nil && note(.granted) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter "probeOrderAndVerdicts|settingsLinkOpens|unreadableFoldersAreRead|unreadableChildrenAreListed|deniedAccessShows"`. Expected: build fails (`FDAStatus` not defined).
- [ ] **Step 3: Implement** the engine, model and builder changes, then run the same filter. Expected: PASS.
- [ ] **Step 4: Implement** `AccessExplainer` and the view changes.
- [ ] **Step 5: Run** `swift test && swift build --product Diskinventory`. Expected: all pass, and the build succeeds.
- [ ] **Step 6: Verify by hand.** Run `tccutil reset SystemPolicyAllFiles com.ooozzy.diskinventory`, then `scripts/make-app.sh debug && open .build/Diskinventory.app`. Expected:
  - The explainer appears once. "Open System Settings" lands on Privacy & Security › Full Disk Access.
  - The dropdown shows the note with "Allow".
  - In the map, `Users/<you>/Library` lists `Mail`, `Safari` and similar folders as "Can't read" rows, with "N folders here can't be read." under the header.
  - Grant access and reopen the app: the note is gone, those folders have sizes after the drive warms, and the explainer does not show again.
- [ ] **Step 7: Commit** `feat: Full Disk Access explainer, unreadable folders marked, retried once access is granted`

---

### Task 8: Hold a Finder eject until the index closes; recover from a refused eject

**Files:**
- Create: `Sources/DiskApp/UnmountGate.swift`, `Sources/Diskinventory/UnmountApprover.swift`, `Tests/DiskAppTests/UnmountGateTests.swift`
- Modify: `Package.swift` (Diskinventory target: `linkerSettings: [.linkedFramework("DiskArbitration")]`), `Sources/DiskApp/Map/MapModel.swift`, `Sources/Diskinventory/Map/MapWindowController.swift`, `Sources/Diskinventory/AppDelegate.swift`
- Test: `Tests/DiskAppTests/MapModelTests.swift`

**Interfaces:**
- Produces:
  - `public enum UnmountHold: Equatable, Sendable { case notOpen, closed, timedOut }`
  - `public final class UnmountGate: @unchecked Sendable`:
    - `init(limit: Duration = .seconds(2), close: @escaping @Sendable (String) async -> Void)`
    - `func setOpen(_ volumePaths: Set<String>)`: the real paths of external drives whose index is opening, scanning or ready. A trailing `/` is dropped.
    - `func approve(volumePath: String) -> UnmountHold`:
      - It blocks the calling thread and must not run on main (`dispatchPrecondition(condition: .notOnQueue(.main))`).
      - A path that is not open returns `.notOpen` at once.
      - Otherwise it starts `close(path)` once per path, so a second caller waits on the same close. It waits at most `limit`. On completion it removes the path from the open set and returns `.closed`; past the limit it returns `.timedOut`, and the close carries on.
      - It uses an `NSLock` and a `DispatchSemaphore` per path.
  - `final class UnmountApprover` (`Diskinventory`), with `init(gate: UnmountGate, log: Logger)`, `start()` and `stop()`:
    - It calls `DASessionCreate`, then `DASessionSetDispatchQueue` on a private serial queue at utility QoS, then `DARegisterDiskUnmountApprovalCallback(session, nil, callback, context)`.
    - The callback reads `kDADiskDescriptionVolumePathKey` from `DADiskCopyDescription`, calls `gate.approve`, and logs `unmount of <path> held N ms (<outcome>)` to the `drives` category.
    - It **always returns nil (approve)**.
  - `MapModel.reattach(to source: any MapSource) async`. It does nothing unless the status is `.offline` from `driveDisconnected()`. Otherwise it swaps the source, then holds and rebuilds at the kept `zoomPath` with the kept selection key. `source` becomes a `private var`.
  - `MapWindowController.reattach(controller: DriveController) async` rebinds `driveController` and the Combine sinks, then calls `model.reattach`. `var onBecameKey: (() -> Void)?` fires from `windowDidBecomeKey`.
  - `AppDelegate`:
    - It owns one `UnmountGate` and one `UnmountApprover`. The gate's close is `{ path in await MainActor.run { self.uuid(forVolumePath: path).flatMap { self.beginUnmount($0) } }?.value }`.
    - It feeds `setOpen` from a sink on every controller's `$activity`.
    - `syncVolumes()` ends by reattaching the map window when a mounted drive has a newer controller than the one the window holds.
    - The map window's `onBecameKey` calls `syncVolumes()`. The failure branch of `ejectSelected` already does.

- [ ] **Step 1: Write the failing tests**

```swift
// UnmountGateTests.swift
final class Closes: @unchecked Sendable { private let lock = NSLock(); private var list: [String] = []
    func add(_ p: String) { lock.withLock { list.append(p) } }; var paths: [String] { lock.withLock { list } } }
func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: body()) } }
}
func timed(_ body: @escaping @Sendable () -> UnmountHold) async -> (UnmountHold, Duration) {
    await offMain { let clock = ContinuousClock(); var out = UnmountHold.notOpen; let d = clock.measure { out = body() }; return (out, d) }
}
@Test func notOpenApprovesAtOnce() async {
    let g = UnmountGate(limit: .milliseconds(300)) { _ in }
    let (out, d) = await timed { g.approve(volumePath: "/Volumes/T7") }
    #expect(out == .notOpen && d < .milliseconds(50))
}
@Test func openDriveIsHeldUntilItCloses() async {
    let closes = Closes()
    let g = UnmountGate(limit: .seconds(2)) { closes.add($0); try? await Task.sleep(for: .milliseconds(100)) }
    g.setOpen(["/Volumes/T7"])
    let (out, d) = await timed { g.approve(volumePath: "/Volumes/T7/") }
    #expect(out == .closed && d >= .milliseconds(100) && d < .seconds(1) && closes.paths == ["/Volumes/T7"])
    #expect(await timed { g.approve(volumePath: "/Volumes/T7") }.0 == .notOpen)
}
@Test func slowCloseIsCutOffAtTheLimit() async {
    let g = UnmountGate(limit: .milliseconds(300)) { _ in try? await Task.sleep(for: .seconds(5)) }
    g.setOpen(["/Volumes/T7"])
    let (out, d) = await timed { g.approve(volumePath: "/Volumes/T7") }
    #expect(out == .timedOut && d >= .milliseconds(250) && d < .milliseconds(800))
}
@Test func concurrentApprovalsShareOneClose() async {
    let closes = Closes()
    let g = UnmountGate(limit: .seconds(2)) { closes.add($0); try? await Task.sleep(for: .milliseconds(150)) }
    g.setOpen(["/Volumes/T7"])
    async let a = timed { g.approve(volumePath: "/Volumes/T7") }
    async let b = timed { g.approve(volumePath: "/Volumes/T7") }
    let results = await [a.0, b.0]
    #expect(results == [.closed, .closed] && closes.paths.count == 1)
}
// MapModelTests.swift
@MainActor @Test func reattachAfterRefusedEjectShowsTheMapAgain() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/c.bin": 1_200_000]); let m = model(src)
    await m.open(path: "a", select: "a/b"); await m.settle()
    m.driveDisconnected()
    #expect(m.status == .offline && src.holds == 0)
    let fresh = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/c.bin": 1_200_000])
    await m.reattach(to: fresh); await m.settle()
    #expect(m.status == .ready && fresh.holds == 1 && m.zoomPath == "a" && m.snapshot?.nodes[m.selected!].key == "a/b")
    await m.reattach(to: src)
    #expect(src.holds == 0)
}
```

- [ ] **Step 2: Run** `swift test --filter "notOpenApproves|openDriveIsHeld|slowCloseIsCutOff|concurrentApprovals|reattachAfterRefused"`. Expected: build fails (`UnmountGate` not defined).
- [ ] **Step 3: Implement** `UnmountGate` and `MapModel.reattach`, then run the same filter. Expected: PASS.
- [ ] **Step 4: Implement** `UnmountApprover` and the controller and `AppDelegate` wiring.
- [ ] **Step 5: Run** `swift test && swift build --product Diskinventory`. Expected: all pass, and the build succeeds.
- [ ] **Step 6: Verify by hand with a scratch disk image.**

```bash
hdiutil create -size 2g -fs APFS -volname DIHold "$S/dihold.dmg" && hdiutil attach "$S/dihold.dmg"
for i in $(seq 1 4000); do mkdir -p "/Volumes/DIHold/d$((i % 200))/e$i"; : > "/Volumes/DIHold/d$((i % 200))/e$i/f"; done
scripts/make-app.sh debug && open .build/Diskinventory.app
# open the dropdown on DIHold so it warms, then within a second:
time diskutil unmount /Volumes/DIHold
log show --predicate 'subsystem == "com.ooozzy.diskinventory" AND category == "drives"' --last 2m
```
Expected:
  - `diskutil unmount` succeeds, `real` is under 2.5 s, and the log has `unmount of /Volumes/DIHold held N ms (closed)` (or `timedOut` with N at about 2000).
  - `ls ~/Library/Application\ Support/Diskinventory/Volumes/*/index.snapshot` lists DIHold's snapshot. Remount with `hdiutil attach "$S/dihold.dmg"`: the drive resumes rather than rescanning from zero.
  - Refused eject: open DIHold's map, then hold a file open with `exec 3< /Volumes/DIHold/d1/e1/f`, then eject it from Finder. Finder says the disk is in use, and the map window says "DIHold was disconnected." Click the map window: it shows the map again at the same folder. Run `exec 3<&-`, then `hdiutil detach /Volumes/DIHold; rm "$S/dihold.dmg"`.
- [ ] **Step 7: Commit** `feat: hold a Finder eject (at most 2 s) until the drive's index closes; reattach after a refused eject`

---

### Task 9: LiveIndex coalesces background churn and says what changed

After the full-window plan, the app measured about 11.7% CPU with the map window open on an idle machine (debug build), mostly in `LiveIndex.applyLocked` processing other apps' background FSEvents. This task cuts the engine's share. Task 10 cuts the map's share and measures the result.

**Files:**
- Modify: `Sources/DiskEngine/EventWatcher.swift`, `Sources/DiskEngine/LiveIndex.swift`, `Sources/DiskApp/DriveController.swift`, `Sources/Diskinventory/AppDelegate.swift` (DEBUG `--apply-stats`)
- Test: `Tests/DiskEngineTests/CoalesceTests.swift`, `Tests/DiskEngineTests/LiveIndexReadTests.swift`, `Tests/DiskEngineTests/EventWatcherTests.swift`

**Interfaces:**
- Consumes: `relistCount` (Task 5).
- Produces:
  - `EventWatcher.init(device:since:latency: Double = 3.0)`.
  - `public struct IndexChange: Equatable, Sendable { var generation: Int; var folders: [String: Int64]? }`:
    - `folders` maps relative paths of changed folders to the change in each folder's total. Only the outermost changed folders appear: a path whose ancestor is also present is dropped.
    - `folders` is nil when anything may have changed: a full rescan, a compaction, `setExclusions`, or `retryUnreadable`.
  - `LiveIndex.updates() -> AsyncStream<IndexChange>`, which used to be `AsyncStream<Int>`. `indexChanged(folders:)` yields it.
  - `public struct ApplyStats: Equatable, Sendable { var applies: Int; var foldersRelisted: Int; var subtreesRescanned: Int; var fullRescans: Int; var busy: Duration }` and `public func stats() -> ApplyStats`. `busy` is the time spent in `applyLocked`, and `foldersRelisted` is Task 5's `relistCount`.
  - `LiveIndex.init(..., coalesceWindow: Duration = .seconds(10))`. Internal `func enqueue(_ changes: [FSChange]) async`, which the watch task calls in place of `apply`. Internal `func apply(_ changes: [FSChange], advanceTo eventID: UInt64) async throws`. The public `apply(_:)` keeps its behavior and advances to the batch's maximum ID.
  - Internal `func injectMountPointLookup(_ lookup: @escaping @Sendable (String) -> String?)`. `open()` throws `DiskEngineError.posix("statfs <root>", errno)` when the lookup returns nil. Before, it fell back to `"/"`, which silently dropped every event for the internal disk.
  - `DriveController`: `@Published public private(set) var lastChange: IndexChange?`, set just before `generation += 1`.
  - DEBUG `--apply-stats`: every 60 s `AppDelegate` logs `apply stats <drive>: A applies, R relists, S subtrees, F full, B ms busy` for each warm controller, as deltas since the last line, to the `index` category.

The coalescing rule. The signatures leave this open:

```swift
// On the actor: deferred: [String: FSChange] (by path, merged: id = max, flags OR-ed), lastRelist: [String: ContinuousClock.Instant]
func enqueue(_ changes: [FSChange]) async {
    let now = clock.now
    var due: [FSChange] = []
    for c in changes {
        if c.historyLost || c.rescanSubtree { due.append(c); lastRelist[c.path] = now; continue }   // never delayed
        if let last = lastRelist[c.path], now - last < coalesceWindow {
            deferred[c.path] = deferred[c.path].map { merged($0, c) } ?? c
        } else {
            due.append(c); lastRelist[c.path] = now                                             // leading edge
        }
    }
    if due.contains(where: \.historyLost) { due += deferred.values; deferred = [:] }        // a full rescan covers them
    if !due.isEmpty {
        let applied = due.map(\.id).max()!
        // The stored ID never passes a change still waiting (spec 6.6).
        let floor = deferred.values.map(\.id).min().map { $0 - 1 } ?? applied
        try? await apply(due, advanceTo: min(applied, floor))
    }
    scheduleFlush()   // one task, due at the earliest lastRelist[path] + coalesceWindow among `deferred`;
                      // it applies those paths with the same floor rule, then reschedules.
                      // lastRelist entries older than the window are pruned here.
}
```

`close()` drops anything still deferred. Their IDs are above the stored event ID, so the next `open()` replays them.

- [ ] **Step 1: Measure the "before"** on the branch as it stands. `S` is the scratchpad directory.

```bash
scripts/make-app.sh debug && open .build/Diskinventory.app --args --show-map
# wait for "first map frame" (log stream --predicate 'category == "map"'), then leave the machine idle
P=$(pgrep -x Diskinventory); ps -o time= -p $P > "$S/cpu-before-0.txt"; sleep 120; ps -o time= -p $P > "$S/cpu-before-1.txt"
sample Diskinventory 10 -file "$S/sample-before.txt"
```
Expected: CPU time grows by about 14 s over 120 s, which is about 11.7%. Record the percentage. Also record the split of `applyLocked` samples in `sample-before.txt` across `BulkDirectoryReader.list`, `ScanIndex.relist`, `deepestFolder` and `scan`. If `deepestFolder` is 25% or more, add a lookup memo (relative path → `FolderID`) that lives for one `applyLocked`, and mention it in the commit body.

- [ ] **Step 2: Write the failing tests**

```swift
// CoalesceTests.swift
func opened(_ spec: [String: Int], window: Duration) async throws -> (LiveIndex, String, UInt64) {
    let root = try Fixtures.tree(spec); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir(), coalesceWindow: window)
    _ = try await live.open()
    return (live, Fixtures.realPath(root), await live.withIndex { $0.lastEventID })
}
func change(_ path: String, _ id: UInt64, subtree: Bool = false) -> FSChange { FSChange(path: path, id: id, rescanSubtree: subtree, historyLost: false) }

@Test func repeatedChangesToAFolderCoalesce() async throws {
    let (live, root, base) = try await opened(["a/f.bin": 10], window: .milliseconds(500))
    for i in 1...10 { await live.enqueue([change(root + "/a", base + UInt64(i))]); try await Task.sleep(for: .milliseconds(20)) }
    #expect(await live.stats().foldersRelisted == 1)
    try await Task.sleep(for: .milliseconds(700))
    #expect(await live.stats().foldersRelisted == 2 && (await live.withIndex { $0.lastEventID }) == base + 10)
    try await live.close()
}
@Test func anotherFolderIsNotDelayed() async throws {
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], window: .seconds(10))
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/b", base + 2)])
    #expect(await live.stats().foldersRelisted == 2)
    try await live.close()
}
@Test func deferredChangesHoldBackTheEventID() async throws {
    let (live, root, base) = try await opened(["a/f.bin": 10, "b/g.bin": 10], window: .seconds(10))
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2), change(root + "/b", base + 3)])
    #expect(await live.stats().foldersRelisted == 2 && (await live.withIndex { $0.lastEventID }) == base + 1)
    try await live.close()
}
@Test func subtreeRescansAreNeverDelayed() async throws {
    let (live, root, base) = try await opened(["a/f.bin": 10], window: .seconds(10))
    await live.enqueue([change(root + "/a", base + 1)])
    await live.enqueue([change(root + "/a", base + 2, subtree: true)])
    #expect(await live.stats().subtreesRescanned == 1)
    try await live.close()
}
@Test func changesNameTheOutermostFolderAndItsDelta() async throws {
    let (live, root, base) = try await opened(["a/x/f.bin": 10, "b/g.bin": 10], window: .seconds(10))
    var it = await live.updates().makeAsyncIterator()
    try Fixtures.write(URL(filePath: root + "/a/x/new.bin"), bytes: 2_000_000)
    try Fixtures.write(URL(filePath: root + "/a/top.bin"), bytes: 1_200_000)
    try await live.apply([change(root + "/a/x", base + 1), change(root + "/a", base + 2)])
    let expected = Fixtures.allocatedSize(URL(filePath: root + "/a/x/new.bin")) + Fixtures.allocatedSize(URL(filePath: root + "/a/top.bin"))
    #expect(await it.next()?.folders == ["a": Int64(expected)])
    try await live.apply([FSChange(path: root, id: base + 3, rescanSubtree: false, historyLost: true)])
    let full = await it.next()
    #expect(full != nil && full?.folders == nil)
    try await live.close()
}
@Test func missingMountPointFailsOpen() async throws {
    let live = LiveIndex(volumeRoot: try Fixtures.tree(["a/f.bin": 10]), store: try Fixtures.tempDir())
    await live.injectMountPointLookup { _ in nil }
    await #expect(throws: (any Error).self) { try await live.open() }
}
```

In `changesNameTheOutermostFolderAndItsDelta`, `a`'s delta covers both new files, and `a/x` is dropped because its ancestor `a` is present.

In `LiveIndexReadTests.updatesYieldAfterApplyAndFinishOnClose`, change `(await updates.next() ?? 0) >= 1` to `(await updates.next()?.generation ?? 0) >= 1`.

Rewrite `EventWatcherTests.reportsAFolderThatChanged` so it no longer depends on timing or on how `since: 0` is treated:

```swift
@Test(.timeLimit(.minutes(1))) func reportsAFolderThatChanged() async throws {
    let root = try Fixtures.tree(["watched/": 0])
    var st = stat(); stat(root.path, &st)
    let rootPath = Fixtures.realPath(root)
    let mapper = EventPathMapper(rootPath: rootPath, mountPoint: try #require(EventPathMapper.mountPoint(of: rootPath)))
    // A concrete start ID: events after it arrive even if the stream starts late. No sleep.
    let w = EventWatcher(device: st.st_dev, since: FSEventsGetCurrentEventId(), latency: 0.2)
    try w.start(); defer { w.stop() }
    try Data([1]).write(to: root.appending(path: "watched/new"))
    for await batch in w.changes where batch.contains(where: { mapper.absolute($0.path) == rootPath + "/watched" }) { return }
    Issue.record("no event for the changed folder")
}
```

- [ ] **Step 3: Run** `swift test --filter "repeatedChangesToAFolder|anotherFolderIsNot|deferredChangesHold|subtreeRescansAre|changesNameTheOutermost|missingMountPoint|updatesYieldAfterApply|reportsAFolderThatChanged"`. Expected: build fails (`enqueue` not defined).
- [ ] **Step 4: Implement** the listed members. `DriveController`'s `watching` loop sets `lastChange` from each `IndexChange`.
- [ ] **Step 5: Run** `swift test`, then `for i in $(seq 20); do swift test --filter reportsAFolderThatChanged 2>&1 | tail -1; done`. Expected: all pass, and 20 lines that each report a pass.
- [ ] **Step 6: Commit** `perf: coalesce FSEvents churn per folder, report what changed; fail open when statfs fails`, with Step 1's numbers in the body.

---

### Task 10: The map skips builds nobody would see; measure idle CPU

**Files:**
- Modify: `Sources/DiskApp/Map/MapModel.swift`, `Sources/Diskinventory/Map/MapWindowController.swift`
- Test: `Tests/DiskAppTests/MapModelTests.swift`

**Interfaces:**
- Consumes: `IndexChange`, `DriveController.lastChange` (Task 9).
- Produces:
  - `MapModel.sourceChanged(_ change: IndexChange? = nil)`. Existing callers that pass nothing still always build, subject to the throttle.
  - `public static func visibleDelta(_ change: IndexChange?, zoomPath: String) -> UInt64?`:
    - nil (must build) when `change` or `change.folders` is nil, or when a changed path is a strict ancestor of `zoomPath`.
    - Otherwise the sum of `|delta|` over the paths equal to `zoomPath` or under it. Every path is under `""`.
  - Accumulation: the model adds each `visibleDelta` to a pending sum, and builds when `pending × width × height / max(snapshot.total, 1) ≥ 1` (1 pt² of map) or when `visibleDelta` is nil. Every build resets the sum.
  - `public var isVisible: Bool = true`. While false, `sourceChanged` only marks the model dirty. Setting it back to true runs one build if dirty.
  - `MapWindowController`:
    - The `$generation` sink calls `model.sourceChanged(controller.lastChange)`. The `$activity` and `$period` sinks call `model.sourceChanged()`.
    - `NSWindow.didChangeOcclusionStateNotification`, `didMiniaturizeNotification` and `didDeminiaturizeNotification` set `model.isVisible = window.occlusionState.contains(.visible) && !window.isMiniaturized`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func changesOutsideTheZoomedFolderAreInvisible() {
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["b": 5_000_000]), zoomPath: "a") == 0)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["a/x": -3_000_000, "ab": 9, "b": 9]), zoomPath: "a") == 3_000_000)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["": 1]), zoomPath: "a") == nil)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: ["b": 7]), zoomPath: "") == 7)
    #expect(MapModel.visibleDelta(IndexChange(generation: 2, folders: nil), zoomPath: "a") == nil)
    #expect(MapModel.visibleDelta(nil, zoomPath: "") == nil)
}
@MainActor @Test func tinyChangesWaitUntilTheyShow() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    m.setSize(CGSize(width: 10, height: 10))
    await m.open(path: "a", select: nil); await m.settle(); let before = src.builds
    m.sourceChanged(IndexChange(generation: 2, folders: ["a": 1_000])); await m.settle()
    #expect(src.builds == before)
    m.sourceChanged(IndexChange(generation: 3, folders: ["a": 30_000])); await m.settle()
    #expect(src.builds == before + 1)
    m.sourceChanged(IndexChange(generation: 4, folders: ["zzz": 9_000_000])); await m.settle()
    #expect(src.builds == before + 1)
}
@MainActor @Test func hiddenWindowBuildsOnceWhenShown() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    m.isVisible = false
    for _ in 0..<3 { m.sourceChanged() }; await m.settle()
    #expect(src.builds == before)
    m.isVisible = true; await m.settle()
    #expect(src.builds == before + 1)
}
```

Zoomed into `a`, the total is about 2 MB on a 10 × 10 map, so 1 pt² is about 20 KB. 1,000 bytes waits, 1,000 + 30,000 builds, and a change in `zzz` (outside `a`) never builds.

- [ ] **Step 2: Run** `swift test --filter "changesOutsideTheZoomed|tinyChangesWait|hiddenWindowBuilds"`. Expected: build fails (`visibleDelta` not defined).
- [ ] **Step 3: Implement** the listed members.
- [ ] **Step 4: Run** `swift test`. Expected: all pass, including `sourceChangesThrottle` and `offlineSourceShowsDisconnected`.
- [ ] **Step 5: Measure the "after"** exactly as in Task 9 Step 1, adding `--apply-stats` to the debug run, then repeat with `scripts/make-app.sh release`:

```bash
P=$(pgrep -x Diskinventory); ps -o time= -p $P > "$S/cpu-after-0.txt"; sleep 120; ps -o time= -p $P > "$S/cpu-after-1.txt"
log show --predicate 'subsystem == "com.ooozzy.diskinventory" AND category == "index"' --last 3m | grep "apply stats"
```
Expected:
  - Debug build: **at most 3.0% average** over 120 s, down from 11.7% (Decision 27). Release build: at most 1.5%.
  - `apply stats` shows relists per minute down from the "before" sample.
  - Zoom into a folder no app is writing to, such as `Applications`: the `map` log shows no map builds for 60 s.
  - A real change still shows: `mkfile 1g ~/Downloads/cpu-test.bin` updates the map within about 5 s. Delete the file afterwards.
- [ ] **Step 6: If a target is missed,** take `sample Diskinventory 10` and record the top 5 frames of ours in the commit body, then stop and report. Don't tune blindly.
- [ ] **Step 7: Commit** `perf: map skips builds outside the zoomed folder or while hidden; idle CPU measured`, with both before and after numbers (debug and release) and the apply-stats lines in the body.

---

### Task 11: Distribution prep: signing, notarization, release notes for the founder

**Files:**
- Create: `scripts/release.sh`, `scripts/Diskinventory.entitlements`, `docs/release.md`
- Modify: `scripts/make-app.sh`

**Interfaces:**
- Produces:
  - `scripts/Diskinventory.entitlements`: a plist with an empty `<dict/>`, and a comment: "Hardened runtime with no exceptions. Not sandboxed: the app needs Full Disk Access to read every folder."
  - `make-app.sh`:
    - It reads `VERSION` (default `0.1`) and `BUILD_NUMBER` (default `git rev-list --count HEAD`) into `CFBundleShortVersionString` and `CFBundleVersion`.
    - It adds `NSHumanReadableCopyright` "© 2026 ooozzy".
    - It signs ad hoc with `--options runtime --entitlements scripts/Diskinventory.entitlements` (Decision 30).
  - `scripts/release.sh`, using `set -euo pipefail`. In order:
    1. If any of `DEVELOPER_ID_APPLICATION`, `TEAM_ID` or `NOTARY_PROFILE` is empty, it prints `release.sh: missing <names, space-separated>` and `See docs/release.md for what each one is.` to stderr and exits 64.
    2. If `DEVELOPER_ID_APPLICATION` does not end in `($TEAM_ID)`, it prints `release.sh: the signing identity is not for team $TEAM_ID` and exits 64.
    3. It runs `scripts/make-app.sh release`.
    4. It runs `codesign --force --timestamp --options runtime --entitlements scripts/Diskinventory.entitlements --sign "$DEVELOPER_ID_APPLICATION" .build/Diskinventory.app`, then `codesign --verify --strict --verbose=2` on it.
    5. It zips with `ditto -c -k --keepParent` to `.build/Diskinventory-$VERSION.zip`.
    6. It runs `xcrun notarytool submit <zip> --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_ID" --wait`, and fails on any status but Accepted.
    7. It runs `xcrun stapler staple` and `xcrun stapler validate` on the app.
    8. It runs `spctl --assess --type execute -vv` on the app.
    9. It re-zips the stapled app to the same path and prints `Release: .build/Diskinventory-$VERSION.zip`.
    - With `DRY_RUN=1`, steps 4 to 8 print each command prefixed with `+ ` instead of running it. Step 3 still runs, so the build is real.
  - `docs/release.md`, for the founder:
    - **What you supply:** Apple Developer Program membership; a "Developer ID Application" certificate in the login keychain (its full name is `DEVELOPER_ID_APPLICATION`); the Team ID; an app-specific password stored with `xcrun notarytool store-credentials diskinventory-notary --apple-id <id> --team-id <TEAM_ID>`, whose profile name is `NOTARY_PROFILE`.
    - **How to cut a release:** the command line, what each step checks, and how to verify a download (`spctl`, `stapler validate`, and opening it on a second Mac).
    - **Launch at login** only registers from `/Applications`.
    - **Full Disk Access** has to be granted again after the bundle ID or the signing team changes.
    - **Sparkle (not included, Decision 28):** add the package `https://github.com/sparkle-project/Sparkle` (2.x), which is a third-party dependency and needs your sign-off. Create the keys with `generate_keys`, then put `SUPublicEDKey` and `SUFeedURL` in `Info.plist`. Start `SPUStandardUpdaterController` in `AppDelegate`, and add "Check for Updates…" to the app menu (`MainMenuSpec`). Sign each archive with `sign_update` and host `appcast.xml`. `release.sh` must then sign Sparkle's nested `Autoupdate`, `Updater.app` and `XPCServices/*.xpc` with the Developer ID before the app.

- [ ] **Step 1: Write the checks** (these are this task's tests):

```bash
bash -n scripts/release.sh && plutil -lint scripts/Diskinventory.entitlements
env -u DEVELOPER_ID_APPLICATION -u TEAM_ID -u NOTARY_PROFILE scripts/release.sh; echo "exit $?"
DEVELOPER_ID_APPLICATION="Developer ID Application: A (AAAA111111)" TEAM_ID=BBBB222222 NOTARY_PROFILE=p scripts/release.sh; echo "exit $?"
DRY_RUN=1 VERSION=0.2 DEVELOPER_ID_APPLICATION="Developer ID Application: A (AAAA111111)" TEAM_ID=AAAA111111 NOTARY_PROFILE=p scripts/release.sh | grep '^+ '
```

- [ ] **Step 2: Run them.** Expected: they fail, because `scripts/release.sh` does not exist.
- [ ] **Step 3: Implement** the two scripts, the entitlements file and `docs/release.md`.
- [ ] **Step 4: Run the checks again.** Expected:
  - `scripts/Diskinventory.entitlements: OK`
  - `release.sh: missing DEVELOPER_ID_APPLICATION TEAM_ID NOTARY_PROFILE`, `See docs/release.md for what each one is.`, `exit 64`
  - `release.sh: the signing identity is not for team BBBB222222`, `exit 64`
  - `+ codesign --force --timestamp --options runtime …`, `+ codesign --verify …`, `+ xcrun notarytool submit …`, `+ xcrun stapler staple …`, `+ xcrun stapler validate …`, `+ spctl --assess …`, in that order
  - `plutil -extract CFBundleShortVersionString raw .build/Diskinventory.app/Contents/Info.plist` prints `0.2`
  - `shellcheck scripts/*.sh`, if installed, prints nothing.
- [ ] **Step 5: Run the hardened dev build.** Run `scripts/make-app.sh debug && codesign -d --verbose=2 .build/Diskinventory.app 2>&1 | grep flags`. Expected: `flags=0x10002(adhoc,runtime)`. Then `open .build/Diskinventory.app --args --show-map`: the dropdown and the map draw as before, which shows the runtime Metal shader compile works under the hardened runtime.
- [ ] **Step 6: Commit** `build: release script for Developer ID signing and notarization; hardened dev builds; release notes`

---

## Self-review

- **Spec coverage:**
  - 3.4 basket and review: Tasks 2, 3 and 4. Drag, ⌫, ⌘K and "Review N GB to clear" are in Task 4. The checkbox versus instruction rule is in Tasks 2 and 4. Move to Trash only, never emptying, "Freed X GB" and immediate updates are in Tasks 2 and 3.
  - 3.5 lenses: the JSON rule list with pattern, name, explanation and safety, the initial set, and Trash shown but not trashed are in Task 1. The hover card uses the same rules (Task 1).
  - 3.2: the "Review N GB to clear" button is in Tasks 3 and 4, and the live "Settings ⌘," in Task 6. 3.3: "Add to basket ⌫" in the key bar and the basket bar over the map are in Task 4.
  - 3.1 and 4: icon-only mode and the 15% / 5% thresholds (now settable) are in Task 6. User-chosen drive tints from the 8-tint palette are in Task 6.
  - 5: Full Disk Access onboarding, the deep link and unreadable folders are in Task 7. Launch at login stays gated to `/Applications` (Task 6). Signed and notarized distribution is Task 11. Sparkle is decided and documented (Decision 28, Task 11).
  - 9: the settings window covers menu bar display, launch at login, warning thresholds, drive tints and excluded folders (Tasks 5 and 6).
  - Deferred items: the eject hold is Task 8; idle CPU is Tasks 9 and 10; `statfs` and the watcher flake are in Task 9; the refused-eject window is in Task 8.
- **Types:**
  - `LensRules.bundled`, `rule(covering:)`, `LensHit`, `LensReport.total(_:)`: Task 1 → Tasks 2, 3, 4.
  - `BasketItem.from(hit:)`, `Basket`, `BasketStore.drop`, `ReviewSheet.trashable`, `TrashOutcome.cleared`, `FixtureTrash`: Task 2 → Tasks 3, 4.
  - `DriveController.lens`, `clearable`, `trash(_:backend:)`, `refreshLens(force:)`: Task 3 → Tasks 4, 5.
  - `relistCount`: Task 5 → Task 9's `stats()`. `DriveController.setExclusions`: Task 5 → Task 6.
  - `IndexChange`, `lastChange`: Task 9 → Task 10. `MapModel.reattach(to:)`: Task 8.
- **Proportion:** the only bodies written out are the lens pattern step and walk (Task 1) and the coalescing rule (Task 9). Both are algorithms the signatures don't determine. The JSON and the UI strings are exact copy. Everything else is signatures, rules with exact values, and tests.
