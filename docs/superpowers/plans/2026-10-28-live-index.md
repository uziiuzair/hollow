# Live Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a volume's index on disk and current, so the app opens instantly, survives quitting mid-scan, catches up on changes without rescanning, and keeps the daily history behind "what changed".

**Architecture:** The whole RAM side of `ScanIndex` (folders, folder names, hard-link set, bookkeeping) is saved as one snapshot file, written to a temp file and renamed into place. The append-only file table records its committed length in that snapshot, so anything written after the last commit is cut off on load. A `LiveIndex` actor owns one volume. It loads or scans, resumes unfinished folders, follows FSEvents from the stored event ID, re-lists only the folders that changed, saves on a debounce, and compacts when garbage builds up. History stores small path-keyed size snapshots, one per day, and a pure function turns two snapshots into the "what changed" list.

**Tech Stack:** Swift 6.3, Swift Testing, CoreServices FSEvents, `PropertyListEncoder` (binary) for history files. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-disk-inventory-design.md` (sections 6.2, 6.3, 6.4, 6.6, 7). Builds on Plan 1, `docs/superpowers/plans/2026-10-28-disk-engine-core.md`, merged to `main`.

## Global Constraints

- Everything from Plan 1's Global Constraints still holds.
- Snapshot and history files are only ever replaced by write-to-temp then `rename` (spec 6.6).
- The stored FSEvents event ID advances only after the matching changes are applied to the index (spec 6.6).
- External drives are never woken or scanned on a timer; this plan never schedules scans by time (spec 6.3).
- Volumes are keyed by volume UUID (`URLResourceValues.volumeUUIDString`) (spec 6.3).
- History: folders at or above `100_000_000` bytes, individual files at or above `500_000_000` bytes, retention 90 days (spec 6.4).
- "What changed" attributes each change to the deepest item explaining at least 70% of it (spec 6.4 plus the spec's fallback ruling).
- Snapshot format version starts at `1`; an unknown version is treated as "no snapshot".

## Review Focus

1. **The volume was erased, replaced, or its FSEvents history was purged** while the app was closed: the stored index must not be trusted; a full rescan runs. Pinned in Task 6 (`fseventsUUIDMismatchForcesFullScan`).
2. **A snapshot from another app version, or a corrupt or truncated one**: treated as no snapshot, full rescan, no crash. Pinned in Task 1.
3. **A folder renamed or deleted while the app was closed**: the old name disappears, the new one appears, and totals match a fresh scan. Pinned in Task 3.
4. **The disk fills up while saving**: the save fails, and the previous snapshot still loads. Pinned in Task 1 (`failedSaveKeepsPreviousSnapshot`).
5. **A burst of thousands of events** (`git checkout`, `npm install`): coalesced per folder, none lost, totals match a fresh scan. Pinned in Task 6.

## File map

```
Sources/DiskEngine/
  Snapshot.swift          SnapshotHeader, save/load of ScanIndex (new)
  FileTable.swift         + reopen existing files, truncate to committed length (modify)
  MappedAppendFile.swift  + open existing, truncate (modify)
  ScanIndex.swift         + bookkeeping fields, relist, resetContents, folder(atRelativePath:) (modify)
  Compaction.swift        ScanIndex.compacted(into:) (new)
  Scanner.swift           + scan(into:pending:...) resumable core with checkpoints (modify)
  EventWatcher.swift      FSEvents stream -> AsyncStream<[FSChange]> (new)
  LiveIndex.swift         the per-volume actor (new)
  History.swift           SizeSnapshot, HistoryStore (new)
  ChangeReport.swift      attribution of changes (new)
  MemoryReport.swift      component sizes + process footprint (new)
Sources/diskscan/main.swift  + `--store <dir>` live mode, `--memory` (modify)
Tests/DiskEngineTests/
  SnapshotTests.swift  ResumeTests.swift  RelistTests.swift  CompactionTests.swift
  EventWatcherTests.swift  LiveIndexTests.swift  HistoryTests.swift  ChangeReportTests.swift
