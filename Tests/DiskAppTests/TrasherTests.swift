import Foundation
import Testing
import DiskEngine
@testable import DiskApp

func trash(_ items: [BasketItem], in root: URL, protected: [LensHit] = []) async throws -> (TrashOutcome, URL) {
    let bin = try Fixtures.tempDir()
    return (await Trasher.moveToTrash(items, root: Fixtures.realPath(root), protected: protected, rules: .bundled,
                                      backend: FixtureTrash(bin: bin)), bin)
}

@MainActor @Test func movesItemsOffMainAndReportsFreed() async throws {
    let root = try Fixtures.tree(["a/big.bin": 3_000_000, "b/keep.bin": 2_000_000])
    let (out, bin) = try await trash([item("a/big.bin", 2_500_000_000)], in: root)
    #expect(out.moved == ["a/big.bin"] && out.failures.isEmpty && out.freed == 2_500_000_000)
    #expect(out.title == "Freed 2.5 GB" && out.detail == "It stays in the Trash until you empty it." && out.failureHeader == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "a/big.bin").path))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "b/keep.bin").path))
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

@Test func pathsThatLeaveTheItemAreRefused() async throws {
    let root = try Fixtures.tree(["a/x.bin": 1_000, "y.bin": 1_000])
    let (out, _) = try await trash([item("a/..", 1, folder: true), item("a/./x.bin", 1), item("/y.bin", 1), item("", 1, folder: true),
                                    item("a//x.bin", 1)], in: root)
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == Array(repeating: .outsideDrive, count: 5))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "a/x.bin").path))
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "y.bin").path))
}

@Test func appManagedItemsAreNeverTrashed() async throws {
    let root = try Fixtures.tree(["Docker.raw": 2_000_000])
    let (out, _) = try await trash([item("Docker.raw", 2, safety: .appManaged)], in: root)
    #expect(out.moved.isEmpty && out.failures.isEmpty && out.title == "Nothing moved to the Trash")
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Docker.raw").path))
}

@Test func folderContainingAppManagedItemIsRefused() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 2_000_000, "Users/u/other.bin": 1_000])
    let (out, _) = try await trash([item("Users/u/Library/Containers", 2, folder: true),
                                    item("Users/u/Library/Containers/com.docker.docker/Data", 1, folder: true)],
                                   in: root, protected: [dockerHit])
    #expect(out.moved.isEmpty)
    #expect(out.failures == [.init(path: "Users/u/Library/Containers", name: "Containers", reason: .failed("Contains an item managed by another app."))])
    #expect(out.failureLines == ["Containers: Contains an item managed by another app."])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw").path))
}

