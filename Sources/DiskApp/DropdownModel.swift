import Foundation
import DiskEngine

public enum FooterAction: Equatable, Sendable { case settings, eject, none }

public enum SegmentKind: Equatable, Sendable {
    case content(ContentKind), reclaimable, free
}

public struct BarSegment: Equatable, Sendable {
    public var kind: SegmentKind
    public var fraction: Double
}

/// Everything the dropdown draws, as plain values.
public struct DropdownModel: Equatable, Sendable {
    public struct Tab: Equatable, Sendable {
        public var uuid: String
        public var name: String
        public var tintIndex: Int
        public var isSelected: Bool
        public var isOffline: Bool
    }

    public struct Row: Equatable, Sendable {
        public var kind: ContentKind
        public var name: String
        public var location: String
        public var delta: String
        public var isGrowth: Bool
        /// The change's path relative to the drive root.
        public var path: String
        /// True when a click can open the map there: the drive is connected and the path is not the root.
        public var opensMap: Bool
    }

    public var tabs: [Tab]
    public var freeTitle: String
    public var freeDetail: String
    public var bar: [BarSegment]
    public var legend: [ContentKind]
    public var showsReclaimable: Bool
    public var rows: [Row]
    public var netLabel: String
    public var netValue: String
    /// True when the drive is filling up (free space went down).
    public var netIsGrowth: Bool
    public var emptyMessage: String?
    public var footerLeft: String
    public var footerRight: FooterAction
    /// The drive is connected, so "Open map" works.
    public var canOpenMap: Bool
    /// "Review N GB to clear": shown while the drive is connected and the lens found at least 0.1 GB that regenerates.
    public var reviewTitle: String?

    private static let barOrder: [ContentKind] = [.appData, .virtualMachines, .developer, .media, .apps, .documents, .caches, .other]
    private static let minus = "\u{2212}"

    public static func make(drives: [KnownDrive], selected: String, connected: Set<String>, summary: DriveSummary?,
                            space: VolumeSpace?, activity: DriveActivity, period: Int, connectedSince: Date?,
                            now: Date, clearable: UInt64? = nil) -> DropdownModel {
        let tabs = tabList(drives, selected: selected, connected: connected)
        let drive = drives.first { $0.uuid == selected }
        let isInternal = drive?.isInternal == true
        let isOnline = connected.contains(selected)

        let (title, detail) = freeText(drive: drive, space: space, isOnline: isOnline)
        // An offline drive keeps its last bar: the cached kinds plus the space the registry remembers.
        let barSpace: VolumeSpace? = isOnline ? space : drive.flatMap { d in
            guard let total = d.lastTotal, let free = d.lastFree else { return nil }
            return VolumeSpace(total: total, available: free, availableForImportantUsage: free)
        }
        let (bar, legend, showsReclaimable) = (isOnline || summary != nil) ? barParts(summary: summary, space: barSpace) : ([], [], false)
        let rows = summary.map { makeRows($0, opensMap: isOnline) } ?? []

        let netLabel = period == 1 ? "Net today" : period == 7 ? "Net this week" : "Net this month"
        var netValue = ""
        var netIsGrowth = false
        if let net = summary?.net {
            let gb = String(format: "%.1f GB", Double(net.magnitude) / 1_000_000_000)
            // Free space moves opposite to size.
            netValue = (net > 0 ? minus : "+") + gb + " free"
            netIsGrowth = net > 0
        }

        var empty: String?
        if !isOnline {
            if let summary { if rows.isEmpty, summary.changes.isEmpty { empty = "Nothing changed by more than 0.1 GB." } }
            else { empty = "Nothing saved for this drive yet." }
        } else {
            if summary == nil, activity == .scanning {
                empty = "Scanning this drive for the first time. Free space is already up to date."
            } else if let summary {
                if summary.net == nil { empty = "No history yet. Changes show up from tomorrow." }
                else if rows.isEmpty { empty = "Nothing changed by more than 0.1 GB." }
            }
        }

        let footerLeft: String
        if !isOnline { footerLeft = summary.map { "Data from " + Format.shortDate($0.updatedAt) } ?? "Offline" }
        else if activity == .opening || activity == .scanning { footerLeft = "Updating\u{2026}" }
        else if isInternal { footerLeft = summary.map { "Updated " + Format.ago($0.updatedAt, now: now) } ?? "Updating\u{2026}" }
        else { footerLeft = connectedSince.map { "Connected " + Format.ago($0, now: now) } ?? "Connected" }

        return DropdownModel(tabs: tabs, freeTitle: title, freeDetail: detail, bar: bar, legend: legend,
                             showsReclaimable: showsReclaimable, rows: rows, netLabel: netLabel, netValue: netValue,
                             netIsGrowth: netIsGrowth, emptyMessage: empty, footerLeft: footerLeft,
                             footerRight: !isOnline ? .none : (isInternal ? .settings : .eject),
                             canOpenMap: isOnline,
                             reviewTitle: clearable.flatMap { isOnline && $0 >= 100_000_000 ? "Review " + Format.gb($0) + " to clear" : nil })
    }

