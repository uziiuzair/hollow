# Disk Engine Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Swift package, `DiskEngine`, that scans a folder tree in parallel without ever holding every file in RAM, plus a `diskscan` command-line tool that proves the memory and speed numbers on a real disk.

**Architecture:** Worker tasks list one directory each with `getattrlistbulk` into a fixed 64 KB buffer and hand back a listing. A single collector loop owns all tables: folders live in a RAM array (one fixed-size record per folder), files at or above 1 MB are appended to an on-disk file that is memory-mapped for reading, and smaller files only bump their folder's small-files counter. Folder totals are pushed up the ancestor chain as each listing lands, so totals are always live.

**Tech Stack:** Swift 6.3 (Xcode 26.6), Swift Package Manager, Swift Testing (`import Testing`), Darwin `getattrlistbulk`, `mmap`. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-10-28-disk-inventory-design.md` (sections 6.1, 6.2, 6.7 and 7 are what this plan builds).

## Where this plan sits

The spec is five subsystems. Each gets its own plan, written after the one before it ships, and each produces working software on its own:

1. **Engine core** (this plan): scanner, folder/file tables, `diskscan` CLI.
2. Live index: persistence on disk, crash safety (spec 6.6), FSEvents catch-up (6.3), history snapshots and "what changed" (6.4).
3. Menu bar app and dropdown (spec 3.1, 3.2, 5).
4. Full window: treemap layout, Metal renderer, side list, key bar (3.3, 4, 6.5).
5. Basket, review, junk lenses, Full Disk Access onboarding, settings, Sparkle (3.4, 3.5, 5).

## Global Constraints

- macOS 14 or newer (`platforms: [.macOS(.v14)]`).
- Swift 6 language mode with strict concurrency on.
- No third-party dependencies in `DiskEngine`.
- Every size the engine reports is **allocated** size. Logical size is stored only for display.
- Never follow symlinks. Never cross onto another device.
- Scanning never runs on the main thread; scanner tasks use `.utility` priority.
- Per-worker read buffer is exactly 64 KB (`65_536` bytes).
- Files below 1 MB (`1_048_576` bytes allocated) are never stored individually.
- Top-largest-files list holds exactly 1,000 entries.
- Hard-linked files (link count > 1) are counted once.

## Review Focus

1. **Folders the app can't read** (very common before Full Disk Access is granted): the scan must finish, the folder is flagged unreadable, and its size counts as 0. Pinned in Task 3 and Task 5.
2. **Symlink loops** such as a link pointing at its own parent: never followed, never infinite. Pinned in Task 3 and Task 5.
3. **Hard links** (Time Machine-style trees, package managers): the same inode counts once. Pinned in Task 4 and Task 5.
4. **Crossing onto another volume** (a mounted disk image inside a scanned folder): not descended. Pinned in Task 5 via the `shouldDescend` decision function.
5. **A folder deleted during the scan** (caches churn constantly): treated as empty, no error, no crash. Pinned in Task 3.

## File map

```
Package.swift
Sources/DiskEngine/
  Records.swift          FolderRecord, FileRecord, FileFlags, FolderFlags, IDs
  NamePool.swift         RAM name pool for folder names
  MappedAppendFile.swift buffered append writer + read-only mmap of the same file
  FileTable.swift        FileRecord storage + file-name pool, both on disk
  BulkDirectoryReader.swift  getattrlistbulk wrapper -> DirectoryListing
  TopFiles.swift         fixed-size heap of largest files
  ScanIndex.swift        the tables, integrate(listing:), children(of:)
  Scanner.swift          concurrent walk, progress stream
  VolumeSpace.swift      total / free / reclaimable for a volume
Sources/diskscan/main.swift
Tests/DiskEngineTests/
  RecordsTests.swift  MappedAppendFileTests.swift  BulkDirectoryReaderTests.swift
  ScanIndexTests.swift  ScannerTests.swift  VolumeSpaceTests.swift
  Fixtures.swift         helpers that build temp folder trees
