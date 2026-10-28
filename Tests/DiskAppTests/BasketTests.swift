import Foundation
import Testing
import DiskEngine
@testable import DiskApp

func item(_ path: String, _ size: UInt64, folder: Bool = false, safety: LensSafety? = nil) -> BasketItem {
    BasketItem(path: path, name: String(path.split(separator: "/").last ?? ""), size: size, kind: .other, isFolder: folder, ruleID: nil, safety: safety)
}

let dockerHit = LensHit(ruleID: "docker", path: "Users/u/Library/Containers/com.docker.docker", name: "com.docker.docker",
                        size: 59_000_000_000, isFolder: true, safety: .appManaged)

@MainActor @Test func nestedItemsCollapseIntoTheirFolder() {
    let b = Basket()
    #expect(b.add(item("a/b/c.bin", 2_000_000_000)))
    #expect(b.add(item("a/b", 5_000_000_000, folder: true)))
    #expect(!b.add(item("a/b/d.bin", 1_000_000_000)))
    #expect(!b.add(item("a/b", 5_000_000_000, folder: true)))
    #expect(!b.add(item("", 9, folder: true)) && !b.add(item("a#small", 9)) && !b.add(item("a/b#more", 9)))
    #expect(b.add(item("a/bc", 1_000_000_000, folder: true)))
    #expect(b.items.map(\.path) == ["a/b", "a/bc"] && b.total == 6_000_000_000)
    #expect(b.add(item("src/C#/x.cs", 1)) && b.add(item("Issue #4.txt", 1)))
}

@MainActor @Test func chipsShowSixThenACount() {
    let b = Basket()
    for i in 0..<8 { b.add(item("f\(i)", 1)) }
    #expect(b.chips.count == 6 && b.moreCount == 2)
    b.remove(paths: ["f0", "f1"]); #expect(b.moreCount == 0)
    b.add(contentsOf: [item("g", 1), item("g", 1)]); #expect(b.items.count == 7)
    b.clear(); #expect(b.items.isEmpty && b.total == 0)
}

@MainActor @Test func basketStoreKeepsOneBasketPerDrive() {
    let store = BasketStore()
    let t7 = store.basket(for: "T7")
    t7.add(item("a", 1))
    #expect(store.basket(for: "T7") === t7 && store.basket(for: "I").items.isEmpty)
    store.drop("T7")
    #expect(t7.items.isEmpty && store.basket(for: "T7") !== t7)
}

@Test func basketItemsFromNodesAndHits() {
    let docker = MapNode(key: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", kind: .virtualMachines, growth: 0, isFolder: false)
    #expect(BasketItem.from(node: docker, size: 59_000_000_000)?.safety == .appManaged)
    #expect(BasketItem.from(node: MapNode(key: "a#small", name: "3 small files", kind: nil, growth: 0, isFolder: false), size: 9) == nil)
    #expect(BasketItem.from(node: MapNode(key: "", name: "Macintosh HD", kind: .other, growth: 0, isFolder: true), size: 9) == nil)
    let hit = LensHit(ruleID: "node-modules", path: "Users/u/web/node_modules", name: "node_modules", size: 2_700_000, isFolder: true, safety: .regenerates)
    #expect(BasketItem.from(hit: hit) == BasketItem(path: "Users/u/web/node_modules", name: "node_modules", size: 2_700_000,
                                                    kind: .developer, isFolder: true, ruleID: "node-modules", safety: .regenerates))
}

@Test func aParentOfAContentsRuleIsNotAKnownItem() {
    let caches = MapNode(key: "Users/u/Library/Caches", name: "Caches", kind: .caches, growth: 0, isFolder: true)
    let yarn = MapNode(key: "Users/u/Library/Caches/Yarn", name: "Yarn", kind: .caches, growth: 0, isFolder: true)
    #expect(BasketItem.from(node: caches, size: 1)?.safety == nil && BasketItem.from(node: caches, size: 1)?.ruleID == nil)
    #expect(BasketItem.from(node: yarn, size: 1)?.safety == .regenerates && BasketItem.from(node: yarn, size: 1)?.ruleID == "yarn-cache")
}

