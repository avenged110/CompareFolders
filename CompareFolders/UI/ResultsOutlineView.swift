// MARK: - ResultsOutlineView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The app's main piece of AppKit — an `NSOutlineView` wrapped for SwiftUI that
// draws both folders as columns of one inset, collapsible, alternating-row list
// with a single scroller. Chosen because `List` will not give standard
// selection behavior for custom cell content.

import AppKit
import SwiftUI

/// The side-by-side result list.
///
/// This is the app's one significant piece of AppKit, and it earns its place
/// several times over. `NSOutlineView` — itself an `NSTableView` subclass —
/// provides collapsible folders, animated, with no custom scroll handling;
/// `NSTableCellView` gives the standard selection behavior, glyphs and text
/// turning white on a highlighted row, which SwiftUI's `List` will not do for
/// custom content; and the `.inset` style supplies the inset, rounded
/// alternating rows that match the rest of the system.
///
/// Both sides are columns of one outline rather than two independent lists, so
/// an item is always level with its counterpart, expanding a folder moves both
/// halves together, and there is a single scroller.
struct ResultsOutlineView: NSViewRepresentable {
    let session: ComparisonSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // The scroll view is layer-backed for compositing; the outline itself
        // deliberately is not. A layer-backed table does not repaint
        // synchronously on `reloadData`, leaving a stale bitmap for a frame.
        scrollView.wantsLayer = true
        scrollView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        let outlineView = ResultsOutline()
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        // NSTableView fills its whole frame with row backgrounds, including
        // the partial band below the last row when the height is not an exact
        // multiple of the row height. Matching the first stripe color makes
        // that band invisible instead of a stray fractional row.
        outlineView.backgroundColor = NSColor.alternatingContentBackgroundColors[0]
        outlineView.rowHeight = 24
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        // Grid lines stay off. `solidVerticalGridLineMask` draws a rule at the
        // trailing edge of *every* column, which put a stray line down the
        // left half and clipped the rounded corners of the inset rows. The one
        // divider that is wanted is an overlay, added below.
        outlineView.gridStyleMask = []
        outlineView.rowSizeStyle = .custom
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.allowsColumnReordering = false
        // The two halves are meant to stay equal, so the user is not offered a
        // handle that would make them unequal.
        outlineView.allowsColumnResizing = false
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.indentationPerLevel = Layout.indentPerLevel
        outlineView.indentationMarkerFollowsCell = true
        outlineView.autoresizesOutlineColumn = false

        var columns: [NSTableColumn] = []
        for side in [FolderSide.left, .right] {
            let column = NSTableColumn(identifier: side.columnIdentifier)
            column.resizingMask = .autoresizingMask
            column.minWidth = 80
            outlineView.addTableColumn(column)
            columns.append(column)
        }
        // Disclosure triangles belong to the outline column, which is the left one.
        // The property is `unowned(unsafe)`; the outline view keeps the column
        // alive itself, having just been handed it by `addTableColumn`.
        unsafe outlineView.outlineTableColumn = columns[0]
        // No header. Each folder's full path is in its own well at the top of
        // the window, directly under the name it belongs to, which is both a
        // shorter trip for the eye than the bottom of the control bar and the
        // one place the path can sit without being repeated.
        outlineView.headerView = nil

        outlineView.delegate = coordinator
        outlineView.dataSource = coordinator
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(Coordinator.revealFromDoubleClick)

        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        coordinator.outlineView = outlineView
        scrollView.documentView = outlineView

