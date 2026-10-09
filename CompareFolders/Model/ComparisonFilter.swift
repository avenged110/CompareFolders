// MARK: - ComparisonFilter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The set of switches that decide which finished findings are shown — hide
// identical, hidden, or by-kind items, ignore selected attribute differences,
// and a name substring match. Filtering is purely a view over the results;
// nothing is ever re-scanned when it changes.

import Foundation

/// Which of the comparison's findings are worth showing right now.
///
/// Filtering is purely a view over the finished results: nothing is ever
/// re-scanned or re-read when these change, so toggling them is instant even
/// on a result set of hundreds of thousands of rows.
struct ComparisonFilter: Equatable, Sendable, Codable {
    /// Hide items that matched in every respect.
    var hideIdentical = false
    /// Hide dot-files and anything inside a dot-directory.
    var hideHidden = false
    var hideFiles = false
    var hideFolders = false
    var hideSymbolicLinks = false

    /// Treat a permission, owner or group difference as uninteresting.
    var ignorePermissions = false
    /// Treat a creation date difference as uninteresting.
    var ignoreCreationDates = false
    /// Treat a modification date difference as uninteresting.
    var ignoreModificationDates = false

    /// Case-insensitive substring match against the item's path.
    var searchText = ""

    /// True when nothing is being filtered out, which lets the results be
    /// handed to the table verbatim.
    var isInactive: Bool {
        self == ComparisonFilter()
    }

    /// True when none of the menu's switches is on.
    ///
    /// The name filter is deliberately not counted: it has its own field
    /// beside the menu, and typing there should not silently uncheck "None".
    var hasNoActiveOptions: Bool {
        withoutSearchText == ComparisonFilter()
    }

    /// The menu's switches alone, with the name filter cleared.
    var withoutSearchText: ComparisonFilter {
        var bare = self
        bare.searchText = ""
        return bare
    }

    /// How many of the three "Hide by Kind" switches are on.
    ///
    /// All three at once would hide every row there is, whatever else the
    /// filter said, so the menu never offers the third: the two already on are
    /// what the user has to choose between, and unchecking either one brings
    /// the third back. Counted here rather than in the menu so the rule lives
    /// with the switches it constrains.
    var hiddenKindCount: Int {
        [hideFiles, hideFolders, hideSymbolicLinks].filter { $0 }.count
    }

    /// Turns every switch off, leaving the name filter alone.
    mutating func clearOptions() {
        self = ComparisonFilter(searchText: searchText)
    }

    /// The differences the "Treat As Identical" switches currently discount.
    var ignoredFlags: ComparisonFlags {
        var mask: ComparisonFlags = []
        if ignorePermissions { mask.formUnion([.permissions, .groupID, .userID]) }
        if ignoreCreationDates { mask.insert(.creationDate) }
        if ignoreModificationDates { mask.insert(.modificationDate) }
        return mask
    }

    /// The row as this filter has it.
    ///
    /// The "Treat As Identical" switches do not hide anything by themselves:
    /// they clear the difference they name, so an item whose only difference
    /// was that one becomes identical in every respect the rest of the
    /// application asks about — it loses its color, its tooltip stops
    /// claiming a difference, and it counts as identical in the status line.
    /// Whether it is then *shown* is up to "Hide identical items", exactly as
    /// for an item that was identical to begin with. Anything structural is
    /// left alone: a mask only ever covers attribute flags.
    func effective(_ row: ComparisonRow) -> ComparisonRow {
        let mask = ignoredFlags
        guard !mask.isEmpty, !row.flags.isDisjoint(with: mask) else { return row }
        var copy = row
        copy.flags.subtract(mask)
        return copy
    }

    /// True when `row` should be shown.
    ///
    /// Expects a row that has already been through `effective(_:)`; every
    /// caller here does that first.
    func accepts(_ row: ComparisonRow) -> Bool {
        if hideIdentical && row.isIdentical { return false }
        if hideHidden && row.isHidden { return false }

        switch row.kind {
        case .file where hideFiles: return false
        case .directory where hideFolders: return false
        case .symbolicLink where hideSymbolicLinks: return false
        default: break
        }

        if !searchText.isEmpty
            && row.displayPath.range(of: searchText, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }

    /// Applies the filter to a flat result set, returning the rows that survive
    /// it as the filter has them.
    ///
    /// The app itself filters the `RowNode` tree instead — see the overload in
    /// `RowNode.swift`, which has to keep a rejected folder whose children
    /// survive. This one is the same rules without the hierarchy, and is what
    /// the engine's verification harness checks them through.
    func apply(to rows: [ComparisonRow]) -> [ComparisonRow] {
        guard !isInactive else { return rows }
        return rows.compactMap { row in
            let row = effective(row)
            return accepts(row) ? row : nil
        }
    }
}

/// Whether the filter menu's switches outlive the app, and where they are kept.
///
/// Off by default, and deliberately so: a filter is usually a question about
/// the comparison in front of you, and one silently still in force a week later
/// would quietly hide findings from a comparison it was never meant for. A user
/// who *does* always want to hide identical items can say so once, and the menu
/// then opens on the next launch exactly as it was left — filter glyph already
/// filled, because a filter really is in force.
enum FilterPersistence {
    /// The `@AppStorage` key the Settings toggle in the filter menu binds to.
    static let rememberKey = "remembersFilterSelections"
    private static let filterKey = "filter"
    private static let modeKey = "comparisonMode"

    static var remembers: Bool {
        UserDefaults.standard.bool(forKey: rememberKey)
    }

    /// The filter a new session should start with.
    static var restored: ComparisonFilter {
        guard remembers,
              let data = UserDefaults.standard.data(forKey: filterKey),
              var stored = try? JSONDecoder().decode(ComparisonFilter.self, from: data)
        else { return ComparisonFilter() }
        // A search term is specific to one comparison and should not silently
        // hide results in a brand new tab.
        stored.searchText = ""
        return stored
    }

    /// Records the filter, if the user has asked for it to be remembered.
    static func store(_ filter: ComparisonFilter) {
        guard remembers,
              let data = try? JSONEncoder().encode(filter.withoutSearchText)
        else { return }
        UserDefaults.standard.set(data, forKey: filterKey)
    }

    /// The comparison method a new session should start with.
    ///
    /// Kept here, beside the filter, because the menu now presents it as one
    /// more thing the Settings switch governs. Byte-for-Byte is a deliberate,
    /// expensive choice — minutes rather than milliseconds on a large pair of
    /// folders — and having it silently still in force in a window opened days
    /// later, with no segmented control on the bar to show it, is exactly the
    /// surprise the filter's own default guards against. So it survives a
    /// relaunch only if the user has said filters should.
    static var restoredMode: ComparisonMode {
        guard remembers,
              let raw = UserDefaults.standard.string(forKey: modeKey),
              let mode = ComparisonMode(rawValue: raw)
        else { return .heuristic }
        return mode
    }

    /// Records the comparison method, under the same condition as the filter.
    static func store(_ mode: ComparisonMode) {
        guard remembers else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }
}
