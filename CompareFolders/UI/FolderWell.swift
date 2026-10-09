// MARK: - FolderWell.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// One of the two folder slots in the control bar — filled by button,
// drag-and-drop, or the File menu — and where each folder's full path and
// volume name are shown. All three selection routes hand back a URL the sandbox
// has already granted access to.

import AppKit
import SwiftUI

/// One of the two folder slots in the control bar.
///
/// A folder can be chosen with the button, dropped anywhere on the well, or
/// picked from the File menu. All three routes hand back a URL the sandbox has
/// already granted access to.
///
/// The well is also where each folder's full path is read. It used to be a
/// column heading over the list, which put a folder's name at the top of the
/// window and its path an inch below, with a row of controls in between; here
/// the two lines that describe one folder are one above the other, and the list
/// underneath needs no header at all.
struct FolderWell: View {
    let side: FolderSide
    let session: ComparisonSession

    @State private var isTargeted = false

    /// Fixed so the bar does not change height when a folder is chosen, when a
    /// long name truncates, or when a side is still empty.
    private static let height: CGFloat = 58
    private static let cornerRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: url == nil ? "folder" : "folder.fill")
                .font(.system(size: 34))
                .foregroundStyle(url == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                // Just enough shadow to lift the glyph off the well. Tight
                // radius and a single point of offset: any more and it reads
                // as a graphic rather than as the one solid object in a row
                // of flat controls.
                .shadow(color: .black.opacity(0.28), radius: 1.5, x: 0, y: 1)
                .frame(width: 42)

            VStack(alignment: .leading, spacing: 1) {
                nameLine
                // Only once there is a path to show. With no folder chosen
                // there is no second line to be the other half of a pair, and
                // reserving its height would hang the placeholder above the
                // well's center — off-axis from the button beside it, which is
                // the one other thing in the row in that state.
                if url != nil { pathLine }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Outside the stacked text, so it stays centered on the well however
            // many lines the text beside it happens to fill.
            Button("Select Folder") { session.chooseFolder(side) }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(background)
        .help(path ?? "Choose a folder to compare")
        .dropDestination(for: URL.self) { urls, _ in accept(urls) }
            isTargeted: { isTargeted = $0 }
    }

    private var url: URL? {
        side == .left ? session.leftURL : session.rightURL
    }

    /// The same color the column headings used to be drawn in — the one
    /// semantic color that reads as *darker than the list* in both
    /// appearances. `windowBackgroundColor` is darker than the white rows in
    /// Light Mode but lighter than them in Dark; `underPageBackgroundColor` is
    /// the other way round. `gridColor` — the content-area rule color, so a
    /// member of the table's own family rather than the window chrome's — sits
    /// just below the row background in each: 0.90 against white, and 0.10
    /// against 0.12. The band it used to fill is gone; the wells now carry it,
    /// which is what makes them read as the surface the list belongs to rather
    /// than as two controls floating on the bar.
    private var background: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
            .fill(Color(nsColor: .gridColor))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isTargeted ? 2 : 1))
    }

    /// The folder's name, and the volume it is on.
    ///
    /// Two folders being compared very often share a name — that is frequently
    /// the whole point — and the volume is the part of the path below that a
    /// user actually navigates by, so it is repeated up here in a fixed place
    /// on both sides rather than having to be picked out of the path.
    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(folderName)
                .font(.headline)
                // Trailing ellipsis: the start of a folder's name is the part
                // that identifies it, so the end is what can be given up.
                .truncationMode(.tail)
                .lineLimit(1)
                .foregroundStyle(url == nil ? .secondary : .primary)
                // The name is what the well is for: it keeps its width, and
                // the volume gives ground first when the two do not both fit.
                .layoutPriority(1)

            if let volume = volumeName {
                // Quoted, because a volume may be called anything at all —
                // "on Backup 2 (old)" reads as a sentence that has run on,
                // while the quotes make plain where the name starts and stops.
                // The name inside them is the part that identifies the volume,
                // so it takes the full-strength color and the words and marks
                // around it stay quiet.
                (Text("on \u{201C}").foregroundStyle(.secondary)
                 + Text(volume).foregroundStyle(.primary)
                 + Text("\u{201D}").foregroundStyle(.secondary))
                    .font(Self.detailFont)
                    .truncationMode(.tail)
                    .lineLimit(1)
            }
        }
    }

    /// The full path, in the same quiet type as the volume above it.
    ///
    /// Drawn only when there is one. The well's own height is fixed, so
    /// dropping the line does not resize the bar — it just lets the single
    /// remaining line center itself.
    private var pathLine: some View {
        Text(path ?? "")
            .font(Self.detailFont)
            .foregroundStyle(.secondary)
            // A path is most recognizable at its two ends, so one too long for
            // the well loses its middle.
            .truncationMode(.middle)
            .lineLimit(1)
    }

    /// The size the volume tag and the path share, so the two quiet halves of
    /// the well are one voice rather than two.
    private static let detailFont: Font = .subheadline

    /// The folder's own name.
    private var folderName: String {
        url.map { DisplayName.normalized($0.lastPathComponent) }
            ?? "No folder selected"
    }

    private var path: String? {
        url.map { DisplayName.normalized($0.path(percentEncoded: false)) }
    }

    private var volumeName: String? {
        url == nil ? nil : session.volumeName(side)
    }

    private func accept(_ urls: [URL]) -> Bool {
        guard let dropped = urls.first(where: \.isDirectoryOnDisk) else { return false }
        if side == .left { session.leftURL = dropped } else { session.rightURL = dropped }
        return true
    }
}

extension URL {
    /// True when this URL names a directory that actually exists.
    var isDirectoryOnDisk: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
