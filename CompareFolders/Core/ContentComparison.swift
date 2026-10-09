// MARK: - ContentComparison.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Byte-exact comparison of two files and their resource forks, stopping at the
// first differing byte. This is the path that guarantees no difference is
// missed, with its reads tuned to the slower of the two storage devices involved.

import Darwin
import Foundation
import System

/// Byte-exact comparison of two files.
///
/// This is the "guaranteed to catch any difference" path. It compares the two
/// files directly rather than hashing them, which is both faster and stronger:
/// there is no checksum to compute over the whole of both files, it stops at
/// the first differing byte, and — unlike a digest — it cannot report a
/// collision as a match.
enum ContentComparison {

    /// 256 KB. Large enough to keep spinning disks streaming, and past the
    /// point where a bigger buffer buys anything on an SSD.
    private static let bufferSize = 256 * 1024

    /// The suffix that addresses a file's resource fork as if it were a file.
    private static let resourceForkSuffix = "/..namedfork/rsrc"

    /// Compares the payload of two items that are known to be the same kind.
    ///
    /// - Parameters:
    ///   - medium: The slower of the two devices involved, which decides how
    ///     the reads are issued.
    ///   - onBytesCompared: Raised as the reads proceed, with the number of
    ///     bytes just settled. Called from whichever thread is doing the
    ///     reading, so it must be safe to call from several at once. It exists
    ///     so that the readout keeps moving *inside* a single large file
    ///     rather than only when the file finishes.
    /// - Returns: The content flags that differ, any diagnostics raised, and
    ///   the number of bytes actually compared — which falls short of the
    ///   files' size whenever a difference was found part-way through and the
    ///   read stopped there.
    static func compare(
        left: String,
        right: String,
        attributes: FileAttributes,
        otherAttributes: FileAttributes,
        medium: StorageMedium,
        cancellation: CancellationFlag,
        onBytesCompared: @Sendable (UInt64) -> Void = { _ in }
    ) -> (flags: ComparisonFlags, diagnostics: [Diagnostic], bytesCompared: UInt64) {
        var flags: ComparisonFlags = []
        var diagnostics: [Diagnostic] = []
        var bytesCompared: UInt64 = 0

        if attributes.kind.isSymbolicLink {
            // A symlink's "content" is the path it points at.
            if attributes.dataSize != otherAttributes.dataSize
                || !sameTarget(left, right, &diagnostics) {
                flags.insert(.dataContent)
            }
            return (flags, diagnostics, 0)
        }

        // A size difference is already proof of a content difference, and
        // checking it first means differing files usually cost no reads at all.
        if attributes.dataSize != otherAttributes.dataSize {
            flags.insert(.dataContent)
        } else if attributes.dataSize > 0 {
            let outcome = sameBytes(
                left, right, &diagnostics, medium, cancellation, onBytesCompared)
            bytesCompared += outcome.bytesCompared
            if !outcome.same { flags.insert(.dataContent) }
        }

        if attributes.resourceSize != otherAttributes.resourceSize {
            flags.insert(.resourceContent)
        } else if attributes.resourceSize > 0 {
            let outcome = sameBytes(
                left + resourceForkSuffix, right + resourceForkSuffix,
                &diagnostics, medium, cancellation, onBytesCompared)
            bytesCompared += outcome.bytesCompared
            if !outcome.same { flags.insert(.resourceContent) }
        }

        return (flags, diagnostics, bytesCompared)
    }

    // MARK: - Symbolic links

    /// `true` when both symlinks resolve to the same literal target path.
    private static func sameTarget(
        _ left: String, _ right: String, _ diagnostics: inout [Diagnostic]
    ) -> Bool {
        guard let leftTarget = readLink(left, &diagnostics),
              let rightTarget = readLink(right, &diagnostics) else { return false }
        return leftTarget == rightTarget
    }

