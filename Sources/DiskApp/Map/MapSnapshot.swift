import CoreGraphics
import Foundation
import DiskEngine

public struct MapRequest: Equatable, Sendable {
    public var path: String
    public var size: CGSize
    public var period: Int
    public var options: TreemapOptions

    public init(path: String, size: CGSize, period: Int, options: TreemapOptions = .init()) {
        self.path = path
        self.size = size
        self.period = period
        self.options = options
    }
}

public struct MapNode: Equatable, Sendable {
    /// The relative path for folders and files, or `"<folder path>#small"` / `"<folder path>#more"` for buckets.
    public var key: String
    public var name: String
    /// Nil for buckets.
    public var kind: ContentKind?
    public var growth: Int64
    public var isFolder: Bool

    public init(key: String, name: String, kind: ContentKind?, growth: Int64, isFolder: Bool) {
        self.key = key
        self.name = name
        self.kind = kind
        self.growth = growth
        self.isFolder = isFolder
    }
}

public struct Crumb: Equatable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct ListRow: Equatable, Sendable {
    /// Index into `MapSnapshot.nodes`, nil for the remainder row.
    public var node: Int?
    public var name: String
    public var size: UInt64
    /// Size over the largest depth-1 size, capped at 1.
    public var fraction: Double
    public var kind: ContentKind?
    /// A folder macOS won't let the app read (no Full Disk Access). It has no size and no block.
    public var isUnreadable: Bool

    public init(node: Int?, name: String, size: UInt64, fraction: Double, kind: ContentKind?, isUnreadable: Bool = false) {
        self.node = node
        self.name = name
        self.size = size
        self.fraction = fraction
        self.kind = kind
        self.isUnreadable = isUnreadable
    }
}

public struct MapSnapshot: Equatable, Sendable {
    public var path: String
    public var rootPath: String
    public var crumbs: [Crumb]
    public var total: UInt64
    public var period: Int
    public var layout: TreemapLayout
    /// Parallel to `layout.rects`.
    public var nodes: [MapNode]
    public var list: [ListRow]
    /// Direct child folders of the zoom folder that can't be read.
    public var unreadableCount: Int

    public init(path: String, rootPath: String, crumbs: [Crumb], total: UInt64, period: Int,
                layout: TreemapLayout, nodes: [MapNode], list: [ListRow], unreadableCount: Int = 0) {
        self.path = path
        self.rootPath = rootPath
        self.crumbs = crumbs
        self.total = total
        self.period = period
        self.layout = layout
        self.nodes = nodes
        self.list = list
        self.unreadableCount = unreadableCount
    }

    public var unreadableNote: String? {
        switch unreadableCount {
        case 0: nil
        case 1: "1 folder here can't be read."
        default: "\(unreadableCount) folders here can't be read."
        }
    }

    /// The file or folder on disk, or nil for a bucket.
    public func url(of node: Int) -> URL? {
        guard nodes.indices.contains(node), nodes[node].kind != nil else { return nil }
        return URL(fileURLWithPath: rootPath + "/" + nodes[node].key)
    }
}

extension MapSnapshot {
    /// What rect `rect` would put in the basket: nil for a bucket, the root or a rect this snapshot does not have.
    public func basketItem(at rect: Int) -> BasketItem? {
        guard nodes.indices.contains(rect), layout.rects.indices.contains(rect) else { return nil }
        return BasketItem.from(node: nodes[rect], size: layout.rects[rect].size)
    }

    /// What a drop of a press on `key` adds: that item as this level shows it now, or nil when it is no longer a
    /// top-level block here (the map was rebuilt, zoomed or the item went away during the drag).
    public func basketItem(droppedKey key: String) -> BasketItem? {
        topLevelRect(forKey: key).flatMap { basketItem(at: $0) }
    }

    /// The top-level rect showing `key` now, or nil when it is no longer a block at this level. A menu holds the
    /// key, not an index, so a rebuild while it is open can't redirect its choice to another block.
    public func topLevelRect(forKey key: String) -> Int? {
        (0..<layout.topLevelCount).first(where: { nodes.indices.contains($0) && nodes[$0].key == key })
    }
}
