import Foundation
import DiskEngine

public struct KnownDrive: Codable, Sendable, Equatable {
    public let uuid: String
    public var name: String
    public var tintIndex: Int
    /// The Mac's own disk. Independent of the tint, which the user can change.
    public let isInternal: Bool
    public var lastSeen: Date
    public var lastFree: UInt64?
    public var lastTotal: UInt64?

    public init(uuid: String, name: String, tintIndex: Int, lastSeen: Date,
                lastFree: UInt64? = nil, lastTotal: UInt64? = nil, isInternal: Bool? = nil) {
        self.uuid = uuid
        self.name = name
        self.tintIndex = tintIndex
        self.isInternal = isInternal ?? (tintIndex == 0)
        self.lastSeen = lastSeen
        self.lastFree = lastFree
        self.lastTotal = lastTotal
    }

    private enum CodingKeys: String, CodingKey { case uuid, name, tintIndex, isInternal, lastSeen, lastFree, lastTotal }

    /// Files from before `isInternal` existed: tint 0 was the internal drive.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try c.decode(String.self, forKey: .name)
        tintIndex = try c.decode(Int.self, forKey: .tintIndex)
        isInternal = try c.decodeIfPresent(Bool.self, forKey: .isInternal) ?? (tintIndex == 0)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        lastFree = try c.decodeIfPresent(UInt64.self, forKey: .lastFree)
        lastTotal = try c.decodeIfPresent(UInt64.self, forKey: .lastTotal)
    }
}

public enum RegistryError: Error, Equatable, Sendable { case unknownDrive, tintOutOfRange }

/// Remembers every drive ever seen, keyed by volume UUID, persisted as JSON.
public final class DriveRegistry: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var drives: [KnownDrive]
    /// Mounted disk images: listed while mounted, never written to the file.
    private var images: Set<String> = []

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

    /// Adds or updates a drive. A disk image is kept in memory only, until `dropUnmountedImage`.
    public func upsert(_ v: VolumeInfo, space: VolumeSpace?, now: Date) throws -> KnownDrive {
        lock.lock(); defer { lock.unlock() }
        if v.isDiskImage { images.insert(v.uuid) }
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
                tintIndex: v.isInternalData ? 0 : Self.nextTint(used: next.map(\.tintIndex), externalCount: next.count),
                lastSeen: now,
                lastFree: space?.availableForImportantUsage, lastTotal: space?.total,
                isInternal: v.isInternalData)
            next.append(drive)
        }
        try write(next)
        drives = next
        return drive
    }

    /// Remembers the user's colour for a drive (0...7).
    public func setTint(uuid: String, index: Int) throws {
        guard (0...7).contains(index) else { throw RegistryError.tintOutOfRange }
        lock.lock(); defer { lock.unlock() }
        var next = drives
        guard let i = next.firstIndex(where: { $0.uuid == uuid }) else { throw RegistryError.unknownDrive }
        next[i].tintIndex = index
        try write(next)
        drives = next
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

    /// Forgets a disk image once it has unmounted (it was never written). Does nothing for a drive.
    public func dropUnmountedImage(uuid: String) {
        lock.lock(); defer { lock.unlock() }
        guard images.remove(uuid) != nil else { return }
        drives.removeAll { $0.uuid == uuid }
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
        let list = list.filter { !images.contains($0.uuid) }
        if list.isEmpty, !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) { return }
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
