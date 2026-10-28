# Full Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The full window from the approved flat mockup: a squarified treemap drawn with Metal next to a sorted side list, with a drive chip, breadcrumb, ⌘K command bar, hover card, Quick Look and a Raycast-style key bar. It opens from the dropdown, keeps the drive's index warm while it is open, and stays under the memory target.

**Architecture:** A pure layout module (`Squarify`, `TreemapLayout`) tiles one zoom level, breadth first, under a rectangle budget. `MapBuilder` runs inside the `LiveIndex` actor under its lock, so it is off the main thread and never sees a half-applied index. It turns the layout into a `MapSnapshot` of plain values: nodes with kind, name and period growth, breadcrumb, and list rows. `MapModel` (main actor, unit-tested with a fake source) owns the zoom path, selection, hover and coalesced rebuilds. The Metal renderer only uploads a snapshot's instance buffer and label atlas, both built off main. During a zoom, only a uniform changes from frame to frame. Everything around the map is SwiftUI/AppKit.

**Tech Stack:** Swift 6.3, AppKit, SwiftUI, MetalKit (`MTKView`), Metal shaders compiled at runtime from source, CoreText (label atlas), Quartz (`QLPreviewPanel`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-28-disk-inventory-design.md` (sections 3.2 actions and rows, 3.3, 4, 5 Dock icon, 6.5, 7). Visual target: `docs/superpowers/specs/2026-10-28-mockups/main-window-flat.html`. Builds on Plans 1 to 3, merged to `main`.

## Decisions this plan makes (founder to check)

1. **The map is nested.** Children of the zoom level are labelled blocks. A top-level folder big enough for a 48 pt label header shows its own contents below the header, recursing down to the 2 pt limit. Deeper blocks have no header and are shaded darker by depth (×0.9 per level, never below ×0.7). The mockup shows one level, but nesting is what shows that "Containers" holds Docker, as in Disk Inventory X.
2. **Selection, the hover outline, dimming and the side list work on top-level blocks.** The hover card describes the deepest item under the pointer. That matches the mockup: the "Docker" block is outlined while the card says "Docker.raw".
3. **Zoom state is a relative path, not a `FolderID`.** Compaction renumbers folders. A path that no longer exists falls back to its deepest existing ancestor.
4. **Clicking a "What changed" row opens the map at the item's parent with the item selected,** so its growth strip shows in context.
5. **The window uses the drive's current period from the dropdown** (default 7 days). The window has no period control of its own.
6. **Growth per block comes from the history baseline,** using `ChangeReport`'s rule: an item missing from the baseline counts as just under the floor. An item that is under the floor now and was missing then has no strip. Strips start at 100 MB of growth.
7. **"Add to basket ⌫" is left out of the key bar** until Plan 5 brings the basket.
8. **The search field holds commands only, plus "Go to <child>" for the current level.** Searching the whole disk by name is deferred.
9. **Shaders are compiled at runtime from a Swift string,** because the SwiftPM command line does not build `.metal` files.
10. **Labels are rasterized with CoreText into one atlas, off main,** and hidden during the 200 ms zoom (scaled text looks wrong).
11. **The side list shows at most 200 rows,** plus one "N more items" row.
12. **While a drive's first scan runs, the window shows a message.** The map appears when the scan finishes; there is no progressive map.
13. **One map window at a time, for one drive.** ↑/↓ move the selection, and zooming out selects the folder you came from.
14. **Index changes rebuild the map at most once per second.**
15. **Hover-card explanations come from a small built-in table.** Plan 5's junk lenses replace it.
16. **Offline drives in the dropdown show the cached summary's bar and rows.** The rows are not clickable, "Open map" is disabled, and the footer reads "Data from <date>".
17. **Latency targets (the spec gives none):** the window is on screen under 100 ms after the click, and the first map frame appears under 500 ms with a warm index and under 3 s with a cold one.
18. **The toolbar row is 52 pt tall,** the height of an empty unified `NSToolbar`, so the real traffic lights sit centered in it as in the mockup. The mockup draws it at 48.

## Global Constraints

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
- **Zoom runs at display refresh rate with no dropped frames on Apple silicon** (spec 7). Frame-to-frame, only a uniform changes. It takes about 200 ms and is off when Reduce Motion is on.
- Window open on a 5-million-file disk: **under 150 MB resident** (spec 7). On close, the window and its map data are released, and the Dock icon shows only while the window is open (spec 5).
- Layout (spec 6.5): squarified, children sorted by size descending, current zoom level only. Anything under 2 pt folds into the parent's small-files block. At most 50,000 rectangles; past that, the smallest siblings merge into "N more items".
- Metal draws only the treemap: blocks, labels, hover outline, dimming, growth strip. Everything else is SwiftUI/AppKit.
- Nothing is deleted from the window in this plan (basket and review are Plan 5).

## Review Focus

1. **The zoomed folder is deleted, or the index is compacted, while the window shows it.** The map moves to the nearest existing ancestor; there is no crash and no wrong folder. Pinned in Task 4 (`zoomByPathSurvivesDeletionAndCompaction`).
2. **The drive in the window is ejected or unplugged.** The window's hold must not block the eject or re-warm the index, and the window says the drive was disconnected. Pinned in Task 6 (`holdAfterUnmountStaysOffline`, `offlineSourceShowsDisconnected`).
3. **One folder holds 200,000 files** (a mail store, a photo cache). The layout stays at the 50,000 cap and the list stays at 201 rows. Pinned in Task 3 (`hugeFolderStaysUnderCap`) and Task 4 (`listRowsCapAt200PlusRemainder`).
4. **Live window resize, or rapid zoom clicks.** Rebuilds coalesce, the latest request wins, and a stale layout is never shown last. Pinned in Task 6 (`rapidRequestsCoalesceLatestWins`).
5. **A zoom level where everything is zero bytes** (an empty drive, a folder of iCloud placeholders). The map shows "Nothing here takes up space." instead of a blank map or NaN rectangles. Pinned in Task 3 (`zeroSizedItemsMakeNoRects`) and Task 6 (`emptyLevelShowsMessage`).

## File map

```
Sources/DiskEngine/LiveIndex.swift              read(_:), updates(), baseline(days:), storeDirectory(base:uuid:) (modify)
Sources/DiskEngine/History.swift                SizeSnapshot.estimatedSize(of:isFile:) (modify)
Sources/DiskEngine/ContentKind.swift            classify(parts:) public (modify)
Sources/DiskEngine/MemoryReport.swift           tablesBytes; holder fix if found (modify)
Sources/diskscan/main.swift                     --hold, unexplained line (modify)
Sources/DiskApp/Treemap/Squarify.swift          squarified tiling
Sources/DiskApp/Treemap/TreemapLayout.swift     one zoom level: fold, cap, headers, hit test
Sources/DiskApp/Treemap/ZoomAnimation.swift     zoom transform and easing
Sources/DiskApp/Treemap/TreemapScene.swift      GPU instances, appearance rule, shader source
Sources/DiskApp/Map/MapSnapshot.swift           MapRequest, MapNode, Crumb, ListRow, MapSnapshot
Sources/DiskApp/Map/MapBuilder.swift            ScanIndex -> MapSnapshot
Sources/DiskApp/Map/KnownItems.swift            one-line explanations
Sources/DiskApp/Map/HoverCard.swift             hover card text
Sources/DiskApp/Map/LabelFit.swift              label lines that fit a block
Sources/DiskApp/Map/MapCommands.swift           ⌘K items and key mapping
Sources/DiskApp/Map/MapModel.swift              MapSource protocol, MapModel
Sources/DiskApp/DriveController.swift           hold/release, generation, buildMap (modify)
Sources/DiskApp/DropdownModel.swift             row paths, canOpenMap, offline data (modify)
Sources/DiskApp/Format.swift                    periodWords (modify)
Sources/Diskinventory/Map/TreemapRenderer.swift MTKViewDelegate
Sources/Diskinventory/Map/TreemapMTKView.swift  MTKView subclass: mouse, resize
Sources/Diskinventory/Map/LabelAtlas.swift      CoreText atlas
Sources/Diskinventory/Map/TreemapView.swift     NSViewRepresentable
Sources/Diskinventory/Map/MapWindowView.swift   toolbar, list, hover card, key bar, command list
Sources/Diskinventory/Map/MapWindowController.swift window, keys, Quick Look, Dock icon
Sources/Diskinventory/MainThreadWatchdog.swift  --watchdog stall logger
Sources/Diskinventory/AppDelegate.swift         openMap, offline summaries (modify)
Sources/Diskinventory/DropdownView.swift        Open map, clickable rows (modify)
Tests/DiskEngineTests/LiveIndexReadTests.swift
Tests/DiskAppTests/TreemapLayoutTests.swift  MapBuilderTests.swift  MapTextTests.swift
Tests/DiskAppTests/MapModelTests.swift  TreemapSceneTests.swift  (DriveController/DropdownModel/Format tests: modify)
```

---

### Task 1: Engine hooks for the window

**Files:**
- Modify: `Sources/DiskEngine/LiveIndex.swift`, `Sources/DiskEngine/History.swift`, `Sources/DiskEngine/ContentKind.swift`
- Test: `Tests/DiskEngineTests/LiveIndexReadTests.swift`

**Interfaces:**
- Produces:
  - `extension LiveIndex { public func read<R: Sendable>(_ body: @Sendable (ScanIndex) throws -> R) async throws -> R }`: takes the lock, like `summary(since:)`. Its precondition is `open()`. `withIndex` stays as it is for existing callers.
  - `public func updates() -> AsyncStream<Int>`: yields a rising generation (starting at 1) each time the index changes after `open()`, which means an apply that touched it or a compaction (FolderIDs change). Any number of subscribers. Every stream finishes on `close()`. Implement it with one `private func indexChanged()` that replaces the `cachedKinds = nil` assignments in `apply` and `saveLocked`.
  - `public func baseline(days: Int, now: Date = .now) async throws -> SizeSnapshot?`: the history snapshot on or before `today − days`, or nil when there is none.
  - `public static func storeDirectory(base: URL, uuid: String) -> URL`: `base/Volumes/<uuid>`. It does not create the directory. `storeDirectory(base:volume:)` calls it.
  - `extension SizeSnapshot { public func estimatedSize(of key: String, isFile: Bool) -> UInt64 }`: `sizes[key]` if present; `0` for `""` when missing; otherwise `min(floor − 1, estimatedSize(of: parent, isFile: false))`, where the floor is `fileFloor` or `folderFloor`. These are the same rules as `ChangeReport`'s inner `size`.
  - `ContentKind.classify(parts:)` becomes `public` (lowercased components).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func readSeesTheOpenIndex() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    #expect(try await live.read { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
@Test func updatesYieldAfterApplyAndFinishOnClose() async throws {
    let root = try Fixtures.tree(["a/f.bin": 10]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    var updates = await live.updates().makeAsyncIterator()
    try Fixtures.write(root.appending(path: "a/g.bin"), bytes: 1_200_000)
    let next = await live.withIndex { $0.lastEventID } + 1_000_000_000
    try await live.apply([FSChange(path: Fixtures.realPath(root) + "/a", id: next, rescanSubtree: false, historyLost: false)])
    #expect((await updates.next() ?? 0) >= 1)
    try await live.close()
    #expect(await updates.next() == nil)
}
@Test func baselineIsTheSnapshotAtThePeriodStart() async throws {
    let root = try Fixtures.tree(["a/f.bin": 10]); let live = LiveIndex(volumeRoot: root, store: try Fixtures.tempDir())
    _ = try await live.open()
    let now = Date.now
    try await live.recordHistory(now: now.addingTimeInterval(-7 * 86_400))
    #expect(try await live.baseline(days: 7, now: now) != nil)
    #expect(try await live.baseline(days: 30, now: now) == nil)
    try await live.close()
}
@Test func estimatedSizeFollowsChangeReportRules() {
    let s = SizeSnapshot(sizes: ["": 5_000_000_000, "a": 300_000_000])
    #expect(s.estimatedSize(of: "a", isFile: false) == 300_000_000)
    #expect(s.estimatedSize(of: "a/b", isFile: false) == 99_999_999)
    #expect(s.estimatedSize(of: "a/big.mov", isFile: true) == 300_000_000)
    #expect(SizeSnapshot(sizes: [:]).estimatedSize(of: "", isFile: false) == 0)
}
@Test func storeDirectoryByUUID() {
    #expect(LiveIndex.storeDirectory(base: URL(filePath: "/x"), uuid: "U").path == "/x/Volumes/U")
}
```

- [ ] **Step 2: Run** `swift test --filter LiveIndexReadTests`. Expected: build fails (`read` not defined).
- [ ] **Step 3: Implement** the listed members. `updates()` stores continuations keyed by a UUID and removes them in `onTermination`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: locked reads, change stream and period baseline on LiveIndex`

---

### Task 2: Find what holds the scan's unexplained memory

Plan 2 measured a full scan of `/System/Volumes/Data` at about 134 MB footprint, but the tables explain only about 50 MB. `malloc_zone_pressure_relief` frees nothing, so the rest is live. This task finds the holder before the window adds its own memory.

**Files:**
- Modify: `Sources/diskscan/main.swift`, `Sources/DiskEngine/MemoryReport.swift`
- Modify (only if the holder is ours): the file that holds it, plus `Tests/DiskEngineTests/MemoryReportTests.swift`

**Interfaces:**
- Produces:
  - `MemoryReport.tablesBytes: Int`: the sum of the four table fields.
  - `diskscan <path> --memory --hold`. With `--memory`, diskscan reads `MemoryReport.footprint()` before the scan and prints `baseline:           X MB`. After the existing lines it prints `unexplained:        X MB`, which is footprint now − baseline − `tablesBytes`. With `--hold` it then prints `holding: pid <pid>. Attach heap or vmmap now; Ctrl-C exits.` and blocks on a `SIGINT` dispatch source, keeping `index` alive (`withExtendedLifetime(index)`).

- [ ] **Step 1: Add `--hold`, `baseline` and `unexplained`** to `diskscan`, and `tablesBytes` to `MemoryReport`.
- [ ] **Step 2: Reproduce.** `S` below is the session scratchpad directory.

```bash
swift build -c release --product diskscan
.build/release/diskscan /System/Volumes/Data --memory --hold > "$S/plain.txt" 2>&1 &
# wait until plain.txt contains "holding:"
PID=$(pgrep -n diskscan); footprint -p $PID > "$S/footprint.txt"; vmmap -summary $PID > "$S/vmmap.txt"; kill -INT $PID
MallocStackLogging=lite .build/release/diskscan /System/Volumes/Data --memory --hold > "$S/msl.txt" 2>&1 &
# wait for "holding:"
PID=$(pgrep -n diskscan); heap -s -H $PID > "$S/heap.txt"; malloc_history $PID -allBySize > "$S/history.txt"; kill -INT $PID
```
Expected: `plain.txt` shows `unexplained:` at about 80 MB or more, which reproduces Plan 2. Use the run without stack logging for every total. Stack logging adds its own memory, so use that run only for stacks.

- [ ] **Step 3: Classify the holder.** Read `vmmap.txt` first:
  - Most dirty memory in `MALLOC_*` regions: take the top classes in `heap.txt` and the top stacks in `history.txt`.
  - Dirty "mapped file" regions for `files.bin` or `filenames.bin`: the holder is `MappedAppendFile`.

  A stack is **ours** when it accounts for 10 MB or more and has a `DiskEngine` frame. Check these first, from reading the code: `DirectoryListing.entries` arrays or entry names kept alive after `integrate`; `PagedArray` or `NamePool` capacity well past their count; the `hardLinkOwners` dictionary and the per-listing `pass` sets; the per-worker 64 KB buffers; and task allocations kept by the collector loop.

- [ ] **Step 4: Apply the decision rule.**
  - **Ours:** fix it at the source. Then add a regression test, `scanReleases<Holder>()`, to `MemoryReportTests.swift`. It scans `Fixtures.tree` with 2,000 folders of 5 files each and asserts that the holder's size or count after the scan is at most a bound stated in the test's comment, derived from the folder count. If the structure legitimately stays, add it as a `MemoryReport` field so `diskscan` names it. Re-run Step 2. Expected: `unexplained:` at 20 MB or less.
  - **Not ours** (system frameworks, dyld, Swift runtime metadata, kernel accounting): change nothing. Put the evidence (the top 5 `vmmap` regions and `heap` classes) in the commit body. Task 10 decides whether the 150 MB target still holds.
  - **Both:** fix ours and record the rest.
- [ ] **Step 5: Run** `swift test`. Expected: all pass.
- [ ] **Step 6: Commit** `perf: find what holds the scan's unexplained memory`, with the before and after `footprint`, `tables` and `unexplained` numbers in the body.

---

### Task 3: Squarified layout of one zoom level

**Files:**
- Create: `Sources/DiskApp/Treemap/Squarify.swift`, `Sources/DiskApp/Treemap/TreemapLayout.swift`, `Sources/DiskApp/Treemap/ZoomAnimation.swift`
- Test: `Tests/DiskAppTests/TreemapLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public enum Squarify { public static func tiles(_ sizes: [Double], in rect: CGRect) -> [CGRect] }`: `sizes` are sorted descending and all > 0. It returns one tile per size, in the same order, tiling `rect` exactly. Coordinates are points with a top-left origin.
  - `public enum TreemapRef: Hashable, Sendable { case folder(FolderID), file(FileIndex), small(parent: FolderID, files: Int, folders: Int), more(parent: FolderID, count: Int) }`
  - `public struct TreemapItem: Equatable, Sendable { public var ref: TreemapRef; public var size: UInt64 }`
  - `public protocol TreemapSource { func items(in folder: FolderID) -> [TreemapItem] }`: the items directly inside `folder`, in any order. The folder's small files come as one `.small(parent:files:folders: 0)`.
  - `public struct TreemapOptions: Equatable, Sendable { var gutter: CGFloat = 2; var minSide: CGFloat = 2; var headerHeight: CGFloat = 48; var cap: Int = 50_000 }`. A `headerHeight` of 0 means no headers, and every folder recurses.
  - `public struct TreemapRect: Equatable, Sendable { var ref: TreemapRef; var size: UInt64; var frame: CGRect; var depth: Int; var parent: Int; var firstChild: Int; var childCount: Int; var hasHeader: Bool }`. `frame` is the drawn frame: the tile inset by `gutter / 2`. `depth` 1 is a child of the zoom root, and `parent` is −1 there. A rect's children are contiguous.
  - `public struct TreemapLayout: Sendable { var rects: [TreemapRect]; var bounds: CGRect; var topLevelCount: Int; static func make(source: some TreemapSource, root: FolderID, bounds: CGRect, options: TreemapOptions = .init()) -> TreemapLayout; func hitTest(_ p: CGPoint) -> Int?; func topLevel(of index: Int) -> Int }`. It has a public memberwise init for tests. `hitTest` returns the deepest rect whose `frame` contains `p`. Depth-1 rects are `0..<topLevelCount`.
  - `public struct ZoomAnimation: Equatable, Sendable { static let duration = 0.2; var bounds: CGRect; var start: CGRect; static func zoomIn(from block: CGRect, bounds: CGRect) -> ZoomAnimation; static func zoomOut(to child: CGRect, bounds: CGRect) -> ZoomAnimation; func transform(progress: Double) -> (scale: CGSize, offset: CGPoint); static func eased(_ t: Double) -> Double }`. `start` is where `bounds` is drawn at progress 0. For `zoomIn`, `start` is the block. For `zoomOut`, `start` is the rect that magnifies `child` to fill `bounds`. Drawing maps a point as `p · scale + offset`. `eased(t) = 1 − (1 − t)³`.

`make` works breadth first from a queue of folder jobs `(folder, area, depth, parentRect)`. The first job is `(root, bounds, 1, −1)`. For each job:
1. Take the items with size > 0, sorted by size descending. A **tiny** item is one with `size / total × area.width × area.height < minSide²`. Tiny items and the folder's own `.small` item merge into one `.small(parent:files:folders:)`, which counts files and folders and is placed by its size. A merged block that is itself tiny is dropped.
2. Budget: with `remaining = cap − rects.count`, if there are at most `remaining` items, emit them all. If `remaining ≥ 2`, emit the `remaining − 1` largest plus `.more(parent:count:)` for the rest. Otherwise emit nothing, and the folder is drawn solid.
3. Tile the items with `Squarify.tiles`. Each frame is the tile inset by `gutter / 2`.
4. Enqueue each emitted `.folder`. Its child area is its frame minus a header, inset by `gutter / 2`. A depth-1 folder gets `hasHeader` when `headerHeight > 0`, `frame.height ≥ headerHeight + 24` and `frame.width ≥ 60`. When `headerHeight > 0` and a depth-1 folder has no header, it does not recurse. Deeper folders have no header and recurse when both sides of the child area are at least `minSide`.

```swift
// Squarify.tiles: Bruls, Huizing, van Wijk (2000).
let total = sizes.reduce(0, +)
guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
let scale = Double(rect.width * rect.height) / total
var free = rect, result: [CGRect] = [], i = 0
while i < sizes.count {
    let side = Double(min(free.width, free.height))
    func worst(_ sum: Double, _ lo: Double, _ hi: Double) -> Double {
        max(side * side * hi / (sum * sum), sum * sum / (side * side * lo))
    }
    var sum = 0.0, lo = Double.infinity, hi = 0.0, j = i
    while j < sizes.count {
        let a = sizes[j] * scale
        if j > i, worst(sum + a, min(lo, a), max(hi, a)) > worst(sum, lo, hi) { break }
        sum += a; lo = min(lo, a); hi = max(hi, a); j += 1
    }
    let thickness = sum / side, column = free.width >= free.height
    var offset = 0.0
    for k in i..<j {
        let length = sizes[k] * scale / thickness
        result.append(column ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                             : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness))
        offset += length
    }
    free = column ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                  : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
    i = j
}
return result
```

- [ ] **Step 1: Write the failing tests**

```swift
struct FakeSource: TreemapSource {
    var table: [FolderID: [TreemapItem]]
    func items(in folder: FolderID) -> [TreemapItem] { table[folder] ?? [] }
}
func files(_ sizes: [UInt64], from first: FileIndex = 0) -> [TreemapItem] {
    sizes.enumerated().map { TreemapItem(ref: .file(first + FileIndex($0.offset)), size: $0.element) }
}
func close(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 1e-6 && abs(a.minY - b.minY) < 1e-6 && abs(a.width - b.width) < 1e-6 && abs(a.height - b.height) < 1e-6
}
let flat = TreemapOptions(gutter: 0, minSide: 2, headerHeight: 0, cap: 50_000)

@Test func squarifyMatchesThePaper() {
    let r = Squarify.tiles([6, 6, 4, 3, 2, 2, 1], in: CGRect(x: 0, y: 0, width: 6, height: 4))
    let e: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(0, 0, 3, 2), (0, 2, 3, 2), (3, 0, 1.7143, 2.3333), (4.7143, 0, 1.2857, 2.3333),
                                                     (3, 2.3333, 1.2, 1.6667), (4.2, 2.3333, 1.2, 1.6667), (5.4, 2.3333, 0.6, 1.6667)]
    #expect(r.count == 7)
    for (t, x) in zip(r, e) {
        #expect(abs(t.minX - x.0) < 1e-3 && abs(t.minY - x.1) < 1e-3 && abs(t.width - x.2) < 1e-3 && abs(t.height - x.3) < 1e-3)
    }
}
@Test func squarifyTilesWithoutGapsOrOverlap() {
    let bounds = CGRect(x: 10, y: 20, width: 640, height: 400)
    let r = Squarify.tiles((1...40).map { Double(41 - $0) * 1.7 }, in: bounds)
    #expect(abs(r.reduce(0) { $0 + $1.width * $1.height } - bounds.width * bounds.height) < 0.01)
    #expect(r.allSatisfy { bounds.insetBy(dx: -1e-6, dy: -1e-6).contains($0) })
    for i in r.indices { for j in r.indices where j > i { let x = r[i].intersection(r[j]); #expect(x.width * x.height < 1e-6) } }
}
@Test func tinyItemsFoldIntoOneSmallBlock() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 9_000), .init(ref: .small(parent: 0, files: 50, folders: 0), size: 200)]
                                   + files(Array(repeating: 2, count: 400))])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), options: flat)
    #expect(l.topLevelCount == 2)
    #expect(l.rects[0].ref == .folder(1) && close(l.rects[0].frame, CGRect(x: 0, y: 0, width: 90, height: 100)))
    #expect(l.rects[1].ref == .small(parent: 0, files: 450, folders: 0) && l.rects[1].size == 1_000)
    #expect(close(l.rects[1].frame, CGRect(x: 90, y: 0, width: 10, height: 100)))
}
@Test func capMergesTheSmallestSiblings() {
    let l = TreemapLayout.make(source: FakeSource(table: [0: files(Array(repeating: 100, count: 20))]), root: 0,
                               bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), options: .init(gutter: 0, minSide: 2, headerHeight: 0, cap: 10))
    #expect(l.rects.count == 10)
    #expect(l.rects.filter { $0.ref == .more(parent: 0, count: 11) }.map(\.size) == [1_100])
}
@Test func capIsSharedBreadthFirst() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 300), .init(ref: .folder(2), size: 150)],
                                 1: files(Array(repeating: 10, count: 30)), 2: files(Array(repeating: 5, count: 30), from: 100)])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                               options: .init(gutter: 0, minSide: 2, headerHeight: 0, cap: 20))
    #expect(l.rects.count == 20)
    #expect(l.rects[0].ref == .folder(1) && l.rects[0].childCount == 18)
    #expect(l.rects[1].ref == .folder(2) && l.rects[1].childCount == 0)
}
@Test func hugeFolderStaysUnderCap() {
    let l = TreemapLayout.make(source: FakeSource(table: [0: files(Array(repeating: 1, count: 200_000))]), root: 0,
                               bounds: CGRect(x: 0, y: 0, width: 4000, height: 4000))
    #expect(l.rects.count == 50_000)
    #expect(l.rects.contains { $0.ref == .more(parent: 0, count: 150_001) })
}
@Test func topLevelFoldersGetAHeaderAndHoldTheirChildren() {
    let src = FakeSource(table: [0: [.init(ref: .folder(1), size: 100)], 1: files([50, 50])])
    let l = TreemapLayout.make(source: src, root: 0, bounds: CGRect(x: 0, y: 0, width: 200, height: 200),
                               options: .init(gutter: 2, minSide: 2, headerHeight: 34, cap: 50_000))
    #expect(close(l.rects[0].frame, CGRect(x: 1, y: 1, width: 198, height: 198)) && l.rects[0].hasHeader)
    #expect(close(l.rects[1].frame, CGRect(x: 3, y: 37, width: 96, height: 160)))
    #expect(close(l.rects[2].frame, CGRect(x: 101, y: 37, width: 96, height: 160)))
    #expect(l.rects[1].parent == 0 && l.rects[1].depth == 2)
    #expect(l.hitTest(CGPoint(x: 50, y: 100)) == 1)
    #expect(l.hitTest(CGPoint(x: 50, y: 20)) == 0)
    #expect(l.hitTest(CGPoint(x: 199.5, y: 100)) == nil)
    #expect(l.topLevel(of: 2) == 0)
}
@Test func zeroSizedItemsMakeNoRects() {
    #expect(TreemapLayout.make(source: FakeSource(table: [0: files([0, 0, 0])]), root: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)).rects.isEmpty)
    #expect(TreemapLayout.make(source: FakeSource(table: [0: files([5])]), root: 0, bounds: .zero).rects.isEmpty)
    #expect(Squarify.tiles([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
}
@Test func zoomTransforms() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600), block = CGRect(x: 400, y: 0, width: 400, height: 300)
    let zin = ZoomAnimation.zoomIn(from: block, bounds: bounds)
    #expect(zin.transform(progress: 0).scale == CGSize(width: 0.5, height: 0.5) && zin.transform(progress: 0).offset == CGPoint(x: 400, y: 0))
    #expect(abs(zin.transform(progress: 0.5).scale.width - 0.9375) < 1e-9 && abs(zin.transform(progress: 0.5).offset.x - 50) < 1e-9)
    #expect(zin.transform(progress: 1).scale == CGSize(width: 1, height: 1) && zin.transform(progress: 1).offset == .zero)
    let zout = ZoomAnimation.zoomOut(to: block, bounds: bounds)
    #expect(zout.transform(progress: 0).scale == CGSize(width: 2, height: 2) && zout.transform(progress: 0).offset == CGPoint(x: -800, y: 0))
    #expect(ZoomAnimation.eased(0.5) == 0.875 && ZoomAnimation.duration == 0.2)
}
```

- [ ] **Step 2: Run** `swift test --filter TreemapLayoutTests`. Expected: build fails (`Squarify` not defined).
- [ ] **Step 3: Implement** the three files. `hitTest` scans the depth-1 rects, then descends through `firstChild..<firstChild + childCount`.
- [ ] **Step 4: Run** `swift test --filter TreemapLayoutTests`. Expected: all pass. `hugeFolderStaysUnderCap` takes under 1 s in a debug build.
- [ ] **Step 5: Commit** `feat: squarified treemap layout with fold and cap`

---

### Task 4: Map snapshot from the index

**Files:**
- Create: `Sources/DiskApp/Map/MapSnapshot.swift`, `Sources/DiskApp/Map/MapBuilder.swift`
- Modify: `Tests/DiskAppTests/Fixtures.swift` (add `index(_:)`)
- Test: `Tests/DiskAppTests/MapBuilderTests.swift`

**Interfaces:**
- Consumes: `TreemapLayout`, `TreemapSource`, `TreemapOptions` (Task 3); `ContentKind.classify(parts:)`, `SizeSnapshot.estimatedSize(of:isFile:)` (Task 1); `ScanIndex`.
- Produces:
  - `public struct MapRequest: Equatable, Sendable { var path: String; var size: CGSize; var period: Int; var options: TreemapOptions = .init() }`
  - `public struct MapNode: Equatable, Sendable { var key: String; var name: String; var kind: ContentKind?; var growth: Int64; var isFolder: Bool }`. `key` is the relative path for folders and files, or `"<folder path>#small"` / `"<folder path>#more"` for buckets. `kind` is nil for buckets.
  - `public struct Crumb: Equatable, Sendable { var name: String; var path: String }`
  - `public struct ListRow: Equatable, Sendable { var node: Int?; var name: String; var size: UInt64; var fraction: Double; var kind: ContentKind? }`. `fraction` is size / the largest depth-1 size, capped at 1. `node` is nil for the remainder row.
  - `public struct MapSnapshot: Sendable { var path: String; var rootPath: String; var crumbs: [Crumb]; var total: UInt64; var period: Int; var layout: TreemapLayout; var nodes: [MapNode]; var list: [ListRow]; func url(of node: Int) -> URL? }`. It has a public memberwise init. `nodes` runs parallel to `layout.rects`. `url` is nil for buckets.
  - `public enum MapBuilder { public static func build(index: ScanIndex, request: MapRequest, baseline: SizeSnapshot?) -> MapSnapshot }`
  - `struct IndexTreemapSource: TreemapSource` reads folder links and file records. It reads sizes only, never names.

Rules:
- **Path:** resolve `request.path` component by component and stop at the deepest existing folder. That folder's path is `snapshot.path`.
- **Kind:** the zoom folder's kind is found by walking its path, as `classify(parts) ?? inherited`, starting from `.other`. A child folder's kind is `classify(parent parts + [lowercased name]) ?? parent's kind`. Files take their folder's kind.
- **Growth:** `now − baseline.estimatedSize(of: key, isFile:)` when the key is in `baseline.sizes`, or when `now` is at least the floor (`folderFloor`, or `fileFloor` for files). Otherwise 0. Buckets and a nil baseline give 0.
- **Bucket names:** `"1 small file"`, `"3,912 small files"` (en_US grouping), `"N small items"` once any folder was folded in, and `"N more items"`.
- **List:** the first 200 depth-1 rects. If there are more, one row `"N more items"` carries the rest's summed size.

- [ ] **Step 1: Write the failing tests**

```swift
// Fixtures: static func index(_ spec: [String: Int]) async throws -> ScanIndex  (tree + DiskScanner(root:storage:).run().index)
let size = CGSize(width: 800, height: 600)

@Test func nodesCarryKindsNamesAndPaths() async throws {
    let idx = try await Fixtures.index(["Users/u/Movies/clip.mov": 3_000_000, "Users/u/Library/Caches/c.bin": 2_000_000, "Users/u/notes.txt": 10])
    let s = MapBuilder.build(index: idx, request: .init(path: "Users/u", size: size, period: 7), baseline: nil)
    #expect(s.path == "Users/u" && s.crumbs == [Crumb(name: "Users", path: "Users"), Crumb(name: "u", path: "Users/u")])
    #expect(s.nodes.first { $0.key == "Users/u/Movies" } == MapNode(key: "Users/u/Movies", name: "Movies", kind: .media, growth: 0, isFolder: true))
    #expect(s.nodes.first { $0.key == "Users/u/Movies/clip.mov" }?.kind == .media)
    #expect(s.nodes.first { $0.key == "Users/u/Library/Caches" }?.kind == .caches)
    #expect(s.nodes.contains { $0.key == "Users/u#small" && $0.kind == nil && $0.name == "1 small file" })
    #expect(s.total == idx.folders[Int(idx.folder(atRelativePath: "Users/u")!)].totalAllocated)
    #expect(s.url(of: s.nodes.firstIndex { $0.key == "Users/u/Movies" }!)?.path == idx.rootPath + "/Users/u/Movies")
}
@Test func zoomByPathSurvivesDeletionAndCompaction() async throws {
    let idx = try await Fixtures.index(["a/b/c/f.bin": 2_000_000, "a/x.bin": 1_200_000])
    #expect(MapBuilder.build(index: idx, request: .init(path: "a/b/gone/deeper", size: size, period: 7), baseline: nil).path == "a/b")
    idx.resetContents(of: idx.folder(atRelativePath: "a/b")!)
    #expect(MapBuilder.build(index: idx, request: .init(path: "a/b/c", size: size, period: 7), baseline: nil).path == "a/b")
    let compacted = try idx.compacted(into: try Fixtures.tempDir())
    #expect(MapBuilder.build(index: compacted, request: .init(path: "a", size: size, period: 7), baseline: nil).nodes.contains { $0.key == "a/x.bin" })
}
@Test func growthComesFromBaseline() async throws {
    let idx = try await Fixtures.index(["big/f.bin": 3_000_000, "other/g.bin": 2_000_000])
    let bigNow = idx.folders[Int(idx.folder(atRelativePath: "big")!)].totalAllocated
    let s = MapBuilder.build(index: idx, request: .init(path: "", size: size, period: 1),
                             baseline: SizeSnapshot(sizes: ["": 1, "big": bigNow - 1_000_000]))
    #expect(s.nodes.first { $0.key == "big" }?.growth == 1_000_000)
    #expect(s.nodes.first { $0.key == "other" }?.growth == 0)
}
@Test func listRowsCapAt200PlusRemainder() async throws {
    let idx = try await Fixtures.index(Dictionary(uniqueKeysWithValues: (0..<250).map { ("d\($0)/f", 10) }))
    let s = MapBuilder.build(index: idx, request: .init(path: "", size: size, period: 7), baseline: nil)
    #expect(s.list.count == 201)
    #expect(s.list.last?.name == "50 more items" && s.list.last?.node == nil)
    #expect(s.list.first?.fraction == 1)
}
```

- [ ] **Step 2: Run** `swift test --filter MapBuilderTests`. Expected: build fails.
- [ ] **Step 3: Implement** both files. While building nodes, keep each folder rect's lowercased path parts in an array indexed by rect, so no path is split twice.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: map snapshot with kinds, growth and side list rows`

---

### Task 5: Hover card, labels, commands and keys

**Files:**
- Create: `Sources/DiskApp/Map/KnownItems.swift`, `Sources/DiskApp/Map/HoverCard.swift`, `Sources/DiskApp/Map/LabelFit.swift`, `Sources/DiskApp/Map/MapCommands.swift`
- Modify: `Sources/DiskApp/Format.swift`, `Tests/DiskAppTests/FormatTests.swift`
- Test: `Tests/DiskAppTests/MapTextTests.swift`

**Interfaces:**
- Consumes: `MapNode` (Task 4), `Format`.
- Produces:
  - `Format.periodWords(_ days: Int) -> String`: `"today"`, `"this week"` or `"this month"` for 1, 7 and 30.
  - `public enum KnownItems { static func explanation(for relativePath: String) -> String? }`. Matching works on lowercased components: `*` matches one whole component, a component like `*.photoslibrary` is matched with `fnmatch`, and a leading `**` matches at any depth. A rule covers its folder and everything below it, and the first rule wins:

    | Pattern | Copy |
    |---|---|
    | `Users/*/Library/Containers/com.docker.docker` | The virtual disk Docker runs on. It grows but never shrinks by itself. Reclaim space in Docker › Settings › Resources. |
    | `Users/*/Library/Developer/Xcode/DerivedData` | Xcode build products. Safe to clear. Rebuilds itself. |
    | `Users/*/Library/Developer/CoreSimulator` | iOS simulators and their data. Remove old ones in Xcode › Settings › Components. |
    | `**/node_modules` | Packages for a JavaScript project. Safe to clear. Reinstall them with npm install. |
    | `Users/*/Library/Caches` | App caches. Apps rebuild what they need. |
    | `Users/*/.Trash` | Files in the Trash. Empty the Trash in Finder to get this space back. |
    | `Users/*/Library/Application Support/MobileSync/Backup` | iPhone and iPad backups. Manage them in Finder › your device › Manage Backups. |
    | `Users/*/Pictures/*.photoslibrary` | Your Photos library. Shrink it from inside Photos, not here. |

  - `public struct HoverCard: Equatable, Sendable { var title: String; var detail: String; var change: String?; var changeIsGrowth: Bool; var explanation: String?; static func make(node: MapNode, size: UInt64, period: Int) -> HoverCard }`. The fields:
    - `detail` is `Format.gb(size)`.
    - `change` is `"up 8.1 GB today"` or `"down 0.6 GB this week"`, shown only when |growth| ≥ 100,000,000.
    - `explanation` comes from `KnownItems`. A `.small` bucket gets `"Files under 1 MB and items too small to draw, shown as one block."` and a `.more` bucket gets `"Too many items to draw one by one here. Zoom in to see them."`. Tell the two buckets apart by their key suffix.
  - `public enum LabelStyle: Sendable { case name, nameLarge, size, sizeLarge, growth }`
  - `public struct LabelLine: Equatable, Sendable { var text: String; var style: LabelStyle; var origin: CGPoint }`. `origin` is relative to the frame's top left.
  - `public struct LabelPlan: Equatable, Sendable { var lines: [LabelLine] }`
  - `public enum LabelFit { static func plan(name: String, size: String, growth: String?, frame: CGRect, large: Bool, measure: (String, LabelStyle) -> CGFloat) -> LabelPlan? }`. The rules:
    - Padding is 12 left and 10 top. Line heights: name 17 (large 21), size 15 (large 16), growth 4 + 16.
    - No label when the width is under 40 or the height is under 30. The size line needs a height of at least 10 + name + size + 4, and the growth line needs 20 more than that.
    - The name is cut to the longest prefix where `measure(prefix + "…") ≤ width − 24`. If even one character doesn't fit, there is no label.
    - Fonts, used by the renderer to measure and draw: name 13 pt semibold (large 17), size 12 pt regular at 80% opacity (large 13), growth 12 pt semibold. `large` means the frame's area is at least 20% of the map.
  - `public enum MapAction: Equatable, Sendable { case revealInFinder, copyPath, zoomToParent, goTo(key: String) }`
  - `public struct CommandItem: Equatable, Sendable { var title: String; var shortcut: String?; var action: MapAction }`
  - `public enum MapCommands { static func items(query: String, hasSelection: Bool, canZoomOut: Bool, children: [(name: String, key: String)]) -> [CommandItem] }`. The base items, in order: "Reveal in Finder" (shortcut nil) and "Copy Path" (shortcut nil), both only with a selection that isn't a bucket, then "Zoom to Parent" (shortcut "Esc") only when `canZoomOut`. They are filtered by a case- and diacritic-insensitive substring match on the title. With a non-empty query, up to 8 "Go to <name>" items follow for children whose names contain the query, in the order given.
  - `public struct KeyModifiers: OptionSet, Sendable { command, shift, option, control }`
  - `public enum MapKeyCommand: Equatable, Sendable { case zoomIn, zoomOut, quickLook, openCommands, selectPrevious, selectNext, closeSearch, runCommand, commandUp, commandDown }`
  - `public enum MapKey { static func command(keyCode: UInt16, modifiers: KeyModifiers, searchFocused: Bool) -> MapKeyCommand? }`. Key codes: 36 ↵, 53 Esc, 49 Space, 40 K, 126 ↑, 125 ↓. While the search field is focused, only ↵, Esc, ↑ and ↓ map, to `runCommand`, `closeSearch`, `commandUp` and `commandDown`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func periodWords() { #expect([1, 7, 30].map(Format.periodWords) == ["today", "this week", "this month"]) }
@Test func knownItemsExplainThemselves() {
    #expect(KnownItems.explanation(for: "Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        == "The virtual disk Docker runs on. It grows but never shrinks by itself. Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(KnownItems.explanation(for: "Users/u/Library/Developer/Xcode/DerivedData") == "Xcode build products. Safe to clear. Rebuilds itself.")
    #expect(KnownItems.explanation(for: "Users/u/code/site/node_modules") == "Packages for a JavaScript project. Safe to clear. Reinstall them with npm install.")
    #expect(KnownItems.explanation(for: "Users/u/Pictures/Photos Library.photoslibrary") == "Your Photos library. Shrink it from inside Photos, not here.")
    #expect(KnownItems.explanation(for: "Users/u/Documents") == nil)
}
@Test func hoverCards() {
    let docker = MapNode(key: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", kind: .virtualMachines, growth: 8_100_000_000, isFolder: false)
    let card = HoverCard.make(node: docker, size: 92_000_000_000, period: 1)
    #expect(card.title == "Docker.raw" && card.detail == "92 GB" && card.change == "up 8.1 GB today" && card.changeIsGrowth)
    #expect(card.explanation?.hasPrefix("The virtual disk Docker runs on.") == true)
    let trash = MapNode(key: "Users/u/.Trash", name: ".Trash", kind: .other, growth: -600_000_000, isFolder: true)
    #expect(HoverCard.make(node: trash, size: 2_000_000_000, period: 7).change == "down 0.6 GB this week")
    let quiet = MapNode(key: "a", name: "a", kind: .other, growth: 50_000_000, isFolder: true)
    #expect(HoverCard.make(node: quiet, size: 1_000_000_000, period: 7).change == nil)
}
@Test func labelsTruncateAndDropLines() throws {
    let measure: (String, LabelStyle) -> CGFloat = { s, _ in CGFloat(s.count) * 7 }
    let p = try #require(LabelFit.plan(name: "Application Support", size: "27 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 50), large: false, measure: measure))
    #expect(p.lines == [LabelLine(text: "Applicati\u{2026}", style: .name, origin: CGPoint(x: 12, y: 10)),
                        LabelLine(text: "27 GB", style: .size, origin: CGPoint(x: 12, y: 27))])
    #expect(LabelFit.plan(name: "Mail", size: "14 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 200, height: 40), large: false, measure: measure)?.lines.map(\.text) == ["Mail"])
    #expect(LabelFit.plan(name: "Mail", size: "14 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 30, height: 50), large: false, measure: measure) == nil)
    #expect(LabelFit.plan(name: "Docker", size: "92 GB", growth: "+8.1 GB today", frame: CGRect(x: 0, y: 0, width: 300, height: 120), large: true, measure: measure)?
        .lines.map(\.style) == [.nameLarge, .sizeLarge, .growth])
}
@Test func commandsFilterAndGoTo() {
    #expect(MapCommands.items(query: "", hasSelection: true, canZoomOut: true, children: []).map(\.title) == ["Reveal in Finder", "Copy Path", "Zoom to Parent"])
    #expect(MapCommands.items(query: "", hasSelection: false, canZoomOut: false, children: []).isEmpty)
    #expect(MapCommands.items(query: "doc", hasSelection: true, canZoomOut: true, children: [("Docker", "Users/u/Docker"), ("Mail", "Users/u/Mail")])
        == [CommandItem(title: "Go to Docker", shortcut: nil, action: .goTo(key: "Users/u/Docker"))])
    #expect(MapCommands.items(query: "PATH", hasSelection: true, canZoomOut: false, children: []).map(\.action) == [.copyPath])
}
@Test func keys() {
    #expect(MapKey.command(keyCode: 36, modifiers: [], searchFocused: false) == .zoomIn)
    #expect(MapKey.command(keyCode: 53, modifiers: [], searchFocused: false) == .zoomOut)
    #expect(MapKey.command(keyCode: 49, modifiers: [], searchFocused: false) == .quickLook)
    #expect(MapKey.command(keyCode: 40, modifiers: .command, searchFocused: false) == .openCommands)
    #expect(MapKey.command(keyCode: 126, modifiers: [], searchFocused: false) == .selectPrevious)
    #expect(MapKey.command(keyCode: 125, modifiers: [], searchFocused: false) == .selectNext)
    #expect(MapKey.command(keyCode: 53, modifiers: [], searchFocused: true) == .closeSearch)
    #expect(MapKey.command(keyCode: 36, modifiers: [], searchFocused: true) == .runCommand)
    #expect(MapKey.command(keyCode: 49, modifiers: [], searchFocused: true) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter "MapTextTests|FormatTests"`. Expected: build fails.
- [ ] **Step 3: Implement** the four files and `periodWords`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: hover card, label fitting, commands and keys for the map`

---

### Task 6: Map model and keeping the drive warm

**Files:**
- Create: `Sources/DiskApp/Map/MapModel.swift`
- Modify: `Sources/DiskApp/DriveController.swift`
- Test: `Tests/DiskAppTests/MapModelTests.swift`, `Tests/DiskAppTests/DriveControllerTests.swift`

**Interfaces:**
- Consumes: `LiveIndex.read`, `updates()`, `baseline(days:)` (Task 1); `MapBuilder`, `MapSnapshot`, `MapRequest` (Task 4); `ZoomAnimation` (Task 3).
- Produces:
  - `@MainActor public protocol MapSource: AnyObject { var activity: DriveActivity { get }; var period: Int { get }; func hold() async; func release(); func buildMap(_ request: MapRequest) async -> MapSnapshot? }`
  - `extension DriveController: MapSource`, adding:
    - `private(set) var holds = 0`
    - `func hold() async`: increments `holds` first, cancels the cool-down timer, then `warm()`s. After `willUnmount()` it does nothing.
    - `func release()`: decrements `holds`, never below 0. At 0 with an open index, it restarts the cool-down timer (5 min).
    - `restartTimer()` does nothing while `holds > 0`, so the dropdown's own `warm()` doesn't start a timer while the window holds the drive.
    - `@Published public private(set) var generation = 0`: bumped from `LiveIndex.updates()`, consumed by a task that starts in `warmBody` after open and is cancelled in `coolBody`.
    - `func buildMap(_:)`: nil when cold or unmounting; otherwise `index.read { MapBuilder.build(index: $0, request: r, baseline: b) }`. The baseline is cached per period and day.
  - `public enum MapStatus: Equatable, Sendable { case loading, scanning, ready, empty, offline }`
  - `@MainActor public final class MapModel: ObservableObject`:
    - `init(source: any MapSource, driveName: String, reduceMotion: Bool, throttle: Duration = .seconds(1))`, `public var reduceMotion: Bool`
    - `@Published private(set) var snapshot: MapSnapshot?`, `status: MapStatus`, `zoomPath: String`, `selected: Int?` (a depth-1 rect index), `animation: ZoomAnimation?`, and `@Published var hovered: Int?` (any rect index)
    - `var statusMessage: String?`:
      - `.loading`: `"Loading the map…"`
      - `.scanning`: `"Scanning this drive for the first time. The map appears when the scan finishes."`
      - `.offline`: `"<driveName> was disconnected. Its map comes back when you plug it in."`
      - `.empty`: `"Nothing here takes up space."`
      - `.ready`: nil
    - `var outlinedTop: Int?`: the top-level ancestor of `hovered`, else `selected`.
    - `func open(path: String, select key: String?) async`: holds the source, then builds.
    - `func setSize(_:)`, `func sourceChanged()` (throttled, leading edge plus one trailing build per `throttle`), `func zoomIn(_ rect: Int)` (folders only), `func zoomOut()` (selects the folder you came from), `func zoom(to crumb: Crumb?)` (nil is the drive root), `func select(_ rect: Int?)`, `func moveSelection(by: Int)`, `func close()` (releases the source and drops the snapshot), and the internal `func settle() async` (waits until no build is in flight, for tests).
    - Builds coalesce: at most one is in flight, and one trailing build runs with the latest request. A result is applied only if it answers the latest request. Selection is kept by node key across rebuilds. `animation` is set together with the snapshot that answers a zoom, and is nil when `reduceMotion` is on.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor final class FakeMapSource: MapSource {
    var activity: DriveActivity = .ready; var period = 7; var holds = 0; var builds = 0; var delay: Duration = .zero
    let index: ScanIndex
    init(_ spec: [String: Int]) async throws { index = try await Fixtures.index(spec) }
    func hold() async { holds += 1 }
    func release() { holds -= 1 }
    func buildMap(_ r: MapRequest) async -> MapSnapshot? {
        builds += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return activity == .offline ? nil : MapBuilder.build(index: index, request: r, baseline: nil)
    }
}
func model(_ src: FakeMapSource, throttle: Duration = .seconds(1)) -> MapModel {
    let m = MapModel(source: src, driveName: "Test", reduceMotion: false, throttle: throttle)
    m.setSize(CGSize(width: 800, height: 600)); return m
}

@MainActor @Test func openHoldsAndCloseReleases() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: nil); await m.settle()
    #expect(src.holds == 1 && m.status == .ready && m.snapshot?.layout.topLevelCount == 2)
    m.close()
    #expect(src.holds == 0 && m.snapshot == nil)
}
@MainActor @Test func rapidRequestsCoalesceLatestWins() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src); src.delay = .milliseconds(50)
    await m.open(path: "", select: nil)
    for w in 600...619 { m.setSize(CGSize(width: w, height: 400)) }
    await m.settle()
    #expect(src.builds <= 3)
    #expect(m.snapshot?.layout.bounds.width == 619)
}
@MainActor @Test func zoomInOutAndBack() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "c/g.bin": 1_200_000]); let m = model(src)
    await m.open(path: "", select: nil); await m.settle()
    let a = try #require(m.snapshot?.nodes.firstIndex { $0.key == "a" }); let frame = m.snapshot!.layout.rects[a].frame
    m.zoomIn(a); await m.settle()
    #expect(m.zoomPath == "a" && m.animation == .zoomIn(from: frame, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
    m.zoomOut(); await m.settle()
    #expect(m.zoomPath == "" && m.snapshot?.nodes[m.selected!].key == "a")
    let c = try #require(m.snapshot?.nodes.firstIndex { $0.key == "c" })
    m.reduceMotion = true; m.zoomIn(c); await m.settle()
    #expect(m.zoomPath == "c" && m.animation == nil)
}
@MainActor @Test func openAtFocusSelectsItem() async throws {
    let src = try await FakeMapSource(["a/b/f.bin": 2_000_000, "a/b/g.bin": 1_500_000]); let m = model(src)
    await m.open(path: "a/b", select: "a/b/f.bin"); await m.settle()
    #expect(m.snapshot?.nodes[m.selected!].key == "a/b/f.bin")
}
@MainActor @Test func selectionFollowsKeyAcrossRebuilds() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000, "b/g.bin": 1_200_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: "b"); await m.settle()
    m.setSize(CGSize(width: 300, height: 900)); await m.settle()
    #expect(m.snapshot?.nodes[m.selected!].key == "b")
}
@MainActor @Test func sourceChangesThrottle() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(300))
    await m.open(path: "", select: nil); await m.settle(); let before = src.builds
    for _ in 0..<10 { m.sourceChanged() }
    try await Task.sleep(for: .milliseconds(400)); await m.settle()
    #expect(src.builds == before + 2)
}
@MainActor @Test func offlineSourceShowsDisconnected() async throws {
    let src = try await FakeMapSource(["a/f.bin": 2_000_000]); let m = model(src, throttle: .milliseconds(10))
    await m.open(path: "", select: nil); await m.settle()
    src.activity = .offline; m.sourceChanged(); await m.settle()
    #expect(m.status == .offline && m.snapshot == nil)
    #expect(m.statusMessage == "Test was disconnected. Its map comes back when you plug it in.")
}
@MainActor @Test func emptyLevelShowsMessage() async throws {
    let src = try await FakeMapSource(["e/z": 0, "a/f.bin": 2_000_000]); let m = model(src)
    await m.open(path: "e", select: nil); await m.settle()
    #expect(m.status == .empty && m.statusMessage == "Nothing here takes up space.")
}
```

Append to `DriveControllerTests.swift`:

```swift
@MainActor @Test func holdKeepsWarmUntilReleased() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir(), coolDown: .milliseconds(200))
    await c.hold(); await c.warm()
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .ready)
    c.release()
    try await Task.sleep(for: .milliseconds(600))
    #expect(c.activity == .idle)
}
@MainActor @Test func holdAfterUnmountStaysOffline() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let c = DriveController(volume: try Fixtures.volume(root), store: store)
    await c.willUnmount(); await c.hold()
    #expect(c.activity == .offline)
    #expect(await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.appending(path: "index.snapshot").path))
}
@MainActor @Test func buildMapAndGenerationWhileHeld() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000])
    let c = DriveController(volume: try Fixtures.volume(root), store: try Fixtures.tempDir())
    await c.hold()
    let s = try #require(await c.buildMap(MapRequest(path: "", size: CGSize(width: 400, height: 300), period: 7)))
    #expect(s.total > 0 && s.layout.topLevelCount >= 1)
    let before = c.generation
    try Data(count: 2_000_000).write(to: root.appending(path: "new.bin"))
    for _ in 0..<50 where c.generation == before { try await Task.sleep(for: .milliseconds(100)) }
    #expect(c.generation > before)
    c.release(); await c.cool()
}
```

- [ ] **Step 2: Run** `swift test --filter "MapModelTests|DriveControllerTests"`. Expected: build fails.
- [ ] **Step 3: Implement** `MapModel.swift` and the `DriveController` changes. All lifecycle work still goes through the existing `run` chain.
- [ ] **Step 4: Run** `swift test`. Expected: all pass, including the existing `DriveControllerTests`.
- [ ] **Step 5: Commit** `feat: map model; the window holds its drive warm`

---

### Task 7: Metal treemap renderer

**Files:**
- Create: `Sources/DiskApp/Treemap/TreemapScene.swift`, `Sources/Diskinventory/Map/TreemapRenderer.swift`, `Sources/Diskinventory/Map/TreemapMTKView.swift`, `Sources/Diskinventory/Map/LabelAtlas.swift`
- Test: `Tests/DiskAppTests/TreemapSceneTests.swift`

**Interfaces:**
- Consumes: `MapSnapshot` (Task 4), `ZoomAnimation` (Task 3), `LabelFit`, `HoverCard`, `Format.periodWords` (Task 5), `Palette`.
- Produces:
  - `public struct BlockInstance: Equatable, Sendable { var rect: SIMD4<Float>; var color: SIMD4<Float>; var stripe: Float; var topLevel: Int32; var flags: UInt32; var pad: Float = 0 }`. The stride is 48, and the shader's struct matches it field for field. `rect` is x, y, w, h in points. Flag bit 0 marks a top-level block and bit 1 a bucket.
  - `public enum TreemapScene`:
    - `static func instances(snapshot: MapSnapshot, dark: Bool) -> [BlockInstance]`: one per rect, in rect order (parents before children). The color is the kind's sRGB hex times the depth shade `max(0.7, 1 − 0.1 × (depth − 1))`, with alpha 1. Buckets are `(1, 1, 1, 0.22)` in dark mode and `(0, 0, 0, 0.22)` in light. `topLevel` is `layout.topLevel(of:)`.
    - `static func stripe(growth: Int64, size: UInt64) -> Float`: 0 below 100,000,000 of growth, otherwise `min(1, growth / size)`.
    - `public struct Appearance: Equatable { var dimmed: Bool; var outline: Float }` and `static func appearance(_ i: BlockInstance, hoveredTop: Int32, outlinedTop: Int32) -> Appearance`. `dimmed` is `hoveredTop >= 0 && i.topLevel != hoveredTop`. `outline` is 2 when `flags & 1 != 0 && i.topLevel == outlinedTop`, else 0. −1 means none. The shader implements exactly this rule.
    - `static let shaderSource: String`: Metal source with `blockVertex`, `blockFragment`, `labelVertex` and `labelFragment`. In `blockFragment`:
      - Shape: a rounded-rect SDF with a 4 pt radius and 1 px antialiasing.
      - Outline: a white inner outline `outline` pt wide.
      - Dim: `rgb = mix(luma, rgb, 0.7) × 0.78`.
      - Growth strip: in the rightmost `stripe × w`, a 1 pt white line at α 0.7 on its left edge, then a period-3 pt pattern of white α 0.34 for 1 pt and α 0.16 for 2 pt, over the fill.
      - Uniforms: `{ float2 viewport; float2 scale; float2 offset; float pixelsPerPoint; int hoveredTop; int outlinedTop; float labelAlpha; }`. The corner radius and outline do not scale with the zoom transform.
  - `final class LabelAtlas { static func build(snapshot: MapSnapshot, scale: CGFloat, dark: Bool, maxPixels: Int = 4096) -> LabelAtlas }`. It has `image: CGImage?` and `quads: [LabelQuad]`, where `LabelQuad { rect: SIMD4<Float>; uv: SIMD4<Float>; topLevel: Int32 }`. It labels depth-1 rects and childless deeper rects. The growth line reads `Format.signedGB(growth) + " " + Format.periodWords(period)`. Text is white, or the label color on buckets. It measures with `CTLineGetTypographicBounds`, packs rows largest first, and skips whatever no longer fits.
  - `final class TreemapRenderer: NSObject, MTKViewDelegate`:
    - `init?(device: MTLDevice)`: compiles `shaderSource` once.
    - `func show(_ snapshot: MapSnapshot, dark: Bool, animation: ZoomAnimation?, in view: MTKView)`: builds instances and the atlas on a detached task, then swaps buffers on main. A newer `show` discards an older one still in flight.
    - `func setHighlight(hoveredTop: Int?, outlinedTop: Int?, in view: MTKView)`: changes uniforms only.
    - `var onFirstFrame: (() -> Void)?`
  - Redraw policy: the view starts with `isPaused = true` and `enableSetNeedsDisplay = true`, and redraws through `needsDisplay` on change. For a zoom:
    - Set `isPaused = false`, `enableSetNeedsDisplay = false` and `preferredFramesPerSecond = screen.maximumFramesPerSecond`, and use `labelAlpha` 0.
    - Each frame, compute progress from `CACurrentMediaTime()` over `ZoomAnimation.duration`, and update only the uniforms.
    - At 1, pause again and set `labelAlpha` to 1.
    - Log `zoom: N frames, M late` with `Logger(subsystem: AppIdentity.bundleID, category: "map")`. A frame is late when its presented interval is over 1.5 / `maximumFramesPerSecond`; the times come from `drawable.addPresentedHandler`.
  - View setup: `colorPixelFormat = .bgra8Unorm`, the layer colorspace is sRGB, and the clear color is the resolved `windowBackgroundColor`.
  - `final class TreemapMTKView: MTKView`: a tracking area for `mouseMoved` and `mouseExited`. It has the callbacks `onHover(CGPoint?)`, `onClick(CGPoint)` and `onResize(CGSize)`. Points are converted to top-left origin. `viewDidChangeEffectiveAppearance` re-shows the snapshot with the new `dark`.

- [ ] **Step 1: Write the failing tests**

```swift
func rect(_ ref: TreemapRef, _ size: UInt64, depth: Int, parent: Int) -> TreemapRect {
    TreemapRect(ref: ref, size: size, frame: CGRect(x: 0, y: 0, width: 100, height: 100), depth: depth, parent: parent, firstChild: 0, childCount: 0, hasHeader: false)
}
func snap(_ rects: [TreemapRect], _ nodes: [MapNode], top: Int) -> MapSnapshot {
    MapSnapshot(path: "", rootPath: "/", crumbs: [], total: 0, period: 1,
                layout: TreemapLayout(rects: rects, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), topLevelCount: top), nodes: nodes, list: [])
}
@Test func instanceLayoutMatchesTheShader() { #expect(MemoryLayout<BlockInstance>.stride == 48) }
@Test func colorsShadeByDepthAndBucketsAreGrey() {
    let s = snap([rect(.folder(1), 92_000_000_000, depth: 1, parent: -1), rect(.small(parent: 0, files: 3_912, folders: 0), 6_000_000_000, depth: 1, parent: -1),
                  rect(.file(0), 50_000_000_000, depth: 3, parent: 0)],
                 [MapNode(key: "d", name: "Docker", kind: .virtualMachines, growth: 8_100_000_000, isFolder: true),
                  MapNode(key: "#small", name: "3,912 small files", kind: nil, growth: 0, isFolder: false),
                  MapNode(key: "d/x/f", name: "f", kind: .virtualMachines, growth: 0, isFolder: false)], top: 2)
    let i = TreemapScene.instances(snapshot: s, dark: true)
    #expect(i[0].color == SIMD4<Float>(0x2E, 0x9F, 0xC4, 255) / 255 && i[0].flags & 1 == 1)
    #expect(i[1].color == SIMD4<Float>(1, 1, 1, 0.22) && i[1].flags & 2 == 2)
    #expect(abs(i[2].color.x - Float(0x2E) / 255 * 0.8) < 1e-6 && i[2].color.w == 1 && i[2].topLevel == 0)
    #expect(TreemapScene.instances(snapshot: s, dark: false)[1].color == SIMD4<Float>(0, 0, 0, 0.22))
    #expect(abs(i[0].stripe - 0.08804) < 0.0001 && i[2].stripe == 0)
}
@Test func stripeRules() {
    #expect(TreemapScene.stripe(growth: 50_000_000, size: 1_000_000_000) == 0)
    #expect(TreemapScene.stripe(growth: -2_000_000_000, size: 9_000_000_000) == 0)
    #expect(TreemapScene.stripe(growth: 3_000_000_000, size: 2_000_000_000) == 1)
}
@Test func hoverDimsOthersAndOutlinesOne() {
    let top = BlockInstance(rect: .zero, color: .zero, stripe: 0, topLevel: 1, flags: 1)
    let child = BlockInstance(rect: .zero, color: .zero, stripe: 0, topLevel: 1, flags: 0)
    #expect(TreemapScene.appearance(top, hoveredTop: 1, outlinedTop: 1) == .init(dimmed: false, outline: 2))
    #expect(TreemapScene.appearance(top, hoveredTop: 0, outlinedTop: 0) == .init(dimmed: true, outline: 0))
    #expect(TreemapScene.appearance(top, hoveredTop: -1, outlinedTop: 1) == .init(dimmed: false, outline: 2))
    #expect(TreemapScene.appearance(child, hoveredTop: 1, outlinedTop: 1) == .init(dimmed: false, outline: 0))
}
@Test func shaderCompiles() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let lib = try device.makeLibrary(source: TreemapScene.shaderSource, options: nil)
    #expect(["blockVertex", "blockFragment", "labelVertex", "labelFragment"].allSatisfy { lib.makeFunction(name: $0) != nil })
}
```

- [ ] **Step 2: Run** `swift test --filter TreemapSceneTests`. Expected: build fails.
- [ ] **Step 3: Implement** `TreemapScene.swift`, then the three `Diskinventory/Map` files. Blocks are drawn as one instanced triangle strip (4 vertices per instance), then labels as instanced textured quads with premultiplied alpha. Labels of dimmed blocks are dimmed the same way.
- [ ] **Step 4: Run** `swift test` and `swift build --product Diskinventory`. Expected: all pass and the build succeeds. The visual check is in Task 8, once the window hosts the view.
- [ ] **Step 5: Commit** `feat: Metal treemap renderer that redraws on change`

---

### Task 8: The map window

**Files:**
- Create: `Sources/Diskinventory/Map/TreemapView.swift`, `Sources/Diskinventory/Map/MapWindowView.swift`, `Sources/Diskinventory/Map/MapWindowController.swift`
- Modify: `Sources/Diskinventory/AppDelegate.swift`

**Interfaces:**
- Consumes: `MapModel`, `MapStatus` (Task 6); `TreemapRenderer`, `TreemapMTKView` (Task 7); `HoverCard`, `MapCommands`, `MapKey` (Task 5); `DriveController`, `KnownDrive`, `Palette`, `Format`.
- Produces:
  - `struct TreemapView: NSViewRepresentable`: hosts `TreemapMTKView` and its renderer. Its callbacks:
    - Hover calls `model.hovered = layout.hitTest(p)` and `renderer.setHighlight`.
    - A click selects the top-level block, then `model.zoomIn` if it's a folder.
    - Resize calls `model.setSize`.
    - A new snapshot calls `renderer.show(snapshot, dark:, animation: model.animation)`.
  - `struct MapWindowView: View`, matching `main-window-flat.html` section by section:
    - **Toolbar row, 52 pt.** 78 pt of leading space for the traffic lights. Then the **drive chip**: tint at 22% behind a 20 pt tint square with the `internaldrive` or `externaldrive` symbol, the name in semibold and `"82 GB free"` in secondary; clicking it zooms to the root. Then the **breadcrumb** of `snapshot.crumbs` with "›" separators; the current crumb is semibold on the chip background, more than 4 crumbs collapse the earliest into a "…" menu, and clicking a crumb calls `model.zoom(to:)`. Then the **search field**, 260 pt wide, with the placeholder "Search files or type a command" and a ⌘K key badge.
    - **Body.** The map gets 10 pt padding. The **side list** is 30% of the width, clamped to 240 to 360 pt. Its header shows the current folder name and `Format.gb(total)`. Each row has a 10 pt type swatch with a 2 pt radius, the name, the size in secondary, and a 3 pt bar of `fraction` in the kind color. The selected row has the drive tint at 26%. Hovering a row sets `model.hovered` to that row's rect.
    - **Hover card**, 236 pt wide with an 8 pt radius on `.regularMaterial`. It sits 14 pt right of and below the pointer, flipped to stay inside the map. It shows a 28 pt kind-colored square with an SF Symbol per kind, then title, detail and change (growth or freed color), then the explanation.
    - **Key bar, 40 pt.** On the left, the selection's swatch and name. On the right, "Zoom in ↵" (primary when the selection is a folder, otherwise dimmed), "Quick Look Space" and "Actions ⌘K".
    - **Command list** under the search field, 320 pt wide, from `MapCommands.items`. ↑/↓ highlight and ↵ runs.
    - **Status message** (`model.statusMessage`) centered over the map area when it isn't nil.
  - `@MainActor final class MapWindowController: NSWindowController, NSWindowDelegate`:
    - `init(controller: DriveController, drive: KnownDrive, path: String, select: String?)`, `let uuid: String`, `var onClose: (() -> Void)?`, `func show(path: String, select: String?)`
    - Window: `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent`, `titleVisibility = .hidden`, an empty `NSToolbar` with `toolbarStyle = .unified`. The title is `"Diskinventory — <drive>"`, for the Window menu and Mission Control. Content size 1100 × 700, `minSize` 760 × 480, `setFrameAutosaveName("MapWindow")`.
    - Keys: a local `keyDown` monitor while the window is key maps through `MapKey.command` to model and renderer actions. It swallows the events it handles.
    - Quick Look: the controller implements `acceptsPreviewPanelControl`, `beginPreviewPanelControl`, `endPreviewPanelControl` and `QLPreviewPanelDataSource` for `snapshot.url(of: selected)`. Space toggles `QLPreviewPanel.shared()`, and a selection change calls `reloadData()`.
    - Actions: Reveal in Finder uses `NSWorkspace.shared.activateFileViewerSelecting`, Copy Path uses `NSPasteboard.general` with the POSIX path string, Zoom to Parent calls `model.zoomOut()`, and Go to selects that row.
    - Glue: Combine sinks on the controller's `$generation`, `$activity` and `$period` call `model.sourceChanged()`. `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` updates `model.reduceMotion`.
    - Close: `windowWillClose` calls `model.close()` (which releases the hold), drops the model, renderer and hosting view, then calls `onClose`.
  - In `AppDelegate`:
    - `func openMap(uuid: String, focus: String?)`: `focus` nil opens the root. Otherwise it opens at `focus`'s parent with `focus` selected. If a window for the same drive is open, it calls `show(path:select:)` and brings it front. A window for another drive is closed first.
    - On open: `NSApp.setActivationPolicy(.regular)` and `NSApp.activate()`. In `onClose`: `.accessory`.
    - It logs `map window shown in X ms` (from `openMap` until after `showWindow`) and `first map frame in X ms` (`renderer.onFirstFrame`) with the `map` Logger.
    - In DEBUG, `--show-map` opens the internal drive's map at launch, as `--show-panel` does for the dropdown.

- [ ] **Step 1: Implement** the three files and the `AppDelegate` changes.
- [ ] **Step 2: Run** `swift test`. Expected: all still pass.
- [ ] **Step 3: Verify by hand.** Run `scripts/make-app.sh debug && open .build/Diskinventory.app --args --show-map`. Expected:
  - The window appears with native traffic lights, and a Dock icon appears. Closing the window removes the Dock icon.
  - `screencapture -l <windowid>` in dark and light mode, saved to the scratchpad and placed next to the mockup, shows the same toolbar, map and list split, list rows, key bar and type colors. The blocks have 4 pt corners and 2 pt gutters, with no gradient and no glow.
  - Hovering a block draws a 2 pt white inner outline, dims the other blocks and shows the hover card. The list row of the same item highlights, and hovering a list row highlights its block.
  - Clicking a folder or pressing ↵ zooms in over about 200 ms. Esc and the breadcrumb zoom out. With System Settings › Accessibility › Display › Reduce motion on, zooming is instant.
  - Space opens Quick Look on the selection. ⌘K opens the command list, and Reveal in Finder, Copy Path and Zoom to Parent work.
  - A block that grew in the period shows the ruled strip on its right edge. Write 1 GB into a folder under the map (`mkfile 1g ~/Downloads/strip-test.bin`) and wait: the map updates within about 2 s, and `Downloads` grows a strip on the next day's baseline. Delete the file afterwards.
- [ ] **Step 4: Commit** `feat: full window with treemap, side list, command bar and Quick Look`

---

### Task 9: Dropdown links into the window; offline drives keep their data

**Files:**
- Modify: `Sources/DiskApp/DropdownModel.swift`, `Sources/Diskinventory/DropdownView.swift`, `Sources/Diskinventory/AppDelegate.swift`
- Test: `Tests/DiskAppTests/DropdownModelTests.swift`

**Interfaces:**
- Consumes: `LiveIndex.storeDirectory(base:uuid:)` (Task 1), `DriveSummary.load(from:period:)`, `AppDelegate.openMap(uuid:focus:)` (Task 8).
- Produces:
  - `DropdownModel.Row` gains `path: String` (the change's relative path) and `opensMap: Bool` (true only when the drive is connected).
  - `DropdownModel.canOpenMap: Bool`: the drive is connected.
  - When the drive is offline and `summary` is not nil, `make`:
    - builds the bar from `summary.kinds`, with space synthesized from the `KnownDrive`: `total = lastTotal`, `available = availableForImportantUsage = lastFree`. There is no bar when either is nil.
    - builds rows from the summary.
    - sets `footerLeft` to `"Data from " + Format.shortDate(summary.updatedAt)`.
  - Offline with no summary: `emptyMessage = "Nothing saved for this drive yet."`, and `footerLeft` stays `"Offline"`.
  - `DropdownView`:
    - The changed section shows for offline drives too.
    - An actions row between that section and the footer holds a full-width "Open map" button: 30 pt tall, chip background, 6 pt radius, at 40% opacity and disabled when `!canOpenMap`. The primary "Review N GB to clear" belongs to Plan 5.
    - Rows with `opensMap` become plain buttons with a chip-colored hover, calling `openMap(row.path)`.
    - `DropdownHost` gains `openMap: (String?) -> Void`.
  - `AppDelegate`:
    - For an offline selected drive, it passes the cached summary loaded from `LiveIndex.storeDirectory(base:uuid:)`, kept in memory per uuid and period.
    - "Open map" and row clicks dismiss the panel, then call `openMap(uuid: selected, focus:)`.

- [ ] **Step 1: Write the failing tests** (and update `connectedInternalState`'s first-row expectation to the new memberwise init)

```swift
// in connectedInternalState:
#expect(m.rows.first == .init(kind: .virtualMachines, name: "Docker.raw", location: "Data", delta: "+8.1 GB", isGrowth: true,
                              path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", opensMap: true))
#expect(m.canOpenMap)

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
```

- [ ] **Step 2: Run** `swift test --filter DropdownModelTests`. Expected: build fails (`path` not a member of `Row`).
- [ ] **Step 3: Implement** the model, view and `AppDelegate` changes.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Verify by hand.** Run `scripts/make-app.sh debug && open .build/Diskinventory.app`. Expected:
  - "Open map" opens the window at the drive root.
  - Clicking a "What changed" row opens it at the item's parent with the item selected and its strip visible.
  - Eject an external drive: its tab still shows the last bar and rows, dimmed rows are not clickable, "Open map" is disabled, and the footer reads "Data from <date>".
- [ ] **Step 6: Commit** `feat: open the map from the dropdown; offline drives show their last data`

---

### Task 10: Measure memory, latency, frames and main-thread stalls

**Files:**
- Create: `Sources/Diskinventory/MainThreadWatchdog.swift`
- Modify: `Sources/Diskinventory/AppDelegate.swift` (start it with `--watchdog`)

**Interfaces:**
- Produces: `final class MainThreadWatchdog: Sendable { init(threshold: Duration = .milliseconds(16)); func start() }`. A utility-QoS thread posts a block to the main queue every 8 ms. When a block runs more than `threshold` late, it logs `main thread stalled N ms` to the `map` Logger. It runs in any build, but only with `--watchdog`.

- [ ] **Step 1: Implement** the watchdog and the `--watchdog` switch.
- [ ] **Step 2: Measure.** Run `scripts/make-app.sh release && open .build/Diskinventory.app --args --watchdog`. Then, on the internal disk: open the dropdown, click "Open map", zoom 5 levels in and back out, sweep the pointer across the map for 10 s, live-resize the window for 5 s, and open ⌘K. Then:

```bash
footprint -p $(pgrep -x Diskinventory)
log show --predicate 'subsystem == "com.ooozzy.diskinventory" AND category == "map"' --last 10m
```
Expected:
  - footprint **under 150 MB** with the window open (spec 7). Record it with the disk's file count from `diskscan /System/Volumes/Data` (stored files plus small files).
  - `map window shown in` under 100 ms, and `first map frame in` under 500 ms.
  - every `zoom:` line shows `0 late`.
  - no `main thread stalled` lines, except during live resize. Any that do show up during live resize must come from AppKit's own layout: check with `sample Diskinventory 3` during a repeat, and fix any whose top frames are ours.
- [ ] **Step 3: Measure close and cold open.** Close the window and wait 6 minutes, then run `footprint` again. Expected: under 40 MB (the Plan 3 idle target holds again), and no Dock icon. Open the map once more, and record `first map frame in` for a cold index. Expected: under 3 s.
- [ ] **Step 4: If a target is missed,** run `vmmap -summary` and `heap -s -H` on the process (and `sample` for stalls). Record the top 5 regions, classes or frames in the commit body, then stop and report. Don't tune blindly.
- [ ] **Step 5: Commit** `perf: measured window memory, open latency and zoom frames`, with every number from Steps 2 and 3 in the body.

---

## Self-review

- **Spec coverage:**
  - 3.3 toolbar, chip, breadcrumb, ⌘K: Task 8. Treemap, zoom and animation: Tasks 3, 6, 7, 8. Growth strip: Tasks 4 and 7. Small files: Tasks 3 and 4. Hover card: Tasks 5 and 8. Side list linked both ways: Tasks 4 and 8. Key bar: Task 8. The basket is Plan 5.
  - 3.2 Open map, clickable rows and offline data: Task 9.
  - 4 colors, shape, dark and light: Tasks 7 and 8.
  - 5 Dock icon and release on close: Tasks 8 and 10.
  - 6.5 off-main layout, 2 pt fold, 50,000 cap, Metal only for the map, redraw on change: Tasks 3, 6, 7.
  - 7 targets for memory, main thread and frames: Tasks 2 and 10.
- **Types:**
  - `MapRequest`, `MapSnapshot`, `MapNode`: Task 4 → Tasks 6, 7, 8.
  - `TreemapRef`, `TreemapRect`, `TreemapLayout.topLevel(of:)`: Task 3 → Tasks 4, 7.
  - `ZoomAnimation.zoomIn(from:bounds:)`: Task 3 → Tasks 6, 7.
  - `DriveController.hold()`, `release()`, `generation`, `buildMap(_:)`: Task 6 → Task 8.
  - `LiveIndex.storeDirectory(base:uuid:)`: Task 1 → Task 9.
- **Proportion:** the only body written out is `Squarify.tiles`. Everything else is signatures, rules with exact values, and tests.
