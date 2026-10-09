// MARK: - TablePlaceholder.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The fixed-size, centered block shown whenever the results area has no results
// to show — no folders chosen, both empty, everything filtered out, a run in
// progress, or a failed run — laid out so moving between those states shifts
// nothing on screen.

import SwiftUI

/// Everything the results area shows when it is not showing results.
///
/// There are five of these — no folders chosen, both folders empty, everything
/// filtered out, a comparison running, a comparison that failed — and the user
/// moves between them constantly: choose folders, press Compare, watch the
/// spinner, get a list, filter it down to nothing. If each state laid itself
/// out in its own way, that sequence would be a glyph jumping up as the title
/// shortens and a message sliding about underneath it.
///
/// So every slot here is a fixed size, and the block as a whole is a fixed
/// size, centered in whatever space it is given. A longer title, a two-line
/// message, a spinner in place of a symbol: none of them moves anything. The
/// only thing that changes between states is what is drawn inside the slots.
struct TablePlaceholder: View {
    /// What sits above the title.
    enum Emblem {
        case symbol(String)
        /// A comparison in progress. The spinner occupies exactly the space a
        /// symbol would, so starting one does not shift the words below it.
        case progress
    }

    let emblem: Emblem
    let title: String
    /// The second line, when there is more to say. The space it would take is
    /// reserved whether or not it is used.
    var message: String?

    var body: some View {
        VStack(spacing: 0) {
            emblemView
                .frame(height: Layout.emblemHeight)

            Text(title)
                .font(.title2)
                .lineLimit(1)
                // A title too long for the block loses its middle rather than
                // widening the block or wrapping into the message's space.
                .truncationMode(.middle)
                .frame(height: Layout.titleHeight)
                .padding(.top, Layout.emblemToTitle)

            // Always present, even when empty: the message slot is part of the
            // block's height, so a state with nothing to add is the same shape
            // as one with two lines.
            Text(message ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(Layout.messageLines)
                .frame(height: Layout.messageHeight, alignment: .top)
                .padding(.top, Layout.titleToMessage)
        }
        .monospacedDigit()
        .frame(width: Layout.width, height: Layout.height)
        // Centered in the whole results area, which is what makes the block's
        // fixed size mean fixed *position*.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private var emblemView: some View {
        switch emblem {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: Layout.symbolPointSize))
                .foregroundStyle(.secondary)
                // Multi-color symbols would each pick their own weight and
                // width; one tint keeps every state's emblem the same object.
                .symbolRenderingMode(.hierarchical)
        case .progress:
            ProgressView()
                .progressViewStyle(.circular)
                // Large by way of the control size, not a scale effect, so the
                // spinner is drawn at its intended size instead of a blurred
                // enlargement of a smaller one.
                .controlSize(.large)
        }
    }

    /// The block's geometry, in one place because the whole point is that it
    /// never varies.
    private enum Layout {
        static let width: CGFloat = 460
        static let symbolPointSize: CGFloat = 38
        /// Tall enough for the largest emblem — the symbol — with the spinner
        /// centered in the same band.
        static let emblemHeight: CGFloat = 46
        static let emblemToTitle: CGFloat = 14
        static let titleHeight: CGFloat = 26
        static let titleToMessage: CGFloat = 6
        static let messageLines = 2
        /// Two lines of `.callout`, reserved whether or not they are used.
        static let messageHeight: CGFloat = 36

        static var height: CGFloat {
            emblemHeight + emblemToTitle + titleHeight + titleToMessage + messageHeight
        }
    }
}
