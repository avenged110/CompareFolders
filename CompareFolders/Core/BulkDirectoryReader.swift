// MARK: - BulkDirectoryReader.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reads a directory's entries and their attributes together in batches via
// `getattrlistbulk`, cutting a large scan from millions of system calls to a
// few hundred. Reports failure on volumes that do not support it so the
// scanner can fall back to a plain `readdir` walk.

import Darwin
import Foundation
import System

/// Reads a directory's children — names *and* attributes together — with
/// `getattrlistbulk`.
///
/// The obvious way to walk a folder is `readdir` for the names and then one
/// `lstat` per name for the attributes, plus a `getattrlist` per file for the
/// resource fork. That is three system calls for every item, and on a folder
/// of a hundred thousand items the calls themselves, not the disk, are what
/// the scan is spent on.
///
/// `getattrlistbulk` answers the same questions for a whole batch of entries
/// at once: one call returns as many children as fit in the buffer, each with
/// every attribute the comparison needs already attached. A folder of a
/// hundred thousand items goes from roughly three hundred thousand calls to a
/// few hundred. Measured over Xcode's `Platforms` folder — 114,619 items — the
/// same walk takes 281 ms this way against 669 ms the old way, and produces
/// byte-identical attributes for every one of them.
///
/// Not every volume implements it, so this reports failure rather than
/// papering over it, and `DirectoryScanner` falls back to the `readdir` walk.
final class BulkDirectoryReader {

    /// One buffer for the whole scan rather than one per directory: a tree
    /// with twenty thousand folders in it would otherwise mean twenty thousand
    /// allocations of a quarter of a megabyte, which is its own kind of slow.
    ///
    /// 128 KB holds on the order of a thousand entries, so all but the largest
    /// directories are read in a single call.
    ///
    /// A byte array rather than raw memory: the kernel fills it through a
    /// pointer that lives only for the call, and every record is then read
    /// back through `Reply`, which checks each field against the array.
    private static let bufferSize = 128 * 1024
    private var buffer = [UInt8](repeating: 0, count: bufferSize)

