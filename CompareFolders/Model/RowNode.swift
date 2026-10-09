// MARK: - RowNode.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Wraps the engine's flat rows into the reference-typed tree that
// `NSOutlineView` addresses by object identity. The full hierarchy is built
// once; changing a filter only recomputes which children are visible rather
// than reallocating every node.

import Foundation

/// One node of the results, as the outline view sees them.
///
/// `NSOutlineView` addresses its content by object identity, so the flat rows
/// the engine produces are wrapped in reference types once, when a comparison
/// finishes. The full hierarchy in `children` is built that one time and never
/// rebuilt; filtering only recomputes `visibleChildren`, so changing a filter
/// or typing in the search field costs a traversal rather than allocating a
/// hundred thousand objects again.
@MainActor
final class RowNode {
    let row: ComparisonRow
    /// The row as the current filter has it: any difference the user has asked
    /// to be treated as identical is already cleared, so everything that draws
    /// a row reads this one rather than re-deriving the mask per cell.
    ///
    /// Recomputed by `prune`, which visits every node whenever the filter
    /// changes anyway.
    var effectiveRow: ComparisonRow
    /// Every child, regardless of the current filter.
    var children: [RowNode] = []
    /// The children the current filter admits.
    var visibleChildren: [RowNode] = []

    init(row: ComparisonRow) {
        self.row = row
        self.effectiveRow = row
    }

    var isExpandable: Bool { !visibleChildren.isEmpty }

    /// Builds the full hierarchy from the engine's flat, parent-before-child rows.
    static func buildTree(from rows: [ComparisonRow]) -> [RowNode] {
        let nodes = rows.map(RowNode.init)
        var roots: [RowNode] = []
        for node in nodes {
            let parent = node.row.parent
            // The walk always emits a folder before anything inside it, so a
            // parent's node is guaranteed to exist by the time a child needs it.
            if parent >= 0 {
                nodes[Int(parent)].children.append(node)
            } else {
                roots.append(node)
            }
        }
        return roots
    }
}

extension ComparisonFilter {
    /// Recomputes `visibleChildren` throughout the tree and returns the roots
    /// that survive.
    ///
    /// A folder that the filter itself would reject is still kept when
    /// something inside it survives. Without that, hiding identical items
    /// would hide an unchanged folder and take every differing file inside it
    /// off screen — the exact opposite of what the filter is for.
    @MainActor
    func apply(to roots: [RowNode]) -> [RowNode] {
        roots.compactMap(prune)
    }

    @MainActor
    private func prune(_ node: RowNode) -> RowNode? {
        node.visibleChildren = node.children.compactMap(prune)
        node.effectiveRow = effective(node.row)
        if accepts(node.effectiveRow) || !node.visibleChildren.isEmpty {
            return node
        }
        return nil
    }
}
