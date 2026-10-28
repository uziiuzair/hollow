import Foundation
import DiskEngine

public struct KnownDrive: Codable, Sendable, Equatable {
    public let uuid: String
    public var name: String
    public var tintIndex: Int
    public var lastSeen: Date
    public var lastFree: UInt64?
    public var lastTotal: UInt64?

    public init(uuid: String, name: String, tintIndex: Int, lastSeen: Date,
                lastFree: UInt64? = nil, lastTotal: UInt64? = nil) {
        self.uuid = uuid
        self.name = name
        self.tintIndex = tintIndex
        self.lastSeen = lastSeen
        self.lastFree = lastFree
        self.lastTotal = lastTotal
    }
}

/// Remembers every drive ever seen, keyed by volume UUID, persisted as JSON.
public final class DriveRegistry: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var drives: [KnownDrive]

    public init(file: URL) {
        self.file = file
        drives = Self.load(file)
    }

    /// Absent file: start empty. Present but unreadable or undecodable: move it
    /// aside to `<name>.corrupt` (replacing any older one) and start empty.
    private static func load(_ file: URL) -> [KnownDrive] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path(percentEncoded: false)) else { return [] }
        if let data = try? Data(contentsOf: file),
           let decoded = try? decoder.decode([KnownDrive].self, from: data) {
            return decoded
        }
        let aside = file.appendingPathExtension("corrupt")
        try? fm.removeItem(at: aside)
        try? fm.moveItem(at: file, to: aside)
        return []
    }

    public func upsert(_ v: VolumeInfo, space: VolumeSpace?, now: Date) throws -> KnownDrive {
        lock.lock(); defer { lock.unlock() }
        var next = drives
        let drive: KnownDrive
        if let i = next.firstIndex(where: { $0.uuid == v.uuid }) {
            next[i].name = v.name
            next[i].lastSeen = now
            if let space {
                next[i].lastFree = space.availableForImportantUsage
                next[i].lastTotal = space.total
            }
            drive = next[i]
        } else {
            drive = KnownDrive(
                uuid: v.uuid, name: v.name,
                tintIndex: v.isInternalData ? 0 : Self.nextTint(used: next.filter { $0.tintIndex != 0 }.map(\.tintIndex),
                                                                externalCount: next.count),
                lastSeen: now,
                lastFree: space?.availableForImportantUsage, lastTotal: space?.total)
            next.append(drive)
        }
        try write(next)
        drives = next
        return drive
    }

    /// Moves a known drive's `lastSeen` forward in memory only; the next write saves it.
    public func markSeen(_ uuid: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        if let i = drives.firstIndex(where: { $0.uuid == uuid }), drives[i].lastSeen < now { drives[i].lastSeen = now }
    }

    /// True when `upsert` would add the drive or change its name.
    public func needsWrite(for v: VolumeInfo) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return drives.first(where: { $0.uuid == v.uuid })?.name != v.name
    }

    public func all() -> [KnownDrive] {
        lock.lock(); defer { lock.unlock() }
        return drives
    }

    public func forget(uuid: String) throws {
        lock.lock(); defer { lock.unlock() }
        let next = drives.filter { $0.uuid != uuid }
        try write(next)
        drives = next
    }

    /// Lowest unused index in 1...7, else wrap around by external count.
    private static func nextTint(used: [Int], externalCount: Int) -> Int {
        if let free = (1...7).first(where: { !used.contains($0) }) { return free }
        return 1 + (externalCount % 7)
    }

    private func write(_ list: [KnownDrive]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(list).write(to: file, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