    private static func tabList(_ drives: [KnownDrive], selected: String, connected: Set<String>) -> [Tab] {
        let internalDrives = drives.filter(\.isInternal)
        let others = drives.filter { !$0.isInternal }.sorted { $0.lastSeen > $1.lastSeen }
        return (internalDrives + others).map {
            Tab(uuid: $0.uuid, name: $0.name, tintIndex: $0.tintIndex, isSelected: $0.uuid == selected,
                isOffline: !connected.contains($0.uuid))
        }
    }

    private static func freeText(drive: KnownDrive?, space: VolumeSpace?, isOnline: Bool) -> (String, String) {
        guard isOnline, let space else {
            guard let drive else { return ("Not connected", "") }
            var detail = "Last seen " + Format.shortDate(drive.lastSeen)
            if let free = drive.lastFree { detail += ", \(Format.gb(free)) free then" }
            return ("Not connected", detail)
        }
        var detail = "of " + Format.gb(space.total)
        if space.reclaimable >= 1_000_000_000 { detail += ", \(Format.gb(space.reclaimable)) more reclaimable" }
        return (Format.gb(space.availableForImportantUsage) + " free", detail)
    }

    private static func barParts(summary: DriveSummary?, space: VolumeSpace?) -> ([BarSegment], [ContentKind], Bool) {
        guard let space, space.total > 0 else { return ([], [], false) }
        var bytes: [ContentKind: UInt64] = summary?.kinds ?? [:]
        let reclaimable = space.reclaimable
        let used = space.total > space.available ? space.total - space.available : 0
        let seen = bytes.values.reduce(0, +) + reclaimable
        bytes[.other, default: 0] += used > seen ? used - seen : 0

        var segments: [(SegmentKind, UInt64)] = barOrder.compactMap { k in
            guard let b = bytes[k], b > 0 else { return nil }
            return (.content(k), b)
        }
        let legend = segments.compactMap { seg -> ContentKind? in
            if case .content(let k) = seg.0 { return k }
            return nil
        }
        if reclaimable > 0 { segments.append((.reclaimable, reclaimable)) }
        if space.available > 0 { segments.append((.free, space.available)) }
        let sum = Double(segments.reduce(0) { $0 + $1.1 })
        guard sum > 0 else { return ([], legend, reclaimable > 0) }
        return (segments.map { BarSegment(kind: $0.0, fraction: Double($0.1) / sum) }, legend, reclaimable > 0)
    }

    private static func makeRows(_ summary: DriveSummary, opensMap: Bool) -> [Row] {
        summary.changes.prefix(5).map { change in
            let parts = change.path.split(separator: "/").map(String.init)
            var kind = ContentKind.other
            for n in stride(from: parts.count, through: 1, by: -1) {
                if let k = ContentKind.classify(parts[..<n].joined(separator: "/")) { kind = k; break }
            }
            return Row(kind: kind, name: parts.last ?? change.path,
                       location: parts.count >= 2 ? parts[parts.count - 2] : "",
                       delta: Format.signedGB(change.delta), isGrowth: change.delta > 0,
                       path: change.path, opensMap: opensMap && !change.path.isEmpty)
        }
    }
}
