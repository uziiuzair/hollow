import Foundation
import Testing
import DiskEngine
@testable import DiskApp

func trash(_ items: [BasketItem], in root: URL, protected: [LensHit] = []) async throws -> (TrashOutcome, URL) {
    let bin = try Fixtures.tempDir()
    return (await Trasher.moveToTrash(items, root: Fixtures.realPath(root), protected: protected, backend: FixtureTrash(bin: bin)), bin)
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
    let (out, _) = try await trash([item("Users", 2, folder: true), item("Users/u/Library/Containers/com.docker.docker/Data", 1, folder: true)],
                                   in: root, protected: [dockerHit])
    #expect(out.moved.isEmpty)
    #expect(out.failures == [.init(path: "Users", name: "Users", reason: .failed("Contains an item managed by another app."))])
    #expect(out.failureLines == ["Users: Contains an item managed by another app."])
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw").path))
}

@Test func outcomeWordingAndDriveGone() {
    let gone = TrashOutcome.driveGone([item("a.bin", 5), item("b", 6, safety: .appManaged)])
    #expect(gone.moved.isEmpty && gone.freed == 0 && gone.cleared.isEmpty && gone.detail == nil)
    #expect(gone.failureHeader == "1 item wasn't moved." && gone.failureLines == ["a.bin: the drive was disconnected."])
    let mixed = TrashOutcome(moved: ["x"], failures: [.init(path: "o", name: "o", reason: .outsideDrive)], freed: 12_000_000_000)
    #expect(mixed.title == "Freed 12 GB" && mixed.failureLines == ["o: no longer on this drive."])
}