```

---

### Task 1: Snapshot save and load

**Files:**
- Create: `Sources/DiskEngine/Snapshot.swift`
- Modify: `Sources/DiskEngine/MappedAppendFile.swift`, `Sources/DiskEngine/FileTable.swift`, `Sources/DiskEngine/ScanIndex.swift`, `Sources/DiskEngine/NamePool.swift`
- Test: `Tests/DiskEngineTests/SnapshotTests.swift`

**Interfaces:**
- Consumes: Plan 1's `ScanIndex`, `FileTable`, `MappedAppendFile`, `NamePool`, `PagedArray`, `DiskScanner`.
- Produces:
  - `MappedAppendFile.init(url: URL, keepingFirst length: UInt64) throws`: opens without `O_TRUNC` and `ftruncate`s to `length`.
  - `FileTable.init(directory: URL, keepingRecords: Int, nameBytes: UInt64) throws` and `var nameBytes: UInt64` (committed length of `filenames.bin`).
  - `NamePool.init(bytes: [UInt8])`, `var bytes: [UInt8] { get }`.
  - New stored state on `ScanIndex`, all saved in the snapshot:
    - `public var rootPath: String` (set by the scanner)
    - `public var rootDevice: Int32`
    - `public var pending: [FolderID]` (folders created but never listed)
    - `public var lastEventID: UInt64` (0 = none)
    - `public var fseventsUUID: String?`
    - `public internal(set) var garbageFolders: Int` and `garbageFiles: Int` (Task 3 fills them)
    - `public var scannedAt: Date`
  - `public enum SnapshotError: Error { case missing, incompatible(String) }`
  - `extension ScanIndex { func save(to directory: URL) throws; static func load(from directory: URL) throws -> ScanIndex }`
  - Snapshot file name: `index.snapshot`. Temp name: `index.snapshot.tmp`.

Snapshot layout (all little-endian, raw struct bytes):
1. Header: magic `"DINX"` (4 bytes), `version: UInt32 = 1`, `folderCount: UInt64`, `folderNameBytes: UInt64`, `fileCount: UInt64`, `fileNameBytes: UInt64`, `hardLinkCount: UInt64`, `pendingCount: UInt64`, `lastEventID: UInt64`, `rootDevice: Int32`, `garbageFolders: UInt64`, `garbageFiles: UInt64`, `scannedAt: Double`.
2. Length-prefixed (`UInt32`) UTF-8 `rootPath`, then length-prefixed `fseventsUUID` (length 0 = nil).
3. `folderCount` × `FolderRecord`, then the folder name pool bytes, then `hardLinkCount` × `UInt64`, then `pendingCount` × `FolderID`.

`save` calls `files.flush`, writes everything to the temp file with `F_FULLFSYNC`, then `rename`s it over `index.snapshot`. `load` checks the magic, version and every length against the actual file size. Any mismatch throws `.incompatible`. It reopens `FileTable` truncated to the committed counts and rebuilds `top` by offering every stored file.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func snapshotRoundTripsAFullScan() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "a/s": 10, "b/c/big2.bin": 1_500_000])
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: root, storage: store).run()
    r.index.lastEventID = 4242
    try r.index.save(to: store)
    let loaded = try ScanIndex.load(from: store)
    #expect(loaded.folders.count == r.index.folders.count)
    #expect(loaded.folders[0].totalAllocated == r.index.folders[0].totalAllocated)
    #expect(loaded.lastEventID == 4242)
    #expect(loaded.rootPath == r.index.rootPath)
    #expect(try loaded.children(of: 0).map(\.name) == (try r.index.children(of: 0).map(\.name)))
    #expect(loaded.top.sortedDescending().count == 2)
}
@Test func filesAppendedAfterSaveAreDroppedOnLoad() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["big.bin": 2_000_000]), storage: store).run()
    try r.index.save(to: store)
    _ = try r.index.files.append(name: "ghost", record: .init(allocated: 9, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    try r.index.files.flush()
    #expect(try ScanIndex.load(from: store).files.count == 1)
}
@Test func missingCorruptOrForeignSnapshotIsRejected() throws {
    let store = try Fixtures.tempDir()
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
    try Data("DINX".utf8 + [9, 0, 0, 0]).write(to: store.appending(path: "index.snapshot"))
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
    try Data(repeating: 7, count: 300).write(to: store.appending(path: "index.snapshot"))
    #expect(throws: SnapshotError.self) { _ = try ScanIndex.load(from: store) }
}
@Test func failedSaveKeepsPreviousSnapshot() async throws {
    let store = try Fixtures.tempDir()
    let r = try await DiskScanner(root: try Fixtures.tree(["big.bin": 2_000_000]), storage: store).run()
    r.index.lastEventID = 1
    try r.index.save(to: store)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
    r.index.lastEventID = 2
    #expect(throws: (any Error).self) { try r.index.save(to: store) }
    #expect(try ScanIndex.load(from: store).lastEventID == 1)
}
```

`FileTable.flush()` is a new public method that forwards to both files.

