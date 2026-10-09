// MARK: - ComparisonSession.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The observable state of one window tab: the chosen folders and their sandbox
// grants, the comparison options, the running engine task, live progress, and
// the finished results. Every tab owns one, so comparisons run fully
// independently of each other.

import Foundation
import Observation

/// The state of one comparison — that is, of one window tab.
///
/// Every tab owns its own session, so comparisons are completely independent
/// of one another and can run at the same time.
@MainActor @Observable
final class ComparisonSession {

    // MARK: - Inputs

    /// The chosen folders, each holding its own sandbox access for as long as
    /// it stays selected. The URL properties below are the UI's view of these.
    private var leftFolder: SecurityScopedFolder?
    private var rightFolder: SecurityScopedFolder?

    var leftURL: URL? {
        get { leftFolder?.url }
        set {
            leftFolder = newValue.map(SecurityScopedFolder.init)
            invalidate()
        }
    }

    var rightURL: URL? {
        get { rightFolder?.url }
        set {
            rightFolder = newValue.map(SecurityScopedFolder.init)
            invalidate()
        }
    }

    /// The name of the volume each chosen folder lives on, for the wells.
    /// `nil` when nothing is chosen, or when the volume declines to name
    /// itself — a network share can.
    func volumeName(_ side: FolderSide) -> String? {
        (side == .left ? leftFolder : rightFolder)?.volumeName
    }

    /// How hard the engine should work to decide whether two files match.
    ///
    /// Changing this invalidates the results, because it changes what the
    /// answer actually means.
    var mode: ComparisonMode = .heuristic {
        didSet {
            guard mode != oldValue else { return }
            FilterPersistence.store(mode)
            invalidate()
        }
    }

    /// True while a folder dialog is on screen, so a second cannot be opened
    /// on top of the first.
    private var isChoosingFolder = false

    /// Which findings to show. Purely a view over `results`; never re-runs anything.
    var filter = ComparisonFilter() {
        didSet {
            guard filter != oldValue else { return }
            // The name field is never persisted (see `FilterPersistence`), so
            // a keystroke there has nothing to record — and re-encoding the
            // whole filter into the defaults on every one would be for nothing.
            if filter.withoutSearchText != oldValue.withoutSearchText {
                FilterPersistence.store(filter)
            }
            // Only the "Treat As Identical" switches can change what the
            // counts say; hiding rows and typing in the name field change
            // which of them are shown, and the status line reports both
            // separately. Recounting on every keystroke would walk every row
            // of a large comparison to arrive at the figures already on
            // screen.
            applyFilter(recountingSummary:
                            filter.ignoredFlags != oldValue.ignoredFlags)
        }
    }

    // MARK: - Outputs

    /// The top-level nodes passing the filter — what the outline displays.
    private(set) var visibleRoots: [RowNode] = []
    /// How many rows the filter admits in total, for the summary line.
    private(set) var visibleCount = 0
    /// The complete hierarchy, built once per comparison.
    private var allRoots: [RowNode] = []
    /// Bumped whenever `visibleRows` changes.
    ///
    /// The table reloads on this rather than on the array itself: SwiftUI
    /// re-runs `updateNSView` for all sorts of reasons, and comparing a
    /// hundred thousand rows to decide whether to redraw would cost more than
    /// the redraw.
    private(set) var revision = 0
    /// Which rows the user has selected, as their `ComparisonRow.id`s.
    ///
    /// Pushed up from the outline view, which owns the selection: AppKit's
    /// table is the one thing that knows what is highlighted, and both the
    /// status bar and the View menu are a long way from it.
    ///
    /// Identifiers rather than the rows themselves. A row carries its paths
    /// and both sides' attributes, so copying the selected ones out on every
    /// arrow-key press would mean copying a few hundred bytes per row for as
    /// long as the user held the key down; an id is four bytes and indexes
    /// straight into `results.rows`.
    private(set) var selectedRowIDs: [Int32] = []

