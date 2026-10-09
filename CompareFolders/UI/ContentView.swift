// MARK: - ContentView.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The root view of one tab: the control bar, the results outline, an optional
// diagnostics bar, and the status bar in a single vertical stack. Owns the
// tab's `ComparisonSession` and publishes it as a focused scene value for the
// menu commands.

import SwiftUI

/// One tab's worth of application: the control bar, and the results beneath it.
struct ContentView: View {
    @State private var session = ComparisonSession()
    @State private var isShowingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            ControlBar(session: session)
            Rectangle()
                .fill(Color(nsColor: .resultsHeaderTopEdge))
                .frame(height: 1)
            results
            // Both bars are ordinary members of the stack rather than overlays
            // or safe-area insets, so the scroll view above them is simply laid
            // out in what is left. Nothing can end up underneath either bar,
            // which means there is no content inset to get wrong and no
            // scroller vanishing behind opaque chrome.
            if !session.results.diagnostics.isEmpty {
                DiagnosticsBar(
                    diagnostics: session.results.diagnostics,
                    deniedAccess: session.results.hasAccessFailures,
                    isExpanded: $isShowingDiagnostics)
            }
            Divider()
            StatusBar(session: session)
        }
        .frame(minWidth: 900, minHeight: 600)
        // The title is deliberately fixed. Apple's guidance is to name the
        // document, but there is no document here — and with several tabs
        // open, a constant title is what keeps the app identifiable.
        .navigationTitle("Compare Folders")
        .windowIdentity(tabTitle: session.tabTitle)
        .focusedSceneValue(\.comparisonSession, session)
    }

    @ViewBuilder
    private var results: some View {
        Group {
            if session.hasResults {
                if session.visibleRoots.isEmpty {
                    emptyResults
                } else {
                    ResultsOutlineView(session: session)
                }
            } else if session.isRunning {
                TablePlaceholder(
                    emblem: .progress,
                    title: "Comparing…",
                    message: describe(session.progress))
            } else if let failure = session.failure {
                TablePlaceholder(
                    emblem: .symbol("exclamationmark.triangle.fill"),
                    title: "Comparison Failed",
                    message: failure)
            } else if session.canCompare {
                // Both folders are chosen and there is nothing on screen:
                // either they have not been compared yet, or a comparison was
                // stopped, which discards what it had gathered. Telling the
                // user to choose folders in that state names the one thing
                // they have already done.
                TablePlaceholder(
                    emblem: .symbol("folder.fill.badge.gearshape"),
                    title: "Ready to Compare",
                    message: "Click Compare to compare the two folders.")
            } else {
                TablePlaceholder(
                    emblem: .symbol("folder.fill.badge.questionmark"),
                    title: "Choose Folders",
                    message: "Select a folder on each side, then click Compare.")
            }
        }
        // The shadows the chrome above and below casts onto the list, results
        // or placeholder alike. Overlays rather than shadows on the bars
        // themselves: a real shadow would be drawn *behind* each bar's opaque
        // material and never seen, and this way the list pays no offscreen
        // pass while scrolling.
        //
        // The lower one sits at the bottom of the results area, so it falls
        // under whichever chrome happens to be there — the diagnostics bar
        // when a comparison raised any, and the status bar when it did not.
        .overlay(alignment: .top) { ChromeShadow(under: .top) }
        .overlay(alignment: .bottom) { ChromeShadow(under: .bottom) }
    }

    /// A finished comparison with nothing to show, which is three different
    /// situations and only one of them is good news.
    ///
    /// Nothing compared *and* something unreadable is the case that has to be
    /// told apart from the rest: a folder the engine was refused entry to
    /// stats perfectly well and then yields no children, so the comparison
    /// succeeds and reports two empty folders. Announcing that they are empty
    /// would be stating as a finding the one thing that was never established.
    @ViewBuilder
    private var emptyResults: some View {
        let total = session.summary.total
        let blocked = total == 0 && !session.results.diagnostics.isEmpty
        TablePlaceholder(
            emblem: .symbol(blocked
                            ? "exclamationmark.triangle.fill"
                            : "line.3.horizontal.decrease.circle.fill"),
            title: blocked
                ? "Nothing to Compare"
                : (total == 0 ? "Both Folders Empty" : "All Results Filtered Out"),
            message: blocked
                ? "Nothing in either folder could be read. Further details below."
                : (total == 0
                   ? nil
                   : "\(total.formatted()) items were compared."))
    }

    /// What the progress readout says while a comparison runs.
    ///
    /// Phrased as the message under a fixed title, so the title stays
    /// "Comparing…" for the whole run and only the detail beneath it changes.
    private func describe(_ progress: ComparisonProgress?) -> String {
        switch progress {
        case .scanning(let items):
            return "Scanned \(items.formatted()) items"
        case .matching:
            return "Matching folders…"
        case .readingContents(let completed, let total, let bytes, let totalBytes):
            // The file count alone is what this used to say, and on real
            // content it is close to meaningless: one disk image and one
            // preference file advance it by exactly the same amount, so it can
            // sit still for many minutes while the app reads at full speed.
            // The bytes are where the time actually goes, so they are said too
            // — parenthesized, because they are a second reading of the same
            // progress rather than a further fact about it.
            let counts = "\(pad(completed.formatted(), toWidthOf: total.formatted())) "
                + "of \(total.formatted())"
            guard totalBytes > 0 else { return "Comparing \(counts)" }
            let totalSize = format(totalBytes)
            return "Comparing \(counts) (\(pad(format(bytes), toWidthOf: totalSize)) "
                + "of \(totalSize))"
        case nil:
            return "Preparing…"
        }
    }

    /// Left-pads `text` to the width of `reference`.
    ///
    /// The figure space is the one blank in the font that is exactly as wide as
    /// a digit, which is what makes this work: the readout is drawn with
    /// `monospacedDigit`, so a padded "12" and an unpadded "999" occupy the
    /// same width to the pixel and the sentence around them stops shuffling
    /// sideways every time a number gains a place.
    private func pad(_ text: String, toWidthOf reference: String) -> String {
        let shortfall = reference.count - text.count
        guard shortfall > 0 else { return text }
        return String(repeating: "\u{2007}", count: shortfall) + text
    }

    /// A byte count, sized as the Finder sizes one but written to a fixed
    /// number of places.
    ///
    /// `.byteCount` is not used, because it varies its precision with the
    /// value: it writes "1 GB", then "1.1 GB", then "12.4 GB", so the string
    /// changes length as the run proceeds even within one unit. Two places
    /// always means the same width for as long as the unit and the number of
    /// whole digits hold, and `pad(_:toWidthOf:)` covers the rest.
    private func format(_ bytes: UInt64) -> String {
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < Self.byteUnits.count - 1 {
            value /= 1000
            unit += 1
        }
        // Whole bytes get no decimal point: a fraction of a byte is not a
        // quantity, and the counts down here are small enough not to jitter.
        guard unit > 0 else { return "\(bytes) bytes" }
        return value.formatted(.number.precision(.fractionLength(2)))
            + "\u{00A0}" + Self.byteUnits[unit]
    }

    /// Decimal units, matching what the Finder reports for the same file.
    private static let byteUnits = ["bytes", "KB", "MB", "GB", "TB", "PB"]

}

