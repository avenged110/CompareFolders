// MARK: - MenuContents.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The shared bodies of the two option menus, written once so the control bar's
// popover and the menu-bar copy always agree on which switches exist, their
// labels, and their enabled state. Both are handed the same observable session.

import SwiftUI

/// The bodies of the two option menus, written once.
///
/// Each of them is now opened from two places — the button on the control bar
/// and an item in the menu bar — and the two have to agree about everything:
/// which switches exist, what they are called, which of them are grayed, and
/// what each one does when it is picked. Duplicating the lists would leave
/// four places to edit for every future switch and no way to notice when one
/// of them was missed.
///
/// Keeping them in lock-step needs nothing beyond this. Both copies are handed
/// the same `ComparisonSession`, which is observable, so a switch thrown in
/// either place changes the one object that both are reading, and the other
/// menu shows the new state the next time it is opened.

/// A heading inside a menu.
///
/// A plain item rather than a `Section` header: the same type, font, size and
/// weight as the switches it introduces, differing only in color and the
/// colon, so the menu reads as one list of labeled groups instead of three
/// lists with small-print titles.
///
/// Styled rather than disabled. A bare `Text` in a menu is already not
/// selectable, so `.disabled(true)` would add nothing but the disabled gray —
/// and that gray is exactly what the third "Hide By Kind" item wears when two
/// are already checked. A heading in the same color would read as one more
/// switch that cannot be thrown right now. `.secondary` is lower in contrast
/// than the selectable items but never matches the disabled ones, which is the
/// distinction that matters.
private struct MenuCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text("\(text):")
            .foregroundStyle(.secondary)
    }
}

/// Which of the comparison's findings to show.
struct FilterMenuItems: View {
    @Bindable var session: ComparisonSession

    /// Whether to head the whole list with "Filter Results". The control bar's
    /// copy wants it, because its button is an icon and the popover otherwise
    /// opens with no name. The menu-bar copy does not: it is already the body
    /// of a menu called "Filter Results", and repeating that title one line
    /// below itself would say nothing new.
    var showsTitle = false

    var body: some View {
        if showsTitle { MenuCaption("Filter Results") }
        // "None" is never absent and never the only thing unchecked: it is on
        // exactly when nothing else is, so the menu always shows one checkmark
        // and a user can always get back to an unfiltered list without hunting
        // for whichever switch they left on.
        Toggle(isOn: Binding(
            get: { session.filter.hasNoActiveOptions },
            // Unchecking "None" would mean "filter by nothing in particular",
            // which is not a state, so only the on direction does anything.
            set: { if $0 { session.filter.clearOptions() } })) {
            Text("None")
        }
        Divider()

        MenuCaption("Hide")
        Toggle("Identical items", isOn: $session.filter.hideIdentical)
        Toggle("Hidden items", isOn: $session.filter.hideHidden)
        Divider()

        MenuCaption("Hide By Kind")
        // At most two of the three. Every row is a file, a folder or a symbolic
        // link, so checking all three would empty the list whatever else the
        // filter said — a state with one meaning and no use. The third item
        // grays out instead of being allowed to say nothing, and unchecking
        // either of the other two returns it.
        kindToggle("Files", isOn: $session.filter.hideFiles)
        kindToggle("Folders", isOn: $session.filter.hideFolders)
        kindToggle("Symbolic links", isOn: $session.filter.hideSymbolicLinks)
        Divider()

        MenuCaption("Treat As Identical")
        Toggle("Differing permissions", isOn: $session.filter.ignorePermissions)
        Toggle("Differing creation dates", isOn: $session.filter.ignoreCreationDates)
        Toggle("Differing modification dates",
               isOn: $session.filter.ignoreModificationDates)
    }

    /// A "Hide by Kind" switch, disabled when it is the last kind still shown.
    private func kindToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            // Never the one that is on: an item the user has checked has to
            // stay clickable, or there would be no way back out of the pair.
            .disabled(!isOn.wrappedValue && session.filter.hiddenKindCount >= 2)
    }
}

/// Everything that outlives the list currently on screen: how the comparison
/// is made, and what survives a relaunch.
struct SettingsMenuItems: View {
    @Bindable var session: ComparisonSession

    /// Whether the filter menu's switches survive a relaunch. Lives in
    /// `UserDefaults` rather than in a session, because it is a statement about
    /// the application, not about one comparison.
    @AppStorage(FilterPersistence.rememberKey) private var remembersFilter = false

    var body: some View {
        // One preference, written as the two answers to it. A lone switch left
        // the "off" case unnamed, and what off actually means here — the filter
        // going back to nothing at the next launch — is worth saying out loud
        // rather than leaving to be inferred from an empty checkbox.
        MenuCaption("Filter Selections")
        persistenceChoice("Remember across sessions", remembering: true)
        persistenceChoice("Reset on quit", remembering: false)
        Divider()

        // The comparison method, which was once a segmented control sitting on
        // the bar. Byte-for-Byte is the expensive half of that choice by a wide
        // margin — it reads both folders in full, where Heuristics opens no
        // file at all — and a segment permanently on display invites being
        // tried for no particular reason. In here it is still one click away
        // for anyone who wants it, without being offered to everyone who does
        // not.
        MenuCaption("Compare Using")
        ForEach(ComparisonMode.allCases) { mode in
            Toggle(isOn: Binding(
                get: { session.mode == mode },
                // Off is not a state: some method is always in use, so only the
                // on direction does anything, and the two items behave as one
                // either/or pair.
                set: { if $0 { session.mode = mode } })) {
                Text(mode.title)
            }
            .help(mode.help)
        }
    }

    /// One half of the either/or: on when persistence is set the way this item
    /// names it, and doing nothing when picked while already on, so the pair
    /// can never both be off.
    private func persistenceChoice(_ title: String, remembering: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { remembersFilter == remembering },
            set: { isOn in
                guard isOn else { return }
                remembersFilter = remembering
                // Choosing to remember records what is already selected, so the
                // switch takes effect on the state the user can see rather than
                // only on the next change they make.
                if remembering {
                    FilterPersistence.store(session.filter)
                    FilterPersistence.store(session.mode)
                }
            })) {
            Text(title)
        }
    }
}
