import CoreGraphics
import DiskEngine

public enum TreemapRef: Hashable, Sendable {
    case folder(FolderID)
    case file(FileIndex)
    case small(parent: FolderID, files: Int, folders: Int)
    case more(parent: FolderID, count: Int)
}

public struct TreemapItem: Equatable, Sendable {
    public var ref: TreemapRef
    public var size: UInt64
    public init(ref: TreemapRef, size: UInt64) {
        self.ref = ref
        self.size = size
    }
}

public protocol TreemapSource {
    /// The items directly inside `folder`, in any order. The folder's small files come as one `.small(parent:files:folders: 0)`.
    func items(in folder: FolderID) -> [TreemapItem]
}

public struct TreemapOptions: Equatable, Sendable {
    public var gutter: CGFloat
    public var minSide: CGFloat
    /// 0 means no headers, and every folder recurses.
    public var headerHeight: CGFloat
    public var cap: Int
    public init(gutter: CGFloat = 2, minSide: CGFloat = 2, headerHeight: CGFloat = 48, cap: Int = 50_000) {
        self.gutter = gutter
        self.minSide = minSide
        self.headerHeight = headerHeight
        self.cap = cap
    }
}

public struct TreemapRect: Equatable, Sendable {
    public var ref: TreemapRef
    public var size: UInt64
    /// The drawn frame: the tile inset by `gutter / 2`.
    public var frame: CGRect
    /// 1 is a child of the zoom root.
    public var depth: Int
    /// Index of the parent rect, -1 at depth 1.
    public var parent: Int
    public var firstChild: Int
    public var childCount: Int
    public var hasHeader: Bool

    public init(ref: TreemapRef, size: UInt64, frame: CGRect, depth: Int, parent: Int,
                firstChild: Int = 0, childCount: Int = 0, hasHeader: Bool = false) {
        self.ref = ref
        self.size = size
        self.frame = frame
        self.depth = depth
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.hasHeader = hasHeader
    }
}

public struct TreemapLayout: Sendable {
    public var rects: [TreemapRect]
    public var bounds: CGRect
    public var topLevelCount: Int

    public init(rects: [TreemapRect], bounds: CGRect, topLevelCount: Int) {
        self.rects = rects
        self.bounds = bounds
        self.topLevelCount = topLevelCount
    }

    private struct Job {
        var folder: FolderID
        var area: CGRect
        var depth: Int
        var parent: Int
    }

    public static func make(source: some TreemapSource, root: FolderID, bounds: CGRect,
                            options: TreemapOptions = .init()) -> TreemapLayout {
        var rects: [TreemapRect] = []
        var topLevelCount = 0
        guard bounds.width > 0, bounds.height > 0 else { return TreemapLayout(rects: [], bounds: bounds, topLevelCount: 0) }
        var queue = [Job(folder: root, area: bounds, depth: 1, parent: -1)]
        var head = 0
        let minArea = Double(options.minSide * options.minSide)

        while head < queue.count {
            let job = queue[head]
            head += 1
            let sorted = source.items(in: job.folder).filter { $0.size > 0 }
            let total = sorted.reduce(0.0) { $0 + Double($1.size) }
            guard total > 0, job.area.width > 0, job.area.height > 0 else { continue }
            let pointsPerByte = Double(job.area.width * job.area.height) / total

            // Fold tiny items and the folder's own small block into one block.
            var items: [TreemapItem] = []
            var mergedSize: UInt64 = 0, mergedFiles = 0, mergedFolders = 0, merged = false
            for item in sorted {
                var fold = false
                switch item.ref {
                case .small(_, let f, let d):
                    fold = true; mergedFiles += f; mergedFolders += d
                case .file:
                    if Double(item.size) * pointsPerByte < minArea { fold = true; mergedFiles += 1 }
                case .folder:
                    if Double(item.size) * pointsPerByte < minArea { fold = true; mergedFolders += 1 }
                case .more:
                    break
                }
                if fold { merged = true; mergedSize += item.size } else { items.append(item) }
            }
            if merged, Double(mergedSize) * pointsPerByte >= minArea {
                items.append(TreemapItem(ref: .small(parent: job.folder, files: mergedFiles, folders: mergedFolders), size: mergedSize))
            }

            // Order by size descending, ties keep incoming order.
            func order(_ list: [TreemapItem]) -> [TreemapItem] {
                list.enumerated().sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size : $0.offset < $1.offset }.map(\.element)
            }
            items = order(items)

            // Budget shared across the whole layout.
            let remaining = options.cap - rects.count
            if items.count > remaining {
                guard remaining >= 2 else { continue }
                let rest = items[(remaining - 1)...]
                let more = TreemapItem(ref: .more(parent: job.folder, count: rest.count), size: rest.reduce(0) { $0 + $1.size })
                items = order(Array(items[..<(remaining - 1)]) + [more])
            }
            guard !items.isEmpty else { continue }

            let tiles = Squarify.tiles(items.map { Double($0.size) }, in: job.area)
            let first = rects.count
            let inset = options.gutter / 2
            for (item, tile) in zip(items, tiles) {
                rects.append(TreemapRect(ref: item.ref, size: item.size, frame: tile.insetBy(dx: inset, dy: inset),
                                         depth: job.depth, parent: job.parent))
            }
            if job.parent >= 0 {
                rects[job.parent].firstChild = first
                rects[job.parent].childCount = items.count
            } else {
                topLevelCount = items.count
            }

            for index in first..<rects.count {
                guard case .folder(let id) = rects[index].ref else { continue }
                let frame = rects[index].frame
                var header: CGFloat = 0
                if job.depth == 1, options.headerHeight > 0 {
                    if frame.height >= options.headerHeight + 24, frame.width >= 60 {
                        header = options.headerHeight
                        rects[index].hasHeader = true
                    } else {
                        continue
                    }
                }
                let child = CGRect(x: frame.minX, y: frame.minY + header, width: frame.width, height: frame.height - header)
                    .insetBy(dx: inset, dy: inset)
                if child.width >= options.minSide, child.height >= options.minSide {
                    queue.append(Job(folder: id, area: child, depth: job.depth + 1, parent: index))
                }
            }
        }
        return TreemapLayout(rects: rects, bounds: bounds, topLevelCount: topLevelCount)
    }

    /// The deepest rect whose `frame` contains `p`.
    public func hitTest(_ p: CGPoint) -> Int? {
        var range = 0..<topLevelCount
        var found: Int?
        while let hit = range.first(where: { rects[$0].frame.contains(p) }) {
            found = hit
            range = rects[hit].firstChild..<(rects[hit].firstChild + rects[hit].childCount)
        }
        return found
    }

    /// The depth-1 ancestor of `index` (or `index` itself at depth 1).
    public func topLevel(of index: Int) -> Int {
        var i = index
        while rects[i].parent >= 0 { i = rects[i].parent }
        return i
    }
}
