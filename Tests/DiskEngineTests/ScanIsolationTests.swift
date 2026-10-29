// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Dispatch
import Foundation
import Testing
@testable import DiskEngine

/// An actor on its own serial queue, so code can tell whether it runs on the actor.
private actor QueueActor {
    static let key = DispatchSpecificKey<Bool>()
    let queue = DispatchSerialQueue(label: "ScanIsolationTests.QueueActor")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init() { queue.setSpecific(key: Self.key, value: true) }

    /// Scans `root` from the actor; for each listing the scan takes in, whether that ran on the actor.
    func scan(_ root: URL, storage: URL) async throws -> [Bool] {
        let index = try ScanIndex(rootName: root.lastPathComponent, storage: storage)
        index.rootPath = Fixtures.realPath(root)
        var info = stat()
        #expect(lstat(index.rootPath, &info) == 0)
        index.rootDevice = info.st_dev
        var onActor: [Bool] = []
        _ = try await DiskScanner(root: root, storage: storage)
            .scan(into: index, starting: [0], checkpointEvery: .zero) { _ in
                onActor.append(DispatchQueue.getSpecific(key: Self.key) == true)
                return .proceed
            }
        return onActor
    }
}

/// The scanner writes the index from its collector loop. Called from an actor (a `LiveIndex`), that loop must run on
/// the actor, or it writes the index at the same time as the actor's own code reads it: a data race that showed up as
/// "Index out of range" in `ScanIndex.child(named:of:)` and a release of a freed array in `PagedArray`.
@Test func aScanFromAnActorTakesItsListingsOnTheActor() async throws {
    let root = try Fixtures.tree(["a/f": 10, "a/b/g": 10, "c/h": 10, "c/d/e/i": 10])
    let onActor = try await QueueActor().scan(root, storage: try Fixtures.tempDir())
    #expect(onActor.count == 6)
    #expect(onActor.allSatisfy { $0 }, "on the actor: \(onActor)")
}
