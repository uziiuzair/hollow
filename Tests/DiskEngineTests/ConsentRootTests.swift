import Foundation
import os
import Testing
@testable import DiskEngine

/// Final review I2: a privacy prompt nobody answers blocks open() under its folder. Each such folder (a consent root) has
/// at most one listing thread waiting in open(), so a prompt costs one thread, never the pool.

/// Opens under `prefix` hang until released; records each open.
private final class PromptHang: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (prefix: String?.none, opened: [String]()))
    private let gate = DispatchSemaphore(value: 0)
    init(under prefix: String) { state.withLock { $0.prefix = prefix } }
    func release() {
        state.withLock { $0.prefix = nil }
        gate.signal()
    }
    var opened: [String] { state.withLock { $0.opened } }
    func read(_ path: String, _ folder: FolderID, _ progress: @escaping @Sendable () -> Void) -> DirectoryListing {
        let blocked = state.withLock { s in
            s.opened.append(path)
            return s.prefix.map { path == $0 || path.hasPrefix($0 + "/") } == true
        }
        if blocked {
            gate.wait()
            gate.signal()
        }
        progress()
        return DirectoryListing(folder: folder, outcome: .ok, entries: [])
    }
}

private func name(_ outcome: DirectoryLister.Outcome) -> String {
    switch outcome {
    case .listed: "listed"
    case .timedOut: "timedOut"
    case .skipped: "skipped"
    }
}

@Test func aPromptUnderOneConsentRootTakesOneThread() async throws {
    let hang = PromptHang(under: "/fake/home/Documents")
    defer { hang.release() }
    let folders = DirectoryLister(timeout: .milliseconds(300), startTimeout: .seconds(5),
                                  consentRoot: { path in
                                      for root in ["/fake/home/Documents", "/fake/home/Desktop"]
                                      where path == root || path.hasPrefix(root + "/") { return root }
                                      return nil
                                  },
                                  read: { hang.read($0, $1, $2) })
    // Eight siblings under the prompting folder at once: one thread waits in open(), the rest never take one.
    let outcomes = await withTaskGroup(of: String.self) { group in
        for i in 0..<8 { group.addTask { name(await folders.list(path: "/fake/home/Documents/p\(i)", folder: 0)) } }
        return await group.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(hang.opened.filter { $0.hasPrefix("/fake/home/Documents/") }.count == 1)
    #expect(outcomes.filter { $0 == "timedOut" }.count == 1)
    #expect(outcomes.filter { $0 == "skipped" }.count == 7)
    #expect(folders.abandonedCount == 1)
    // While it is hung, more requests under it fail at once and take no thread.
    let started = ContinuousClock.now
    #expect(name(await folders.list(path: "/fake/home/Documents/later", folder: 0)) == "skipped")
    #expect(ContinuousClock.now - started < .milliseconds(100))
    #expect(hang.opened.filter { $0.hasPrefix("/fake/home/Documents/") }.count == 1)
    // Other consent roots and ordinary folders still list.
    #expect(name(await folders.list(path: "/fake/home/Desktop/x", folder: 0)) == "listed")
    let others = await withTaskGroup(of: String.self) { group in
        for i in 0..<12 { group.addTask { name(await folders.list(path: "/elsewhere/\(i)", folder: 0)) } }
        return await group.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(others == Array(repeating: "listed", count: 12))
    // Answered: the thread comes back and the folder lists again.
    hang.release()
    for _ in 0..<100 where folders.abandonedCount > 0 { try await Task.sleep(for: .milliseconds(20)) }
    #expect(name(await folders.list(path: "/fake/home/Documents/p0", folder: 0)) == "listed")
}

// Opens under one consent root wait for each other, but a busy root is not a hung one: nothing is skipped.
@Test func opensUnderAConsentRootTakeTurnsWithoutSkipping() async throws {
    let open = OSAllocatedUnfairLock(initialState: (now: 0, most: 0))
    let folders = DirectoryLister(consentRoot: { $0.hasPrefix("/r/") ? "/r" : nil }, read: { _, folder, progress in
        open.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        usleep(20_000)
        open.withLock { $0.now -= 1 }
        progress()
        return DirectoryListing(folder: folder, outcome: .ok, entries: [])
    })
    let outcomes = await withTaskGroup(of: String.self) { group in
        for i in 0..<10 { group.addTask { name(await folders.list(path: "/r/\(i)", folder: 0)) } }
        return await group.reduce(into: [String]()) { $0.append($1) }
    }
    #expect(outcomes == Array(repeating: "listed", count: 10))
    #expect(open.withLock { $0.most } == 1)
}

@Test func consentRootsAreTheFoldersMacOSPromptsFor() {
    let roots = ConsentRoots(home: "/Users/u")
    #expect(roots.root(of: "/Users/u/Documents") == "/Users/u/Documents")
    #expect(roots.root(of: "/Users/u/Documents/a/b") == "/Users/u/Documents")
    #expect(roots.root(of: "/System/Volumes/Data/Users/u/Downloads/x") == "/System/Volumes/Data/Users/u/Downloads")
    #expect(roots.root(of: "/Users/u/Desktop/x") == "/Users/u/Desktop")
    #expect(roots.root(of: "/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a") == "/Users/u/Library/Mobile Documents")
    #expect(roots.root(of: "/Users/u/Library/CloudStorage/Dropbox/a") == "/Users/u/Library/CloudStorage/Dropbox")
    #expect(roots.root(of: "/Users/u/Library/CloudStorage") == nil)
    #expect(roots.root(of: "/Users/u/Library/Mail/V10") == "/Users/u/Library/Mail")
    #expect(roots.root(of: "/Users/u/Library/Containers/com.other/Data") == "/Users/u/Library/Containers/com.other")
    #expect(roots.root(of: "/Users/u/Library/Containers") == nil)
    #expect(roots.root(of: "/Users/u/Pictures/Photos Library.photoslibrary/x") == "/Users/u/Pictures/Photos Library.photoslibrary")
    #expect(roots.root(of: "/Volumes/T7/a/b") == "/Volumes/T7")
    #expect(roots.root(of: "/Volumes") == nil)
    #expect(roots.root(of: "/Users/u/code/x") == nil)
    #expect(roots.root(of: "/Users/u") == nil)
    #expect(roots.root(of: "/Library/Caches") == nil)
}
