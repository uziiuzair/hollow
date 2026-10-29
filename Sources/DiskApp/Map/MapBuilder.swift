// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import DiskEngine

/// Feeds the layout from the index. Reads sizes only, never names.
struct IndexTreemapSource: TreemapSource {
    let index: ScanIndex

    func items(in folder: FolderID) -> [TreemapItem] {
        let record = index.folders[Int(folder)]
        var items: [TreemapItem] = []
        var child = record.firstChildFolder
        while child != noFolder {
            let childRecord = index.folders[Int(child)]
            items.append(TreemapItem(ref: .folder(child), size: childRecord.totalAllocated))
            child = childRecord.nextSibling
        }
        for file in record.firstFile..<(record.firstFile + record.bigFileCount) {
            if let size = try? index.files.record(file).allocated {
                items.append(TreemapItem(ref: .file(file), size: size))
            }
        }
        if record.smallFileCount > 0 {
            items.append(TreemapItem(ref: .small(parent: folder, files: Int(record.smallFileCount), folders: 0),
                                     size: record.smallAllocated))
        }
        return items
    }
}

public enum MapBuilder {
    static let listLimit = 200
    static let unreadableListLimit = 50

    public static func build(index: ScanIndex, request: MapRequest, baseline: SizeSnapshot?) -> MapSnapshot {
        // Resolve the path to the deepest folder that still exists.
        var zoom: FolderID = 0
        var names: [String] = []
        var crumbs: [Crumb] = []
        var zoomKind = ContentKind.other
        var zoomParts: [String] = []
        for part in request.path.split(separator: "/", omittingEmptySubsequences: true) {
            var child = index.folders[Int(zoom)].firstChildFolder
            while child != noFolder, index.folderName(child) != part {
                child = index.folders[Int(child)].nextSibling
            }
            guard child != noFolder else { break }
            zoom = child
            names.append(String(part))
            zoomParts.append(part.lowercased())
            zoomKind = ContentKind.classify(parts: zoomParts) ?? zoomKind
            crumbs.append(Crumb(name: String(part), path: names.joined(separator: "/")))
        }
        let path = names.joined(separator: "/")

        let bounds = CGRect(origin: .zero, size: request.size)
        let layout = TreemapLayout.make(source: IndexTreemapSource(index: index), root: zoom,
                                        bounds: bounds, options: request.options)

        // Rects run in breadth-first order, so a parent is always built before its children.
        var nodes: [MapNode] = []
        var kinds: [ContentKind] = []
        var keys: [String] = []
        var parts: [[String]] = []
        nodes.reserveCapacity(layout.rects.count)
        for rect in layout.rects {
            let parentKey = rect.parent >= 0 ? keys[rect.parent] : path
            let parentKind = rect.parent >= 0 ? kinds[rect.parent] : zoomKind
            let parentParts = rect.parent >= 0 ? parts[rect.parent] : zoomParts
            func child(_ name: String) -> String { parentKey.isEmpty ? name : parentKey + "/" + name }
            switch rect.ref {
            case .folder(let id):
                let name = index.folderName(id)
                let key = child(name)
                let folderParts = parentParts + [name.lowercased()]
                let kind = ContentKind.classify(parts: folderParts) ?? parentKind
                nodes.append(MapNode(key: key, name: name, kind: kind,
                                     growth: growth(key, now: rect.size, isFile: false, baseline), isFolder: true))
                kinds.append(kind); keys.append(key); parts.append(folderParts)
            case .file(let id):
                let name = (try? index.files.name(id)) ?? ""
                let key = child(name)
                nodes.append(MapNode(key: key, name: name, kind: parentKind,
                                     growth: growth(key, now: rect.size, isFile: true, baseline), isFolder: false))
                kinds.append(parentKind); keys.append(key); parts.append(parentParts)
            case .small(_, let files, let folders):
                let name: String
                if folders > 0 {
                    name = "\(grouped(files + folders)) small items"
                } else {
                    name = files == 1 ? "1 small file" : "\(grouped(files)) small files"
                }
                nodes.append(MapNode(key: parentKey + "#small", name: name, kind: nil, growth: 0, isFolder: false))
                kinds.append(parentKind); keys.append(parentKey + "#small"); parts.append(parentParts)
            case .more(_, let count):
                nodes.append(MapNode(key: parentKey + "#more", name: "\(grouped(count)) more items",
                                     kind: nil, growth: 0, isFolder: false))
                kinds.append(parentKind); keys.append(parentKey + "#more"); parts.append(parentParts)
            }
        }

        // Side list: the first 200 depth-1 rects, then one remainder row.
        let top = layout.topLevelCount
        let largest = layout.rects[..<top].map(\.size).max() ?? 0
        func fraction(_ size: UInt64) -> Double { largest == 0 ? 0 : min(1, Double(size) / Double(largest)) }
        var list: [ListRow] = []
        for i in 0..<min(top, listLimit) {
            list.append(ListRow(node: i, name: nodes[i].name, size: layout.rects[i].size,
                                fraction: fraction(layout.rects[i].size), kind: nodes[i].kind))
        }
        if top > listLimit {
            let rest = layout.rects[listLimit..<top].reduce(UInt64(0)) { $0 + $1.size }
            list.append(ListRow(node: nil, name: "\(grouped(top - listLimit)) more items", size: rest,
                                fraction: fraction(rest), kind: nil))
        }

        // Unreadable child folders have no size, so no block: they close the list, in sibling order.
        var unreadable = 0
        var sibling = index.folders[Int(zoom)].firstChildFolder
        while sibling != noFolder {
            let record = index.folders[Int(sibling)]
            if record.flags.contains(.unreadable) {
                unreadable += 1
                if unreadable <= unreadableListLimit {
                    list.append(ListRow(node: nil, name: index.folderName(sibling), size: 0, fraction: 0, kind: nil,
                                        isUnreadable: true))
                }
            }
            sibling = record.nextSibling
        }

        return MapSnapshot(path: path, rootPath: index.rootPath, crumbs: crumbs,
                           total: index.folders[Int(zoom)].totalAllocated, period: request.period,
                           layout: layout, nodes: nodes, list: list, unreadableCount: unreadable)
    }

    private static func growth(_ key: String, now: UInt64, isFile: Bool, _ baseline: SizeSnapshot?) -> Int64 {
        guard let baseline else { return 0 }
        let floor = isFile ? SizeSnapshot.fileFloor : SizeSnapshot.folderFloor
        guard baseline.sizes[key] != nil || now >= floor else { return 0 }
        return Int64(clamping: now) - Int64(clamping: baseline.estimatedSize(of: key, isFile: isFile))
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
