// MARK: - FileAttributes.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Low-level, POSIX-faithful description of a single file-system object — its
// kind, permissions, ownership, timestamps, and sizes — as read from the file
// system. Also defines `FileKind` and the whole-second timestamp type the
// comparison reasons about.

import Darwin
import Foundation

/// The kind of file-system object, mirroring the `S_IFMT` classes the
/// comparison engine knows how to reason about.
///
/// Anything that is not a directory, a regular file or a symbolic link is
/// deliberately ignored during scanning, exactly as the reference
/// implementation does: sockets, FIFOs and device nodes have no meaningful
/// "contents" to diff, and silently skipping them keeps the results honest.
enum FileKind: UInt8, Sendable, Hashable {
    case directory
    case file
    case symbolicLink

    /// Maps a raw `st_mode` value onto a kind.
    init?(mode: mode_t) {
        switch mode & S_IFMT {
        case S_IFDIR: self = .directory
        case S_IFREG: self = .file
        case S_IFLNK: self = .symbolicLink
        default: return nil
        }
    }

    var isDirectory: Bool { self == .directory }
    var isFile: Bool { self == .file }
    var isSymbolicLink: Bool { self == .symbolicLink }
}

/// A whole-second timestamp.
///
/// HFS+ only ever stored second precision, and even on APFS sub-second
/// timestamps are not preserved when files are copied or restored from a
/// backup. Comparing at sub-second resolution therefore produces a flood of
/// false "modified" reports, so — like the reference application — we
/// deliberately truncate to seconds.
struct Timestamp: Sendable, Hashable {
    var seconds: Int64

    init(seconds: Int64) { self.seconds = seconds }
    init(_ spec: timespec) { self.seconds = Int64(spec.tv_sec) }

    /// False when the volume never recorded this timestamp at all.
    ///
    /// Creation dates are the case that matters: several file systems — most
    /// network shares, and anything served over MS-DOS or exFAT — have no
    /// birth time to report, and `getattrlist` answers with the epoch rather
    /// than with an error. That zero is the absence of an answer, not a date,
    /// and comparing it against a real one says nothing true about the two
    /// files.
    var isRecorded: Bool { seconds > 0 }
}

/// Everything the engine needs to know about an object, captured in one pass.
///
/// This is a plain value type with no references, which is what lets the whole
/// scan cross concurrency domains for free under Swift 6's strict checking.
struct FileAttributes: Sendable, Hashable {
    var kind: FileKind
    /// POSIX permission bits only (`ALLPERMS`), with the format bits masked off.
    var permissions: UInt16
    var userID: UInt32
    var groupID: UInt32
    var creationDate: Timestamp
    var modificationDate: Timestamp
    /// Size of the data fork. For symbolic links this is the length of the
    /// target path.
    ///
    /// Always zero for a directory. What a volume reports as a directory's
    /// size describes how it stores that directory's index, not what is in it,
    /// so it is neither compared nor shown — and the two ways of asking for it
    /// do not always agree, `lstat` and `getattrlist` differing on the odd
    /// directory. Rather than carry a number that means nothing and is not
    /// even stable between the two readers, there is no number.
    var dataSize: UInt64
    /// Size of the (essentially vestigial, but still occasionally present) resource fork.
    var resourceSize: UInt64
    /// True for a Finder alias — a regular file whose whole content is a
    /// pointer to another item. Presentation only: the engine compares an
    /// alias exactly as it compares any other file.
    var isAlias = false

    /// `ALLPERMS` from <sys/stat.h>: setuid, setgid, sticky and the nine rwx bits.
    /// Written out because the macro does not import into Swift.
    static let allPermissions: UInt16 = 0o7777
}
