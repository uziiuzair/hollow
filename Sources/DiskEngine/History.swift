import Foundation

/// Sizes of the big items in an index, keyed by path relative to the root ("" is the
/// root). Folders below `folderFloor` and files below `fileFloor` are left out.
public struct SizeSnapshot: Codable, Sendable, Equatable {
    public static let folderFloor: UInt64 = 100_000_000
    public static let fileFloor: UInt64 = 500_000_000

    public var sizes: [String: UInt64]
    /// Keys that are files (their floor is `fileFloor`); the rest are folders.
    public var files: Set<String>

    public init(sizes: [String: UInt64], files: Set<String> = []) {
        self.sizes = sizes
        self.files = files
    }

    /// The size of `key` with the floor rules `ChangeReport` uses for items the snapshot
    /// left out: just under the floor, and never more than the parent.
    public func estimatedSize(of key: String, isFile: Bool) -> UInt64 {
        if let value = sizes[key] { return value }
        if key.isEmpty { return 0 }
        let floor = isFile ? Self.fileFloor : Self.folderFloor
        let parent = key.lastIndex(of: "/").map { String(key[..<$0]) } ?? ""
        return min(floor - 1, estimatedSize(of: parent, isFile: false))
    }

    public static func capture(_ index: ScanIndex) throws -> SizeSnapshot {
        var sizes: [String: UInt64] = ["": index.folders[0].totalAllocated]
        var files: Set<String> = []
        var stack: [(FolderID, String)] = [(0, "")]
        while let (folder, path) = stack.popLast() {
            let record = index.folders[Int(folder)]
            for file in record.firstFile..<(record.firstFile + record.bigFileCount) {
                let allocated = try index.files.record(file).allocated
                if allocated >= fileFloor {
                    let filePath = join(path, try index.files.name(file))
                    sizes[filePath] = allocated
                    files.insert(filePath)
                }
            }
            var child = record.firstChildFolder
            while child != noFolder {
                let total = index.folders[Int(child)].totalAllocated
                if total >= folderFloor {
                    let childPath = join(path, index.folderName(child))
                    sizes[childPath] = total
                    stack.append((child, childPath))
                }
                child = index.folders[Int(child)].nextSibling
            }
        }
        return SizeSnapshot(sizes: sizes, files: files)
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}

/// A calendar day, independent of time of day.
public struct Day: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year!
        month = c.month!
        day = c.day!
    }

    init?(fileName: String, calendar: Calendar) {
        let parts = fileName.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        self.init(date, calendar: calendar)
    }

    public func adding(days: Int, calendar: Calendar) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: date(in: calendar))!, calendar: calendar)
    }

    func days(until other: Day, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: date(in: calendar), to: other.date(in: calendar)).day!
    }

    func date(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    var fileName: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// One `SizeSnapshot` per day, as binary plists. A full ("key") snapshot is stored at
/// least every 7 days; days in between store only what changed since the day before.
public final class HistoryStore {
    static let keyEvery = 7

    private enum Entry: Codable {
        case key(SizeSnapshot)
        case delta(changed: [String: UInt64], removed: [String], files: Set<String>)
    }

    private let directory: URL
    private let calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    /// Stores the snapshot for `day`, replacing any already stored for it.
    public func record(_ snapshot: SizeSnapshot, on day: Day) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let all = try days()
        // Later days are deltas against this chain; rebuild them after the change.
        let later = try all.filter { $0 > day }.map { ($0, try reconstruct($0, from: all)!) }
        try write(snapshot, on: day, existing: all.filter { $0 < day })
        for (laterDay, laterSnapshot) in later {
            try write(laterSnapshot, on: laterDay, existing: try days().filter { $0 < laterDay })
        }
    }

    /// The snapshot of the latest stored day on or before `day`.
    public func snapshot(onOrBefore day: Day) throws -> SizeSnapshot? {
        let all = try days()
        guard let found = all.last(where: { $0 <= day }) else { return nil }
        return try reconstruct(found, from: all)
    }

    public func days() throws -> [Day] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".plist") }
            .compactMap { Day(fileName: String($0.dropLast(6)), calendar: calendar) }
            .sorted()
    }

    /// Deletes days older than `today - keeping`, turning the oldest kept day into a key.
    public func prune(keeping: Int = 90, today: Day) throws {
        let all = try days()
        let cutoff = today.adding(days: -keeping, calendar: calendar)
        let old = all.filter { $0 < cutoff }
        guard !old.isEmpty else { return }
        if let first = all.first(where: { $0 >= cutoff }), let snapshot = try reconstruct(first, from: all) {
            try save(.key(snapshot), on: first)
        }
        for day in old { try FileManager.default.removeItem(at: url(day)) }
    }

    // MARK: - Private

    private func write(_ snapshot: SizeSnapshot, on day: Day, existing earlier: [Day]) throws {
        guard let previous = earlier.last,
              let lastKey = try earlier.last(where: { if case .key = try read($0) { true } else { false } }),
              lastKey.days(until: day, calendar: calendar) < Self.keyEvery,
              let base = try reconstruct(previous, from: earlier)
        else {
            try save(.key(snapshot), on: day)
            return
        }
        let changed = snapshot.sizes.filter { base.sizes[$0.key] != $0.value }
        let removed = base.sizes.keys.filter { snapshot.sizes[$0] == nil }
        try save(.delta(changed: changed, removed: Array(removed), files: snapshot.files), on: day)
    }

    private func reconstruct(_ day: Day, from all: [Day]) throws -> SizeSnapshot? {
        let chain = all.filter { $0 <= day }
        guard let keyIndex = try chain.lastIndex(where: { if case .key = try read($0) { true } else { false } }) else { return nil }
        guard case .key(var snapshot) = try read(chain[keyIndex]) else { return nil }
        for later in chain[(keyIndex + 1)...] {
            if case .delta(let changed, let removed, let files) = try read(later) {
                snapshot.sizes.merge(changed) { $1 }
                for key in removed { snapshot.sizes[key] = nil }
                snapshot.files = files
            }
        }
        return snapshot
    }

    private func read(_ day: Day) throws -> Entry {
        try PropertyListDecoder().decode(Entry.self, from: Data(contentsOf: url(day)))
    }

    private func save(_ entry: Entry, on day: Day) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(entry).write(to: url(day), options: .atomic)
    }

    private func url(_ day: Day) -> URL {
        directory.appending(path: day.fileName + ".plist")
    }
}
