// MARK: - ComparisonMode.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The `FolderSide` and `ComparisonMode` enums — which side a folder sits on,
// and whether the engine compares only file-system metadata (heuristic) or also
// reads every matched pair byte-for-byte. Carries the user-facing title and
// help text for each mode.

import Foundation

/// Which side of a comparison a folder sits on.
enum FolderSide: Hashable, Sendable {
    case left, right
}

/// How hard the engine works to decide whether two files are the same.
enum ComparisonMode: String, CaseIterable, Identifiable, Sendable {
    /// Compare only what the file system already knows: size and timestamps.
    /// No file is ever opened, so this costs no I/O beyond listing the folders.
    case heuristic

    /// Read both files and compare them in full. Cannot miss a difference.
    case byteForByte = "checksum"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristic: "Heuristics"
        case .byteForByte: "Byte-for-Byte"
        }
    }

    var help: String {
        switch self {
        case .heuristic:
            """
            Compares what the file system already records — size, modification \
            date and creation date. Reads no file contents, so it is close to \
            instant, and it catches essentially every real change.
            """
        case .byteForByte:
            """
            Additionally reads every matched pair of files and compares them \
            byte for byte. Cannot miss a difference, but has to read both \
            folders in full.
            """
        }
    }

    var engineOptions: ComparisonOptions {
        self == .byteForByte ? [.fileContent] : []
    }
}
