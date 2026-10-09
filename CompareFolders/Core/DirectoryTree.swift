// MARK: - DirectoryTree.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// The immutable struct-of-arrays snapshot of a scanned folder hierarchy,
// holding nodes and their child ranges as flat buffers. Being entirely value
// types, it is `Sendable` and can be handed back from a background scan with no
// copying or locking.

import Foundation

/// One scanned file-system object, stored inside a `DirectoryTree`'s arena.
///
/// Children are referenced as a contiguous index range rather than a nested
/// array, so an entire tree of hundreds of thousands of items is three flat
/// buffers. Walking it touches no reference counts and stays in cache.
struct ScanNode: Sendable {
    var name: String
    var attributes: FileAttributes
    /// Index of the parent node, or `-1` for the root.
    var parent: Int32
    /// Start of this node's slice of `DirectoryTree.childIndices`.
    var childrenStart: Int32
    var childrenCount: Int32

    var kind: FileKind { attributes.kind }
}

/// A complete, immutable snapshot of one folder hierarchy.
///
/// Being a struct of arrays of value types, it is `Sendable` without ceremony,
/// which is what lets scanning happen off the main actor and the results be
/// handed back with no copying or locking.
struct DirectoryTree: Sendable {
    /// Absolute, standardized path of the scanned root.
    let rootPath: String
    /// Node 0 is always the root itself.
    var nodes: [ScanNode]
    /// Flattened child index ranges, sorted by `FilenameOrder.sortingCompare`.
    var childIndices: [Int32]

    static let rootIndex: Int32 = 0

    subscript(index: Int32) -> ScanNode { nodes[Int(index)] }

    /// The child indices of `index`, in sorted order.
    func children(of index: Int32) -> ArraySlice<Int32> {
        let node = nodes[Int(index)]
        let start = Int(node.childrenStart)
        return childIndices[start ..< (start + Int(node.childrenCount))]
    }
}
