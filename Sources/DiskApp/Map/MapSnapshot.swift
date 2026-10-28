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

    public init(node: Int?, name: String, size: UInt64, fraction: Double, kind: ContentKind?) {
        self.node = node
        self.name = name
        self.size = size
        self.fraction = fraction
        self.kind = kind
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

    public init(path: String, rootPath: String, crumbs: [Crumb], total: UInt64, period: Int,
                layout: TreemapLayout, nodes: [MapNode], list: [ListRow]) {
        self.path = path
        self.rootPath = rootPath
        self.crumbs = crumbs
        self.total = total
        self.period = period
        self.layout = layout
        self.nodes = nodes
        self.list = list
    }

    /// The file or folder on disk, or nil for a bucket.
    public func url(of node: Int) -> URL? {
        guard nodes.indices.contains(node), nodes[node].kind != nil else { return nil }
        return URL(fileURLWithPath: rootPath + "/" + nodes[node].key)
    }
}
