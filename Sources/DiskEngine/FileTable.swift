import Foundation

/// Stored files (24-byte records) and their names, both on disk and memory-mapped.
/// Names use the same encoding as `NamePool`.
public final class FileTable {
    private let records: MappedAppendFile
    private let names: MappedAppendFile
    public private(set) var count = 0

    public init(directory: URL) throws {
        records = try MappedAppendFile(url: directory.appending(path: "files.bin"))
        names = try MappedAppendFile(url: directory.appending(path: "filenames.bin"))
    }

    public func append(name: String, record: FileRecord) throws -> FileIndex {
        var record = record
        let utf8 = Array(name.utf8.prefix(Int(UInt16.max)))
        let length = UInt16(utf8.count)
        record.nameOffset = UInt32(names.length)
        try withUnsafeBytes(of: length.littleEndian) { _ = try names.append($0) }
        try utf8.withUnsafeBytes { _ = try names.append($0) }
        try withUnsafeBytes(of: record) { _ = try records.append($0) }
        count += 1
        return FileIndex(count - 1)
    }

    public func record(_ i: FileIndex) throws -> FileRecord {
        try records.withMappedBytes {
            $0.loadUnaligned(fromByteOffset: Int(i) * MemoryLayout<FileRecord>.stride, as: FileRecord.self)
        }
    }

    public func name(_ i: FileIndex) throws -> String {
        let offset = Int(try record(i).nameOffset)
        return try names.withMappedBytes { bytes in
            let length = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[(offset + 2)..<(offset + 2 + length)]), as: UTF8.self)
        }
    }
}