@Test func rulesRefuseAppManagedEvenWithoutAProtectedList() async throws {
    let root = try Fixtures.tree(["Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 2_000_000])
    let byID = BasketItem(path: "Users/u/Library/Containers/com.docker.docker", name: "com.docker.docker", size: 2, kind: .virtualMachines,
                          isFolder: true, ruleID: "docker", safety: nil)
    let (out, _) = try await trash([item("Users/u/Library/Containers", 2, folder: true), byID,
                                    item("Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", 1)], in: root, protected: [])
    #expect(out.moved.isEmpty)
    #expect(out.failures == [.init(path: "Users/u/Library/Containers", name: "Containers", reason: .failed("Contains an item managed by another app."))])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw").path))
}

@Test func structuralFoldersAreRefused() async throws {
    let root = try Fixtures.tree(["Users/u/Desktop/a": 10, "Users/u/Library/b": 10, "Users/u/.Trash/c": 10, "Applications/d": 10,
                                  ".fseventsd/e": 10, "private/f": 10, "Users/u/Documents/keep.txt": 10])
    let structural = ["Users/u", "users/U/desktop", "Users/u/Library", "Applications", ".fseventsd", "private", "Users"]
    let (out, _) = try await trash(structural.map { item($0, 1, folder: true) } + [item("Users/u/Documents/keep.txt", 1)], in: root)
    #expect(out.moved == ["Users/u/Documents/keep.txt"])
    #expect(out.failures.map(\.path) == structural)
    #expect(out.failures.allSatisfy { $0.reason == .failed("This is a system or account folder; remove things inside it instead.") })
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Desktop/a").path))
    // Users/u/.Trash is app-managed (the trash rule), so it is skipped silently rather than failed.
    let (trashOut, _) = try await trash([item("Users/u/.Trash", 1, folder: true)], in: root)
    #expect(trashOut.moved.isEmpty && trashOut.failures.isEmpty)
}

@Test func anItemOnAnotherDeviceIsOutsideTheDrive() throws {
    let root = try Fixtures.tree(["nested/x.bin": 1_000, "y.bin": 1_000])
    let rootPath = Fixtures.realPath(root)
    let out = Trasher.move([item("nested/x.bin", 1), item("y.bin", 2)], root: rootPath, protected: [], rules: .bundled,
                           expectedDevice: nil, backend: FixtureTrash(bin: try Fixtures.tempDir())) { path in
        guard case .ok(var st) = Trasher.realStat(path) else { return Trasher.realStat(path) }
        if path.hasSuffix("/nested/x.bin") { st.st_dev &+= 1 }
        return .ok(st)
    }
    #expect(out.moved == ["y.bin"] && out.failures.map(\.reason) == [.outsideDrive])
    #expect(FileManager.default.fileExists(atPath: rootPath + "/nested/x.bin"))
}

@Test func aRootThatChangesDeviceFailsTheRestAsDriveGone() throws {
    let root = try Fixtures.tree(["a.bin": 1_000, "b.bin": 1_000, "c.bin": 1_000])
    let rootPath = Fixtures.realPath(root)
    nonisolated(unsafe) var rootStats = 0
    let out = Trasher.move([item("a.bin", 1), item("b.bin", 2), item("c.bin", 3)], root: rootPath, protected: [], rules: .bundled,
                           expectedDevice: nil, backend: FixtureTrash(bin: try Fixtures.tempDir())) { path in
        guard path == rootPath, case .ok(var st) = Trasher.realStat(path) else { return Trasher.realStat(path) }
        rootStats += 1
        if rootStats > 2 { st.st_dev &+= 1 }   // once up front, once before a.bin; then it changes
        return .ok(st)
    }
    #expect(out.moved == ["a.bin"] && out.freed == 1)
    #expect(out.failures == [.init(path: "b.bin", name: "b.bin", reason: .driveGone), .init(path: "c.bin", name: "c.bin", reason: .driveGone)])
    #expect(out.cleared == ["a.bin"])
}

struct RootRemovingTrash: TrashBackend {
    let inner: FixtureTrash
    let root: String
    func trash(_ url: URL) throws {
        try inner.trash(url)
        RunRoot.removeTree(atPath: root)
    }
}

@Test func aRootThatVanishesMidRunIsNotReportedAsAlreadyGone() async throws {
    let root = try Fixtures.tree(["a.bin": 1_000, "b.bin": 1_000])
    let rootPath = Fixtures.realPath(root)
    let out = await Trasher.moveToTrash([item("a.bin", 1), item("b.bin", 2)], root: rootPath, protected: [], rules: .bundled,
                                        backend: RootRemovingTrash(inner: FixtureTrash(bin: try Fixtures.tempDir()), root: rootPath))
    #expect(out.moved == ["a.bin"] && out.failures.map(\.reason) == [.driveGone] && out.cleared == ["a.bin"])
}

@Test func anUnexpectedRootDeviceMovesNothing() async throws {
    let root = try Fixtures.tree(["a.bin": 1_000])
    let rootPath = Fixtures.realPath(root)
    guard case .ok(let st) = Trasher.realStat(rootPath) else { Issue.record("no root"); return }
    let out = await Trasher.moveToTrash([item("a.bin", 1)], root: rootPath, protected: [], rules: .bundled, expectedDevice: st.st_dev &+ 1,
                                        backend: FixtureTrash(bin: try Fixtures.tempDir()))
    #expect(out.moved.isEmpty && out.failures.map(\.reason) == [.driveGone])
    #expect(FileManager.default.fileExists(atPath: rootPath + "/a.bin"))
}

@Test func nestedItemsInOneRequestAreCountedOnce() async throws {
    let root = try Fixtures.tree(["a/b.bin": 1_000, "a/c/d.bin": 1_000])
    let (out, bin) = try await trash([item("a/b.bin", 1), item("a/c/d.bin", 2), item("a", 10, folder: true), item("a/c", 3, folder: true),
                                      item("a", 10, folder: true)], in: root)
    #expect(out.moved == ["a/b.bin", "a/c/d.bin", "a", "a/c"] && out.freed == 10 && out.failures.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).count == 1)
}

@Test func outcomeWordingAndDriveGone() {
    let gone = TrashOutcome.driveGone([item("a.bin", 5), item("b", 6, safety: .appManaged), item("Users/u/Library/Containers", 7, folder: true),
                                       item("Users/u/Library", 8, folder: true), item("x/dockerish", 9, folder: true)],
                                      protected: [LensHit(ruleID: "docker", path: "x/dockerish/inner", name: "inner", size: 1, isFolder: true, safety: .appManaged)])
    #expect(gone.moved.isEmpty && gone.freed == 0 && gone.cleared.isEmpty && gone.detail == nil)
    #expect(gone.failureHeader == "1 item wasn't moved." && gone.failureLines == ["a.bin: the drive was disconnected."])
    let mixed = TrashOutcome(moved: ["x"], failures: [.init(path: "o", name: "o", reason: .outsideDrive)], freed: 12_000_000_000)
    #expect(mixed.title == "Freed 12 GB" && mixed.failureLines == ["o: no longer on this drive."])
}
