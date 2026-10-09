// MARK: - OpenPanelPresenter.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Presents `NSOpenPanel` as a sheet attached to the asking window, with a
// reusable configuration struct and consistent sizing. Each window is one
// comparison, so the folder chooser has to belong visibly to its tab.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How one file dialog should be configured.
@MainActor
struct OpenPanelConfiguration {
    var canChooseFiles: Bool = false
    var canChooseDirectories: Bool = true
    var allowsMultipleSelection: Bool = false
    var allowedContentTypes: [UTType] = []

    /// Shown at the top of the panel, saying what the user is choosing and why.
    var message: String?
    /// The confirmation button's label.
    var prompt: String?
    /// Where the panel opens. Defaults to the Desktop.
    var directoryURL: URL?
}

@MainActor
enum OpenPanelSelection {
    case canceled
    case urls([URL])
}

/// Presents `NSOpenPanel` as a sheet, with consistent sizing everywhere.
///
/// A sheet rather than a free-floating panel matters here beyond appearance:
/// each window is one comparison, so the dialog has to belong visibly to the
/// tab that asked for it.
@MainActor
enum OpenPanelPresenter {
    static func present(
        configuration: OpenPanelConfiguration,
        attachedTo window: NSWindow? = nil
    ) async -> OpenPanelSelection {
        let panel = NSOpenPanel()
        panel.canChooseFiles = configuration.canChooseFiles
        panel.canChooseDirectories = configuration.canChooseDirectories
        panel.allowsMultipleSelection = configuration.allowsMultipleSelection

        if !configuration.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = configuration.allowedContentTypes
        }
        if let directoryURL = configuration.directoryURL {
            panel.directoryURL = directoryURL
        } else if let desktop = FileManager.default.urls(
            for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }
        if let message = configuration.message { panel.message = message }
        if let prompt = configuration.prompt { panel.prompt = prompt }

        panel.styleMask.remove(.resizable)
        panel.setContentSize(NSSize(width: 600, height: 400))
        panel.isMovable = false

        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow

        return await withCheckedContinuation { continuation in
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(
                    returning: response == .OK ? .urls(panel.urls) : .canceled)
            }
            if let targetWindow {
                panel.beginSheetModal(for: targetWindow, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }
    }
}