    /// The attributes asked for, which must be requested as three separate
    /// groups because a directory and a file answer different ones.
    ///
    /// `ATTR_CMN_RETURNED_ATTRS` is what makes that safe: the kernel says, per
    /// entry, which attributes it actually supplied, and the reply is packed
    /// with only those present. A file therefore carries the two `ATTR_FILE_*`
    /// lengths where a directory carries neither, and the difference does not
    /// have to be guessed at from the record's size.
    private var attributes = attrlist(
        bitmapcount: u_short(ATTR_BIT_MAP_COUNT),
        reserved: 0,
        commonattr: attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
            | attrgroup_t(ATTR_CMN_CRTIME)
            | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FNDRINFO)
            | attrgroup_t(ATTR_CMN_OWNERID)
            | attrgroup_t(ATTR_CMN_GRPID)
            | attrgroup_t(ATTR_CMN_ACCESSMASK)
            | attrgroup_t(ATTR_CMN_ERROR),
        volattr: 0,
        dirattr: 0,
        fileattr: attrgroup_t(ATTR_FILE_DATALENGTH) | attrgroup_t(ATTR_FILE_RSRCLENGTH),
        forkattr: 0)

    /// Reads every child of `path`.
    ///
    /// - Returns: The children, or `nil` when this directory cannot be read
    ///   this way at all — an unopenable directory, or a volume that does not
    ///   implement `getattrlistbulk`. The caller is expected to fall back;
    ///   nothing has been reported and no entry has been produced, so the
    ///   fallback starts from a clean slate.
    func read(
        atPath path: String,
        parent: Int32,
        diagnostics: inout [Diagnostic]
    ) -> [ScanNode]? {
        // No `O_NOFOLLOW`: the caller reached this path because the object it
        // found *was* a directory, and a symlink is never descended into.
        guard let directory = try? FileDescriptor.open(
            FilePath(path), .readOnly, options: .directory) else { return nil }
        defer { try? directory.close() }

        var entries: [ScanNode] = []
        // Whether any batch has come back, which is what proves the volume
        // supports the call. Not `entries.isEmpty`: a batch holding only
        // sockets or FIFOs yields no entries, yet may already have raised
        // diagnostics, and falling back then would report them twice.
        var hasReadBatch = false
        while true {
            // The one unsafe step in the read: the call is handed a pointer
            // into `buffer` and its length together, both taken from the
            // array itself, so it cannot be told a size the array lacks.
            let count = unsafe buffer.withUnsafeMutableBytes { bytes in
                unsafe getattrlistbulk(
                    directory.rawValue, &attributes, bytes.baseAddress, bytes.count, 0)
            }

            if count < 0 {
                // A volume that does not implement the call fails on the very
                // first request, before a single entry has been handed back —
                // so nothing has been built yet and the caller can start over
                // on the fallback. A failure part way through is a real error
                // on a volume that does support it, and is reported exactly as
                // the `readdir` walk reports one: say so, and keep what was
                // read rather than silently truncating the folder.
                if !hasReadBatch { return nil }
                diagnostics.append(Diagnostic(
                    path: path, summary: "Could not finish reading folder",
                    code: errno))
                return entries
            }
            if count == 0 { break }  // End of the directory.
            hasReadBatch = true

            unsafe buffer.withUnsafeBytes { bytes in
                let reply = unsafe Reply(bytes)
                var record = 0
                for _ in 0 ..< count {
                    let length = Int(reply.load(fromByteOffset: record, as: UInt32.self))
                    decode(reply, recordAt: record, path: path, parent: parent,
                           into: &entries, diagnostics: &diagnostics)
                    record += length
                }
            }
        }
        return entries
    }

    // MARK: - One entry

    /// Unpacks one entry's record and appends it, if it is a kind we compare.
    ///
    /// The fields arrive in the fixed order the attribute bits are defined in,
    /// not the order they were asked for, and only those the kernel marked as
    /// returned are present at all — so the record is walked with a running
    /// offset rather than read at fixed positions.
    private func decode(
        _ reply: Reply,
        recordAt record: Int,
        path: String,
        parent: Int32,
        into entries: inout [ScanNode],
        diagnostics: inout [Diagnostic]
    ) {
        // Offsets from here on are from the start of the record.
        var offset = MemoryLayout<UInt32>.size  // Past the record's own length.
        func field<T: FixedWidthInteger & BitwiseCopyable>(at fieldOffset: Int, as _: T.Type) -> T {
            reply.load(fromByteOffset: record + fieldOffset, as: T.self)
        }
        func take<T: FixedWidthInteger & BitwiseCopyable>(_ type: T.Type) -> T {
            let value = field(at: offset, as: T.self)
            offset += MemoryLayout<T>.size
            return value
        }

        // Only two of the `attribute_set_t` groups are ever asked for.
        let returnedCommon = field(
            at: offset + MemoryLayout<attribute_set_t>.offset(of: \.commonattr)!,
            as: attrgroup_t.self)
        let returnedFile = field(
            at: offset + MemoryLayout<attribute_set_t>.offset(of: \.fileattr)!,
            as: attrgroup_t.self)
        offset += MemoryLayout<attribute_set_t>.size

        func has(_ bit: Int32) -> Bool { returnedCommon & attrgroup_t(bit) != 0 }
        func hasFile(_ bit: Int32) -> Bool { returnedFile & attrgroup_t(bit) != 0 }
        func takeTimespec() -> timespec {
            let seconds = take(Int.self)
            let nanoseconds = take(Int.self)
            return timespec(tv_sec: seconds, tv_nsec: nanoseconds)
        }

        // The one exception to bit order: `ATTR_CMN_ERROR`, when the kernel
        // returns it, sits directly after the returned-attributes set and
        // ahead of the name (getattrlistbulk(2)). Read anywhere else, an
        // entry that failed would have its error code taken for the name's
        // reference and every field after it read out of place.
        var failure: UInt32 = 0
        if has(ATTR_CMN_ERROR) { failure = take(UInt32.self) }

        // The name is the one attribute that cannot be missing and cannot be
        // recovered from anywhere else; without it there is nothing to report
        // and nothing to look up.
        guard has(ATTR_CMN_NAME) else { return }
        // An `attrreference_t`: where the name's bytes sit, counted from the
        // reference itself, and how many there are including the terminator.
        let nameFieldOffset = offset
        let nameDataOffset = take(Int32.self)
        let nameLength = take(UInt32.self)
        let nameStart = record + nameFieldOffset + Int(nameDataOffset)
        let name = reply.loadString(
            fromByteOffset: nameStart, maxLength: Int(nameLength))

        var objectType: fsobj_type_t = 0
        if has(ATTR_CMN_OBJTYPE) { objectType = take(fsobj_type_t.self) }
        var creation = timespec()
        if has(ATTR_CMN_CRTIME) { creation = takeTimespec() }
        var modification = timespec()
        if has(ATTR_CMN_MODTIME) { modification = takeTimespec() }
        var isAlias = false
        if has(ATTR_CMN_FNDRINFO) {
            // `FileInfo.finderFlags` is a big-endian UInt16 eight bytes into
            // the 32 bytes of Finder info, and `kIsAliasFile` is its 0x8000 bit.
            isAlias = UInt16(bigEndian: reply.load(
                fromByteOffset: record + offset + 8, as: UInt16.self)) & 0x8000 != 0
            offset += 32
        }
        var userID: uid_t = 0
        if has(ATTR_CMN_OWNERID) { userID = take(uid_t.self) }
        var groupID: gid_t = 0
        if has(ATTR_CMN_GRPID) { groupID = take(gid_t.self) }
        // `ATTR_CMN_ACCESSMASK` is the whole of `st_mode`, format bits included.
        var mode: UInt32 = 0
        if has(ATTR_CMN_ACCESSMASK) { mode = take(UInt32.self) }
        // The kernel could name this entry but not describe it — a vanished
        // file, or one on a mount it could not reach. Ask about it directly,
        // which either succeeds or produces the same diagnostic the `readdir`
        // walk would have.
        guard failure == 0,
              has(ATTR_CMN_OBJTYPE), has(ATTR_CMN_CRTIME), has(ATTR_CMN_MODTIME),
              has(ATTR_CMN_OWNERID), has(ATTR_CMN_GRPID), has(ATTR_CMN_ACCESSMASK),
              let kind = FileKind(objectType: objectType)
        else {
            // A socket, FIFO or device node is not an error and not a hole in
            // the comparison; it is simply not something with contents to
            // compare, and is dropped exactly as the fallback drops it.
            if failure == 0 && has(ATTR_CMN_OBJTYPE)
                && FileKind(objectType: objectType) == nil { return }
            appendByLookingUp(name: name, in: path, parent: parent,
                              into: &entries, diagnostics: &diagnostics)
            return
        }

        // Lengths are asked for, and returned, only for non-directories —
        // see `FileAttributes.dataSize`. A missing one is a zero, which is
        // what the volume is saying it has to offer.
        var dataSize: off_t = 0
        var resourceSize: off_t = 0
        if !kind.isDirectory {
            if hasFile(ATTR_FILE_DATALENGTH) { dataSize = take(off_t.self) }
            if hasFile(ATTR_FILE_RSRCLENGTH) { resourceSize = take(off_t.self) }
        }

        entries.append(ScanNode(
            name: name,
            attributes: FileAttributes(
                kind: kind,
                permissions: UInt16(truncatingIfNeeded: mode) & FileAttributes.allPermissions,
                userID: userID,
                groupID: groupID,
                creationDate: Timestamp(creation),
                modificationDate: Timestamp(modification),
                dataSize: UInt64(max(dataSize, 0)),
                // Only a regular file has either of these to answer for.
                resourceSize: kind.isFile ? UInt64(max(resourceSize, 0)) : 0,
                isAlias: kind.isFile && isAlias),
            parent: parent,
            childrenStart: 0,
            childrenCount: 0))
    }

    /// Falls back to a direct `lstat` for one entry the batch could not describe.
    private func appendByLookingUp(
        name: String,
        in path: String,
        parent: Int32,
        into entries: inout [ScanNode],
        diagnostics: inout [Diagnostic]
    ) {
        let childPath = path + "/" + name
        switch DirectoryScanner.lookUpAttributes(ofPath: childPath) {
        case .found(let attributes):
            entries.append(ScanNode(
                name: name, attributes: attributes,
                parent: parent, childrenStart: 0, childrenCount: 0))
        case .unsupportedKind:
            break
        case .failed(let code):
            diagnostics.append(Diagnostic(
                path: childPath, summary: "Could not read item", code: code))
        }
    }
}