        // The center divider is an overlay rather than a grid line so it marks
        // only the boundary between the two halves and leaves the rounded row
        // backgrounds alone.
        let container = DividerContainer()
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = .separatorColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(divider)
        container.scrollView = scrollView
        container.divider = divider
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.session = session
        context.coordinator.syncIfNeeded()
    }

    enum Layout {
        static let indentPerLevel: CGFloat = 14
        /// Width the outline view reserves for a disclosure triangle. The right
        /// column has no triangles of its own, so it reproduces the same gutter
        /// to stay level with the left.
        static let disclosureGutter: CGFloat = 16
        static let baseInset: CGFloat = 6
        /// The margin the `.inset` table style leaves around its row
        /// backgrounds. AppKit fixes this at ten points, and it is the line
        /// everything down the left of the window aligns to: the folder wells,
        /// the Compare button, the column headings and the stripes themselves.
        static let rowBackgroundInset: CGFloat = 10
    }

    // MARK: - Divider

    /// Holds the scroll view, and lays the center divider out by hand beside it.
    ///
    /// The divider spans exactly the rows' area, which is a figure the scroll
    /// view works out during its own tiling rather than one Auto Layout can be
    /// told in advance. Positioning the line in `layout()`, from the clip view
    /// the scroller has just placed, keeps the two in step without constraining
    /// a view the scroll view insists on framing itself.
    private final class DividerContainer: NSView {
        weak var scrollView: NSScrollView?
        weak var divider: NSView?

        override func layout() {
            super.layout()
            guard let scrollView, let divider else { return }
            // The scroll view frames its clip view during its own layout,
            // which by default runs after this one. Asking for it now means
            // the line is never a frame behind the rows.
            scrollView.layoutSubtreeIfNeeded()
            // The clip view is precisely the rows' area. Converted rather than
            // read off the frame so this holds whichever way round the
            // coordinates run.
            let rows = convert(scrollView.contentView.bounds, from: scrollView.contentView)
            divider.frame = NSRect(
                // Dead center, which is exactly where two equal columns meet.
                x: bounds.midX - 0.5,
                y: rows.minY,
                width: 1,
                height: rows.height)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var session: ComparisonSession
        fileprivate weak var outlineView: ResultsOutline?

        /// The results revision already on screen, so a redraw only happens
        /// when the data genuinely changed — SwiftUI re-runs `updateNSView`
        /// for reasons that have nothing to do with the rows.
        private var displayedRevision = -1

        init(session: ComparisonSession) {
            self.session = session
        }

        func syncIfNeeded() {
            guard let outlineView else { return }
            guard session.revision != displayedRevision else { return }
            displayedRevision = session.revision
            // The rows these refer to are about to be replaced.
            outlineView.forgetDeferredState()
            outlineView.reloadData()
            // Folders start open, so a fresh comparison reads exactly as it did
            // before collapsing existed; the user closes what they don't want.
            outlineView.expandItem(nil, expandChildren: true)
            // Reloading empties the selection, but whether that is reported as
            // a selection change is AppKit's business rather than something to
            // rely on. Pushing it explicitly means the status line and the
            // View menu can never go on describing a selection of rows that
            // are no longer in the list — commands that would then act on
            // whatever now sits at those positions.
            pushSelection()
        }

        // MARK: Data

        private func children(of item: Any?) -> [RowNode] {
            (item as? RowNode)?.visibleChildren ?? session.visibleRoots
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? RowNode)?.isExpandable ?? false
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let tableColumn, let node = item as? RowNode else { return nil }
            let row = node.effectiveRow
            let isLeft = tableColumn.identifier == FolderSide.left.columnIdentifier

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
                as? ComparisonCellView ?? ComparisonCellView(identifier: identifier)

            // The outline view indents the outline column itself, triangle
            // gutter included. The right column gets no such treatment, so it
            // reproduces both by hand and the two halves stay level.
            let indent = isLeft
                ? 0
                : CGFloat(row.depth) * Layout.indentPerLevel + Layout.disclosureGutter

            cell.configure(
                with: row,
                exists: isLeft ? row.existsOnLeft : row.existsOnRight,
                extraIndent: indent)
            return cell
        }

        /// The status bar's selection count comes from here, because this is
        /// where the selection actually lives.
        func outlineViewSelectionDidChange(_ notification: Notification) {
            pushSelection()
        }

        private func pushSelection() {
            guard let outlineView else {
                session.selectionChanged(to: [])
                return
            }
            session.selectionChanged(to: outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? RowNode)?.row.id
            })
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let rows = targetRows
            guard !rows.isEmpty else { return }
            // Worded exactly as the View menu's own pair, which act on the
            // same rows by the same rules — the only difference is that these
            // can also be aimed at a row by right-clicking it without
            // selecting it first. The plural follows the rows this menu will
            // actually act on, which is not always the selection.
            menu.addItem(withTitle: RevealInFinder.menuTitle(.left, count: rows.count),
                         action: #selector(revealLeft), keyEquivalent: "")
            menu.addItem(withTitle: RevealInFinder.menuTitle(.right, count: rows.count),
                         action: #selector(revealRight), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: CopyPaths.menuTitle(count: rows.count),
                         action: #selector(copyPaths), keyEquivalent: "")
            for item in menu.items { item.target = self }
        }

        /// The rows a command applies to: the selection when the click landed
        /// inside it, otherwise just the row that was clicked.
        private var targetRows: [ComparisonRow] {
            guard let outlineView else { return [] }
            let clicked = outlineView.clickedRow
            let selected = outlineView.selectedRowIndexes
            let indexes = (clicked >= 0 && !selected.contains(clicked))
                ? IndexSet(integer: clicked)
                : selected
            return indexes.compactMap {
                (outlineView.item(atRow: $0) as? RowNode)?.row
            }
        }

        /// A double-click reveals the item — unless it is a folder, whose
        /// double-click already belongs to the disclosure triangle. Reveal is
        /// still a click away for folders, in the contextual menu.
        ///
        /// The half of the row that was clicked is the one revealed. Each row
        /// spans both folders, and a double-click that always reached for the
        /// left one would open the wrong folder for every item picked out on
        /// the right — or, for an item that exists only on the right, do
        /// nothing at all and look broken. An item absent from the clicked
        /// side falls back to the side it does exist on, which is the only
        /// item the row is offering.
        @objc func revealFromDoubleClick() {
            guard let outlineView, outlineView.clickedRow >= 0,
                  let node = outlineView.item(atRow: outlineView.clickedRow) as? RowNode,
                  !node.isExpandable
            else { return }
            let column = outlineView.clickedColumn
            let clickedRight = column >= 0
                && outlineView.tableColumns[column].identifier
                    == FolderSide.right.columnIdentifier
            let row = node.row
            let side: FolderSide = clickedRight
                ? (row.existsOnRight ? .right : .left)
                : (row.existsOnLeft ? .left : .right)
            reveal(on: side)
        }
        @objc private func revealLeft() { reveal(on: .left) }
        @objc private func revealRight() { reveal(on: .right) }

        private func reveal(on side: FolderSide) {
            RevealInFinder.reveal(
                targetRows,
                on: side,
                in: session.results,
                from: unsafe outlineView?.window)
        }

        @objc private func copyPaths() {
            CopyPaths.copy(targetRows)
        }
    }
}

