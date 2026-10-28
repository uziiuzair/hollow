import Foundation

/// What a folder's contents are for, used to color the menu bar breakdown.
public enum ContentKind: String, CaseIterable, Codable, Sendable {
    case apps, virtualMachines, developer, media, documents, appData, caches, other

    /// Rules in priority order. A pattern matches the folder it names and everything below it. Patterns are lowercased path components; `*` matches
    /// exactly one component and a leading `**` lets the rest match at any depth.
    private static let rules: [(kind: ContentKind, patterns: [[String]])] = {
        func p(_ paths: [String]) -> [[String]] {
            paths.map { $0.lowercased().split(separator: "/").map(String.init) }
        }
        return [
            (.developer, p(["*/Library/Developer", "Users/*/Library/Developer", "**/node_modules",
                            "Users/*/.gradle", "Users/*/.cargo", "Users/*/.rustup"])),
            (.virtualMachines, p(["Users/*/Library/Containers/com.docker.docker",
                                  "Users/*/Library/Group Containers/group.com.docker",
                                  "Users/*/.orbstack", "Users/*/Parallels", "Users/*/Virtual Machines.localized",
                                  "Users/*/Library/Containers/com.utmapp.UTM"])),
            (.caches, p(["Library/Caches", "Users/*/Library/Caches", "Users/*/.cache", "private/var/folders"])),
            (.media, p(["Users/*/Pictures", "Users/*/Movies", "Users/*/Music"])),
            (.documents, p(["Users/*/Documents", "Users/*/Desktop", "Users/*/Downloads", "Users/*/Library/Mail"])),
            (.apps, p(["Applications", "Users/*/Applications"])),
            (.appData, p(["Users/*/Library/Application Support", "Users/*/Library/Containers",
                          "Users/*/Library/Group Containers", "Library/Application Support"])),
        ]
    }()

    private static func matches(_ pattern: [String], _ parts: [String]) -> Bool {
        if pattern.first == "**" {
            let rest = Array(pattern.dropFirst())
            guard !rest.isEmpty, parts.count >= rest.count else { return false }
            return (0...(parts.count - rest.count)).contains { start in
                matches(rest, Array(parts[start...]))
            }
        }
        guard parts.count >= pattern.count else { return false }
        return zip(pattern, parts).allSatisfy { $0 == "*" || $0 == $1 }
    }

    /// The kind a folder (path relative to the scanned root) belongs to, or nil when
    /// no rule matches and the caller should look deeper. Never returns `.other`.
    public static func classify(_ relativePath: String) -> ContentKind? {
        let parts = relativePath.lowercased().split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return nil }
        for rule in rules where rule.patterns.contains(where: { matches($0, parts) }) {
            return rule.kind
        }
        return nil
    }

    /// Bytes per kind. A folder that matches a rule contributes its whole subtree and
    /// is not entered; any other folder contributes its direct files to `.other`.
    public static func totals(in index: ScanIndex) -> [ContentKind: UInt64] {
        var result: [ContentKind: UInt64] = [:]
        var stack: [(id: FolderID, path: String)] = [(0, "")]
        while let (id, path) = stack.popLast() {
            let folder = index.folders[Int(id)]
            if let kind = classify(path) {
                result[kind, default: 0] += folder.totalAllocated
                continue
            }
            var direct = folder.smallAllocated
            for i in 0..<folder.bigFileCount {
                if let rec = try? index.files.record(folder.firstFile + FileIndex(i)) { direct += rec.allocated }
            }
            if direct > 0 { result[.other, default: 0] += direct }
            var child = folder.firstChildFolder
            while child != noFolder {
                let name = index.folderName(child)
                stack.append((child, path.isEmpty ? name : path + "/" + name))
                child = index.folders[Int(child)].nextSibling
            }
        }
        return result
    }
}