/// One batch of `getattrlistbulk`'s reply, read with every field checked
/// against the bytes the batch actually occupies.
///
/// The kernel packs its records with no regard for alignment, hence the
/// unaligned loads. Each field is checked against the buffer before it is
/// read, in every build: a record that claims more than the buffer holds
/// stops the program rather than reading past it. That check is what makes
/// the loads safe; it is made once per field, which keeps a scan of a
/// hundred thousand items as fast as reading the pointer directly.
///
/// It lives only for the `withUnsafeBytes` call that creates it, which is
/// why it is private to this file and never stored.
@safe
private struct Reply {
    private let bytes: UnsafeRawBufferPointer

    init(_ bytes: UnsafeRawBufferPointer) { unsafe self.bytes = bytes }

    func load<T: BitwiseCopyable>(fromByteOffset offset: Int, as _: T.Type) -> T {
        unsafe precondition(offset >= 0 && offset <= bytes.count - MemoryLayout<T>.size,
                     "field lies outside the reply")
        return unsafe bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
    }

    /// The UTF-8 string starting at `offset`, ending at its terminator or
    /// after `maxLength` bytes, whichever comes first — never past either.
    func loadString(fromByteOffset offset: Int, maxLength: Int) -> String {
        unsafe precondition(offset >= 0 && maxLength >= 0 && offset <= bytes.count - maxLength,
                     "name lies outside the reply")
        let field = unsafe UnsafeRawBufferPointer(
            rebasing: bytes[offset ..< offset + maxLength])
        let end = unsafe field.firstIndex(of: 0) ?? field.count
        return unsafe String(decoding: field[..<end], as: UTF8.self)
    }
}

private extension FileKind {
    /// Maps `ATTR_CMN_OBJTYPE`'s `vnode` type onto a kind, recognizing exactly
    /// the three `FileKind(mode:)` does.
    init?(objectType: fsobj_type_t) {
        switch objectType {
        case fsobj_type_t(VDIR.rawValue): self = .directory
        case fsobj_type_t(VREG.rawValue): self = .file
        case fsobj_type_t(VLNK.rawValue): self = .symbolicLink
        default: return nil
        }
    }
}