extension FolderSide {
    var columnIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier(self == .left ? "left" : "right")
    }
}

/// The outline view itself, with three behaviors `NSOutlineView` does not
/// provide: a click in the inset side margins deselects, a click anywhere in an
/// already-selected folder works its disclosure triangle, and very large
/// folders open and close without the long stall and the empty gap that the
/// stock implementation gives them.
private final class ResultsOutline: NSOutlineView {

    // MARK: - Clicking

    /// With the `.inset` style, rows are drawn with horizontal margins that
    /// hit-testing considers part of no column. Without this, clicking there
    /// does nothing at all, which feels broken; deselecting matches what
    /// clicking below the last row already does.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0 && column(at: point) < 0 {
            deselectAll(nil)
            return
        }

        // Once a folder is selected, the whole highlight is its disclosure
        // triangle. Aiming for a thirteen-point chevron to close a folder you
        // have already picked out is a precision the task does not deserve.
        //
        // Only on a row that was already selected: the first click on a row is
        // how it gets selected, and folding a folder shut as a side effect of
        // selecting it would be worse than the aiming.
        if event.clickCount == 1, clicked >= 0,
           selectedRowIndexes.contains(clicked),
           let node = item(atRow: clicked) as? RowNode, node.isExpandable,
           // The triangle itself is left to AppKit, which does more with it
           // than this does — option-clicking it opens the whole subtree.
           !frameOfOutlineCell(atRow: clicked).contains(point),
           let triangle = disclosureButton(inRow: clicked) {
            // The triangle's own button, clicked. Not `collapseItem` — calling
            // that directly changes the rows without animating them, because
            // the animation belongs to the control's action, not to the method.
            // Pressing the button is the only way to get *exactly* what
            // clicking it gives, this and everything else it does.
            triangle.performClick(nil)
            return
        }

        super.mouseDown(with: event)
    }

    /// The disclosure triangle in a row, which AppKit installs as an ordinary
    /// button under a documented identifier.
    private func disclosureButton(inRow row: Int) -> NSButton? {
        guard let rowView = rowView(atRow: row, makeIfNecessary: false) else { return nil }
        func search(_ view: NSView) -> NSButton? {
            if view.identifier == NSOutlineView.disclosureButtonIdentifier {
                return view as? NSButton
            }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(rowView)
    }

    // MARK: - Large folders

    /// Folders whose contents were thrown away to close them quickly, and the
    /// folders inside each that the user had shut by hand.
    private var discarded: [ObjectIdentifier: [RowNode]] = [:]

    /// True while performing a later stage of a staged open or close, so the
    /// re-entrant call does the plain AppKit thing and nothing else.
    private var isStaging = false

    /// Which set of rows the staged work below is operating on.
    ///
    /// A staged open or close runs over several turns of the run loop, and a
    /// filter change or a fresh comparison in the middle of one replaces the
    /// rows underneath it. Stamping each stage means the later ones can tell
    /// that the list they were working on is gone — otherwise they would go on
    /// to insert and remove rows in an outline that has since been reloaded,
    /// and to put back a `visibleChildren` the filter had just recomputed.
    private var generation = 0

    /// Discards that bookkeeping, for when the rows it refers to are about to
    /// stop existing.
    func forgetDeferredState() {
        discarded.removeAll()
        generation &+= 1
    }

    /// A window's worth of rows: the most that is ever worth animating, and —
    /// as it turns out — the least that `NSTableView` will animate at all.
    private var windowful: Int {
        max(1, rows(in: visibleRect).length)
    }

    /// Closes a folder of any size in a fixed amount of work, with the rows on
    /// screen actually sliding up into it.
    ///
    /// `NSTableView` animates a collapse by sliding the removed rows up behind
    /// the ones that stay, and it only ever makes views for rows near the
    /// window. Closing a folder of a hundred thousand items therefore animates
    /// the screenful it has views for while the rows *after* the folder travel
    /// two million points in a quarter of a second — off screen for all but the
    /// last instant of it. That is the blank gap, and the following rows
    /// appearing from nowhere at the end of it.
    ///
    /// So the folder is emptied out of sight first, down to the screenful that
    /// is actually being looked at, and only that screenful is animated. Three
    /// things make it work, and all three were arrived at by measuring:
    ///
    /// * **Nothing happens in this turn of the run loop.** The click that got
    ///   us here is running inside a transaction of AppKit's own, and any row
    ///   change made inside it is folded together with the collapse that
    ///   follows — which animates everything from where it was *before* the
    ///   trim, restoring the whole problem.
    /// * **Whole children only.** Shortening a list further down the tree takes
    ///   away rows that are on screen, which is a worse fault than any missing
    ///   animation: content vanishing between one frame and the next.
    /// * **A screenful is the floor as well as the ceiling.** `NSTableView`
    ///   declines to animate a removal smaller than the window, so trimming
    ///   past that point buys nothing and loses the animation.
    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        guard !isStaging, !collapseChildren, let node = item as? RowNode,
              row(forItem: node) >= 0
        else { super.collapseItem(item, collapseChildren: collapseChildren); return }

        let all = node.visibleChildren
        var kept = 0
        var covered = 0
        let want = windowful
        while kept < all.count && covered < want {
            covered += 1
            if isItemExpanded(all[kept]) {
                covered += rowsUnder(all[kept], cap: want - covered)
            }
            kept += 1
        }
        guard kept < all.count else {
            super.collapseItem(node, collapseChildren: false); return
        }

        // Taken while the folder is still open, because this is the only moment
        // `NSOutlineView` will answer for it: once the rows are gone, so is its
        // memory of which folders inside them were open. Recorded the short way
        // round — the ones that are *shut* — since a comparison starts with
        // everything open and shutting one is the deliberate act.
        var closed: [RowNode] = []
        var folders = 0
        func record(_ folder: RowNode) {
            for child in folder.visibleChildren where child.isExpandable {
                folders += 1
                if isItemExpanded(child) { record(child) } else { closed.append(child) }
            }
        }
        record(node)

        let stamp = generation
        onNextTurn { [weak self] in
            self?.trimAndClose(node, all: all, kept: kept,
                               closed: folders > 0 ? closed : nil, stamp: stamp)
        }
    }

    private func trimAndClose(
        _ node: RowNode, all: [RowNode], kept: Int, closed: [RowNode]?, stamp: Int
    ) {
        // Nothing has been touched yet, so an abandoned stage leaves the rows
        // exactly as whatever replaced them left them.
        guard stamp == generation else { return }

        // Everything below the window, dropped without animation. None of it is
        // on screen, so none of it is seen to go.
        node.visibleChildren = Array(all[..<kept])
        removeItems(at: IndexSet(kept..<all.count), inParent: node, withAnimation: [])

        onNextTurn { [weak self] in
            guard let self, stamp == self.generation else { return }
            self.isStaging = true
            // Through the animator, which is how AppKit documents animating an
            // outline and the only call that actually animates one.
            self.animator().collapseItem(node)
            self.isStaging = false
            self.afterAnimating { [weak self] in
                guard let self, stamp == self.generation else { return }
                // Put the list back now the folder is shut and owns no rows, so
                // nothing is left holding a shortened one: a folder in that
                // state stops its own parent animating later.
                self.withoutAnimation {
                    node.visibleChildren = all
                    self.reloadItem(node, reloadChildren: true)
                }
                if let closed { self.discarded[ObjectIdentifier(node)] = closed }
            }
        }
    }

    /// Opens a folder of any size in a fixed amount of work.
    ///
    /// The seconds between the click and a huge folder opening are
    /// `NSOutlineView` inserting every one of those rows before it will draw
    /// anything. Only a screenful goes in to begin with — which is all that can
    /// be looked at — and the rest follows once the animation has played, off
    /// the bottom of the window where its arrival cannot be seen.
    override func expandItem(_ item: Any?, expandChildren: Bool) {
        guard !isStaging, !expandChildren, let node = item as? RowNode,
              row(forItem: node) >= 0
        else { super.expandItem(item, expandChildren: expandChildren); return }

        let all = node.visibleChildren
        let stamp = generation
        guard all.count > windowful else {
            super.expandItem(node, expandChildren: false)
            onNextTurn { [weak self] in
                guard let self, stamp == self.generation else { return }
                self.reopenDiscarded(node)
            }
            return
        }
        onNextTurn { [weak self] in self?.trimAndOpen(node, all: all, stamp: stamp) }
    }

    private func trimAndOpen(_ node: RowNode, all: [RowNode], stamp: Int) {
        guard stamp == generation else { return }

        // The folder is shut, so this takes no rows away from anything. It only
        // decides how many the opening will put in.
        let kept = windowful
        withoutAnimation {
            node.visibleChildren = Array(all[..<kept])
            reloadItem(node, reloadChildren: true)
        }
        onNextTurn { [weak self] in
            guard let self, stamp == self.generation else { return }
            self.isStaging = true
            self.animator().expandItem(node)
            self.isStaging = false
            self.afterAnimating { [weak self] in
                guard let self, stamp == self.generation else { return }
                self.withoutAnimation {
                    node.visibleChildren = all
                    self.insertItems(at: IndexSet(kept..<all.count),
                                     inParent: node, withAnimation: [])
                }
                self.onNextTurn { [weak self] in
                    guard let self, stamp == self.generation else { return }
                    self.reopenDiscarded(node)
                }
            }
        }
    }

    /// Restores the open and shut folders inside a subtree that was discarded.
    ///
    /// One bulk pass and then the handful the user had shut: opening them one
    /// at a time costs several times as much, and everything under a folder
    /// starts open anyway.
    private func reopenDiscarded(_ node: RowNode) {
        guard let closed = discarded.removeValue(forKey: ObjectIdentifier(node))
        else { return }
        isStaging = true
        withoutAnimation {
            super.expandItem(node, expandChildren: true)
            for folder in closed { super.collapseItem(folder, collapseChildren: false) }
        }
        isStaging = false
    }

    /// Rows an open folder currently contributes, counted no further than `cap`
    /// so the cost does not depend on how large the folder is.
    private func rowsUnder(_ node: RowNode, cap: Int) -> Int {
        var total = 0
        for child in node.visibleChildren {
            if total >= cap { break }
            total += 1
            if isItemExpanded(child) { total += rowsUnder(child, cap: cap - total) }
        }
        return total
    }

    private func withoutAnimation(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        changes()
        NSAnimationContext.endGrouping()
    }

    private func onNextTurn(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    private func afterAnimating(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NSAnimationContext.current.duration + 0.1
        ) { MainActor.assumeIsolated { work() } }
    }
}

