import Darwin
import Foundation

public enum DiskEngineError: Error {
    case posix(String, Int32)
    case notADirectory(String)
}

/// A file that is written by appending through a 1 MB buffer and read through a
/// read-only memory map. Mapped pages are clean, so macOS can drop them under
/// memory pressure instead of swapping.
final class MappedAppendFile {
    private static let bufferCapacity = 1 << 20

    private let fd: Int32
    private var buffer: [UInt8] = []
    private var flushedLength: UInt64 = 0
    private var map: UnsafeMutableRawPointer?
    private var mappedLength: Int = 0

    init(url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DiskEngineError.posix("open \(url.path)", errno) }
        buffer.reserveCapacity(Self.bufferCapacity)
    }

    deinit {
        if let map { munmap(map, mappedLength) }
        close(fd)
    }

    var length: UInt64 { flushedLength + UInt64(buffer.count) }

    @discardableResult
    func append(_ bytes: UnsafeRawBufferPointer) throws -> UInt64 {
        let offset = length
        if buffer.count + bytes.count > Self.bufferCapacity { try flush() }
        if bytes.count > Self.bufferCapacity {
            try write(bytes)
        } else {
            buffer.append(contentsOf: bytes)
        }
        return offset
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBytes { try write($0) }
        buffer.removeAll(keepingCapacity: true)
    }

    func withMappedBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try flush()
        let wanted = Int(flushedLength)
        if wanted != mappedLength {
            if let map { munmap(map, mappedLength) }
            map = nil
            mappedLength = 0
            if wanted > 0 {
                let p = mmap(nil, wanted, PROT_READ, MAP_PRIVATE, fd, 0)
                guard let p, p != MAP_FAILED else { throw DiskEngineError.posix("mmap", errno) }
                map = p
                mappedLength = wanted
            }
        }
        return try body(UnsafeRawBufferPointer(start: map, count: mappedLength))
    }

    private func write(_ bytes: UnsafeRawBufferPointer) throws {
        var done = 0
        while done < bytes.count {
            let n = pwrite(fd, bytes.baseAddress! + done, bytes.count - done, off_t(flushedLength))
            if n < 0 {
                if errno == EINTR { continue }
                throw DiskEngineError.posix("pwrite", errno)
            }
            done += n
            flushedLength += UInt64(n)
        }
    }
}
