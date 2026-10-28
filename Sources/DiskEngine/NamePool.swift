/// Append-only store of names. Each entry is a little-endian UInt16 byte length
/// followed by the UTF-8 bytes.
public struct NamePool: Sendable {
    private var bytes: [UInt8] = []

    public init() {}

    public var byteCount: Int { bytes.count }

    public mutating func append(_ name: String) -> UInt32 {
        let offset = UInt32(bytes.count)
        let utf8 = Array(name.utf8.prefix(Int(UInt16.max)))
        let length = UInt16(utf8.count)
        bytes.append(UInt8(length & 0xFF))
        bytes.append(UInt8(length >> 8))
        bytes.append(contentsOf: utf8)
        return offset
    }

    public func name(at offset: UInt32) -> String {
        let start = Int(offset)
        let length = Int(bytes[start]) | Int(bytes[start + 1]) << 8
        return String(decoding: bytes[(start + 2)..<(start + 2 + length)], as: UTF8.self)
    }
}
