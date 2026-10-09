// MARK: - ComparisonFlags.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Defines the bit sets that describe a comparison: `ComparisonOptions` for what
// the engine is allowed to spend time on, and `ComparisonFlags` for every way
// one pair of items was found to differ. The flag layout deliberately mirrors
// the reference application's.

import Foundation

/// What the engine is allowed to spend time on.
struct ComparisonOptions: OptionSet, Sendable, Hashable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Read both files back and compare them byte for byte.
    ///
    /// Without this, two files that agree on size and timestamps are reported
    /// as identical — which is right virtually all of the time and costs no
    /// I/O at all. With it, a difference in content is *guaranteed* to be
    /// found, at the price of reading every matched pair off disk.
    static let fileContent = ComparisonOptions(rawValue: 1 << 0)
}

/// Everything that was found to differ about one pair of items.
///
/// The bit layout intentionally mirrors the reference application: the low
/// half describes attributes that differ between two items that *both* exist,
/// and the high half describes structural differences where one side is
/// missing or is a different kind of object entirely.
struct ComparisonFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    // Attribute differences (both sides present, same kind).
    static let permissions          = ComparisonFlags(rawValue: 1 << 0)
    static let groupID              = ComparisonFlags(rawValue: 1 << 1)
    static let userID               = ComparisonFlags(rawValue: 1 << 2)
    static let creationDate         = ComparisonFlags(rawValue: 1 << 3)
    static let modificationDate     = ComparisonFlags(rawValue: 1 << 4)
    static let dataSize             = ComparisonFlags(rawValue: 1 << 5)
    static let resourceSize         = ComparisonFlags(rawValue: 1 << 6)
    /// Only ever set when `.fileContent` was requested.
    static let dataContent          = ComparisonFlags(rawValue: 1 << 7)
    /// Only ever set when `.fileContent` was requested.
    static let resourceContent      = ComparisonFlags(rawValue: 1 << 8)

    // Structural differences.
    /// Present on the left, absent on the right.
    static let removed              = ComparisonFlags(rawValue: 1 << 16)
    /// Absent on the left, present on the right.
    static let added                = ComparisonFlags(rawValue: 1 << 17)
    /// Present on both sides, but as different kinds of object
    /// (a folder on one side and a file on the other, say).
    static let replaced             = ComparisonFlags(rawValue: 1 << 18)

    /// The high half: every flag that describes a *structural* change.
    static let structuralMask = ComparisonFlags(rawValue: 0xFFFF_0000)

    var isIdentical: Bool { isEmpty }
    var isStructural: Bool { !isDisjoint(with: .structuralMask) }
}
