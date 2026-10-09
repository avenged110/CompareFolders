// MARK: - CompareFoldersApp.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The `@main` entry point. Defines the app's single `WindowGroup` scene — each
// window a self-contained comparison tab — and installs the File, View, and
// Settings menu commands, all of which act on whichever tab is frontmost.

import AppKit
import SwiftUI

@main
struct CompareFoldersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    static let windowID = "comparison"

    var body: some Scene {
        // Each tab is an independent comparison, which is the whole reason the
        // app supports them: two folders per tab, as many tabs as the user has
        // questions.
        WindowGroup(id: Self.windowID) {
            ContentView()
                .onAppear {
                    delegate.openNewWindow = { openWindow(id: Self.windowID) }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            // "About Compare Folders" with the ⌘? the stock item lacks.
            AppInfoCommands(appName: "Compare Folders")
            CommandGroup(replacing: .newItem) {
                FileCommands(openWindow: openWindow, delegate: delegate)
            }
            // The application menu's own Settings submenu, immediately under
            // About. `.appSettings` is the placement macOS reserves for it,
            // and using it rather than `after: .appInfo` means the separator
            // and the position are the system's, in whatever order a future
            // macOS decides that menu should run.
            CommandGroup(replacing: .appSettings) {
                SettingsCommands()
            }
            // `.sidebar` is the top of the View menu — above AppKit's own tab
            // items, which sit between it and the toolbar group. Inserting
            // before `.toolbar` instead put these underneath Show Tab Bar and
            // Show All Tabs, which is a long way down a menu for the commands
            // this app's View menu is mostly *for*.
            CommandGroup(before: .sidebar) {
                ViewCommands()
            }
            // The app has nothing to put in a Help menu. Emptying the group
            // clears it, and `AppDelegate.removeHelpMenu()` takes out any
            // title left behind. Removing the scene's whole command set would
            // also have done it, but takes the application, Edit and Window
            // menus with it.
            EmptyCommandGroup(.help)
        }
    }
}

/// The top of the View menu: what the list is showing, then what to do with
/// what is selected in it.
///
/// The filter submenu comes first because it governs the whole list, and the
/// selection commands after it because they govern a part of it. Both are also
/// reachable inside the window — the filter from the button on the control bar,
/// the two Reveals and Copy from the list's own contextual menu — and neither
/// place is redundant: the menu bar is where a user looks for a keyboard
/// shortcut and for what an app can do at all, and the window is where the
/// hand already is.
///
/// The selection commands are disabled with nothing selected rather than
/// quietly acting on everything. ⌥⌘L and ⌥⌘R deliberately echo the File menu's
/// ⌘L and ⌘R: the same two sides, one pair choosing the folders and the other
/// looking inside them.
private struct ViewCommands: View {
    /// The session of whichever window is frontmost, exactly as the File menu
    /// reaches it.
    @FocusedValue(\.comparisonSession) private var session

    var body: some View {
        // The same items as the control bar's filter button, from the same
        // source, reading and writing the same session — so a switch thrown
        // here is already thrown there.
        Menu("Filter Results") {
            if let session {
                FilterMenuItems(session: session)
            }
        }
        .disabled(session == nil)

        Divider()

        // Titled from the selection, so a dozen highlighted rows are not
        // described as one item. Worded by the same helpers as the list's own
        // contextual menu, which offers the same three commands.
        Button(RevealInFinder.menuTitle(.left, count: selectedCount)) { reveal(.left) }
            .keyboardShortcut("l", modifiers: [.option, .command])
            .disabled(selectedCount == 0)

        Button(RevealInFinder.menuTitle(.right, count: selectedCount)) { reveal(.right) }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(selectedCount == 0)

        // ⇧⌘C, not ⌘C: plain Copy belongs to the Edit menu and to the name
        // field, and taking it would have meant the field's own Copy stopped
        // working whenever a row happened to be selected behind it.
        Button(CopyPaths.menuTitle(count: selectedCount)) {
            CopyPaths.copy(session?.selectedRows ?? [])
        }
        .keyboardShortcut("c", modifiers: [.shift, .command])
        .disabled(selectedCount == 0)

        Divider()
    }

    private var selectedCount: Int { session?.selectedCount ?? 0 }

    private func reveal(_ side: FolderSide) {
        guard let session else { return }
        RevealInFinder.reveal(
            session.selectedRows, on: side, in: session.results,
            from: NSApp.keyWindow)
    }
}

/// The application menu's Settings item, as a submenu rather than a window.
///
/// macOS expects Settings to open a panel, and SwiftUI would supply one for
/// free given a `Settings` scene. This app deliberately has none: everything
/// it can be told is a statement about the comparison in front of you, and a
/// separate window would put those switches somewhere you cannot see what they
/// change. A submenu keeps the item where the system puts it — and where a
/// user who has not found the gear button on the control bar will look — while
/// leaving the switches themselves one gesture from the list they act on.
///
/// No ⌘, for the same reason: the shortcut belongs to a panel that opens, not
/// to a submenu that springs.
private struct SettingsCommands: View {
    @FocusedValue(\.comparisonSession) private var session

    var body: some View {
        Menu("Settings") {
            if let session {
                SettingsMenuItems(session: session)
            }
        }
        .disabled(session == nil)
    }
}

/// The File menu.
///
/// Folder selection comes first because it is what the user reaches for most,
/// then the window and tab commands.
private struct FileCommands: View {
    let openWindow: OpenWindowAction
    let delegate: AppDelegate

    /// The session of whichever window is frontmost. Menu commands live
    /// outside any view hierarchy, so the focused scene publishes it for them.
    @FocusedValue(\.comparisonSession) private var session

    var body: some View {
        Button("Select Left Folder…") { session?.chooseFolder(.left) }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(session == nil)

        Button("Select Right Folder…") { session?.chooseFolder(.right) }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session == nil)

        // ⌘↩ rather than ⌘C, which is also Copy and shadowed it everywhere in
        // the app, including the name filter field. The Compare button no
        // longer carries the shortcut itself: a menu item's key equivalent is
        // already window-wide, and duplicating it on the button would only add
        // a second responder competing for the same keystroke.
        Button("Compare Folders") { session?.compare() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(session?.canCompare != true)

        Divider()

        // Called directly, not sent: SwiftUI answers `newWindowForTab:`
        // before the app delegate ever sees it, and opens a detached window.
        // See `AppDelegate.newWindowForTab(_:)`.
        Button("New Tab") {
            delegate.newWindowForTab(nil)
        }
        .keyboardShortcut("t", modifiers: .command)

        Button("New Window") {
            openWindow(id: CompareFoldersApp.windowID)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}