- [ ] **Step 2: Run** `swift test --filter SnapshotTests`. Expected: build fails (`save`, `load`, `SnapshotError` not defined).
- [ ] **Step 3: Implement** the reopen initializers, the `ScanIndex` fields (the scanner's `run()` sets `rootPath` and `rootDevice`), and `Snapshot.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: save and load the index as an atomic snapshot`

---

### Task 2: Resumable scanning with checkpoints

**Files:**
- Modify: `Sources/DiskEngine/Scanner.swift`
- Test: `Tests/DiskEngineTests/ResumeTests.swift`

**Interfaces:**
- Consumes: Task 1 (`pending`, `save`, `load`, `rootPath`, `rootDevice`).
- Produces:
  - `public enum CheckpointDecision: Sendable { case proceed, stop }`
  - `extension DiskScanner { public func scan(into index: ScanIndex, starting: [FolderID], checkpointEvery: Duration = .seconds(30), checkpoint: (ScanIndex) throws -> CheckpointDecision = { _ in .proceed }, isolation: isolated (any Actor)? = #isolation) async throws -> Int }` returns unreadable-folder count. It uses `index.rootPath` and `index.rootDevice`. At each checkpoint, `index.pending` holds every queued **and in-flight** folder, so a saved index can resume from it. On normal completion `index.pending` is `[]`.
  - `run()` becomes: resolve root, create the index, set `rootPath` and `rootDevice`, `scan(into:starting:[0])`.
  - `public static func resume(_ index: ScanIndex, workers:) async throws` is **not** added. Callers call `scan(into: index, starting: index.pending)`.

The `isolation` parameter lets an actor (Task 6) pass its own non-Sendable `ScanIndex` without crossing isolation. Child tasks still return only `DirectoryListing`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func stoppedScanResumesToSameTotals() async throws {
    var spec: [String: Int] = [:]
    for i in 0..<400 { spec["d\(i % 40)/e\(i)/f.bin"] = (i % 3 == 0) ? 1_200_000 : 100 }
    let root = try Fixtures.tree(spec)
    let fresh = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run()

    let store = try Fixtures.tempDir()
    let scanner = DiskScanner(root: root, storage: store, workers: 2)
    let index = try ScanIndex(rootName: root.lastPathComponent, storage: store)
    index.rootPath = root.path; index.rootDevice = fresh.index.rootDevice
    var checkpoints = 0
    _ = try await scanner.scan(into: index, starting: [0], checkpointEvery: .zero) { idx in
        checkpoints += 1
        if checkpoints == 3 { try idx.save(to: store); return .stop }
        return .proceed
    }
    let reloaded = try ScanIndex.load(from: store)
    #expect(!reloaded.pending.isEmpty)
    _ = try await DiskScanner(root: root, storage: store).scan(into: reloaded, starting: reloaded.pending)
    #expect(reloaded.pending.isEmpty)
    #expect(reloaded.folders[0].totalAllocated == fresh.index.folders[0].totalAllocated)
    #expect(reloaded.files.count == fresh.index.files.count)
}
```

- [ ] **Step 2: Run** `swift test --filter ResumeTests`. Expected: build fails (`scan(into:...)` not defined).
- [ ] **Step 3: Implement** `scan(into:...)` by moving the loop out of `run()`. Keep an in-flight `Set<FolderID>`. The checkpoint sets `index.pending = inFlight + queue[head...]` before calling the closure. `.stop` cancels the group and returns after in-flight listings drain **without** integrating them, so they stay pending.
- [ ] **Step 4: Run** `swift test`. Expected: all pass, including Plan 1's scanner tests.
- [ ] **Step 5: Commit** `feat: resumable scans with checkpoints`

---

### Task 3: Re-listing changed folders

**Files:**
- Modify: `Sources/DiskEngine/ScanIndex.swift`, `Sources/DiskEngine/Records.swift`
- Test: `Tests/DiskEngineTests/RelistTests.swift`

**Interfaces:**
- Consumes: Plan 1 `integrate`, `DirectoryListing`, `BulkDirectoryReader`.
- Produces:
  - `FolderFlags.garbage` (`1 << 4`): a slot no longer reachable from the root.
  - `func folder(atRelativePath path: String) -> FolderID?`: path relative to `rootPath`, `""` is the root. Walks child names and skips garbage.
  - `func relist(_ listing: DirectoryListing) throws -> [FolderID]`: replaces one already-listed folder's direct contents. Returns new subfolders to scan.
  - `func resetContents(of folder: FolderID)`: subtracts the folder's total from its ancestors, marks every descendant garbage, and zeroes the folder's counts, ranges and flags (except `.garbage`), so `integrate` can list it fresh. This is used for "must scan subdirs".

`relist` algorithm (keeps "children are contiguous" true everywhere):
1. Old direct bytes = `smallAllocated` + the allocated size of the folder's current big files.
2. Build a name map of the folder's current non-garbage child folders.
3. Append a new contiguous block of child records in listing order. For a name already present, **copy** the old record into the new slot, set every child of the copied record to point at the new ID as its `parent`, and mark the old slot `.garbage`. A new name gets a fresh record and is returned for scanning.
4. Old children not in the listing: subtract their `totalAllocated` (they are about to vanish) and mark them and their whole subtree `.garbage`.
5. Append a new block of big files. Count the old block in `garbageFiles`. Reset the small counters from the listing.
6. New direct bytes minus old direct bytes, plus the removed-children totals (negative), is applied to this folder and every ancestor.
7. Unreadable or vanished outcomes: treat as an empty listing and set the flag.
`garbageFolders` counts every slot marked garbage.

Accepted limitation (documented in the code): the hard-link set is not shrunk when a hard-linked file is removed. If a remaining link to that inode is seen later it is skipped, so the total can be low until the next compaction rebuilds the set (Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
private func scanned(_ root: URL) async throws -> ScanIndex {
    try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
}
private func relist(_ idx: ScanIndex, _ rel: String) throws -> [FolderID] {
    var r = BulkDirectoryReader()
    let id = try #require(idx.folder(atRelativePath: rel))
    return try idx.relist(r.list(path: idx.path(of: id, rootPath: idx.rootPath), folder: id))
}

@Test func addedFileUpdatesAncestors() async throws {
    let root = try Fixtures.tree(["a/b/x": 10])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 3_000_000).write(to: root.appending(path: "a/b/new.bin"))
    _ = try relist(idx, "a/b")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
}
@Test func renamedFolderKeepsItsSubtree() async throws {
    let root = try Fixtures.tree(["a/old/deep/f.bin": 2_000_000])
    let idx = try await scanned(root)
    try FileManager.default.moveItem(at: root.appending(path: "a/old"), to: root.appending(path: "a/new"))
    #expect(try relist(idx, "a").count == 1)
    #expect(idx.folder(atRelativePath: "a/old") == nil)
    // the new folder is reported for scanning; it is a fresh record
}
@Test func untouchedSiblingSubtreeSurvivesRelist() async throws {
    let root = try Fixtures.tree(["a/keep/deep/f.bin": 2_000_000, "a/x": 10])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 50).write(to: root.appending(path: "a/y"))
    #expect(try relist(idx, "a").isEmpty)
    let deep = try #require(idx.folder(atRelativePath: "a/keep/deep"))
    #expect(idx.path(of: deep, rootPath: "/r") == "/r/a/keep/deep")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.garbageFolders == 1)
}
@Test func removedFolderSubtractsItsTotal() async throws {
    let root = try Fixtures.tree(["a/gone/f.bin": 2_000_000, "a/stay": 10])
    let idx = try await scanned(root)
    try FileManager.default.removeItem(at: root.appending(path: "a/gone"))
    _ = try relist(idx, "a")
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(idx.folder(atRelativePath: "a/gone") == nil)
}
@Test func resetContentsThenRescanMatchesFresh() async throws {
    let root = try Fixtures.tree(["a/b/c/f.bin": 2_000_000])
    let idx = try await scanned(root)
    try Data(repeating: 1, count: 1_500_000).write(to: root.appending(path: "a/b/c/g.bin"))
    let a = try #require(idx.folder(atRelativePath: "a"))
    idx.resetContents(of: a)
    _ = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).scan(into: idx, starting: [a])
    #expect(idx.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
}
```

- [ ] **Step 2: Run** `swift test --filter RelistTests`. Expected: build fails.
- [ ] **Step 3: Implement** `folder(atRelativePath:)`, `relist`, `resetContents`, and `.garbage`. `children(of:)` and `path(of:)` need no change, because ranges never include garbage.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: re-list changed folders in place`

---

### Task 4: Compaction

**Files:**
- Create: `Sources/DiskEngine/Compaction.swift`
- Test: `Tests/DiskEngineTests/CompactionTests.swift`

**Interfaces:**
- Consumes: Task 1 fields, Task 3 garbage.
- Produces: `extension ScanIndex { func compacted(into storage: URL) throws -> ScanIndex; var garbageRatio: Double { get } }`. `garbageRatio` is `Double(garbageFolders + garbageFiles) / Double(max(1, folders.count + files.count))`.

Approach: breadth-first from the root. The new index appends each folder's children as one block (same order), copies big files into a fresh `FileTable` under `storage`, rebuilds the hard-link set from `.hardLinked` files, and rebuilds `top`. It copies `rootPath`, `rootDevice`, `lastEventID`, `fseventsUUID`, `scannedAt`, and `pending` (remapped to new IDs; pending folders not reachable are dropped). Garbage counters start at 0.

- [ ] **Step 1: Write the failing test**

```swift
@Test func compactionDropsGarbageAndKeepsTotals() async throws {
    let root = try Fixtures.tree(["a/keep/f.bin": 2_000_000, "a/gone/g.bin": 1_500_000, "b/x": 10])
    let idx = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run().index
    try FileManager.default.removeItem(at: root.appending(path: "a/gone"))
    var r = BulkDirectoryReader()
    let a = try #require(idx.folder(atRelativePath: "a"))
    _ = try idx.relist(r.list(path: root.appending(path: "a").path, folder: a))
    #expect(idx.garbageRatio > 0)
    let c = try idx.compacted(into: try Fixtures.tempDir())
    #expect(c.garbageRatio == 0)
    #expect(c.folders.count == 4) // root, a, a/keep, b
    #expect(c.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(c.files.count == 1)
    #expect(c.folder(atRelativePath: "a/keep") != nil)
}
```

- [ ] **Step 2: Run** `swift test --filter CompactionTests`. Expected: build fails.
- [ ] **Step 3: Implement** `Compaction.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: compact the index to drop garbage`

---

### Task 5: FSEvents watcher

**Files:**
- Create: `Sources/DiskEngine/EventWatcher.swift`
- Test: `Tests/DiskEngineTests/EventWatcherTests.swift`

**Interfaces:**
- Produces:
  - `public struct FSChange: Sendable, Equatable { path: String; id: UInt64; rescanSubtree: Bool; historyLost: Bool }`
  - `static func FSChange.from(path: String, flags: FSEventStreamEventFlags, id: UInt64) -> FSChange?`: returns nil for `kFSEventStreamEventFlagHistoryDone`. `rescanSubtree` is true for `MustScanSubDirs`. `historyLost` is true for `EventIdsWrapped`, `RootChanged`, or a `MustScanSubDirs` that also has `UserDropped`/`KernelDropped` on the root path.
  - `public final class EventWatcher: Sendable { init(device: dev_t, since: UInt64, latency: Double = 2.0); let changes: AsyncStream<[FSChange]>; func start() throws; func stop(); static func journalUUID(device: dev_t) -> String? }`. It uses `FSEventStreamCreateRelativeToDevice` and `FSEventStreamSetDispatchQueue` on a private serial queue at `.utility`. Paths come back relative to the volume's mount point. `journalUUID` wraps `FSEventsCopyUUIDForDevice`, and nil means the volume keeps no event history (spec 6.3: exFAT, FAT). `since == 0` means `kFSEventStreamEventIdSinceNow`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func flagMapping() {
    let sub = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
    #expect(FSChange.from(path: "a", flags: sub, id: 5) == FSChange(path: "a", id: 5, rescanSubtree: true, historyLost: false))
    #expect(FSChange.from(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 6) == nil)
    #expect(FSChange.from(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped), id: 7)?.historyLost == true)
}
@Test func internalVolumeHasAJournal() throws {
    var st = stat(); stat(FileManager.default.temporaryDirectory.path, &st)
    #expect(EventWatcher.journalUUID(device: st.st_dev) != nil)
}
@Test(.timeLimit(.minutes(1))) func reportsAFolderThatChanged() async throws {
    let root = try Fixtures.tree(["watched/": 0])
    var st = stat(); stat(root.path, &st)
    let w = EventWatcher(device: st.st_dev, since: 0, latency: 0.2)
    try w.start(); defer { w.stop() }
    try await Task.sleep(for: .milliseconds(500))
    try Data([1]).write(to: root.appending(path: "watched/new"))
    let target = root.appending(path: "watched").resolvingSymlinksInPath().path
    for await batch in w.changes {
        if batch.contains(where: { target.hasSuffix("/" + $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }) { return }
    }
    Issue.record("no event for the changed folder")
}
```

- [ ] **Step 2: Run** `swift test --filter EventWatcherTests`. Expected: build fails.
- [ ] **Step 3: Implement** `EventWatcher.swift`. The C callback gets an `Unmanaged` context holding the stream continuation, and builds one `[FSChange]` per callback.
- [ ] **Step 4: Run** `swift test --filter EventWatcherTests`. Expected: 3 pass.
- [ ] **Step 5: Commit** `feat: add FSEvents watcher`

---

### Task 6: LiveIndex

**Files:**
- Create: `Sources/DiskEngine/LiveIndex.swift`
- Test: `Tests/DiskEngineTests/LiveIndexTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 5.
- Produces:
  - `public enum OpenedFrom: Sendable, Equatable { case snapshot, resumed, fullScan(reason: String) }`
  - `public actor LiveIndex`:
    - `init(volumeRoot: URL, store: URL, saveDebounce: Duration = .seconds(30), compactAbove: Double = 0.25)`
    - `func open() async throws -> OpenedFrom`: load the snapshot. A full scan happens if the snapshot is missing or incompatible, `rootPath` differs, the device's journal UUID differs from `fseventsUUID`, or the journal UUID is nil (no history; spec 6.3). If `pending` is non-empty, resume. Then catch up and start watching. Saves once at the end.
    - `func apply(_ changes: [FSChange]) async throws`: called by the watcher loop, and directly in tests. Here `FSChange.path` is **absolute**: the watcher loop prefixes the volume mount point (`URLResourceValues.volumeURL`) to the device-relative paths FSEvents delivers, before calling `apply`. Coalesce by folder. `historyLost` means full rescan. For each path, take the deepest existing folder via `folder(atRelativePath:)` (a missing path re-lists its nearest existing ancestor). `rescanSubtree` means `resetContents` then scan. Otherwise `relist`, then scan the folders it returns. Ignore paths outside `rootPath`. After applying, set `lastEventID` to the batch's max ID and mark the index dirty.
    - `func saveNow() throws`: compact first if `garbageRatio > compactAbove` (into `store/compact.tmp`, then swap file-table files into place before saving), then `save(to: store)`.
    - `func close() async throws`: stop watching, `saveNow()`.
    - Read access for later plans: `func withIndex<R: Sendable>(_ body: (ScanIndex) throws -> R) rethrows -> R`.
    - `static func storeDirectory(base: URL, volume: URL) throws -> URL`: returns `base/Volumes/<volume UUID>/` and creates it (spec 6.2, 6.3).
  - Debounce: after a change, schedule one save `saveDebounce` later. Further changes do not move it.
  - `rootPath` must equal the volume mount point or be inside it. `apply` ignores absolute paths outside `rootPath`, and strips the `rootPath` prefix before `folder(atRelativePath:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func secondOpenLoadsSnapshot() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store)
    #expect(try await first.open() == .fullScan(reason: "no snapshot"))
    try await first.close()
    let second = LiveIndex(volumeRoot: root, store: store)
    #expect(try await second.open() == .snapshot)
    try await second.close()
}
@Test func burstOfChangesMatchesFreshScan() async throws {
    let root = try Fixtures.tree(["seed/": 0]); let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
    let base = root.resolvingSymlinksInPath().path
    var changes: [FSChange] = []
    for d in 0..<200 {
        for f in 0..<10 { try Fixtures.write(root.appending(path: "seed/d\(d)/f\(f)"), bytes: f == 0 ? 1_100_000 : 10) }
        changes.append(FSChange(path: base + "/seed/d\(d)", id: UInt64(d + 1), rescanSubtree: false, historyLost: false))
    }
    changes.append(FSChange(path: base + "/seed", id: 999, rescanSubtree: false, historyLost: false))
    try await live.apply(changes)
    let total = await live.withIndex { $0.folders[0].totalAllocated }
    #expect(total == Fixtures.sumAllocated(under: root))
    #expect(await live.withIndex { $0.lastEventID } == 999)
    try await live.close()
}
@Test func fseventsUUIDMismatchForcesFullScan() async throws {
    let root = try Fixtures.tree(["a/f.bin": 2_000_000]); let store = try Fixtures.tempDir()
    let first = LiveIndex(volumeRoot: root, store: store); _ = try await first.open()
    await first.withIndex { $0.fseventsUUID = "not-the-real-one" }
    try await first.close()
    #expect(try await LiveIndex(volumeRoot: root, store: store).open() == .fullScan(reason: "event history changed"))
}
@Test func storeDirectoryIsKeyedByVolumeUUID() throws {
    let tmp = FileManager.default.temporaryDirectory
    let uuid = try #require(try tmp.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let dir = try LiveIndex.storeDirectory(base: try Fixtures.tempDir(), volume: tmp)
    #expect(dir.lastPathComponent == uuid)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}
@Test func interruptedScanResumes() async throws {
    // Build a snapshot with pending folders by stopping a scan (as in Task 2), save it, then open.
    let root = try Fixtures.tree(Dictionary(uniqueKeysWithValues: (0..<200).map { ("d\($0)/f", 10) }))
    let store = try Fixtures.tempDir()
    let idx = try ScanIndex(rootName: root.lastPathComponent, storage: store)
    var st = stat(); stat(root.path, &st)
    idx.rootPath = root.resolvingSymlinksInPath().path; idx.rootDevice = st.st_dev
    idx.fseventsUUID = EventWatcher.journalUUID(device: st.st_dev)
    _ = try await DiskScanner(root: root, storage: store, workers: 1).scan(into: idx, starting: [0], checkpointEvery: .zero) { i in
        try i.save(to: store); return .stop
    }
    let live = LiveIndex(volumeRoot: root, store: store)
    #expect(try await live.open() == .resumed)
    #expect(await live.withIndex { $0.folders[0].totalAllocated } == Fixtures.sumAllocated(under: root))
    try await live.close()
}
```

Add `Fixtures.write(_ url: URL, bytes: Int)` (creates parent folders). The `withIndex` calls that mutate in tests use a test-only `withIndex` overload taking `(ScanIndex) -> Void`.

- [ ] **Step 2: Run** `swift test --filter LiveIndexTests`. Expected: build fails.
- [ ] **Step 3: Implement** `LiveIndex.swift`. Exact `fullScan` reasons: `"no snapshot"`, `"incompatible snapshot"`, `"different root"`, `"event history changed"`, `"no event history"`, `"history lost"`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: LiveIndex keeps a volume's index current`

---

### Task 7: History and "what changed"

**Files:**
- Create: `Sources/DiskEngine/History.swift`, `Sources/DiskEngine/ChangeReport.swift`
- Test: `Tests/DiskEngineTests/HistoryTests.swift`, `Tests/DiskEngineTests/ChangeReportTests.swift`

**Interfaces:**
- Consumes: `ScanIndex` (reachable folders, files, `rootPath`).
- Produces:
  - `public struct SizeSnapshot: Codable, Sendable, Equatable { var sizes: [String: UInt64] }`, with keys being paths relative to the root (`""` = root). `static func capture(_ index: ScanIndex) throws -> SizeSnapshot` takes every reachable folder `>= 100_000_000` (root always included) and every stored file `>= 500_000_000`.
  - `public struct Day: Codable, Hashable, Comparable, Sendable { let year, month, day: Int; init(_ date: Date, calendar: Calendar); func adding(days: Int, calendar: Calendar) -> Day }`
  - `public final class HistoryStore { init(directory: URL, calendar: Calendar = .current); func record(_ s: SizeSnapshot, on day: Day) throws; func snapshot(onOrBefore day: Day) throws -> SizeSnapshot?; func days() throws -> [Day]; func prune(keeping days: Int = 90, today: Day) throws }`
    - Files: `history/<yyyy-mm-dd>.plist`, binary plist of `enum Entry: Codable { case key(SizeSnapshot), delta(changed: [String: UInt64], removed: [String]) }`.
    - Store a key when there is no earlier day, or the nearest earlier key is 7 or more days back; otherwise store a delta against the previous stored day's reconstructed snapshot. `record` on an existing day replaces it (app quit, spec 6.4). Writes are temp-then-rename.
    - `prune` deletes days older than `today − 90`. If the oldest remaining day is a delta, rewrite it as a key first.
  - `extension LiveIndex { func recordHistory(now: Date = .now) async throws }`: captures a `SizeSnapshot` and records it for today in `HistoryStore(directory: store/history)`, then `prune(today:)`. `close()` calls it (spec 6.4: "once a day and at app quit"). Plan 3 schedules the daily call.
  - `extension LiveIndex { func changes(since days: Int, now: Date = .now) async throws -> [Change] }`: `ChangeReport.changes(from: history.snapshot(onOrBefore: today − days) ?? empty, to: SizeSnapshot.capture(index))`, live against stored (spec 6.4 "Today is computed live"). `days` is 1, 7 or 30.
  - `public struct Change: Sendable, Equatable { path: String; delta: Int64 }`
  - `public enum ChangeReport { static func changes(from old: SizeSnapshot, to new: SizeSnapshot, minimum: UInt64 = 100_000_000, explained: Double = 0.7) -> [Change] }`

Attribution algorithm. Paths missing on one side count as 0, a documented limit of the thresholds. Walk the union tree from `""`. At node N with delta d (|d| ≥ minimum):
- S = N's children with |delta| ≥ minimum.
- If Σ|delta of S| ≥ `explained` × |d|, N is explained by its children: don't report N; recurse into each of S.
- Otherwise report N, and still recurse into S.
Result sorted by |delta| descending. A node's children are the keys whose parent path (everything before the last `/`, or `""`) is N.

- [ ] **Step 1: Write the failing tests**

```swift
// ChangeReportTests
let GB: UInt64 = 1_000_000_000
@Test func deepestExplainingItemIsReported() {
    let old = SizeSnapshot(sizes: ["": 500*GB, "Library": 300*GB, "Library/Docker": 84*GB, "Library/Docker/Docker.raw": 84*GB,
                                   "Developer": 40*GB, "Developer/DerivedData": 10*GB])
    let new = SizeSnapshot(sizes: ["": 514*GB, "Library": 308*GB, "Library/Docker": 92*GB, "Library/Docker/Docker.raw": 92*GB,
                                   "Developer": 46*GB, "Developer/DerivedData": 16*GB])
    #expect(ChangeReport.changes(from: old, to: new) == [
        Change(path: "Library/Docker/Docker.raw", delta: 8_000_000_000),
        Change(path: "Developer/DerivedData", delta: 6_000_000_000)])
}
@Test func spreadOutGrowthReportsTheFolder() {
    let old = SizeSnapshot(sizes: ["": 100*GB, "Downloads": 10*GB, "Downloads/a": 200_000_000])
    let new = SizeSnapshot(sizes: ["": 103*GB, "Downloads": 13*GB, "Downloads/a": 300_000_000])
    #expect(ChangeReport.changes(from: old, to: new).first == Change(path: "Downloads", delta: 3_000_000_000))
}
@Test func freedSpaceIsNegative() {
    let old = SizeSnapshot(sizes: ["": 100*GB, "Trash": 2*GB]); let new = SizeSnapshot(sizes: ["": 98*GB])
    #expect(ChangeReport.changes(from: old, to: new) == [Change(path: "Trash", delta: -2_000_000_000)])
}

// HistoryTests
@Test func deltasReconstructAndKeysEveryWeek() throws {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Karachi")!
    let store = HistoryStore(directory: try Fixtures.tempDir(), calendar: cal)
    let d0 = Day(Date(timeIntervalSince1970: 1_790_000_000), calendar: cal)
    for i in 0..<10 { try store.record(SizeSnapshot(sizes: ["": UInt64(i) * GB, "x\(i)": GB]), on: d0.adding(days: i, calendar: cal)) }
    #expect(try store.snapshot(onOrBefore: d0.adding(days: 8, calendar: cal)) == SizeSnapshot(sizes: ["": 8 * GB, "x8": GB]))
    #expect(try store.snapshot(onOrBefore: d0.adding(days: 20, calendar: cal))?.sizes[""] == 9 * GB)
    #expect(try store.snapshot(onOrBefore: d0.adding(days: -1, calendar: cal)) == nil)
}
@Test func recordingTheSameDayReplacesIt() throws {
    let cal = Calendar(identifier: .gregorian); let store = HistoryStore(directory: try Fixtures.tempDir(), calendar: cal)
    let d = Day(Date(), calendar: cal)
    try store.record(SizeSnapshot(sizes: ["": 1]), on: d); try store.record(SizeSnapshot(sizes: ["": 2]), on: d)
    #expect(try store.days().count == 1)
    #expect(try store.snapshot(onOrBefore: d)?.sizes[""] == 2)
}
@Test func pruneKeepsNinetyDaysAndRekeys() throws {
    let cal = Calendar(identifier: .gregorian); let store = HistoryStore(directory: try Fixtures.tempDir(), calendar: cal)
    let start = Day(Date(timeIntervalSince1970: 1_780_000_000), calendar: cal)
    for i in 0..<100 { try store.record(SizeSnapshot(sizes: ["": UInt64(i)]), on: start.adding(days: i, calendar: cal)) }
    let today = start.adding(days: 99, calendar: cal)
    try store.prune(keeping: 90, today: today)
    #expect(try store.days().first == today.adding(days: -90, calendar: cal))
    #expect(try store.snapshot(onOrBefore: today.adding(days: -90, calendar: cal))?.sizes[""] == 9)
}
@Test func liveIndexReportsGrowthSinceYesterday() async throws {
    let root = try Fixtures.tree(["keep/": 0]); let store = try Fixtures.tempDir()
    let live = LiveIndex(volumeRoot: root, store: store); _ = try await live.open()
    let yesterday = Date.now.addingTimeInterval(-86_400)
    try await live.recordHistory(now: yesterday)
    try Fixtures.write(root.appending(path: "keep/big.bin"), bytes: 600_000_000)
    let base = root.resolvingSymlinksInPath().path
    try await live.apply([FSChange(path: base + "/keep", id: 1, rescanSubtree: false, historyLost: false)])
    let changes = try await live.changes(since: 1)
    #expect(changes.first?.path == "keep/big.bin")
    try await live.close()
}
@Test func captureUsesThresholds() async throws {
    let idx = try ScanIndex(rootName: "r", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [.file("huge", allocated: 600_000_000), .dir("small")]), rootDevice: 1)
    #expect(try SizeSnapshot.capture(idx).sizes == ["": 600_000_000, "huge": 600_000_000])
}
```

- [ ] **Step 2: Run** `swift test --filter "HistoryTests|ChangeReportTests"`. Expected: build fails.
- [ ] **Step 3: Implement** `History.swift` and `ChangeReport.swift`.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** `feat: daily size history and change attribution`

---

### Task 8: Memory breakdown and live mode in `diskscan`

**Files:**
- Create: `Sources/DiskEngine/MemoryReport.swift`
- Modify: `Sources/diskscan/main.swift`
- Test: `Tests/DiskEngineTests/MemoryReportTests.swift`

**Interfaces:**
- Produces:
  - `public struct MemoryReport: Sendable { folderTableBytes: Int; folderNameBytes: Int; hardLinkBytes: Int; pendingBytes: Int; processFootprint: UInt64; static func measure(_ index: ScanIndex) -> MemoryReport }`. `processFootprint` is `phys_footprint` from `task_info(TASK_VM_INFO)`, which is what Activity Monitor shows. The other fields estimate capacity times stride.
  - `diskscan <path> --memory` additionally prints the report, plus `ru_maxrss`.
  - `diskscan <path> --store <dir>` runs a `LiveIndex`: prints `OpenedFrom` and elapsed time to open, then prints each applied batch (`N changes, total X GB`) until Ctrl-C, then `close()`s.

- [ ] **Step 1: Write the failing test**

```swift
@Test func memoryReportCountsTables() async throws {
    let idx = try await DiskScanner(root: try Fixtures.tree(["a/f": 10, "b/g": 10]), storage: try Fixtures.tempDir()).run().index
    let m = MemoryReport.measure(idx)
    #expect(m.folderTableBytes >= 3 * MemoryLayout<FolderRecord>.stride)
    #expect(m.processFootprint > 0)
}
```

- [ ] **Step 2: Run** `swift test --filter MemoryReportTests`. Expected: build fails.
- [ ] **Step 3: Implement** `MemoryReport.swift` and the CLI flags.
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Measure**

Run: `swift build -c release && .build/release/diskscan /System/Volumes/Data --memory`
Expected: it prints the component breakdown and footprint. Record which component dominates. If the footprint is above 150 MB, or the breakdown explains less than half of it, stop and report the numbers. Don't tune blindly.

Run: `.build/release/diskscan ~ --store "$TMPDIR/live"` twice, quitting with Ctrl-C after the open line.
Expected: the first prints `fullScan(reason: "no snapshot")`. The second prints `snapshot` with an open time **under 2 s**. Then create a 200 MB file in `~/Downloads` while the second run is watching; a batch line appears within about 5 s and the total rises by about 0.2 GB.

- [ ] **Step 6: Commit** `feat: memory breakdown and live mode in diskscan` (measured numbers in the body)
