// SPDX-License-Identifier: GPL-3.0-or-later

import DiskEngine
import Foundation

public enum LensMatcher {
    /// Walks the index once, depth first, and returns the largest hits. A folder hit is never descended into, so each byte counts once.
    /// `modified` receives `index.rootPath + "/" + relativePath`. A cancelled task gets the hits found so far.
    public static func report(index: ScanIndex, rules: LensRules, generation: Int = 0, now: Date = .now,
                              minBytes: UInt64 = 1_000_000, limit: Int = 2_000,
                              modified: (String) -> Date? = LensMatcher.modificationDate) -> LensReport {
        var walk = LensWalk(rules: rules, generation: generation, now: now, minBytes: minBytes, limit: limit)
        walk.advance(index: index, folders: .max, modified: modified)
        return walk.report()
    }

    static func fileHits(index: ScanIndex, folder: FolderID, path: String, rule: LensRule, now: Date,
                                 minBytes: UInt64, modified: (String) -> Date?) -> [LensHit] {
        let globs = (rule.files ?? []).map { $0.lowercased() }
        let cutoff = now.addingTimeInterval(-Double(rule.minAgeDays ?? 0) * 86_400)
        let record = index.folders[Int(folder)]
        var out: [LensHit] = []
        for file in record.firstFile..<(record.firstFile + record.bigFileCount) {
            guard let name = try? index.files.name(file), let size = (try? index.files.record(file))?.allocated, size >= minBytes
            else { continue }
            let lower = name.lowercased()
            guard globs.contains(where: { fnmatch($0, lower, 0) == 0 }) else { continue }
            let relative = path.isEmpty ? name : path + "/" + name
            if rule.minAgeDays != nil {
                guard let date = modified(index.rootPath + "/" + relative), date <= cutoff else { continue }
            }
            out.append(LensHit(ruleID: rule.id, path: relative, name: name, size: size, isFolder: false, safety: rule.safety))
        }
        return out
    }

    public static func modificationDate(_ absolutePath: String) -> Date? {
        var st = stat()
        guard lstat(absolutePath, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }
}

/// A lens walk that can stop and go on: `advance` visits at most a given number of folders, so a caller holding the index
/// lock can let go of it between chunks. It checks for cancellation every `cancelCheckEvery` folders and stops there.
/// The index may change between chunks: folders since removed are skipped, and a different index (a compaction) starts the
/// walk again. The report carries the generation the walk started at, so a caller sees it is stale and walks again.
public struct LensWalk: Sendable {
    public let rules: LensRules
    public let generation: Int
    let now: Date
    let minBytes: UInt64
    let limit: Int
    let cancelCheckEvery: Int
    private let fileRules: [Int]
    private let folderRules: [Int]
    private var stack: [Pending]
    private var hits: [LensHit] = []
    private var indexID: ObjectIdentifier?
    /// Folders taken off the stack so far.
    public private(set) var foldersVisited = 0

    private struct Pending: Sendable {
        var folder: FolderID
        var path: String
        var masks: [UInt64]
    }

    public init(rules: LensRules, generation: Int = 0, now: Date = .now, minBytes: UInt64 = 1_000_000, limit: Int = 2_000,
                cancelCheckEvery: Int = 4_096) {
        self.rules = rules
        self.generation = generation
        self.now = now
        self.minBytes = minBytes
        self.limit = limit
        self.cancelCheckEvery = max(cancelCheckEvery, 1)
        fileRules = rules.rules.indices.filter { rules.rules[$0].isFileRule }
        folderRules = rules.folderRuleIndices
        stack = [Pending(folder: 0, path: "", masks: rules.startMasks())]
    }

    public var isFinished: Bool { stack.isEmpty }

    /// Visits up to `budget` folders (fewer when the task is cancelled).
    public mutating func advance(index: ScanIndex, folders budget: Int,
                                 modified: (String) -> Date? = LensMatcher.modificationDate) {
        let id = ObjectIdentifier(index)
        if let indexID, indexID != id {
            // A different index (compacted): its folder IDs mean other folders. Start over.
            stack = [Pending(folder: 0, path: "", masks: rules.startMasks())]
            hits = []
        }
        indexID = id
        var visited = 0
        while visited < budget, let next = stack.popLast() {
            visited += 1
            foldersVisited += 1
            if foldersVisited % cancelCheckEvery == 0, Task.isCancelled { return }
            let (folder, path, masks) = (next.folder, next.path, next.masks)
            guard Int(folder) < index.folders.count, !index.folders[Int(folder)].flags.contains(.garbage) else { continue }
            for r in fileRules where rules.patterns[r].accepts(masks[r]) {
                hits += LensMatcher.fileHits(index: index, folder: folder, path: path, rule: rules.rules[r], now: now,
                                             minBytes: minBytes, modified: modified)
            }
            var child = index.folders[Int(folder)].firstChildFolder
            while child != noFolder {
                let name = index.folderName(child)
                let nextMasks = rules.step(masks, name.lowercased())
                let childPath = path.isEmpty ? name : path + "/" + name
                if let r = rules.best(rules.accepting(nextMasks, among: folderRules)) {
                    let size = index.folders[Int(child)].totalAllocated
                    if size >= minBytes {
                        hits.append(LensHit(ruleID: rules.rules[r].id, path: childPath, name: name, size: size,
                                            isFolder: true, safety: rules.rules[r].safety))
                    }
                    // A hit is never descended into, even when it is too small to report.
                } else if rules.isLive(nextMasks) {
                    stack.append(Pending(folder: child, path: childPath, masks: nextMasks))
                }
                child = index.folders[Int(child)].nextSibling
            }
        }
    }

    /// The largest hits found so far, largest first.
    public func report() -> LensReport {
        let sorted = hits.sorted { $0.size > $1.size }
        return LensReport(hits: Array(sorted.prefix(limit)), generation: generation)
    }
}