/// The soft edge a bar casts onto the list it abuts.
///
/// Drawn into the list's own bounds rather than out of the bar, because the
/// bars are opaque and a shadow behind one is a shadow nobody sees. Three
/// stops rather than two: a straight linear ramp reads as a gray band with a
/// visible end, while falling away quickly and then trailing off is what an
/// actual shadow does.
private struct ChromeShadow: View {
    /// The side of the list the chrome is on — `.top` for the control bar
    /// above it, `.bottom` for the status and diagnostics bars below.
    let edge: VerticalEdge

    init(under edge: VerticalEdge) { self.edge = edge }

    /// Deep enough to read as a real edge at a glance, shallow enough that the
    /// first row of the list is never hard to read through it.
    private static let height: CGFloat = 6

    var body: some View {
        LinearGradient(
            colors: [.black.opacity(0.34), .black.opacity(0.08), .clear],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top)
            .frame(height: Self.height)
            .allowsHitTesting(false)
    }
}

/// The strip along the very bottom, reading out what the list currently holds.
///
/// The counts used to sit beside the Compare button, where they were both a
/// caption on a control they do not describe and a moving target that resized
/// the row. Down here they are where the counts in a Finder window are, and
/// they can say as much as they need to without pushing anything around.
private struct StatusBar: View {
    let session: ComparisonSession

    private let barHeight: CGFloat = 24

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: barHeight)
            .padding(.horizontal, 8)
    }

    private var text: String {
        if session.isRunning { return "Comparing…" }
        if session.failure != nil { return "Comparison failed" }
        guard session.hasResults else {
            switch (session.leftURL != nil, session.rightURL != nil) {
            case (false, false): return "No folders selected"
            case (true, false): return "No folder selected on the right"
            case (false, true): return "No folder selected on the left"
            case (true, true): return "Ready to compare"
            }
        }
        return counts
    }

    /// The finished comparison in one line: how much was looked at, and then,
    /// in brackets, every way in which any of it differs.
    private var counts: String {
        let summary = session.summary
        var items = summary.total == 1
            ? "1 comparison"
            : "\(summary.total.formatted()) comparisons"
        // The selection leads, because it is the thing that just changed and
        // the thing the user is asking about.
        if session.selectedCount > 0 {
            items = "\(session.selectedCount.formatted()) selected of \(items)"
        }

        var detail = summary.differences.described
        if detail.isEmpty { detail = ["no differences"] }
        // What the filter is holding back belongs with the counts it
        // contradicts: without it the brackets describe a list the user is not
        // looking at.
        if session.visibleCount != summary.total {
            detail.append("showing \(session.visibleCount.formatted())")
        }
        return "\(items) (\(detail.joined(separator: ", ")))"
    }
}

/// A quiet strip along the bottom listing anything the engine could not read.
///
/// These are never dropped on the floor: a folder that could not be opened is
/// a hole in the comparison, and the user has to be able to see that it exists
/// before trusting the result.
private struct DiagnosticsBar: View {
    let diagnostics: [Diagnostic]
    /// Whether anything was refused outright, as opposed to merely unreadable.
    let deniedAccess: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if isExpanded {
                List(diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(diagnostic.localizedDescription)
                            .font(.callout)
                        Text(diagnostic.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(height: 130)
                Divider()
            }
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: deniedAccess
                          ? "lock.trianglebadge.exclamationmark.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(deniedAccess ? .red : .yellow)
                    // An access failure is not a footnote. A comparison that
                    // was refused entry to part of a folder will look calm and
                    // successful while hiding every difference inside it, so
                    // it says plainly that the result cannot be trusted.
                    Text(deniedAccess
                         ? "Access was denied — this comparison is incomplete"
                         : (diagnostics.count == 1
                            ? "1 item could not be read"
                            : "\(diagnostics.count) items could not be read"))
                        .fontWeight(deniedAccess ? .semibold : .regular)
                        .foregroundStyle(deniedAccess ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .background(.bar)
    }
}
