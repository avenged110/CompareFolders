// MARK: - ComparisonRow.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The value type for one line of the comparison — a single item as it exists on
// each side, with its paths, attributes, and difference flags. Each row carries
// its own copies so the scanned trees can be released once the comparison ends.

import Foundation

/// One line of the comparison: a single item, as it exists on each side.
///
/// Rows carry their own copies of the paths and attributes they display rather
/// than pointing back into the scanned trees. Each row is a couple of hundred
/// bytes, which is a very cheap price for letting the trees be released as
/// soon as the comparison ends and for making the table's data a plain,
/// self-contained array.
struct ComparisonRow: Identifiable, Sendable {
    /// Position in the full, unfiltered result. Stable, and unique per result set.
    let id: Int32
    /// Everything that differs about this item. Empty means identical.
    var flags: ComparisonFlags
    /// The kind of object this is. For a `.replaced` row, the left side's kind.
    let kind: FileKind

    /// Path relative to the left root, or `nil` if the item is not on the left.
    let leftPath: String?
    /// Path relative to the right root, or `nil` if the item is not on the right.
    let rightPath: String?
    let leftAttributes: FileAttributes?
    let rightAttributes: FileAttributes?

    /// The path to show, from whichever side exists.
    ///
    /// The final component alone — what the list actually draws — is
    /// `displayName`, in `RowStatus.swift` alongside the rest of the row's
    /// presentation.
    var displayPath: String { leftPath ?? rightPath ?? "" }

    var isIdentical: Bool { flags.isIdentical }
    var existsOnLeft: Bool { leftPath != nil }
    var existsOnRight: Bool { rightPath != nil }

    /// The row this one sits inside, or `-1` for a top-level item.
    ///
    /// Carried so the results can be rebuilt as a tree for the outline view
    /// without re-deriving the hierarchy from path strings.
    let parent: Int32

    /// How deeply this item is nested below the root. Top-level items are 0.
    ///
    /// Stored rather than derived so the list can indent rows without walking
    /// a path string on every redraw.
    let depth: Int32

    /// True when any path component starts with a dot.
    ///
    /// Computed once at construction because the "hide hidden items" filter
    /// would otherwise re-derive it for every row on every keystroke.
    let isHidden: Bool
}

/// A finished comparison.
struct ComparisonResults: Sendable {
    var leftRoot: String
    var rightRoot: String
    var rows: [ComparisonRow]
    var diagnostics: [Diagnostic]

    static let empty = ComparisonResults(
        leftRoot: "", rightRoot: "", rows: [], diagnostics: [])

    /// True when anything was refused for permission reasons.
    ///
    /// This is worth singling out because of how it fails: the chosen folder
    /// itself usually stats successfully while everything inside it is denied,
    /// so the comparison completes, reports almost no items, and looks for all
    /// the world like two folders that simply match.
    var hasAccessFailures: Bool {
        diagnostics.contains { $0.code == EPERM || $0.code == EACCES }
    }

    func absoluteLeftPath(of row: ComparisonRow) -> String? {
        row.leftPath.map { leftRoot + "/" + $0 }
    }

    func absoluteRightPath(of row: ComparisonRow) -> String? {
        row.rightPath.map { rightRoot + "/" + $0 }
    }
}
