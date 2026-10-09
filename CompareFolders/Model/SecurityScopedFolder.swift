// MARK: - SecurityScopedFolder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// A user-chosen folder together with the security-scoped access claim that
// makes it readable under the sandbox, held for as long as the folder stays
// selected. Stores the system-supplied URL untouched so its sandbox token is
// never lost.

import Foundation

/// A user-chosen folder, together with the sandbox grant that makes it readable.
///
/// This app is sandboxed and holds only `files.user-selected.read-only`, so a
/// folder is readable purely because the user pointed at it. The URL handed
/// back by `fileImporter` — or by a drag — carries a sandbox extension token,
/// and that token has to be *claimed* with
/// `startAccessingSecurityScopedResource()` before anything can be read. Skip
/// that call and every `opendir` and `open` fails with `EPERM`, no matter that
/// the user just picked the folder by hand.
///
/// Two rules follow, and both are easy to violate by accident:
///
/// - The claim has to stay held for the *whole* comparison, not just the
///   moment of picking. That is why this is an object with a lifetime rather
///   than a function: access ends when the folder is replaced or the tab goes
///   away, and not before.
/// - The token belongs to the specific URL value the system produced.
///   Rebuilding an equivalent URL from a path string, or even taking
///   `standardizedFileURL`, yields a URL with no token and access is silently
///   lost. The original is therefore stored untouched, and only ever *read*
///   from to derive a path for the engine.
final class SecurityScopedFolder {
    /// The URL exactly as the system supplied it. Never rebuilt or normalized.
    let url: URL

    /// Whether the claim succeeded and therefore needs releasing.
    ///
    /// A URL with no sandbox extension — one from an unsandboxed build, say —
    /// returns `false` here. That is not an error, and it must not be balanced
    /// with a matching `stop`.
    private let isHolding: Bool

    /// The name of the volume the folder lives on, as the Finder shows it.
    ///
    /// Read once, here, rather than whenever the well redraws: it is a trip
    /// into the file system, and the answer cannot change while this object
    /// exists — a folder that was on a volume stays on it, and a folder that is
    /// picked afresh gets a new object anyway.
    let volumeName: String?

    init(url: URL) {
        self.url = url
        self.isHolding = url.startAccessingSecurityScopedResource()
        self.volumeName = try? url.resourceValues(forKeys: [.volumeNameKey])
            .volumeName
    }

    deinit {
        if isHolding {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// The file-system path for the engine to walk.
    var path: String {
        url.path(percentEncoded: false)
    }
}
