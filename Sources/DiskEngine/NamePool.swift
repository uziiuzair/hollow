/// Append-only store of names. Each entry is a little-endian UInt16 byte length
/// followed by the UTF-8 bytes; an offset counts bytes from the start of the pool.
///
/// The bytes live in fixed chunks of `chunkSize`. Growing adds a chunk and never
/// copies: a single doubling buffer freed every old copy on growth, and malloc kept
/// those freed blocks dirty (19-30 MB after a 1.8M-folder scan). An entry may
/// straddle two chunks.
public struct NamePool: Sendable {
    /// 64 KiB less the array header, so each chunk is exactly one 64 KiB allocation.
    static let chunkSize = 65_536 - 32

    /// Every chunk but the last is full.
    private var chunks: [ContiguousArray<UInt8>] = []
    public private(set) var byteCount = 0

    public init() {}

    public init<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        var rest = bytes[...]
        while !rest.isEmpty {
            var chunk = ContiguousArray<UInt8>()
            chunk.reserveCapacity(Self.chunkSize)
            chunk.append(contentsOf: rest.prefix(Self.chunkSize))
            rest = rest.dropFirst(chunk.count)
            chunks.append(chunk)
        }
        byteCount = bytes.count
    }

    /// Bytes the allocated chunks can hold.
    public var capacity: Int { chunks.reduce(0) { $0 + $1.capacity } }

    public mutating func append(_ name: String) -> UInt32 {
        let offset = UInt32(byteCount)
        var name = name
        name.withUTF8 { utf8 in
            let body = UnsafeBufferPointer(rebasing: utf8.prefix(Int(UInt16.max)))
            let length = UInt16(body.count)
            withUnsafeBytes(of: length.littleEndian) { append($0.assumingMemoryBound(to: UInt8.self)) }
            append(body)
        }
        return offset
    }

    private mutating func append(_ source: UnsafeBufferPointer<UInt8>) {
        var start = 0
        while start < source.count {
            if chunks.isEmpty || chunks[chunks.count - 1].count == Self.chunkSize {
                var chunk = ContiguousArray<UInt8>()
                chunk.reserveCapacity(Self.chunkSize)
                chunks.append(chunk)
            }
            let room = Self.chunkSize - chunks[chunks.count - 1].count
            let end = min(source.count, start + room)
            chunks[chunks.count - 1].append(contentsOf: UnsafeBufferPointer(rebasing: source[start..<end]))
            start = end
        }
        byteCount += source.count
    }

    public func byte(at offset: Int) -> UInt8 {
        chunks[offset / Self.chunkSize][offset % Self.chunkSize]
    }

    public func name(at offset: UInt32) -> String {
        let start = Int(offset)
        let length = Int(byte(at: start)) | Int(byte(at: start + 1)) << 8
        // An empty name can end exactly at the pool's last chunk boundary.
        guard length > 0 else { return "" }
        let first = start + 2
        let chunk = first / Self.chunkSize
        let inChunk = first % Self.chunkSize
        if inChunk + length <= Self.chunkSize {
            return String(decoding: chunks[chunk][inChunk..<(inChunk + length)], as: UTF8.self)
        }
        // Straddles a chunk boundary: join the two pieces.
        let head = chunks[chunk][inChunk...]
        let tail = chunks[chunk + 1][..<(length - head.count)]
        return String(decoding: Array(head) + Array(tail), as: UTF8.self)
    }

    /// Calls `body` with each chunk's bytes, in order; together they are the whole pool.
    public func forEachChunk(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        for chunk in chunks { try chunk.withUnsafeBytes(body) }
    }
}
