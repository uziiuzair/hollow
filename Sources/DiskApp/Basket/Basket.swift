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

    /// The app-managed hit this item is, or is inside.
    func managingHit(in protected: [LensHit]) -> LensHit? {
        protected.first { $0.safety == .appManaged && BasketItem.covers($0.path, path) }
    }

    /// An app-managed hit strictly inside this item.
    func containedHit(in protected: [LensHit]) -> LensHit? {
        protected.first { $0.safety == .appManaged && $0.path.hasPrefix(path + "/") }
    }

    private static func covers(_ folder: String, _ other: String) -> Bool { other == folder || other.hasPrefix(folder + "/") }
}

/// The items picked on one drive, in the order they were added. A folder swallows anything inside it.
@MainActor public final class Basket: ObservableObject {
    @Published public private(set) var items: [BasketItem] = []

    public init() {}

    public var total: UInt64 { items.reduce(0) { $0 + $1.size } }
    /// The kinds of the first six items.
    public var chips: [ContentKind?] { items.prefix(6).map(\.kind) }
    public var moreCount: Int { max(0, items.count - 6) }

    /// False for the root, a bucket, a path already here, or a path under an item already here.
    /// Anything already here that is under the new item leaves.
    @discardableResult public func add(_ item: BasketItem) -> Bool {
        var next = items
        guard Self.insert(item, into: &next) else { return false }
        items = next
        return true
    }

    public func add(contentsOf newItems: [BasketItem]) {
        var next = items
        var changed = false
        for item in newItems where Self.insert(item, into: &next) { changed = true }
        if changed { items = next }
    }

    public func remove(paths: Set<String>) {
        guard items.contains(where: { paths.contains($0.path) }) else { return }
        items.removeAll { paths.contains($0.path) }
    }

    public func clear() {
        if !items.isEmpty { items = [] }
    }

    private static func insert(_ item: BasketItem, into list: inout [BasketItem]) -> Bool {
        guard !BasketItem.isBucketOrRoot(item.path), !list.contains(where: { $0.covers(item.path) }) else { return false }
        list.removeAll { item.covers($0.path) }
        list.append(item)
        return true
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
