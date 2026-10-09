// MARK: - RowStatus.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reduces a row's difference flags to the three states that color alone has to
// carry now that there is no status column: identical (uncolored), unmatched
// (red), and modified (gold).

import AppKit

/// How a row reads at a glance.
///
/// Color carries the whole signal now that there is no status column, so
/// there are only three states and they are kept far apart: an item with no
/// counterpart is red, an item that exists on both sides but differs is gold,
/// and an item with no color at all is identical. Saying nothing about
/// identical rows is deliberate — they are the overwhelming majority, and
/// tinting them would drown out the handful that matter.
enum RowStatus: Sendable {
    case identical
    /// Missing from one side, or present on both as different kinds of object.
    case unmatched
    /// Present on both sides, but something about it differs.
    case modified

    init(_ row: ComparisonRow) {
        if row.flags.isIdentical {
            self = .identical
        } else if row.flags.isStructural {
            self = .unmatched
        } else {
            self = .modified
        }
    }

    /// The color of the item's name on an unselected row.
    var nameColor: NSColor {
        switch self {
        case .identical: .labelColor
        case .unmatched: .systemRed
        case .modified: .comparisonGold
        }
    }
}

extension NSColor {
    /// A gold that stays legible in both appearances.
    ///
    /// A single fixed gold cannot work: dark enough to read on a white
    /// background is nearly black on a dark one, and bright enough for dark
    /// mode washes out on white. This resolves per appearance, so the color
    /// is always distinct from red and always readable.
    static let comparisonGold = NSColor(name: "comparisonGold") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.95, green: 0.76, blue: 0.22, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.43, blue: 0.02, alpha: 1)
    }
}

extension ComparisonRow {
    /// The item's own name, without any of its parent folders.
    ///
    /// Nesting is shown by indentation instead of by a path prefix: repeating
    /// the same long parent path on every row of a folder is a great deal of
    /// text that says nothing new.
    var displayName: String {
        DisplayName.normalized((displayPath as NSString).lastPathComponent)
    }

    /// The glyph for this item, by type where the extension gives one away.
    ///
    /// A link is a link whatever it is called: it is compared by its target
    /// path rather than by any bytes of its own, and a row that says "differs"
    /// means something different for a link than for a file, so the extension
    /// is not consulted at all.
    var kindSymbol: String {
        if kind == .symbolicLink { return FileTypeGlyph.symbolicLink }
        // An alias is checked before the extension, because an alias to a
        // photo is an alias rather than a photo: what the row is describing is
        // the pointer, whose size, dates and permissions are its own.
        if (leftAttributes ?? rightAttributes)?.isAlias == true {
            return FileTypeGlyph.alias
        }
        if let symbol = FileTypeGlyph.symbol(
            forExtension: (displayPath as NSString).pathExtension) {
            return symbol
        }
        return kind.isDirectory ? FileTypeGlyph.folder : FileTypeGlyph.file
    }

    /// Folders are blue the way they are in the Finder — a fixed blue rather
    /// than the user's accent color, which would drift and could collide with
    /// the red and gold that carry the comparison's meaning.
    ///
    /// Keyed off the glyph rather than the kind, so a document bundle such as
    /// a `.pages` file — a directory, as far as the file system is concerned —
    /// is not the one item in the list drawn as a blue text document.
    var kindColor: NSColor {
        kindSymbol == FileTypeGlyph.folder ? .systemBlue : .secondaryLabelColor
    }

    /// A plain-language list of exactly what differs, shown on hover.
    var differenceDescription: String {
        if flags.contains(.added) { return "Only on the right" }
        if flags.contains(.removed) { return "Only on the left" }
        if flags.contains(.replaced) { return "Different kind of item" }

        var parts: [String] = []
        if flags.contains(.dataContent) { parts.append("contents") }
        else if flags.contains(.dataSize) { parts.append("size") }
        if flags.contains(.resourceContent) || flags.contains(.resourceSize) {
            parts.append("resource fork")
        }
        if flags.contains(.modificationDate) { parts.append("modification date") }
        if flags.contains(.creationDate) { parts.append("creation date") }
        if flags.contains(.permissions) { parts.append("permissions") }
        if flags.contains(.userID) { parts.append("owner") }
        if flags.contains(.groupID) { parts.append("group") }

        guard !parts.isEmpty else { return "Identical" }
        return "Differs in " + parts.joined(separator: ", ")
    }
}

/// Makes a filename safe to draw in a single line of a table.
///
/// A file name on a POSIX volume is very nearly arbitrary bytes: anything but
/// a slash and a null is legal, and that includes newlines, tabs, other
/// control characters, and the Unicode bidirectional overrides. Handed to a
/// text field verbatim, those do not merely look odd — they move the text.
/// A newline pushes the name onto a second line the row has no height for, so
/// what shows is the middle of a name sitting at the wrong baseline; a bidi
/// override reverses everything after it, including the rest of the column.
/// Every row in the list has to sit on the same baseline as its neighbors no
/// matter what its name contains, so anything that could move it is replaced
/// with a visible placeholder.
///
/// Nothing here touches comparison: names are matched, sorted and revealed in
/// the Finder by their real bytes throughout. This is only what is drawn.
enum DisplayName {
    /// Stands in for one unprintable character. The same glyph the system's
    /// own text rendering uses for a character it cannot draw, so a name
    /// carrying one reads as damaged rather than as silently shorter.
    private static let placeholder: Character = "\u{FFFD}"

    static func normalized(_ name: String) -> String {
        // Precomposed first: a decomposed name — which is what HFS+ volumes
        // hand back — otherwise draws its accents inconsistently beside the
        // precomposed spelling of the same name on the other side of the row.
        let composed = name.precomposedStringWithCanonicalMapping
        guard composed.unicodeScalars.contains(where: needsReplacing) else {
            return composed
        }
        var result = ""
        result.reserveCapacity(composed.count)
        for scalar in composed.unicodeScalars {
            result.append(needsReplacing(scalar)
                          ? placeholder : Character(scalar))
        }
        return result
    }

    /// True for anything that would move the text rather than add to it.
    private static func needsReplacing(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0 and C1 controls, and DEL: newlines and tabs among them.
        case 0x00...0x1F, 0x7F...0x9F: true
        // Line and paragraph separators.
        case 0x2028, 0x2029: true
        // The bidirectional embeddings, overrides and isolates.
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }
}
