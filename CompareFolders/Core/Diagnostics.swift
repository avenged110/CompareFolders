// MARK: - Diagnostics.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The `Diagnostic` type for a problem hit while scanning or comparing —
// recorded rather than thrown, so one unreadable file never aborts a comparison
// of thousands. Provides a stable ordering so the same comparison reports its
// problems in the same order on every run.

import Darwin
import Foundation
import Synchronization
import System

/// A problem encountered while scanning or comparing, recorded rather than thrown.
///
/// A single unreadable file must never abort a comparison of a hundred
/// thousand others, but it must never be silently swallowed either: a folder
/// the engine could not read is exactly the kind of thing that would otherwise
/// masquerade as "no differences here".
struct Diagnostic: Sendable, Hashable, Identifiable {
    let id = UUID()
    /// Absolute path of the object involved.
    var path: String
    /// What the engine was attempting.
    var summary: String
    /// `errno` at the point of failure, or 0.
    var code: Int32

    var localizedDescription: String {
        // `Errno`'s description is the same text `strerror` gives, without
        // handing a C pointer back to this code.
        code == 0 ? summary : "\(summary): \(Errno(rawValue: code))"
    }

    /// A stable order for a set of diagnostics.
    ///
    /// The order they were raised in is the order several threads happened to
    /// reach them, which differs from one run to the next over the same two
    /// folders. Everything else a comparison produces is already independent
    /// of that, and this is the one thing the user sees that would not have
    /// been — a list that reshuffles itself when the same comparison is run
    /// twice reads as though the findings changed.
    ///
    /// Every field takes part in the ordering, not just the path: `sorted` is
    /// not a stable sort, so two diagnostics that compared equal could still
    /// swap places between runs.
    static func ordered(_ diagnostics: [Diagnostic]) -> [Diagnostic] {
        diagnostics.sorted {
            ($0.path, $0.code, $0.summary) < ($1.path, $1.code, $1.summary)
        }
    }
}

/// Cooperative cancellation that the synchronous scanning loops can poll.
///
/// `Task.isCancelled` is not reachable from inside the tight C-level loops in
/// the scanner, so cancellation is carried explicitly by this flag, which the
/// owning `Task` sets when it is itself canceled.
final class CancellationFlag: Sendable {
    private let flag = Atomic<Bool>(false)

    init() {}

    var isCanceled: Bool { flag.load(ordering: .relaxed) }

    func cancel() { flag.store(true, ordering: .relaxed) }
}