    /// How many rows the user has selected, for the status line.
    var selectedCount: Int { selectedRowIDs.count }

    /// The selected rows themselves, for the commands that act on them.
    ///
    /// Bounds-checked rather than subscripted directly: a selection reported
    /// by the table and a fresh set of results can cross in flight when a
    /// comparison finishes while rows are highlighted.
    var selectedRows: [ComparisonRow] {
        let rows = results.rows
        return selectedRowIDs.compactMap { id in
            rows.indices.contains(Int(id)) ? rows[Int(id)] : nil
        }
    }

    private(set) var results = ComparisonResults.empty
    private(set) var summary = ComparisonSummary()
    private(set) var progress: ComparisonProgress?
    private(set) var isRunning = false
    /// Set when the comparison could not be performed at all.
    private(set) var failure: String?
    /// True once a comparison has finished and its results are current.
    private(set) var hasResults = false

    private var task: Task<Void, Never>?
    /// Identifies the current run, so a progress report from a comparison that
    /// has since been canceled or superseded cannot write over the new one's.
    ///
    /// Canceling a `Task` does not stop reports already in flight: each one
    /// hops to the main actor on its own, and several can be waiting there
    /// when the next comparison starts.
    private var runID = 0

    init() {
        mode = FilterPersistence.restoredMode
        filter = FilterPersistence.restored
    }

    /// Asks the user for one of the two folders.
    ///
    /// Used by the wells and by the File menu alike, so both routes present
    /// exactly the same dialog.
    func chooseFolder(_ side: FolderSide) {
        guard !isChoosingFolder else { return }
        isChoosingFolder = true
        Task { @MainActor in
            defer { isChoosingFolder = false }
            let configuration = OpenPanelConfiguration(
                message: side == .left
                    ? "Select a folder for the left column."
                    : "Select a folder for the right column.",
                prompt: "Select Folder")
            guard case .urls(let urls) = await OpenPanelPresenter.present(
                configuration: configuration),
                  let url = urls.first else { return }
            if side == .left { leftURL = url } else { rightURL = url }
        }
    }

    /// The name shown on this tab: distinct per comparison, so several open
    /// tabs can be told apart at a glance.
    var tabTitle: String {
        guard let left = leftFolder?.url.lastPathComponent,
              let right = rightFolder?.url.lastPathComponent else {
            return "Compare Folders"
        }
        return "\(left) ↔ \(right)"
    }

    /// Both folders are chosen, so a comparison is possible.
    var canCompare: Bool { leftFolder != nil && rightFolder != nil }

    // MARK: - Running

    /// Starts (or restarts) the comparison.
    func compare() {
        guard let leftFolder, let rightFolder else { return }
        task?.cancel()

        let options: ComparisonOptions = mode.engineOptions
        let left = leftFolder.path
        let right = rightFolder.path

        isRunning = true
        failure = nil
        hasResults = false
        progress = .scanning(items: 0)
        allRoots = []
        visibleRoots = []
        visibleCount = 0
        results = .empty
        summary = ComparisonSummary()
        selectedRowIDs = []
        revision &+= 1
        runID &+= 1
        let run = runID

        // `self` is a main-actor-isolated class, so it is `Sendable`; the
        // strong capture lasts only as long as the comparison does.
        task = Task { @MainActor in
            do {
                let outcome = try await ComparisonEngine.run(
                    leftRoot: left, rightRoot: right, options: options
                ) { update in
                    Task { @MainActor in self.report(update, from: run) }
                }
                try Task.checkCancellation()
                self.finish(with: outcome, from: run)
            } catch is CancellationError {
                self.stopped(from: run)
            } catch {
                self.fail(error.localizedDescription, from: run)
            }
        }
    }