@Test func reviewRowsShowCheckboxesExceptForAppManaged() {
    let items = [
        BasketItem(path: "Users/u/Library/Developer/Xcode/DerivedData", name: "DerivedData", size: 6_200_000_000, kind: .developer, isFolder: true, ruleID: "xcode-derived-data", safety: .regenerates),
        BasketItem(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", size: 59_000_000_000, kind: .virtualMachines, isFolder: false, ruleID: "docker", safety: .appManaged),
        BasketItem(path: "Users/u/Movies/old.mov", name: "old.mov", size: 2_000_000_000, kind: .media, isFolder: false, ruleID: nil, safety: nil),
        BasketItem(path: "Users/u/Downloads/Setup.dmg", name: "Setup.dmg", size: 300_000_000, kind: .other, isFolder: false, ruleID: "old-installers", safety: .review),
        BasketItem(path: "notes.txt", name: "notes.txt", size: 1, kind: .other, isFolder: false, ruleID: nil, safety: nil),
    ]
    let s = ReviewSheet.make(items: items, unchecked: ["Users/u/Movies/old.mov", "Users/u/Downloads/Setup.dmg", "notes.txt"],
                             protected: [], driveName: "Macintosh HD", driveConnected: true)
    #expect(s.rows.map(\.isCheckable) == [true, false, true, true, true] && s.rows.map(\.isChecked) == [true, false, false, false, false])
    #expect(s.rows[0].explanation == "Xcode build products. Safe to clear. Rebuilds itself." && s.rows[0].location == "Users/u/Library/Developer/Xcode")
    #expect(s.rows[0].size == "6.2 GB" && s.rows[0].instruction == nil)
    #expect(s.rows[1].instruction == "Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(s.rows[2].explanation == "Not a known item. Make sure you don't need it.")
    #expect(s.rows[3].explanation == "An installer you downloaded over a month ago. Once the app is installed, you don't need it.")
    #expect(s.rows[4].location == "Drive root")
    #expect(s.buttonTitle == "Move 1 item to Trash" && s.canTrash && s.selectedTotal == 6_200_000_000 && s.selectedLabel == "6.2 GB selected")
    #expect(s.notice == nil)
    #expect(ReviewSheet.trashable(items, unchecked: [], protected: []).map(\.name) == ["DerivedData", "old.mov", "Setup.dmg", "notes.txt"])
    #expect(ReviewSheet.make(items: items, unchecked: [], protected: [], driveName: "M", driveConnected: true).buttonTitle == "Move 4 items to Trash")
}

@Test func disconnectedDriveCannotTrash() {
    let s = ReviewSheet.make(items: [item("a.bin", 5)], unchecked: [], protected: [], driveName: "Samsung T7", driveConnected: false)
    #expect(!s.canTrash && s.notice == "Samsung T7 is disconnected. Plug it back in to move these items.")
    #expect(ReviewSheet.make(items: [item("a.bin", 5)], unchecked: ["a.bin"], protected: [], driveName: "T7", driveConnected: true).buttonTitle == "Move to Trash")
}

@Test func folderContainingAppManagedItemIsRefusedInReview() {
    let items = [item("Users", 80_000_000_000, folder: true), item("Users/u/Library/Containers/com.docker.docker", 59_000_000_000, folder: true),
                 item("Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", 1), item("Users/u/Library/Containers/com.dockerx", 1, folder: true)]
    let s = ReviewSheet.make(items: items, unchecked: [], protected: [dockerHit], driveName: "Macintosh HD", driveConnected: true)
    #expect(s.rows.map(\.isCheckable) == [false, false, false, true])
    #expect(s.rows[0].instruction == "This is a system or account folder; remove things inside it instead.")
    #expect(s.rows[1].instruction == "Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(ReviewSheet.trashable(items, unchecked: [], protected: [dockerHit]).map(\.path) == ["Users/u/Library/Containers/com.dockerx"])
    #expect(s.buttonTitle == "Move 1 item to Trash")
}

@Test func trashPathUsesTheUserPathOnTheDataVolume() {
    #expect(TrashPath.userPath(root: "/System/Volumes/Data", relative: "Users/u/x.bin") == "/Users/u/x.bin")
    #expect(TrashPath.userPath(root: "/System/Volumes/Data/", relative: "Users/u/x.bin") == "/Users/u/x.bin")
    #expect(TrashPath.userPath(root: "/Volumes/T7", relative: "a/b.bin") == "/Volumes/T7/a/b.bin")
    #expect(TrashPath.physicalPath(root: "/System/Volumes/Data", relative: "Users/u/x.bin") == "/System/Volumes/Data/Users/u/x.bin")
}

@Test func reviewRefusesAppManagedHoldersEvenWithoutAProtectedList() {
    let items = [item("Users/u/Library/Containers", 9, folder: true), item("x/holder", 9, folder: true),
                 BasketItem(path: "Users/u/Library/Containers/com.docker.docker", name: "com.docker.docker", size: 1, kind: .virtualMachines,
                            isFolder: true, ruleID: "docker", safety: nil),
                 item("Users/u/Library/Caches", 4, folder: true)]
    let s = ReviewSheet.make(items: items, unchecked: [], protected: [
        LensHit(ruleID: "photos-library", path: "x/holder/P.photoslibrary", name: "P.photoslibrary", size: 1, isFolder: true, safety: .appManaged)],
        driveName: "Macintosh HD", driveConnected: true)
    #expect(s.rows.map(\.isCheckable) == [false, false, false, true])
    #expect(s.rows[0].instruction == "May contain Docker. Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(s.rows[1].instruction == "Contains Photos library. Shrink it from inside Photos, not here.")
    #expect(s.rows[2].instruction == "Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(s.selectedTotal == 4 && s.buttonTitle == "Move 1 item to Trash")
}

@Test func structuralFoldersHaveNoCheckbox() {
    let paths = ["", "Users", "Users/u", "Users/u/Library", "USERS/u/Pictures", "Users/u/.Trash", "Users/u/Applications", "Volumes",
                 "System", "Library", ".Trashes", ".Spotlight-V100", ".DocumentRevisions-V100",
                 "Users/u/Library/Mobile Documents", "Backups.backupdb", "opt", ".TemporaryItems", "MobileSoftwareUpdate"]
    let s = ReviewSheet.make(items: paths.map { item($0, 1, folder: true) } + [item("Users/u/Movies/clip.mov", 2)], unchecked: [],
                             protected: [], driveName: "Macintosh HD", driveConnected: true)
    #expect(s.rows.map(\.isCheckable) == Array(repeating: false, count: paths.count) + [true])
    #expect(s.rows[1].instruction == "This is a system or account folder; remove things inside it instead.")
    #expect(s.rows[4].instruction == "This is a system or account folder; remove things inside it instead.")
    #expect(s.selectedTotal == 2)
}

@Test func dragStartsAfterFourPointsAndDropsOnTheBar() {
    var d = BasketDrag(at: CGPoint(x: 100, y: 100), item: 3)
    d.move(to: CGPoint(x: 103, y: 100)); #expect(!d.isActive)
    d.move(to: CGPoint(x: 104, y: 101)); #expect(d.isActive)
    d.move(to: CGPoint(x: 100, y: 100)); #expect(d.isActive)
    #expect(d.dropsOnBasket(CGRect(x: 90, y: 90, width: 30, height: 30)) && !d.dropsOnBasket(CGRect(x: 0, y: 0, width: 50, height: 50)))
    var tap = BasketDrag(at: .zero, item: 1); tap.move(to: CGPoint(x: 2, y: 2))
    #expect(!tap.dropsOnBasket(CGRect(x: -10, y: -10, width: 20, height: 20)))
}

@MainActor @Test func acceptsWhatAddWouldTake() {
    let b = Basket()
    b.add(item("a", 1, folder: true))
    #expect(!b.accepts(item("a", 1)) && !b.accepts(item("a/b", 1)) && !b.accepts(item("", 1)) && !b.accepts(item("x#small", 1)))
    #expect(b.accepts(item("c", 1)) && b.accepts(item("ab", 1)))
}

private func level(_ nodes: [MapNode], sizes: [UInt64]) -> MapSnapshot {
    let rects = sizes.map { TreemapRect(ref: .folder(1), size: $0, frame: .zero, depth: 1, parent: -1) }
    return MapSnapshot(path: "", rootPath: "/", crumbs: [], total: 0, period: 7,
                       layout: TreemapLayout(rects: rects, bounds: .zero, topLevelCount: rects.count), nodes: nodes, list: [])
}

@Test func dropAfterARebuildAddsThePressedItemOrNothing() {
    let a = MapNode(key: "Users/u/a", name: "a", kind: .other, growth: 0, isFolder: true)
    let b = MapNode(key: "Users/u/b", name: "b", kind: .media, growth: 0, isFolder: false)
    let small = MapNode(key: "Users/u#small", name: "Small files", kind: nil, growth: 0, isFolder: false)
    let before = level([a, b], sizes: [9, 5])
    var d = BasketDrag(at: .zero, item: 0, key: before.nodes[0].key)
    d.move(to: CGPoint(x: 10, y: 0))
    // Rebuilt during the drag: rect 0 is now b, and a moved to rect 1 with a new size.
    let reordered = level([b, a], sizes: [12, 9])
    #expect(reordered.basketItem(droppedKey: d.key!)?.path == "Users/u/a")
    #expect(reordered.basketItem(droppedKey: d.key!)?.size == 9)
    // Gone from this level (folded into the small-files bucket): nothing is added.
    #expect(level([b, small], sizes: [12, 1]).basketItem(droppedKey: d.key!) == nil)
    #expect(level([b, small], sizes: [12, 1]).basketItem(droppedKey: "Users/u#small") == nil)
    #expect(level([b, small], sizes: [12, 1]).basketItem(at: 1) == nil)
}