    private static func readLink(
        _ path: String, _ diagnostics: inout [Diagnostic]
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        // One short of the buffer, which keeps a terminator after whatever
        // `readlink` writes; the length it returns is what is decoded.
        let length = unsafe path.withCString { cPath in
            unsafe buffer.withUnsafeMutableBufferPointer { target in
                unsafe readlink(cPath, target.baseAddress, target.count - 1)
            }
        }
        guard length >= 0 else {
            diagnostics.append(Diagnostic(
                path: path, summary: "Could not read symbolic link", code: errno))
            return nil
        }
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    // MARK: - Regular files

    /// Whether both files hold exactly the same bytes, and how many were read
    /// to find out.
    ///
    /// Any failure to read either side reports "not the same" — an unreadable
    /// file is reported as a difference rather than quietly assumed to match,
    /// and the reason is recorded as a diagnostic. A canceled comparison
    /// reports the same, and no diagnostic: whatever it reports is thrown away
    /// by the caller, which never delivers the results of a canceled run.
    private static func sameBytes(
        _ left: String, _ right: String, _ diagnostics: inout [Diagnostic],
        _ medium: StorageMedium,
        _ cancellation: CancellationFlag,
        _ onBytesCompared: @Sendable (UInt64) -> Void
    ) -> (same: Bool, bytesCompared: UInt64) {
        guard let leftFile = openForReading(left, medium, &diagnostics) else {
            return (false, 0)
        }
        defer { close(leftFile) }
        guard let rightFile = openForReading(right, medium, &diagnostics) else {
            return (false, 0)
        }
        defer { close(rightFile) }

        // The one case where two paths can be proved identical without reading
        // anything: they are the same file. A hard link, or one volume mounted
        // at two places, makes this real rather than hypothetical, and it is a
        // proof rather than a guess — there is only one set of bytes.
        if let identity = sameFile(leftFile, rightFile), identity {
            return (true, 0)
        }

        let leftBuffer = buffers.take()
        defer { buffers.give(leftBuffer) }
        let rightBuffer = buffers.take()
        defer { buffers.give(rightBuffer) }

        let partner = PartnerRead(descriptor: rightFile, buffer: rightBuffer)
        var compared: UInt64 = 0

        while true {
            // A single pair of multi-gigabyte files would otherwise be read to
            // the end no matter what: this is the only place a long comparison
            // can notice that it has been stopped.
            if cancellation.isCanceled { return (false, compared) }

            // Both sides at once. Read one after the other, every block costs
            // the sum of the two devices' latencies instead of the greater of
            // them — which on two network shares is simply double the time,
            // for two reads that have nothing to do with each other.
            let group = DispatchGroup()
            readQueue.async(group: group) { partner.perform() }
            let leftCount = readFully(leftFile, leftBuffer)
            // Taken here, not after the failure is noticed: `errno` is
            // thread-local and `group.wait()` is itself a system call, so by
            // the time both counts are in hand this thread's `errno` may
            // already describe something else entirely.
            let leftError = leftCount < 0 ? errno : 0
            group.wait()
            let rightCount = partner.count

            if leftCount < 0 || rightCount < 0 {
                // The right-hand side was read on another thread, and `errno`
                // does not cross one — the partner records its own.
                diagnostics.append(Diagnostic(
                    path: leftCount < 0 ? left : right,
                    summary: "Could not read file",
                    code: leftCount < 0 ? leftError : partner.errorCode))
                return (false, compared)
            }
            if leftCount != rightCount { return (false, compared) }
            if leftCount == 0 { return (true, compared) }  // Both hit the end together.
            if !leftBuffer.hasSamePrefix(as: rightBuffer, length: leftCount) {
                return (false, compared)
            }

            compared += UInt64(leftCount)
            onBytesCompared(UInt64(leftCount))
        }
    }

    /// Whether two open descriptors refer to one and the same file.
    ///
    /// - Returns: `nil` if either side could not be interrogated, in which
    ///   case the answer is simply unknown and the bytes get read as usual.
    private static func sameFile(_ first: Int32, _ second: Int32) -> Bool? {
        var firstInfo = stat()
        var secondInfo = stat()
        guard unsafe fstat(first, &firstInfo) == 0,
              unsafe fstat(second, &secondInfo) == 0 else {
            return nil
        }
        return firstInfo.st_dev == secondInfo.st_dev
            && firstInfo.st_ino == secondInfo.st_ino
    }

    /// The right-hand side of one block, read on a thread of its own.
    ///
    /// A box rather than a captured variable because the buffer is not
    /// `Sendable`, and cannot cross into a `@Sendable` closure on its own. It is
    /// safe here for a reason the compiler cannot see: only one thread touches
    /// the box at a time — the partner writes `count` before the group
    /// completes, and the caller reads it only after waiting on that group.
    private final class PartnerRead: @unchecked Sendable {
        private let descriptor: Int32
        private let buffer: ReadBuffer
        private(set) var count = 0
        /// The `errno` of a failed read, carried back explicitly because
        /// `errno` is per-thread and this read happens on a thread of its own.
        private(set) var errorCode: Int32 = 0

        init(descriptor: Int32, buffer: ReadBuffer) {
            self.descriptor = descriptor
            self.buffer = buffer
        }

        func perform() {
            count = readFully(descriptor, buffer)
            errorCode = count < 0 ? errno : 0
        }
    }

    /// Where the second side of each pair is read.
    ///
    /// Its own queue rather than the global one, so that these short reads are
    /// never queued behind the long-running jobs that occupy the global pool
    /// for the whole of a file.
    private static let readQueue = DispatchQueue(
        label: "ContentComparison.read", qos: .userInitiated, attributes: .concurrent)

    /// Opens a file for reading, tuned for a single sequential streaming pass.
    private static func openForReading(
        _ path: String, _ medium: StorageMedium, _ diagnostics: inout [Diagnostic]
    ) -> Int32? {
        let descriptor: Int32
        do {
            descriptor = try FileDescriptor.open(
                FilePath(path), .readOnly, options: .noFollow).rawValue
        } catch {
            diagnostics.append(Diagnostic(
                path: path, summary: "Could not open file",
                code: (error as? Errno)?.rawValue ?? 0))
            return nil
        }
        // On a local device these files are read once and never looked at
        // again, so keeping them out of the unified buffer cache avoids
        // evicting everything the user actually has open, and read-ahead keeps
        // the sequential scan fed. On a network share both settings are
        // actively harmful — see `StorageMedium.bypassesCache` — and asking
        // for read-ahead means nothing once the cache they feed is bypassed.
        if medium.bypassesCache {
            _ = fcntl(descriptor, F_NOCACHE, 1)
            _ = fcntl(descriptor, F_RDAHEAD, 1)
        }
        return descriptor
    }

    // MARK: - Buffers

    /// The read buffers, handed out and taken back rather than allocated per file.
    ///
    /// Half a megabyte a pair, allocated and released again for every file
    /// compared, is not free: an allocation this size is served by `mmap`
    /// rather than out of the heap, so each pair costs four trips into the
    /// kernel and — because the mapping is fresh every time — a hundred and
    /// twenty-eight page faults as the reads first touch it. Over a folder of
    /// several thousand small files that is a great deal of work done for
    /// memory that is being asked for and given back over and over.
    ///
    /// Handing the same buffers round instead makes the pages resident once.
    /// At most `contentWidth` pairs read at a time, so the pool settles at a
    /// handful of buffers on its own; the cap is there only so that nothing
    /// unforeseen can make it grow without bound.
    private static let buffers = BufferPool(byteCount: bufferSize)

    private final class BufferPool: @unchecked Sendable {
        private let byteCount: Int
        private let lock = NSLock()
        /// Guarded by `lock`.
        private var free: [ReadBuffer] = []

        /// Comfortably above the widest content phase, which is the network
        /// case's sixteen pairs — thirty-two buffers — and reached only if
        /// something else ever shares the pool.
        ///
        /// It has to clear that figure, not merely approach it: a cap below the
        /// number of buffers actually in flight is returned to on every single
        /// hand-back, so the pool would free and re-allocate a buffer per file
        /// and undo the very cost it exists to avoid — on the one medium whose
        /// reads are slowest to begin with.
        private static let limit = 40

        init(byteCount: Int) { self.byteCount = byteCount }

        func take() -> ReadBuffer {
            lock.lock()
            let reused = free.popLast()
            lock.unlock()
            return reused ?? ReadBuffer(byteCount: byteCount)
        }

        /// A buffer past the cap is simply dropped, which frees it.
        func give(_ buffer: ReadBuffer) {
            lock.lock()
            if free.count < Self.limit { free.append(buffer) }
            lock.unlock()
        }
    }

    /// One read buffer, owning memory the size of a block.
    ///
    /// Raw memory rather than a `[UInt8]` for the two things the pool relies
    /// on: its address never moves, and the allocation is never silently
    /// copied — which an array shared for a moment between the pool and a
    /// reader would be, on its next write. Nothing outside this type ever sees
    /// the pointer. Every length it is handed is checked against its own
    /// size, and the memory lives exactly as long as the object does, so its
    /// interface is safe to use without an `unsafe` in sight.
    @safe
    final class ReadBuffer {
        let byteCount: Int
        private let storage: UnsafeMutableRawPointer

        init(byteCount: Int) {
            self.byteCount = byteCount
            unsafe storage = .allocate(byteCount: byteCount, alignment: 16)
        }

        deinit { unsafe storage.deallocate() }

        /// One `read` into the buffer from `offset` onward.
        ///
        /// - Returns: What `read` returned: bytes read, 0 at end of file, or
        ///   -1 with `errno` set.
        func read(from descriptor: Int32, atByteOffset offset: Int) -> Int {
            precondition(offset >= 0 && offset <= byteCount)
            return unsafe Darwin.read(descriptor, storage + offset, byteCount - offset)
        }

        /// Whether the first `length` bytes of the two buffers are equal.
        func hasSamePrefix(as other: ReadBuffer, length: Int) -> Bool {
            precondition(length >= 0 && length <= byteCount && length <= other.byteCount)
            return unsafe memcmp(storage, other.storage, length) == 0
        }
    }

    /// Fills `buffer` completely unless the end of the file is reached.
    ///
    /// A short `read` is legal at any time and does not mean end-of-file, so
    /// comparing raw `read` results directly would falsely report two
    /// identical files as different whenever the two sides happened to return
    /// different amounts. Looping until the buffer is full removes that
    /// possibility entirely.
    ///
    /// - Returns: Bytes read, 0 at end of file, or -1 on error.
    private static func readFully(
        _ descriptor: Int32, _ buffer: ReadBuffer
    ) -> Int {
        var total = 0
        while total < buffer.byteCount {
            let count = buffer.read(from: descriptor, atByteOffset: total)
            if count < 0 {
                if errno == EINTR { continue }
                return -1
            }
            if count == 0 { break }  // End of file.
            total += count
        }
        return total
    }
}