extension NSColor {
    /// The rule closing off the control bar from the results below it.
    ///
    /// A separator is meant to be barely there, and between two surfaces of
    /// different weight — the translucent bar above, the list below — barely
    /// there is not enough: the two grays meet with a lighter gray drawn
    /// between them, which reads as a gap rather than an edge. A hard dark line
    /// reads as the bar's own bottom edge, the way the title bar in Film
    /// Tracker's gallery does.
    ///
    /// Black outright in Dark Mode. In Light Mode the same idea has to be drawn
    /// with a fraction of the ink — a solid black rule across a pale window
    /// would be a stripe, not an edge — so it is the standard separator's own
    /// black, roughly three times as opaque.
    static let resultsHeaderTopEdge = NSColor(name: "resultsHeaderTopEdge") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 1)
            : NSColor(white: 0, alpha: 0.3)
    }
}

// MARK: - Cell

/// One half of one row: a glyph and a name.
///
/// Built on `NSTableCellView` with its standard `imageView` and `textField`
/// outlets, which is what makes selection behave the way the system does
/// everywhere else — see `backgroundStyle` below.
private final class ComparisonCellView: NSTableCellView {
    /// Held here as well as in the outlets, which are `unowned(unsafe)`: the
    /// cell reads and writes its own strong references, and only hands the
    /// outlets to AppKit.
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var leadingConstraint: NSLayoutConstraint!
    /// The color the name takes when the row is not highlighted.
    private var restingTextColor: NSColor = .labelColor
    /// The color the glyph takes when the row is not highlighted.
    private var restingIconColor: NSColor = .secondaryLabelColor

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        // Centered in a fixed-width well: the glyphs vary in width, the column
        // they sit in does not.
        icon.imageAlignment = .alignCenter
        addSubview(icon)
        // Set only once each view is a subview and so retained by the cell,
        // for as long as the cell itself exists.
        unsafe imageView = icon

        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        // Belt and braces beside `DisplayName`: even were something unprintable
        // to reach the field, it lays out on one line at one baseline like
        // every other row rather than growing and drifting out of alignment.
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        addSubview(label)
        unsafe textField = label