    /// Accepts a progress report from the engine, if it is still relevant.
    ///
    /// The content phase reads several files at once, so its reports are
    /// raised on different threads and can arrive here out of order. A count
    /// that went backwards would be visible as a stuttering readout, so one
    /// that has been overtaken is simply dropped.
    private func report(_ update: ComparisonProgress, from run: Int) {
        guard isRunning, run == runID else { return }
        switch (update, progress) {
        // Scanning is finished for good once the walk has started, so a
        // straggler from a scanning thread means nothing but a readout that
        // jumps backwards to a phase the comparison has left.
        case (.scanning, .matching), (.scanning, .readingContents):
            return
        // The content phase reads several files at once, so its reports are
        // raised on different threads and can arrive out of order. Either
        // count going backwards would stutter, so a report that has been
        // overtaken in either of them is dropped — both have to be at least
        // where the readout already stands for it to be worth showing.
        case (.readingContents(let completed, let total, let bytes, _),
              .readingContents(let shown, let shownTotal, let shownBytes, _))
            where total == shownTotal && (completed < shown || bytes < shownBytes):
            return
        default:
            progress = update
        }
    }

    /// Records the list's selection. Called only by the results view.
    func selectionChanged(to ids: [Int32]) {
        guard ids != selectedRowIDs else { return }
        selectedRowIDs = ids
    }

    /// Cancels a running comparison, leaving no partial results behind.
    ///
    /// A half-finished comparison is worse than none — it looks like an
    /// answer — so stopping discards what was gathered rather than showing it.
    func cancel() {
        task?.cancel()
        task = nil
        // Retires the run before stopping it, so the canceled task's own
        // ending — which arrives later, on its own schedule — is recognized as
        // stale and cannot write over whatever the user has done in between.
        runID &+= 1
        isRunning = false
        progress = nil
    }

    // MARK: - Transitions

    /// - Parameter run: The comparison this is the ending of. A run that has
    ///   since been canceled or replaced ends silently: its `Task` may be
    ///   canceled, but the ending is already on its way to the main actor by
    ///   then, and letting a superseded one land would stop the run that
    ///   replaced it — an apparently finished window with a comparison still
    ///   going on underneath it.
    private func finish(with outcome: ComparisonResults, from run: Int) {
        guard run == runID else { return }
        results = outcome
        allRoots = RowNode.buildTree(from: outcome.rows)
        isRunning = false
        progress = nil
        hasResults = true
        applyFilter()
    }

    private func stopped(from run: Int) {
        guard run == runID else { return }
        isRunning = false
        progress = nil
    }

    private func fail(_ message: String, from run: Int) {
        guard run == runID else { return }
        isRunning = false
        progress = nil
        failure = message
    }

    /// Discards results that no longer describe the current inputs.
    private func invalidate() {
        task?.cancel()
        task = nil
        runID &+= 1
        isRunning = false
        progress = nil
        hasResults = false
        // The failure described the inputs that have just been replaced. Left
        // standing it outlives them: the window goes on reporting "Comparison
        // failed" over a pair of folders that has never been compared, and the
        // report only clears when the next comparison happens to be run.
        failure = nil
        results = .empty
        allRoots = []
        visibleRoots = []
        visibleCount = 0
        summary = ComparisonSummary()
        selectedRowIDs = []
        revision &+= 1
    }

    private func applyFilter(recountingSummary: Bool = true) {
        // Recounted rather than kept from the comparison: a difference the
        // user has asked to treat as identical is identical everywhere, the
        // status line included, and the pass costs one walk of the rows on a
        // menu click.
        if recountingSummary {
            summary = ComparisonSummary(rows: results.rows, ignoring: filter.ignoredFlags)
        }
        visibleRoots = filter.apply(to: allRoots)
        visibleCount = visibleRoots.reduce(0) { $0 + count(of: $1) }
        revision &+= 1
    }

    private func count(of node: RowNode) -> Int {
        node.visibleChildren.reduce(1) { $0 + count(of: $1) }
    }
}

