// MARK: - RevealInFinder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Shows the selected items in the Finder, working out how many Finder windows
// that would open — one per containing folder — and asking first when a
// scattered selection would open a great many.

import AppKit
import Foundation

/// Shows selected items in the Finder, asking first when that would mean
/// opening a great many windows.
///
/// `activateFileViewerSelecting` opens one window per containing folder, and
/// selects within it every item that lives there. For a selection that all
/// came from one folder that is a single window — which is the common case,
/// and never worth interrupting. For a selection gathered from all over a
/// large comparison it is one window per folder, and a user who picked two
/// hundred scattered rows and pressed a menu item has no reason to expect
/// their screen to fill up.
@MainActor
enum RevealInFinder {

    /// Below this many items nothing is asked, however scattered they are.
    ///
    /// Five windows is a mess but a recoverable one, and stopping to ask about
    /// two or three would be the more annoying of the two failures.
    private nonisolated static let itemsBeforeAsking = 5

    /// What revealing a particular set of items would entail, and how to put
    /// that to the user.
    ///
    /// Separated from the revealing itself so the arithmetic — which windows
    /// count, and when the count is worth stopping for — can be checked
    /// without a Finder or a screen.
    nonisolated struct Plan: Equatable {
        /// How many items were asked for.
        let items: Int
        /// How many Finder windows they would open: one per containing folder.
        let windows: Int

        /// Scattered *and* numerous. Either alone is unremarkable — a hundred
        /// items from one folder is a single window, and three items from
        /// three folders is three windows nobody minds.
        var needsConfirmation: Bool { items > itemsBeforeAsking && windows > 1 }

        var question: String { "Reveal \(items.formatted()) Items in Finder?" }
        var explanation: String {
            "This will open \(windows.formatted()) separate Finder windows."
        }
    }

    /// The title of a Reveal command, for a selection of `count` items.
    ///
    /// Shared by the View menu and the list's contextual menu so the two are
    /// worded identically, and so the plural is decided in exactly one place:
    /// they act on the same rows by the same rules, and a menu that says
    /// "Item" over a selection of twelve is describing something else.
    nonisolated static func menuTitle(_ side: FolderSide, count: Int) -> String {
        let noun = count > 1 ? "Items" : "Item"
        return "Reveal \(side == .left ? "Left" : "Right") \(noun) in Finder"
    }

    /// Works out what revealing `urls` would do.
    nonisolated static func plan(for urls: [URL]) -> Plan {
        Plan(
            items: urls.count,
            // One window per distinct parent folder, which is what the count
            // in the question has to describe — not the number of items, which
            // is usually much larger and would overstate the mess considerably.
            windows: Set(urls.map { $0.deletingLastPathComponent().path }).count)
    }

    /// Reveals `rows` on one side, confirming first if that is a lot of windows.
    ///
    /// - Parameter window: The window to hang the confirmation sheet on. A
    ///   sheet rather than a free-floating dialog, so the question stays
    ///   attached to the comparison it is about — several tabs can each have
    ///   their own selection.
    static func reveal(
        _ rows: [ComparisonRow],
        on side: FolderSide,
        in results: ComparisonResults,
        from window: NSWindow?
    ) {
        let urls = rows.compactMap { row -> URL? in
            let path = side == .left
                ? results.absoluteLeftPath(of: row)
                : results.absoluteRightPath(of: row)
            return path.map { URL(filePath: $0) }
        }
        guard !urls.isEmpty else { return }

        let plan = plan(for: urls)
        guard plan.needsConfirmation else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return
        }

        confirm(plan, from: window) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Asks whether to go ahead, and calls `proceed` only if the answer is yes.
    private static func confirm(
        _ plan: Plan,
        from window: NSWindow?,
        proceed: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = plan.question
        alert.informativeText = plan.explanation
        // The first button added is the rightmost and the default, so Open is
        // added first to be the highlighted one. AppKit gives a button titled
        // "Cancel" the Escape key of its own accord.
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { proceed() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }
}
