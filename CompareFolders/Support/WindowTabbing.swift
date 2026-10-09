// MARK: - WindowTabbing.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Bridges to AppKit to give each window its tab identity — a constant title
// bar, a per-comparison tab title, and a matching Window-menu entry — none of
// which SwiftUI exposes. Coalesces the updates so a counting progress readout
// does not rebuild the menu many times a second.

import AppKit
import SwiftUI

/// Gives each window its tab identity.
///
/// Three different names are involved and they are deliberately not the same:
///
/// - `window.title` stays "Compare Folders" forever, so the title bar is a
///   constant, recognizable label rather than a changing description.
/// - `window.tab.title` names *this* comparison, so a row of tabs can be told
///   apart at a glance.
/// - The Window menu is given the same per-comparison name through
///   `changeWindowsItem`, since it otherwise follows `window.title` and would
///   list several identical entries.
///
/// SwiftUI exposes none of this, which is why it is done here.
private struct WindowIdentity: NSViewRepresentable {
    let tabTitle: String

    func makeNSView(context: Context) -> IdentityView {
        IdentityView(frame: .zero)
    }

    func updateNSView(_ view: IdentityView, context: Context) {
        view.desiredTitle = tabTitle
        view.scheduleApply()
    }

    /// Carries the name to the window, and remembers what it last carried.
    ///
    /// `updateNSView` runs whenever anything the window's view hierarchy reads
    /// changes, which during a comparison is many times a second as the
    /// progress readout counts up. Applying the same two names to AppKit that
    /// many times a second is pure waste — and `changeWindowsItem` rebuilds a
    /// menu each time — so the work is coalesced onto one turn of the run loop
    /// and then skipped entirely unless the name has actually changed.
    final class IdentityView: NSView {
        var desiredTitle = ""
        private var appliedTitle: String?
        /// The window `appliedTitle` was applied to. A view that has moved to
        /// a different window has told that window nothing, however familiar
        /// the name it is carrying looks.
        private weak var appliedWindow: NSWindow?
        private var isScheduled = false

        /// The window arrives after the first update pass, and nothing
        /// guarantees another one follows it — so the name is applied from
        /// here as well, which is exactly the moment there is a window to
        /// apply it to.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        func scheduleApply() {
            guard !isScheduled else { return }
            isScheduled = true
            // SwiftUI sets `window.title` on its own schedule; applying on the
            // next turn of the run loop lands after it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isScheduled = false
                self.apply()
            }
        }

        private func apply() {
            // `NSView.window` is `unowned(unsafe)`; the window owns this
            // view for as long as the view is in it, which is when this runs.
            guard let window = unsafe window else { return }
            if window.tabbingIdentifier != AppDelegate.tabbingIdentifier {
                window.tabbingIdentifier = AppDelegate.tabbingIdentifier
            }
            guard appliedTitle != desiredTitle || appliedWindow !== window else { return }
            appliedTitle = desiredTitle
            appliedWindow = window
            window.tab.title = desiredTitle
            NSApp.changeWindowsItem(window, title: desiredTitle, filename: false)
        }
    }
}

extension View {
    /// Names this window's tab and its Window-menu entry.
    func windowIdentity(tabTitle: String) -> some View {
        background(WindowIdentity(tabTitle: tabTitle)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true))
    }
}

/// The session belonging to whichever window is frontmost.
///
/// This is how the File menu reaches the tab the user is actually looking at:
/// menu commands live outside any window's view hierarchy, so the focused
/// scene has to publish its session for them to act on.
extension FocusedValues {
    @Entry var comparisonSession: ComparisonSession?
}

