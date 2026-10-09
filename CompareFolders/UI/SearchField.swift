// MARK: - SearchField.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// An `NSSearchField` wrapped for SwiftUI, used because `.searchable` insists on
// placing its field in a toolbar this window does not have. Reports every
// keystroke, since filtering is just a view over rows already in memory.

import AppKit
import SwiftUI

/// The name filter's text field, drawn by AppKit.
///
/// SwiftUI's `.searchable` is not an option here. It does not place a field
/// where it is asked to: it hands the search field to the nearest navigation
/// container, which puts it in a toolbar. This window has no navigation
/// container and no toolbar — the control bar is an ordinary stack of views —
/// so `.searchable` would either do nothing or move the field somewhere the
/// rest of the bar is not.
///
/// `NSSearchField` is what `.searchable` would have used anyway, so wrapping it
/// directly gives exactly the chrome that was wanted — the fixed magnifying
/// glass, the clear button that appears only once there is something to clear,
/// the rounded search bezel — with the field still sitting in the row beside
/// the filter menu, and still bound to the same `searchText`.
struct SearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        // Report every keystroke rather than waiting for Return: filtering is
        // a view over rows already in memory, so there is nothing to defer.
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        // The clear button ends editing without a text-change notification, so
        // the field's own action is watched too. Both routes land in the same
        // place, and setting the binding to a value it already holds is free.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        // Guarded: assigning to `stringValue` while the user is typing would
        // collapse the insertion point to the end of the line.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            publish(field.stringValue)
        }

        // Explicitly main-actor: an `@objc` action is nonisolated by default,
        // and this one only ever arrives from the AppKit event loop.
        @MainActor @objc func searchFieldChanged(_ sender: NSSearchField) {
            publish(sender.stringValue)
        }

        private func publish(_ value: String) {
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }
    }
}