```

---

### Task 1: Package, records, folder name pool

**Files:**
- Create: `Package.swift`, `Sources/DiskEngine/Records.swift`, `Sources/DiskEngine/NamePool.swift`, `Sources/diskscan/main.swift` (prints "diskscan" for now)
- Test: `Tests/DiskEngineTests/RecordsTests.swift`

**Interfaces:**
- Produces:
  - `public typealias FolderID = UInt32`, `public typealias FileIndex = UInt32`, `public let noFolder: FolderID = .max`
  - `public struct FolderFlags: OptionSet { rawValue: UInt32 }` with `.unreadable`, `.vanished`, `.otherDevice`
  - `public struct FileFlags: OptionSet { rawValue: UInt16 }` with `.dataless`, `.mayShareBlocks`, `.hardLinked`, `.symlink`
  - `public struct FolderRecord` (stored fields in this order): `parent: FolderID`, `nameOffset: UInt32`, `firstChildFolder: FolderID`, `childFolderCount: UInt32`, `firstFile: FileIndex`, `bigFileCount: UInt32`, `smallFileCount: UInt32`, `flags: FolderFlags`, `totalAllocated: UInt64`, `smallAllocated: UInt64`
  - `public struct FileRecord` (in order): `allocated: UInt64`, `parent: FolderID`, `nameOffset: UInt32`, `logicalKiB: UInt32`, `flags: FileFlags`, `kind: UInt8`, one `UInt8` pad
  - `public struct NamePool { mutating func append(_ name: String) -> UInt32; func name(at offset: UInt32) -> String; var byteCount: Int }`. Storage is `[UInt8]`; each entry is a `UInt16` little-endian byte length followed by the UTF-8 bytes.

Note: the spec says "about 32 bytes" per folder. Keeping children and files contiguous (instead of linked lists) costs 48 bytes per folder. 500,000 folders is 24 MB, still well inside the targets. This is the intended trade.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func recordSizesStayCompact() {
    #expect(MemoryLayout<FolderRecord>.stride == 48)
    #expect(MemoryLayout<FileRecord>.stride == 24)
}
@Test func namePoolRoundTripsUnicodeAndEmpty() {
    var pool = NamePool()
    let a = pool.append("Photos Library.photoslibrary")
    let b = pool.append("Ünïcødé 写真 🗂")
    let c = pool.append("")
    #expect(pool.name(at: a) == "Photos Library.photoslibrary")
    #expect(pool.name(at: b) == "Ünïcødé 写真 🗂")
    #expect(pool.name(at: c) == "")
}
```

- [ ] **Step 2: Run** `swift test --filter RecordsTests`. Expected: build fails, types not defined.
- [ ] **Step 3: Implement** `Package.swift` (tools 6.0, products `DiskEngine` library and `diskscan` executable depending on it, test target), `Records.swift`, `NamePool.swift`.
- [ ] **Step 4: Run** `swift test --filter RecordsTests`. Expected: 2 tests pass.
- [ ] **Step 5: Commit** `feat: add DiskEngine package, compact records, name pool`

---

### Task 2: On-disk file table

**Files:**
- Create: `Sources/DiskEngine/MappedAppendFile.swift`, `Sources/DiskEngine/FileTable.swift`
- Test: `Tests/DiskEngineTests/MappedAppendFileTests.swift`