/// Headline counts for the status line.
///
/// Every count is taken in one pass over the finished rows, at the moment the
/// comparison ends. Nothing here is recomputed while the user hovers, scrolls
/// or filters.
struct ComparisonSummary: Equatable, Sendable {
    var identical = 0
    var modified = 0
    var added = 0
    var removed = 0
    /// How many rows carry each individual kind of difference.
    ///
    /// These overlap on purpose: one file whose contents and modification date
    /// both changed is counted under each. They answer "how many items differ
    /// in *this* way", which is the question the status line asks, rather than
    /// partitioning the results.
    var differences = DifferenceCounts()

    var total: Int { identical + modified + added + removed }
    var differingItems: Int { modified + added + removed }

    init() {}

    /// - Parameter mask: differences the filter has been told to treat as
    ///   identical, which are discounted here exactly as they are in the list.
    init(rows: [ComparisonRow], ignoring mask: ComparisonFlags = []) {
        for row in rows {
            let flags = row.flags.subtracting(mask)
            if flags.contains(.added) { added += 1 }
            else if flags.contains(.removed) { removed += 1 }
            else if flags.isIdentical { identical += 1 }
            else { modified += 1 }

            guard !flags.isIdentical else { continue }
            if flags.contains(.added) { differences.rightExclusive += 1 }
            if flags.contains(.removed) { differences.leftExclusive += 1 }
            if flags.contains(.replaced) { differences.replaced += 1 }
            if flags.contains(.dataContent) { differences.contents += 1 }
            else if flags.contains(.dataSize) { differences.size += 1 }
            if flags.contains(.resourceContent) || flags.contains(.resourceSize) {
                differences.resourceFork += 1
            }
            if flags.contains(.modificationDate) { differences.modificationDate += 1 }
            if flags.contains(.creationDate) { differences.creationDate += 1 }
            if flags.contains(.permissions) { differences.permissions += 1 }
            if flags.contains(.userID) { differences.owner += 1 }
            if flags.contains(.groupID) { differences.group += 1 }
        }
    }
}

/// One counter per kind of difference the engine can report.
///
/// The full set — there is nothing the comparison can find that is not
/// represented here, so the status line can never be silently incomplete.
struct DifferenceCounts: Equatable, Sendable {
    /// Files whose bytes were read and found to differ. Byte-for-Byte only.
    var contents = 0
    /// Files of unequal length. Under Heuristics this is as close to a content
    /// difference as the mode gets; under Byte-for-Byte `contents` supersedes
    /// it, so the two are never counted for the same row.
    var size = 0
    /// Differing resource forks, by length or by content.
    var resourceFork = 0
    var modificationDate = 0
    var creationDate = 0
    /// Differing mode bits.
    var permissions = 0
    var owner = 0
    var group = 0
    /// Present on both sides, but as different kinds of object.
    var replaced = 0
    /// Present on the left only.
    var leftExclusive = 0
    /// Present on the right only.
    var rightExclusive = 0

    /// Each non-zero count with its phrasing, in the order the status line
    /// reads them out: what the item *is* first, then when it changed, then who
    /// owns it, then whether it is there at all.
    var described: [String] {
        var parts: [String] = []
        func add(_ count: Int, _ phrase: String) {
            guard count > 0 else { return }
            parts.append("\(count.formatted()) \(phrase)")
        }
        // Just the count and what it is about. "differ in" in front of each of
        // eight entries is the same three words eight times over, and the line
        // is long enough already; the brackets follow "items compared", which
        // is all the sentence the reader needs.
        add(contents, "contents")
        add(size, "size")
        add(resourceFork, "resource fork")
        add(modificationDate, "mod. date")
        add(creationDate, "creation date")
        add(permissions, "permissions")
        add(owner, "owner")
        add(group, "group")
        add(replaced, "different kind")
        add(leftExclusive, "left exclusive")
        add(rightExclusive, "right exclusive")
        return parts
    }
}
