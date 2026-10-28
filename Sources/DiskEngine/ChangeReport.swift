/// One item that grew (positive) or shrank (negative).
public struct Change: Sendable, Equatable {
    public var path: String
    public var delta: Int64

    public init(path: String, delta: Int64) {
        self.path = path
        self.delta = delta
    }
}

public enum ChangeReport {
    /// Changes between two snapshots, each attributed to the deepest item that explains
    /// it. A node is reported when its own change is at least `minimum` and its
    /// significant children explain less than `explained` of it; significant children
    /// are always explored. An item missing from one snapshot was below the size floor
    /// there, so it counts as just under the floor, and never more than its parent.
    public static func changes(
        from old: SizeSnapshot, to new: SizeSnapshot,
        minimum: UInt64 = 100_000_000, explained: Double = 0.7
    ) -> [Change] {
        var children: [String: [String]] = [:]
        for key in Set(old.sizes.keys).union(new.sizes.keys) where !key.isEmpty {
            children[key.lastIndex(of: "/").map { String(key[..<$0]) } ?? "", default: []].append(key)
        }
        let isFile = old.files.union(new.files)
        func parent(_ key: String) -> String {
            key.lastIndex(of: "/").map { String(key[..<$0]) } ?? ""
        }
        func size(_ key: String, in snapshot: SizeSnapshot) -> UInt64 {
            if let value = snapshot.sizes[key] { return value }
            if key.isEmpty { return 0 }
            let floor = isFile.contains(key) ? SizeSnapshot.fileFloor : SizeSnapshot.folderFloor
            return min(floor - 1, size(parent(key), in: snapshot))
        }
        func delta(_ key: String) -> Int64 {
            Int64(bitPattern: size(key, in: new)) - Int64(bitPattern: size(key, in: old))
        }
        let floor = Int64(minimum)

        var result: [Change] = []
        var stack = [""]
        while let node = stack.popLast() {
            let d = delta(node)
            let significant = (children[node] ?? []).filter { abs(delta($0)) >= floor }
            let explainedBytes = significant.reduce(Int64(0)) { $0 + abs(delta($1)) }
            if abs(d) >= floor, Double(explainedBytes) < explained * Double(abs(d)) {
                result.append(Change(path: node, delta: d))
            }
            stack += significant
        }
        return result.sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }
    }
}
