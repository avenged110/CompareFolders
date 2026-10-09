// MARK: - CopyPaths.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Puts the display paths of the selected rows on the pasteboard, one per line,
// and supplies the singular/plural title for the Copy command shared by the
// list's contextual menu and the View menu.

import AppKit

/// Puts the paths of selected rows on the pasteboard.
///
/// Offered from the list's contextual menu and from the View menu, which is
/// why the wording and the text itself are settled here rather than in either
/// of them: the two act on the same rows by the same rules, and a menu that
/// says "Path" over a selection of twelve is describing something else.
@MainActor
enum CopyPaths {
    /// The title of a Copy command, for a selection of `count` items.
    nonisolated static func menuTitle(count: Int) -> String {
        count > 1 ? "Copy Paths" : "Copy Path"
    }

    /// One path per line, in the order the rows were given.
    ///
    /// The display path, not either absolute one: it is what the list shows,
    /// what identifies the item in both folders at once, and what a user
    /// pasting into a note or a message is almost always after. The absolute
    /// paths are what Reveal is for.
    nonisolated static func text(for rows: [ComparisonRow]) -> String {
        rows.map(\.displayPath).joined(separator: "\n")
    }

    static func copy(_ rows: [ComparisonRow]) {
        let text = text(for: rows)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