**Interfaces:**
- Consumes: `FileRecord`, `FileIndex` (Task 1).
- Produces:
  - `final class MappedAppendFile`: `init(url: URL) throws` (creates/truncates), `func append(_ bytes: UnsafeRawBufferPointer) throws -> UInt64` (returns the byte offset written at), `func flush() throws`, `func withMappedBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R`. Writes go through a 1 MB in-memory buffer. Reads `mmap` the file `PROT_READ, MAP_PRIVATE`, remapping only when the file has grown since the last map.
  - `final class FileTable`: `init(directory: URL) throws` (creates `files.bin` and `filenames.bin` there), `func append(name: String, record: FileRecord) throws -> FileIndex` (fills `nameOffset` itself), `var count: Int`, `func record(_ i: FileIndex) throws -> FileRecord`, `func name(_ i: FileIndex) throws -> String`. Same name encoding as `NamePool`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func fileTableRoundTripsAfterFlush() throws {
    let dir = try Fixtures.tempDir()
    let t = try FileTable(directory: dir)
    var r = FileRecord(allocated: 5_000_000, parent: 7, nameOffset: 0, logicalKiB: 4_800, flags: [.mayShareBlocks], kind: 1)
    let i = try t.append(name: "Docker.raw", record: r)
    r.allocated = 2_000_000
    let j = try t.append(name: "big.mov", record: r)
    #expect(t.count == 2)
    #expect(try t.record(i).allocated == 5_000_000)
    #expect(try t.record(i).flags == [.mayShareBlocks])
    #expect(try t.name(j) == "big.mov")
}
@Test func readsSeeAppendsMadeAfterAnEarlierRead() throws {
    let t = try FileTable(directory: try Fixtures.tempDir())
    _ = try t.append(name: "a", record: .init(allocated: 1, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    _ = try t.record(0)
    let k = try t.append(name: "b", record: .init(allocated: 2, parent: 0, nameOffset: 0, logicalKiB: 0, flags: [], kind: 0))
    #expect(try t.record(k).allocated == 2)
    #expect(try t.name(k) == "b")
}
```

`Fixtures.tempDir()` creates a unique directory under `FileManager.default.temporaryDirectory` and returns it.

- [ ] **Step 2: Run** `swift test --filter MappedAppendFileTests`. Expected: fail, types not defined.
- [ ] **Step 3: Implement** `MappedAppendFile`, `FileTable`, and `Tests/DiskEngineTests/Fixtures.swift` with `tempDir()`. `record(_:)` and `name(_:)` flush pending writes before mapping.
- [ ] **Step 4: Run** `swift test --filter MappedAppendFileTests`. Expected: pass.
- [ ] **Step 5: Commit** `feat: add memory-mapped on-disk file table`

---

### Task 3: Bulk directory reader

**Files:**
- Create: `Sources/DiskEngine/BulkDirectoryReader.swift`
- Test: `Tests/DiskEngineTests/BulkDirectoryReaderTests.swift`; extend `Fixtures.swift`

**Interfaces:**
- Consumes: `FileFlags` (Task 1).
- Produces:
  - `public enum EntryKind: UInt8 { case file = 0, directory = 1, symlink = 2, other = 3 }`
  - `public struct RawEntry: Sendable { name: String; kind: EntryKind; allocated: UInt64; logical: UInt64; device: Int32; inode: UInt64; linkCount: UInt32; flags: FileFlags; isMountPoint: Bool }`
  - `public enum ListingOutcome: Sendable { case ok, unreadable, vanished }`
  - `public struct DirectoryListing: Sendable { folder: FolderID; outcome: ListingOutcome; entries: [RawEntry] }`
  - `struct BulkDirectoryReader { init(); mutating func list(path: String, folder: FolderID) -> DirectoryListing }`. Owns one 64 KB buffer reused across calls.

Approach: `open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`. `ENOENT`/`ENOTDIR` gives `.vanished`, `EACCES`/`EPERM` gives `.unreadable`. Then loop `getattrlistbulk` until it returns 0, with `FSOPT_PACK_INVAL_ATTRS` and these attributes:
- common: `ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS | ATTR_CMN_FILEID`, forcommon `ATTR_CMNEXT_EXT_FLAGS`
- dir: `ATTR_DIR_MOUNTSTATUS`
- file: `ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH`

Map `SF_DATALESS` to `.dataless`, `EF_MAY_SHARE_BLOCKS` to `.mayShareBlocks`, `DIR_MNTSTATUS_MNTPOINT` to `isMountPoint`, `VLNK` to `.symlink` kind. Parse in the kernel's fixed attribute order, honouring `returned_attrs` for missing fields. Directories report `allocated` 0.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func listsFilesDirsAndSizesMatchingFoundation() throws {
    let root = try Fixtures.tree(["a.bin": 2_000_000, "b.txt": 10, "sub/": 0])
    var r = BulkDirectoryReader()
    let l = r.list(path: root.path, folder: 0)
    #expect(l.outcome == .ok)
    let byName = Dictionary(uniqueKeysWithValues: l.entries.map { ($0.name, $0) })
    #expect(byName["sub"]?.kind == .directory)
    #expect(byName["a.bin"]?.allocated == Fixtures.allocatedSize(root.appending(path: "a.bin")))
    #expect(byName["a.bin"]?.logical == 2_000_000)
}
@Test func symlinkIsReportedNotFollowed() throws {
    let root = try Fixtures.tree(["d/": 0])
    try FileManager.default.createSymbolicLink(at: root.appending(path: "d/loop"), withDestinationURL: root)
    var r = BulkDirectoryReader()
    let l = r.list(path: root.appending(path: "d").path, folder: 1)
    #expect(l.entries.single?.kind == .symlink)
}
@Test func unicodeNamesSurvive() throws {
    let root = try Fixtures.tree(["Ünïcødé 写真 🗂.txt": 1])
    var r = BulkDirectoryReader()
    #expect(r.list(path: root.path, folder: 0).entries.first?.name == "Ünïcødé 写真 🗂.txt")
}
@Test func missingFolderIsVanishedNotError() {
    var r = BulkDirectoryReader()
    let l = r.list(path: "/nonexistent-\(UUID())", folder: 3)
    #expect(l.outcome == .vanished && l.entries.isEmpty)
}
@Test func lockedFolderIsUnreadable() throws {
    let root = try Fixtures.tree(["locked/x": 5])
    let locked = root.appending(path: "locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    var r = BulkDirectoryReader()
    #expect(r.list(path: locked.path, folder: 2).outcome == .unreadable)
}
```

`Fixtures.tree(_:)` takes relative paths mapped to byte sizes (trailing `/` means folder, parent folders created as needed) and returns the root URL. `Fixtures.allocatedSize(_:)` reads `URLResourceValues.totalFileAllocatedSize`. Add `extension Array { var single: Element? }` in Fixtures (nil unless exactly one element).

- [ ] **Step 2: Run** `swift test --filter BulkDirectoryReaderTests`. Expected: fail, not defined.
- [ ] **Step 3: Implement** `BulkDirectoryReader.swift` and the fixture helpers.
- [ ] **Step 4: Run** `swift test --filter BulkDirectoryReaderTests`. Expected: 5 pass.
- [ ] **Step 5: Commit** `feat: add getattrlistbulk directory reader`

---

### Task 4: Scan index and the collector logic

**Files:**
- Create: `Sources/DiskEngine/TopFiles.swift`, `Sources/DiskEngine/ScanIndex.swift`
- Test: `Tests/DiskEngineTests/ScanIndexTests.swift`

**Interfaces:**
- Consumes: Task 1 records and `NamePool`, Task 2 `FileTable`, Task 3 `DirectoryListing`/`RawEntry`.
- Produces:
  - `public struct TopFiles { init(capacity: Int = 1000); mutating func offer(_ file: FileIndex, allocated: UInt64); func sortedDescending() -> [(FileIndex, UInt64)] }`. Min-heap; when full, replace the smallest only if the new one is larger.
  - `public final class ScanIndex`:
    - `init(rootName: String, storage: URL) throws`. Creates folder 0 (the root, `parent == noFolder`).
    - `static let bigFileThreshold: UInt64 = 1_048_576`
    - `private(set) var folders: ContiguousArray<FolderRecord>`, `let files: FileTable`, `private(set) var top: TopFiles`
    - `func integrate(_ listing: DirectoryListing, rootDevice: Int32) throws -> [FolderID]`. Returns the new child folders that should be scanned.
    - `func path(of folder: FolderID, rootPath: String) -> String`
    - `func folderName(_ id: FolderID) -> String`
    - `public enum ChildKind { case folder(FolderID), file(FileIndex), smallFiles(count: UInt32) }`, `public struct Child { kind: ChildKind; name: String; allocated: UInt64 }`
    - `func children(of folder: FolderID) throws -> [Child]`. Folders, then big files, then one `.smallFiles` entry if `smallFileCount > 0` (name `"\(n) small files"`), sorted by `allocated` descending.

`integrate` rules, in order:
1. Set the folder's outcome flag (`.unreadable` / `.vanished`) and return `[]` if the outcome is not `.ok`.
2. Directories: skip if `!shouldDescend(entryDevice:rootDevice:isMountPoint:)`. Otherwise append a new `FolderRecord` and add the name to the folder name pool. All of one listing's subfolders are appended back to back, so set `firstChildFolder` and `childFolderCount` once.
3. Hard links: if `linkCount > 1`, keep a `Set<UInt64>` of inodes and skip any inode already seen. Mark the first one `.hardLinked`.
4. Files and symlinks: `allocated >= bigFileThreshold` gives a `FileTable.append` (also `top.offer`), contiguous per folder (`firstFile`, `bigFileCount`). Anything smaller adds to `smallFileCount` and `smallAllocated`.
5. Add the listing's direct bytes (big plus small) to `totalAllocated` of this folder **and every ancestor** up to the root.

`public func shouldDescend(entryDevice: Int32, rootDevice: Int32, isMountPoint: Bool) -> Bool` is a free function in this file: `entryDevice == rootDevice && !isMountPoint`.

- [ ] **Step 1: Write the failing tests** (build `DirectoryListing` values by hand; no disk scanning)

```swift
@Test func smallFilesFoldAndBigFilesAreStored() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("big.mov", allocated: 3_000_000), .file("a", allocated: 4096), .file("b", allocated: 4096)
    ]), rootDevice: 1)
    #expect(idx.folders[0].bigFileCount == 1)
    #expect(idx.folders[0].smallFileCount == 2)
    #expect(idx.folders[0].smallAllocated == 8192)
    #expect(idx.folders[0].totalAllocated == 3_008_192)
}
@Test func totalsPropagateToEveryAncestor() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    let l1 = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [.dir("a")]), rootDevice: 1)
    let l2 = try idx.integrate(.init(folder: l1[0], outcome: .ok, entries: [.dir("b")]), rootDevice: 1)
    _ = try idx.integrate(.init(folder: l2[0], outcome: .ok, entries: [.file("x", allocated: 5_000_000)]), rootDevice: 1)
    #expect(idx.folders[0].totalAllocated == 5_000_000)
    #expect(idx.folders[Int(l1[0])].totalAllocated == 5_000_000)
    #expect(idx.path(of: l2[0], rootPath: "/r") == "/r/a/b")
}
@Test func hardLinkCountedOnce() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("one", allocated: 2_000_000, inode: 42, links: 2), .file("two", allocated: 2_000_000, inode: 42, links: 2)
    ]), rootDevice: 1)
    #expect(idx.folders[0].totalAllocated == 2_000_000)
}
@Test func otherDeviceAndMountPointsAreNotDescended() {
    #expect(shouldDescend(entryDevice: 1, rootDevice: 1, isMountPoint: false))
    #expect(!shouldDescend(entryDevice: 2, rootDevice: 1, isMountPoint: false))
    #expect(!shouldDescend(entryDevice: 1, rootDevice: 1, isMountPoint: true))
}
@Test func unreadableFolderFlaggedAndZero() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    #expect(try idx.integrate(.init(folder: 0, outcome: .unreadable, entries: []), rootDevice: 1).isEmpty)
    #expect(idx.folders[0].flags.contains(.unreadable))
    #expect(idx.folders[0].totalAllocated == 0)
}
@Test func childrenSortedWithSmallFilesBucket() throws {
    let idx = try ScanIndex(rootName: "root", storage: try Fixtures.tempDir())
    _ = try idx.integrate(.init(folder: 0, outcome: .ok, entries: [
        .file("big.mov", allocated: 3_000_000), .file("a", allocated: 4096), .dir("d")
    ]), rootDevice: 1)
    let c = try idx.children(of: 0)
    #expect(c.map(\.name) == ["big.mov", "1 small files", "d"])
}
@Test func topFilesKeepsLargestOnly() {
    var t = TopFiles(capacity: 2)
    t.offer(0, allocated: 10); t.offer(1, allocated: 30); t.offer(2, allocated: 20)
    #expect(t.sortedDescending().map(\.0) == [1, 2])
}
```

Add `RawEntry.file(_:allocated:inode:links:)` and `RawEntry.dir(_:)` test helpers in `Fixtures.swift` (device 1, unique inode by default, link count 1).

- [ ] **Step 2: Run** `swift test --filter ScanIndexTests`. Expected: fail, not defined.
- [ ] **Step 3: Implement** `TopFiles.swift`, `ScanIndex.swift`.
- [ ] **Step 4: Run** `swift test --filter ScanIndexTests`. Expected: 7 pass.
- [ ] **Step 5: Commit** `feat: add scan index with folding, hard-link dedupe, live totals`

---

### Task 5: Concurrent scanner

**Files:**
- Create: `Sources/DiskEngine/Scanner.swift`
- Test: `Tests/DiskEngineTests/ScannerTests.swift`

**Interfaces:**
- Consumes: `BulkDirectoryReader` (Task 3), `ScanIndex` (Task 4).
- Produces:
  - `public struct ScanProgress: Sendable { foldersDone: Int; filesSeen: Int; bytesSeen: UInt64 }`
  - `public struct ScanResult { index: ScanIndex; elapsed: Duration; unreadableFolders: Int }`
  - `public final class Scanner: Sendable { init(root: URL, storage: URL, workers: Int = ProcessInfo.processInfo.activeProcessorCount); var progress: AsyncStream<ScanProgress> { get }; func run() async throws -> ScanResult }`

Approach: `run()` reads the root's device with `stat`, then drives a `withTaskGroup(of: DirectoryListing.self)` at `.utility` priority. It keeps at most `workers` listings in flight, pulling folder IDs from a FIFO `[FolderID]` queue. Each child task makes its own `BulkDirectoryReader` and lists `index.path(of:rootPath:)`. Paths are rebuilt from the folder table, so the queue holds only 4-byte IDs. Only the group's consuming loop calls `integrate`; no locks are needed. Yield a progress value at most every 100 ms. The progress stream finishes when `run()` returns. Cancellation stops issuing new folders and returns what is done.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func scansTreeAndTotalsMatchFoundation() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "a/s1": 100, "b/c/s2": 100, "b/c/big2.bin": 1_500_000])
    let r = try await Scanner(root: root, storage: try Fixtures.tempDir(), workers: 4).run()
    #expect(r.index.folders[0].totalAllocated == Fixtures.sumAllocated(under: root))
    #expect(r.index.files.count == 2)
    #expect(r.index.top.sortedDescending().count == 2)
}
@Test func symlinkLoopTerminates() async throws {
    let root = try Fixtures.tree(["d/f": 10])
    try FileManager.default.createSymbolicLink(at: root.appending(path: "d/up"), withDestinationURL: root)
    let r = try await Scanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.index.folders.count == 2)
}
@Test func unreadableSubfolderDoesNotStopScan() async throws {
    let root = try Fixtures.tree(["ok/f": 2_000_000, "locked/g": 10])
    let locked = root.appending(path: "locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let r = try await Scanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.unreadableFolders == 1)
    #expect(r.index.files.count == 1)
}
@Test func hardLinkedFileCountedOnceOnDisk() async throws {
    let root = try Fixtures.tree(["a/big.bin": 2_000_000, "b/": 0])
    try FileManager.default.linkItem(at: root.appending(path: "a/big.bin"), to: root.appending(path: "b/link.bin"))
    let r = try await Scanner(root: root, storage: try Fixtures.tempDir()).run()
    #expect(r.index.folders[0].totalAllocated == Fixtures.allocatedSize(root.appending(path: "a/big.bin")))
}
@Test func manyFoldersWithFewWorkers() async throws {
    var spec: [String: Int] = [:]
    for i in 0..<300 { spec["d\(i % 30)/e\(i)/f"] = 10 }
    let root = try Fixtures.tree(spec)
    let r = try await Scanner(root: root, storage: try Fixtures.tempDir(), workers: 2).run()
    #expect(r.index.folders.count == 1 + 30 + 300)
}
```

Add `Fixtures.sumAllocated(under:)`: walks with `FileManager.enumerator` (no symlink following), summing `totalFileAllocatedSize` once per inode.

- [ ] **Step 2: Run** `swift test --filter ScannerTests`. Expected: fail, not defined.
- [ ] **Step 3: Implement** `Scanner.swift` and the fixture helper.
- [ ] **Step 4: Run** `swift test`. Expected: every test in the package passes.
- [ ] **Step 5: Commit** `feat: add concurrent scanner with bounded workers and progress`

---

### Task 6: Volume space and the `diskscan` tool

**Files:**
- Create: `Sources/DiskEngine/VolumeSpace.swift`; replace `Sources/diskscan/main.swift`
- Test: `Tests/DiskEngineTests/VolumeSpaceTests.swift`

**Interfaces:**
- Consumes: `Scanner`, `ScanResult` (Task 5).
- Produces:
  - `public struct VolumeSpace: Sendable { total: UInt64; available: UInt64; availableForImportantUsage: UInt64; var reclaimable: UInt64 { availableForImportantUsage &- available clamped at 0 }; static func read(_ url: URL) throws -> VolumeSpace }` using `URLResourceValues` `volumeTotalCapacity`, `volumeAvailableCapacity`, `volumeAvailableCapacityForImportantUsage`.
  - `diskscan <path> [--top N]` prints, in this order: path, elapsed seconds, folders, stored files, small files, total allocated (GB, 1 decimal), unreadable folders, **peak resident memory (MB)** from `getrusage(RUSAGE_SELF).ru_maxrss` (bytes on macOS), volume total/free/reclaimable, then the N largest folders directly under the root and the N largest files (default 10). Index storage goes in a fresh temp directory that is deleted on exit.

- [ ] **Step 1: Write the failing test**

```swift
@Test func volumeSpaceIsSane() throws {
    let v = try VolumeSpace.read(FileManager.default.temporaryDirectory)
    #expect(v.total > 0)
    #expect(v.available <= v.total)
    #expect(v.availableForImportantUsage >= v.available || v.reclaimable == 0)
}
```

- [ ] **Step 2: Run** `swift test --filter VolumeSpaceTests`. Expected: fail, not defined.
- [ ] **Step 3: Implement** `VolumeSpace.swift` and `main.swift` (argument parsing by hand; no dependencies).
- [ ] **Step 4: Run** `swift test`. Expected: all pass.
- [ ] **Step 5: Measure on a real tree**

Run: `swift build -c release && .build/release/diskscan ~`
Expected: it finishes without the system slowing down, and prints a peak resident memory **under 150 MB**. Then, with Full Disk Access granted to the terminal, run `.build/release/diskscan /System/Volumes/Data`. Expected: finishes within **30 to 90 s** on an internal SSD, with peak memory under 150 MB. Paste both outputs into the commit message body. If either target is missed, stop and report the numbers instead of tuning blindly.

- [ ] **Step 6: Commit** `feat: add volume space reader and diskscan CLI` (with the measured numbers in the body)