/// Application-level plumbing that SwiftUI does not reach.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let tabbingIdentifier = "comparison"

    /// Opens a fresh window from the app's `WindowGroup`. Installed by the
    /// scene, which is the only place SwiftUI's `openWindow` action exists.
    var openNewWindow: (() -> Void)?

    private var shortcutMonitor: Any?
    private var helpMenuObserver: MenuTrackingObserver?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // "Start Dictation" and "Emoji & Symbols" are injected into the Edit
        // menu by the text input system, below the level SwiftUI's Commands
        // API operates at. It only works from here — by
        // `applicationDidFinishLaunching` the menu already exists.
        MenuBarPolicy.suppressInputMenuItems()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeHelpMenu()
        installShortcutMonitor()

        // SwiftUI rebuilds the menu bar when commands re-evaluate, which can
        // put the empty Help menu back. Removing it again whenever a menu is
        // about to open means it is never seen; the removal is idempotent.
        helpMenuObserver = MenuTrackingObserver { [weak self] _ in
            self?.removeHelpMenu()
        }
    }

    /// Closing the last tab quits.
    ///
    /// Every window is one comparison and there is no document, no library and
    /// nothing kept between launches, so an app with no windows open has
    /// nothing left to be: it would sit in the Dock owning a menu bar whose
    /// every command is disabled. Closing the last tab is therefore the same
    /// act as quitting, and is treated as one.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Handles ⇧⌘T ourselves.
    ///
    /// AppKit adds "Show/Hide Tab Bar" to the View menu lazily — the item does
    /// not exist until a menu has been opened once. A key equivalent assigned
    /// to that item therefore cannot fire until the user has already pulled
    /// down the View menu, which is exactly the symptom it was supposed to
    /// cure. Watching the event stream instead makes the shortcut work from
    /// launch and leaves the menu item untouched.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags
                .intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                  event.charactersIgnoringModifiers?.lowercased() == "t"
            else { return event }
            NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: nil, from: nil)
            return nil  // Consumed.
        }
    }

    /// Removes the Help menu outright.
    ///
    /// Replacing the `.help` command group with nothing empties the menu but
    /// leaves the (now pointless) title sitting in the menu bar, so the menu
    /// itself has to be taken out here.
    private func removeHelpMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        if let help = mainMenu.items.first(where: {
            $0.submenu?.title == "Help" || $0.title == "Help"
        }) {
            mainMenu.removeItem(help)
        }
    }

    // MARK: - Tabbing

    /// Supplies the standard New Tab behavior.
    ///
    /// Named for the selector macOS's own tabbing machinery sends, and kept
    /// `@objc` so that machinery can still reach it — but the File menu calls
    /// it *directly* rather than through `NSApp.sendAction`. Sending it does
    /// not arrive here: SwiftUI's window hosting answers `newWindowForTab:`
    /// itself, further up the responder chain, and what it does with it is
    /// open a detached window. `sendAction` duly reports the action as
    /// handled, so the failure is silent — a new window every time, and this
    /// method never called at all. Calling it directly is what actually gets
    /// a tab.
    ///
    /// The new window has to be added to the existing one's tab group
    /// explicitly: automatic tabbing only takes over when the user has set
    /// "Prefer tabs" to "Always" in System Settings, and everywhere else a
    /// plain separate window is what would otherwise appear.
    @objc func newWindowForTab(_ sender: Any?) {
        let host = hostWindow
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))

        openNewWindow?()

        // SwiftUI does not necessarily have the window on screen by the next
        // turn of the run loop — how long it takes depends on how much of the
        // scene has to be built. A single deferred check therefore misses it
        // sometimes and silently leaves a detached window behind, so this
        // keeps looking briefly until the window actually exists.
        adoptNewWindow(host: host, existingBefore: before, attemptsRemaining: 40)
    }

    private func adoptNewWindow(
        host: NSWindow?,
        existingBefore: Set<ObjectIdentifier>,
        attemptsRemaining: Int
    ) {
        guard attemptsRemaining > 0 else { return }

        // Matching on the tabbing identifier would be tighter, but that is
        // applied by the window's own SwiftUI accessor a run loop turn after
        // the window appears, so the poll can see the window before its
        // identifier is set. Excluding panels is enough to pick the right one.
        let created = NSApp.windows.first {
            !existingBefore.contains(ObjectIdentifier($0))
                && $0.isVisible
                && !($0 is NSPanel)
        }

        guard let created else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.adoptNewWindow(
                    host: host,
                    existingBefore: existingBefore,
                    attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }

        created.tabbingIdentifier = Self.tabbingIdentifier
        if let host, host !== created, host.tabGroup !== created.tabGroup {
            host.addTabbedWindow(created, ordered: .above)
        }
        created.makeKeyAndOrderFront(nil)
    }

    /// The window a new tab should join.
    ///
    /// `keyWindow` alone is not enough: it is nil whenever the app is not
    /// active, which is exactly the case when the command arrives by keyboard
    /// shortcut as the app is being brought forward. Falling back through the
    /// main window to any visible comparison window means a tab is still
    /// created rather than a stray separate window.
    private var hostWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first {
                $0.isVisible && $0.tabbingIdentifier == Self.tabbingIdentifier
            }
    }
}

