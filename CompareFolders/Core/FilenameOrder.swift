// MARK: - FilenameOrder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The one collation rule used both to sort directory listings and to decide
// whether two names are the same item, so the two can never drift apart. It
// folds only case and Unicode composition — the distinctions the file system
// itself ignores — and refuses every other kind of collator similarity.

import Foundation

/// Filename collation, and the single most consequential piece of the engine.
///
/// Two directory listings are matched up by a merge walk, which is only
/// correct if both sides are sorted by *exactly* the same rule that is later
/// used to decide whether two names refer to the same item. Both operations go
/// through this one type so they cannot drift apart.
///
/// Two names are the same item when they differ only in ways the *file system*
/// itself does not distinguish, and that is a much shorter list than a
/// collator's idea of similarity:
///
/// - **Case**, because the overwhelmingly common case is comparing two copies
///   of a tree across volumes, and macOS volumes are usually case-insensitive.
///   Treating `README` and `readme` as different items there would report
///   phantom additions and removals.
/// - **Unicode composition**, because the same name really is stored
///   decomposed on one volume and precomposed on another. A byte-wise
///   comparison would report every single such file as both added and removed.
///
/// Everything else a collator will offer is deliberately refused. A numeric
/// reading makes `IMG_1.jpg` and `IMG_01.jpg` the same photograph; width
/// folding makes `1` and `１` the same file; the compatibility folds equate
/// `ﬁ` with `fi` and `ß` with `ss`. Each of those pairs is two files that sit
/// side by side in one folder quite happily, and calling any of them one item
/// makes the app report a file that is on both sides as missing from one of
/// them.
///
/// A numeric reading is still wanted for the *order* names are listed in,
/// where nothing is decided by it, and it lives in `naturalOptions` alone.
/// Width folding is not kept even for that, for a reason given there.
enum FilenameOrder {

    /// The form of a name that decides which item it is.
    ///
    /// Lower-casing folds case, and Swift compares the results by canonical
    /// equivalence, so both of the things volumes really do to a name are
    /// accounted for and nothing else is.
    ///
    /// Being a key rather than a comparison also makes identity *provably*
    /// transitive: it is plain equality on a derived value. The collator does
    /// not manage that. Asked directly it will call `FⅣ` equal to `ﬁ`, and
    /// then order those same two names as different when handed them the other
    /// way round.
    private static func identityKey(_ name: String) -> String {
        name.lowercased()
    }

    /// The natural reading order: `file2` before `file10`.
    ///
    /// Width folding is left out here too, to keep the ordering and the
    /// identity rule talking about the same things. With it in, the collator
    /// reads `１０` as ten when set beside `10` but not when set beside `3`,
    /// which orders those three names in a cycle — and a sort given a cycle
    /// has no defined result, so the two sides of a comparison can shelve a
    /// shared name differently and the walk then misses it.
    private static let naturalOptions: String.CompareOptions =
        [.caseInsensitive, .numeric]

    /// Ordering used to sort the children of a directory.
    ///
    /// Three levels, and the lower two are load-bearing rather than tidy.
    /// Natural order decides first, which is what puts `file2` before
    /// `file10`. It has nothing to say about `FILE1`, `FILE01` and `File1` —
    /// a numeric reading makes all three the same — and left to break that tie
    /// on its own it will happily seat `FILE01` between the two spellings of
    /// the same item.
    ///
    /// That gap is all it takes to lose a match. The merge walk compares only
    /// the two names at the front of each list, so a pairing it steps past is
    /// gone: `FILE1` and `File1` would be reported as one item removed and
    /// another added rather than as one unchanged file. Sorting ties by
    /// identity key keeps every spelling of one item together, and the last
    /// level makes the whole a total order, so a folder sorts the same way
    /// whatever order the file system happened to hand it over in.
    static func sortingCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }

        let natural = (lhs as NSString).compare(rhs, options: naturalOptions)
        if natural != .orderedSame { return natural }

        let leftKey = identityKey(lhs), rightKey = identityKey(rhs)
        if leftKey != rightKey {
            return leftKey < rightKey ? .orderedAscending : .orderedDescending
        }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// Ordering used to decide whether two names denote the same item.
    ///
    /// Names that are *not* the same item fall back to `sortingCompare`, and
    /// that is not a detail: the merge walk picks which side to advance from
    /// this result, while both sides were *sorted* by that one. Taking the
    /// direction from the sort itself makes it impossible for the two to
    /// disagree and for the walk to step past an item as a result. All this is
    /// then left to decide is where the equalities are.
    static func matchingCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        // Identical strings are by far the common case, and short-circuiting
        // them here avoids building two keys to reach the same answer.
        if lhs == rhs { return .orderedSame }
        if identityKey(lhs) == identityKey(rhs) { return .orderedSame }
        return sortingCompare(lhs, rhs)
    }
}
