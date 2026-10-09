// MARK: - ControlBar.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The bar across the top of the window holding the two folder wells and every
// option, filter, and the Compare/Stop button — the reason the app needs no
// separate settings window. Delays the Stop button's appearance so it does not
// flash into view on comparisons that finish in under a second.

import AppKit
import SwiftUI

/// The bar across the top of the window: everything selectable, configurable
/// and filterable lives here, which is why the app has no separate settings
/// window. Nothing is hidden behind a preferences panel because all of it
/// changes what the list below is showing right now.
struct ControlBar: View {
    @Bindable var session: ComparisonSession

    /// Set a moment after a comparison starts, and cleared the instant it ends.
    ///
    /// The Stop button waits for this rather than appearing with the first
    /// frame of the run: most comparisons under Heuristics are over in well
    /// under a second, and a button that appears and vanishes again before it
    /// can be read is worse than no button at all.
    @State private var isShowingStop = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                FolderWell(side: .left, session: session)
                FolderWell(side: .right, session: session)
            }
            optionsRow
        }
        // Ten points, matching the margin the inset table style leaves around
        // its row backgrounds. One vertical line then runs the height of the
        // window through the left folder well's border, the Compare button's
        // leading edge, the left column's heading and the edge of every stripe
        // in the list below.
        .padding(.horizontal, ResultsOutlineView.Layout.rowBackgroundInset)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Options

    /// The gap between every pair of controls in the options row.
    private static let spacing: CGFloat = 10

    /// How long a comparison has to still be running before Stop appears.
    private static let stopButtonDelay = Duration.milliseconds(750)

    private var optionsRow: some View {
        HStack(spacing: Self.spacing) {
            compareButton
            if isShowingStop {
                stopButton
                    // Opacity only. The button appears in a row that is already
                    // laid out, so anything that moved or scaled it would drag
                    // the controls beside it along; fading leaves them still.
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            settingsMenu
            filterMenu
            SearchField(placeholder: "Filter by name",
                        text: $session.filter.searchText)
                .frame(width: 260)
        }
        // Quick enough to feel like the button was always going to be there,
        // slow enough not to read as a flicker. Scoped to `isShowingStop` so
        // nothing else in the row animates when the comparison starts.
        .animation(.easeInOut(duration: 0.18), value: isShowingStop)
        // Restarted whenever the run state changes, which cancels a pending
        // reveal the moment a short comparison finishes.
        .task(id: session.isRunning) {
            guard session.isRunning else {
                isShowingStop = false
                return
            }
            try? await Task.sleep(for: Self.stopButtonDelay)
            isShowingStop = !Task.isCancelled && session.isRunning
        }
    }

    /// Starts a comparison, and does nothing else.
    ///
    /// One button, one job. It reads "Compare Again" once results are on screen
    /// because pressing it then is a different act — re-running a comparison
    /// the user is already looking at — and it goes back to "Compare" as soon
    /// as either folder changes and those results stop describing anything.
    ///
    /// The chrome changes with the state rather than the accent being dimmed,
    /// which is what AppKit does with a default button and what SwiftUI's
    /// prominent style does not: it keeps the accent when disabled, only
    /// washed out, so an unusable button goes on presenting itself as the
    /// thing the window is inviting you to do. Ordinary gray chrome says
    /// plainly that there is nothing to press, and the accent returns the
    /// moment there is. Both branches are the same size — the title sets the
    /// width — so nothing moves as it changes.
    @ViewBuilder
    private var compareButton: some View {
        let title = session.hasResults ? "Compare Again" : "Compare"
        // Held down for the duration of the run: the comparison it starts is
        // already under way, and there is nothing to press it for.
        let isEnabled = session.canCompare && !session.isRunning

        // No shortcut on either branch. ⌘↩ belongs to the File menu's Compare
        // Folders item, which is what makes it work everywhere in the window —
        // including while the name field has the keyboard focus, where a
        // button's own shortcut would be competing with the menu's.
        if isEnabled {
            Button { session.compare() } label: { buttonTitle(title) }
                .buttonStyle(.borderedProminent)
        } else {
            Button {} label: { buttonTitle(title) }
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }

    /// Cancels a running comparison. Present only while there is one.
    ///
    /// Plain bordered chrome, not prominent: stopping is the way out of
    /// something, never the thing the window is inviting you to do, and two
    /// accent-colored buttons side by side would leave neither of them
    /// reading as the primary one.
    private var stopButton: some View {
        Button(role: .destructive) {
            session.cancel()
        } label: {
            // The destructive role is carried for what it means rather than
            // for how it looks: outside an alert, macOS gives a bordered button
            // no red of its own, so the red is asked for here. `systemRed` is
            // the same red the system uses for a destructive menu item, at full
            // strength in both appearances.
            buttonTitle("Stop")
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(".", modifiers: .command)
    }

    /// A button title laid out at the width of the longest title either button
    /// carries, so both have identical chrome and neither changes size.
    ///
    /// The width is put on the *title*, not on the button: a frame around the
    /// button centers the chrome inside it, which would have walked Compare's
    /// leading edge away from the folder well above it every time the word
    /// shortened. Widening what the button is wrapped around instead leaves the
    /// button hugging it, still starting exactly where the row starts.
    private func buttonTitle(_ text: String) -> some View {
        Text(text).frame(width: Self.buttonTitleWidth)
    }

    private static let buttonTitleWidth: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .body)
        return ["Compare", "Compare Again", "Stop"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max()?.rounded(.up) ?? 0
    }()

    /// Everything that outlives the list currently on screen.
    ///
    /// Its own button rather than a drawer inside the filter menu. What is in
    /// here is not a filter: the comparison method decides what the engine
    /// does, and the persistence switch is a statement about the application.
    /// Even the half of that switch which does concern filters concerns them
    /// as a class, across every window and every launch, rather than saying
    /// anything about which of these findings to show — and the filter menu is
    /// easier to read for holding only the switches that answer that one
    /// question.
    ///
    /// The items themselves live in `SettingsMenuItems`, which the menu bar's
    /// copy of this menu uses too.
    private var settingsMenu: some View {
        Menu {
            SettingsMenuItems(session: session)
        } label: {
            Image(systemName: "gear")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose how folders are compared, and what is remembered")
    }

    /// Which findings the list shows. Shares its items with the menu bar's
    /// View ▸ Filter Results, by way of `FilterMenuItems`.
    ///
    /// The glyph fills in as soon as any switch is on, so a filtered list is
    /// never silently filtered: the button says so from across the window,
    /// without having to be opened.
    private var filterMenu: some View {
        Menu {
            FilterMenuItems(session: session, showsTitle: true)
        } label: {
            Image(systemName: session.filter.isInactive
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        // `.button` gives the menu ordinary push-button chrome, which the
        // borderless style does not.
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose which findings to show")
    }
}