        leadingConstraint = icon.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: ResultsOutlineView.Layout.baseInset)
        NSLayoutConstraint.activate([
            leadingConstraint,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Every glyph the list has drawn so far, at the one size it draws them.
    ///
    /// There are a few dozen distinct symbols in the whole table, and a
    /// scrolling list asks for one on every cell it recycles. Looking each up
    /// once and handing back the same image thereafter keeps the symbol
    /// lookup off the scrolling path entirely.
    private static var glyphs: [String: NSImage] = [:]

    /// A fixed point size for every glyph, so a run of files does not visibly
    /// change weight from row to row. The image well itself is a fixed width,
    /// and the glyph is centered in it, so the name beside it never moves.
    private static let glyphConfiguration = NSImage.SymbolConfiguration(
        pointSize: 13, weight: .regular)

    private static func glyph(named name: String) -> NSImage? {
        if let cached = glyphs[name] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphConfiguration)
        if let image { glyphs[name] = image }
        return image
    }

    func configure(with row: ComparisonRow, exists: Bool, extraIndent: CGFloat) {
        leadingConstraint.constant = ResultsOutlineView.Layout.baseInset + extraIndent

        // Only a row with something to say says it. A tooltip that appears
        // over every one of thousands of identical rows to report that they are
        // identical is noise the pointer cannot get away from.
        toolTip = row.isIdentical ? nil : row.differenceDescription

        let status = RowStatus(row)
        guard exists else {
            // Nothing on this side at all. An em dash reads as "absent" far
            // more clearly than an empty cell, which just looks like a bug —
            // and it takes the row's own color, because an item present on
            // only one side is a single finding spanning both halves.
            icon.image = nil
            label.stringValue = "—"
            let absent: NSColor = status == .identical
                ? .tertiaryLabelColor : status.nameColor
            restingTextColor = absent
            restingIconColor = absent
            applyColors()
            return
        }

        icon.image = Self.glyph(named: row.kindSymbol)
        label.stringValue = row.displayName
        restingTextColor = status.nameColor
        restingIconColor = row.kindColor
        applyColors()
    }

    /// Restores the standard highlight behavior that a custom color breaks.
    ///
    /// `NSTableCellView` normally flips its text to white on a highlighted row
    /// by itself, but only for text it is still choosing the color of. As
    /// soon as an explicit color is set — which the red and gold here require
    /// — that automatic handling stops, and the glyph's `contentTintColor` was
    /// never covered by it at all. Reapplying both whenever the background
    /// style changes keeps a selected row looking like every other selected
    /// row in the system.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let isHighlighted = backgroundStyle == .emphasized
        // `alternateSelectedControlTextColor` is the semantic color for
        // content drawn on a highlighted row, and it correctly stays put when
        // the window is not key and the row is drawn unemphasized.
        label.textColor = isHighlighted
            ? .alternateSelectedControlTextColor : restingTextColor
        icon.contentTintColor = isHighlighted
            ? .alternateSelectedControlTextColor : restingIconColor
    }
}
