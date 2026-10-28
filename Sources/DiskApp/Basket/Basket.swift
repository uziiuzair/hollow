import Combine
import DiskEngine
import Foundation

/// Something the user picked to clear: a folder or file, relative to its drive's root.
public struct BasketItem: Equatable, Sendable, Identifiable {
    /// Relative to the drive root.
    public var path: String
    public var name: String
    public var size: UInt64
    public var kind: ContentKind?
    public var isFolder: Bool
    public var ruleID: String?
    public var safety: LensSafety?
    public var id: String { path }

    public init(path: String, name: String, size: UInt64, kind: ContentKind?, isFolder: Bool, ruleID: String?, safety: LensSafety?) {
        self.path = path
        self.name = name
        self.size = size
        self.kind = kind
        self.isFolder = isFolder
        self.ruleID = ruleID
        self.safety = safety
    }

    /// Nil for the small-files and "more" buckets and for the drive root. A folder gets a rule only when a rule covers the
    /// folder itself, never because a rule covers something inside it.
    public static func from(node: MapNode, size: UInt64, rules: LensRules = .bundled) -> BasketItem? {
        guard node.kind != nil, !isBucketOrRoot(node.key) else { return nil }
        let rule = rules.rule(covering: node.key, includeParents: false)
        return BasketItem(path: node.key, name: node.name, size: size, kind: node.kind, isFolder: node.isFolder,
                          ruleID: rule?.id, safety: rule?.safety)
    }

    public static func from(hit: LensHit) -> BasketItem {
        BasketItem(path: hit.path, name: hit.name, size: hit.size, kind: ContentKind.classify(hit.path) ?? .other,
                   isFolder: hit.isFolder, ruleID: hit.ruleID, safety: hit.safety)
    }

    /// The drive root `""`, or a map bucket key (`"<folder>#small"`, `"<folder>#more"`). A real name such as `C#` is fine.
    static func isBucketOrRoot(_ key: String) -> Bool {
        key.isEmpty || key.hasSuffix("#small") || key.hasSuffix("#more")
    }

    /// True when `other` is this item or is inside it.
    func covers(_ other: String) -> Bool { other == path || other.hasPrefix(path + "/") }

    /// Each proper ancestor of a relative path, shallowest first: "a", "a/b" for "a/b/c".
    static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            out.append(String(path[..<slash]))
            index = path.index(after: slash)
        }
        return out
    }
}

/// A drive's app-managed hits, indexed by path, so the review sheet and `Trasher` ask about each item in its depth, not
/// in the number of hits.
struct ProtectedHits: Sendable {
    /// Each app-managed hit by its path (the first one listed wins).
    private var byPath: [String: LensHit] = [:]
    /// Each proper ancestor of an app-managed hit, with the first hit under it.
    private var byAncestor: [String: LensHit] = [:]

    init(_ hits: [LensHit]) {
        for hit in hits where hit.safety == .appManaged {
            if byPath[hit.path] == nil { byPath[hit.path] = hit }
            for ancestor in BasketItem.ancestors(of: hit.path) where byAncestor[ancestor] == nil { byAncestor[ancestor] = hit }
        }
    }

    /// The app-managed hit `path` is, or is inside.
    func managing(_ path: String) -> LensHit? {
        PathChecks.tick()
        if let hit = byPath[path] { return hit }
        for ancestor in BasketItem.ancestors(of: path) {
            PathChecks.tick()
            if let hit = byPath[ancestor] { return hit }
        }
        return nil
    }

    /// An app-managed hit strictly inside `path`.
    func contained(in path: String) -> LensHit? {
        PathChecks.tick()
        return byAncestor[path]
    }
}

/// The items picked on one drive, in the order they were added. A folder swallows anything inside it.
@MainActor public final class Basket: ObservableObject {
    @Published public private(set) var items: [BasketItem] = []
    /// The paths in `items`, and for each proper ancestor of one, the item paths under it: an add checks its own
    /// ancestors (its depth) and finds what it swallows directly, so a prefill of n items costs n times the depth.
    private var paths: Set<String> = []
    private var under: [String: Set<String>] = [:]

    public init() {}

    public var total: UInt64 { items.reduce(0) { $0 + $1.size } }
    /// The kinds of the first six items.
    public var chips: [ContentKind?] { items.prefix(6).map(\.kind) }
    public var moreCount: Int { max(0, items.count - 6) }

    /// False for the root, a bucket, a path already here, or a path under an item already here.
    /// Anything already here that is under the new item leaves.
    @discardableResult public func add(_ item: BasketItem) -> Bool {
        var next = items
        guard insert(item, into: &next) else { return false }
        items = next.count == paths.count ? next : next.filter { paths.contains($0.path) }
        return true
    }

    /// True when `add(item)` would take it.
    public func accepts(_ item: BasketItem) -> Bool {
        !BasketItem.isBucketOrRoot(item.path) && !isCovered(item.path)
    }

    public func add(contentsOf newItems: [BasketItem]) {
        var next = items
        var changed = false
        for item in newItems where insert(item, into: &next) { changed = true }
        // Swallowed items left `paths` as they went; one pass drops them from the list.
        if changed { items = next.count == paths.count ? next : next.filter { paths.contains($0.path) } }
    }

    public func remove(paths removed: Set<String>) {
        guard items.contains(where: { removed.contains($0.path) }) else { return }
        for path in removed where paths.contains(path) { forget(path) }
        items.removeAll { removed.contains($0.path) }
    }

    public func clear() {
        paths = []
        under = [:]
        if !items.isEmpty { items = [] }
    }

    /// The path is here, or is under an item here.
    private func isCovered(_ path: String) -> Bool {
        PathChecks.tick()
        if paths.contains(path) { return true }
        for ancestor in BasketItem.ancestors(of: path) {
            PathChecks.tick()
            if paths.contains(ancestor) { return true }
        }
        return false
    }

    /// Appends the item and drops what it swallows from the index (the caller drops them from the list).
    private func insert(_ item: BasketItem, into list: inout [BasketItem]) -> Bool {
        guard !BasketItem.isBucketOrRoot(item.path), !isCovered(item.path) else { return false }
        for child in under[item.path] ?? [] { forget(child) }
        paths.insert(item.path)
        for ancestor in BasketItem.ancestors(of: item.path) { under[ancestor, default: []].insert(item.path) }
        list.append(item)
        return true
    }

    private func forget(_ path: String) {
        PathChecks.tick()
        paths.remove(path)
        for ancestor in BasketItem.ancestors(of: path) {
            under[ancestor]?.remove(path)
            if under[ancestor]?.isEmpty == true { under[ancestor] = nil }
        }
    }
}

/// One basket per drive, by volume UUID.
@MainActor public final class BasketStore {
    private var baskets: [String: Basket] = [:]

    public init() {}

    public func basket(for uuid: String) -> Basket {
        if let b = baskets[uuid] { return b }
        let b = Basket()
        baskets[uuid] = b
        return b
    }

    /// Empties that drive's basket, then forgets it.
    public func drop(_ uuid: String) {
        baskets[uuid]?.clear()
        baskets[uuid] = nil
    }
}
