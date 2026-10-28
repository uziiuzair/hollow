import Foundation

/// What the menu bar dropdown shows for one drive.
public struct DriveSummary: Codable, Sendable, Equatable {
    public var scannedBytes: UInt64
    public var kinds: [ContentKind: UInt64]
    /// At most 5 entries.
    public var changes: [Change]
    /// The root's size change over the period; nil when there is no history.
    public var net: Int64?
    public var period: Int
    public var updatedAt: Date

    public init(scannedBytes: UInt64, kinds: [ContentKind: UInt64], changes: [Change], net: Int64?, period: Int, updatedAt: Date) {
        self.scannedBytes = scannedBytes
        self.kinds = kinds
        self.changes = changes
        self.net = net
        self.period = period
        self.updatedAt = updatedAt
    }

    static func fileURL(in store: URL, period: Int) -> URL {
        store.appending(path: "summary-\(period).json")
    }

    public static func load(from store: URL, period: Int) -> DriveSummary? {
        guard let data = try? Data(contentsOf: fileURL(in: store, period: period)) else { return nil }
        let decoder = JSONDecoder()
        // Bit pattern, because JSON doubles can lose the last digit of a Date.
        decoder.dateDecodingStrategy = .custom { Date(timeIntervalSinceReferenceDate: Double(bitPattern: try $0.singleValueContainer().decode(UInt64.self))) }
        return try? decoder.decode(DriveSummary.self, from: data)
    }

    public func save(to store: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate.bitPattern)
        }
        try encoder.encode(self).write(to: Self.fileURL(in: store, period: period), options: .atomic)
    }
}

extension LiveIndex {
    /// Kinds, top changes and net change over the last `days` days, read under the index
    /// lock so it never sees a half-applied index.
    public func summary(since days: Int, now: Date = .now) async throws -> DriveSummary {
        await lock()
        defer { unlock() }
        guard let index else { preconditionFailure("LiveIndex used before open()") }
        let current = try SizeSnapshot.capture(index)
        var changes: [Change] = []
        var net: Int64?
        let today = Day(now, calendar: .current)
        if let then = try history.snapshot(onOrBefore: today.adding(days: -days, calendar: .current)) {
            changes = Array(ChangeReport.changes(from: then, to: current).prefix(5))
            net = Int64(bitPattern: index.folders[0].totalAllocated) - Int64(bitPattern: then.sizes[""] ?? 0)
        }
        return DriveSummary(
            scannedBytes: index.folders[0].totalAllocated, kinds: ContentKind.totals(in: index),
            changes: changes, net: net, period: days, updatedAt: now)
    }
}
