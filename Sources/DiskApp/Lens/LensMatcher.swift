import DiskEngine
import Foundation

public enum LensMatcher {
    /// Walks the index once, depth first, and returns the largest hits. A folder hit is never descended into, so each byte counts once.
    /// `modified` receives `index.rootPath + "/" + relativePath`.
    public static func report(index: ScanIndex, rules: LensRules, generation: Int = 0, now: Date = .now,
                              minBytes: UInt64 = 1_000_000, limit: Int = 2_000,
                              modified: (String) -> Date? = LensMatcher.modificationDate) -> LensReport {
        let fileRules = rules.rules.indices.filter { rules.rules[$0].isFileRule }
        let folderRules = rules.folderRuleIndices
        var hits: [LensHit] = []
        var stack: [(folder: FolderID, path: String, masks: [UInt64])] = [(0, "", rules.startMasks())]
        while let (folder, path, masks) = stack.popLast() {
            for r in fileRules where rules.patterns[r].accepts(masks[r]) {
                hits += fileHits(index: index, folder: folder, path: path, rule: rules.rules[r], now: now,
                                 minBytes: minBytes, modified: modified)
            }
            var child = index.folders[Int(folder)].firstChildFolder
            while child != noFolder {
                let name = index.folderName(child)
                let next = rules.step(masks, name.lowercased())
                let childPath = path.isEmpty ? name : path + "/" + name
                if let r = rules.best(rules.accepting(next, among: folderRules)) {
                    let size = index.folders[Int(child)].totalAllocated
                    if size >= minBytes {
                        hits.append(LensHit(ruleID: rules.rules[r].id, path: childPath, name: name, size: size,
                                            isFolder: true, safety: rules.rules[r].safety))
                    }
                    // A hit is never descended into, even when it is too small to report.
                } else if rules.isLive(next) {
                    stack.append((child, childPath, next))
                }
                child = index.folders[Int(child)].nextSibling
            }
        }
        hits.sort { $0.size > $1.size }
        return LensReport(hits: Array(hits.prefix(limit)), generation: generation)
    }

    private static func fileHits(index: ScanIndex, folder: FolderID, path: String, rule: LensRule, now: Date,
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
