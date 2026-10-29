// SPDX-License-Identifier: GPL-3.0-or-later

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
    /// The write call; replaceable in tests to simulate a full disk.
    var writer: (Int32, UnsafeRawPointer, Int, off_t) -> Int = { pwrite($0, $1, $2, $3) }

    convenience init(url: URL) throws {
        try self.init(url: url, keepingFirst: 0)
    }

    /// Opens an existing file (or creates one) and cuts it to `length` bytes, dropping
    /// anything written after the last committed length.
    init(url: URL, keepingFirst length: UInt64) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DiskEngineError.posix("open \(url.path)", errno) }
        guard ftruncate(fd, off_t(length)) == 0 else {
            let failure = errno
            close(fd)
            throw DiskEngineError.posix("ftruncate \(url.path)", failure)
        }
        flushedLength = length
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

    /// Flushes and forces the data to stable storage.
    func sync() throws {
        try flush()
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw DiskEngineError.posix("fsync", errno) }
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

    /// Writes all of `bytes` at the end, or nothing: on failure the file is cut back
    /// to its previous length so a retry writes at the same offset.
    private func write(_ bytes: UnsafeRawBufferPointer) throws {
        let start = flushedLength
        var done = 0
        while done < bytes.count {
            let n = writer(fd, bytes.baseAddress! + done, bytes.count - done, off_t(flushedLength))
            if n < 0 {
                if errno == EINTR { continue }
                let failure = errno
                ftruncate(fd, off_t(start))
                flushedLength = start
                throw DiskEngineError.posix("pwrite", failure)
            }
            done += n
            flushedLength += UInt64(n)
        }
    }
}
