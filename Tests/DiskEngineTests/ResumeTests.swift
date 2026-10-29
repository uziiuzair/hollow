// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import DiskEngine

@Test func stoppedScanResumesToSameTotals() async throws {
    var spec: [String: Int] = [:]
    for i in 0..<400 { spec["d\(i % 40)/e\(i)/f.bin"] = (i % 3 == 0) ? 1_200_000 : 100 }
    let root = try Fixtures.tree(spec)
    let fresh = try await DiskScanner(root: root, storage: try Fixtures.tempDir()).run()

    let store = try Fixtures.tempDir()
    let scanner = DiskScanner(root: root, storage: store, workers: 2)
    let index = try ScanIndex(rootName: root.lastPathComponent, storage: store)
    index.rootPath = fresh.index.rootPath
    index.rootDevice = fresh.index.rootDevice
    var checkpoints = 0
    _ = try await scanner.scan(into: index, starting: [0], checkpointEvery: .zero) { idx in
        checkpoints += 1
        if checkpoints == 3 {
            try idx.save(to: store)
            return .stop
        }
        return .proceed
    }
    let reloaded = try ScanIndex.load(from: store)
    #expect(!reloaded.pending.isEmpty)
    _ = try await DiskScanner(root: root, storage: store).scan(into: reloaded, starting: reloaded.pending)
    #expect(reloaded.pending.isEmpty)
    #expect(reloaded.folders.count == fresh.index.folders.count)
    #expect(reloaded.folders[0].totalAllocated == fresh.index.folders[0].totalAllocated)
    #expect(reloaded.files.count == fresh.index.files.count)
}
