// MARK: - FolderComparator.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Lines two scanned trees up against each other with a single ordered merge
// walk, emitting one row per item and queuing matched file pairs for the
// parallel byte-for-byte content checks that run afterwards.

import Foundation

/// A matched pair of files whose bytes still need to be compared.
///
/// The structural walk only records these; the reads themselves happen
/// afterwards and in parallel, so that one slow file cannot stall the walk.
struct PendingContentCheck: Sendable {
    let rowIndex: Int
    let leftPath: String
    let rightPath: String
    let leftAttributes: FileAttributes
    let rightAttributes: FileAttributes
}

/// Lines two scanned trees up against each other.
enum FolderComparator {

    /// Walks both trees in parallel and produces one row per item.
    ///
    /// Both trees are sorted by `FilenameOrder`, so a single ordered merge is
    /// enough to pair items up — no lookups, no hashing, one pass.
    static func compare(
        left: DirectoryTree,
        right: DirectoryTree,
        options: ComparisonOptions,
        cancellation: CancellationFlag
    ) -> (rows: [ComparisonRow], pending: [PendingContentCheck]) {
        var rows: [ComparisonRow] = []
        var pending: [PendingContentCheck] = []
        let wantsContent = options.contains(.fileContent)

        /// Appends a row and returns nothing; `id` is the row's position.
        func emit(
            flags: ComparisonFlags,
            kind: FileKind,
            leftPath: String?,
            rightPath: String?,
            leftAttributes: FileAttributes?,
            rightAttributes: FileAttributes?,
            parent: Int32
        ) -> Int {
            let index = rows.count
            let path = leftPath ?? rightPath ?? ""
            rows.append(ComparisonRow(
                id: Int32(index),
                flags: flags,
                kind: kind,
                leftPath: leftPath,
                rightPath: rightPath,
                leftAttributes: leftAttributes,
                rightAttributes: rightAttributes,
                parent: parent,
                depth: Int32(path.utf8.count(where: { $0 == UInt8(ascii: "/") })),
                isHidden: isHidden(leftPath) || isHidden(rightPath)))
            return index
        }

        /// Reports an item that exists on one side only.
        ///
        /// A whole folder that is present on just one side is reported as a
        /// single row rather than being expanded: the fact that it is absent
        /// is the finding, and listing its ten thousand descendants as ten
        /// thousand more findings would bury it.
        func emitOneSided(
            _ tree: DirectoryTree, _ index: Int32, prefix: String,
            isLeft: Bool, parent: Int32
        ) {
            let node = tree[index]
            let path = prefix.isEmpty ? node.name : prefix + "/" + node.name
            _ = emit(
                flags: isLeft ? .removed : .added,
                kind: node.kind,
                leftPath: isLeft ? path : nil,
                rightPath: isLeft ? nil : path,
                leftAttributes: isLeft ? node.attributes : nil,
                rightAttributes: isLeft ? nil : node.attributes,
                parent: parent)
        }

        /// One matched pair of directories whose children are being merged,
        /// and how far through each side's children the merge has got.
        struct Level {
            let leftChildren: ArraySlice<Int32>
            let rightChildren: ArraySlice<Int32>
            var l: Int
            var r: Int
            let leftPrefix: String
            let rightPrefix: String
            let parent: Int32
        }

        /// The folders currently being merged, innermost last.
        ///
        /// A work list rather than recursion, for the reason the scanner gives:
        /// a hierarchy a few hundred levels deep — which the file system allows
        /// — would otherwise overflow the stack of the thread this runs on.
        /// Descending pushes a level and finishing one pops back to its parent
        /// exactly where it left off, so rows come out in the same order a
        /// recursive walk would produce.
        var levels: [Level] = []

        func descend(
            leftIndex: Int32, rightIndex: Int32,
            leftPrefix: String, rightPrefix: String, parent: Int32
        ) {
            let leftChildren = left.children(of: leftIndex)
            let rightChildren = right.children(of: rightIndex)
            levels.append(Level(
                leftChildren: leftChildren, rightChildren: rightChildren,
                l: leftChildren.startIndex, r: rightChildren.startIndex,
                leftPrefix: leftPrefix, rightPrefix: rightPrefix, parent: parent))
        }

        /// Advances the innermost level by one item, or pops it when it is done.
        func step() {
            let top = levels.count - 1
            let level = levels[top]
            let l = level.l, r = level.r
            let leftDone = l >= level.leftChildren.endIndex
            let rightDone = r >= level.rightChildren.endIndex

            if leftDone && rightDone {
                levels.removeLast()
                return
            }
            if rightDone {
                levels[top].l += 1
                emitOneSided(left, level.leftChildren[l], prefix: level.leftPrefix,
                             isLeft: true, parent: level.parent)
                return
            }
            if leftDone {
                levels[top].r += 1
                emitOneSided(right, level.rightChildren[r], prefix: level.rightPrefix,
                             isLeft: false, parent: level.parent)
                return
            }

            let leftChild = level.leftChildren[l]
            let rightChild = level.rightChildren[r]
            switch FilenameOrder.matchingCompare(left[leftChild].name, right[rightChild].name) {
            case .orderedSame:
                // Advanced before pairing: a matched folder pushes its own
                // level, and this one must resume past it afterwards.
                levels[top].l += 1
                levels[top].r += 1
                pair(leftChild, rightChild, level.leftPrefix, level.rightPrefix, level.parent)
            case .orderedAscending:
                levels[top].l += 1
                emitOneSided(left, leftChild, prefix: level.leftPrefix,
                             isLeft: true, parent: level.parent)
            case .orderedDescending:
                levels[top].r += 1
                emitOneSided(right, rightChild, prefix: level.rightPrefix,
                             isLeft: false, parent: level.parent)
            }
        }

        /// Handles two items that matched by name.
        func pair(
            _ leftIndex: Int32, _ rightIndex: Int32,
            _ leftPrefix: String, _ rightPrefix: String, _ parent: Int32
        ) {
            let leftNode = left[leftIndex]
            let rightNode = right[rightIndex]
            let leftPath = leftPrefix.isEmpty
                ? leftNode.name : leftPrefix + "/" + leftNode.name
            let rightPath = rightPrefix.isEmpty
                ? rightNode.name : rightPrefix + "/" + rightNode.name

            guard leftNode.kind == rightNode.kind else {
                // Same name, different sort of object entirely.
                _ = emit(
                    flags: .replaced, kind: leftNode.kind,
                    leftPath: leftPath, rightPath: rightPath,
                    leftAttributes: leftNode.attributes,
                    rightAttributes: rightNode.attributes,
                    parent: parent)
                return
            }

            let flags = attributeFlags(leftNode.attributes, rightNode.attributes)
            let rowIndex = emit(
                flags: flags, kind: leftNode.kind,
                leftPath: leftPath, rightPath: rightPath,
                leftAttributes: leftNode.attributes,
                rightAttributes: rightNode.attributes,
                parent: parent)

            if leftNode.kind.isDirectory {
                descend(
                    leftIndex: leftIndex, rightIndex: rightIndex,
                    leftPrefix: leftPath, rightPrefix: rightPath,
                    parent: Int32(rowIndex))
            } else if wantsContent {
                pending.append(PendingContentCheck(
                    rowIndex: rowIndex,
                    leftPath: left.rootPath + "/" + leftPath,
                    rightPath: right.rootPath + "/" + rightPath,
                    leftAttributes: leftNode.attributes,
                    rightAttributes: rightNode.attributes))
            }
        }

        // The two roots themselves are not compared — the user chose them, and
        // reporting that two folders picked by hand have different names or
        // permissions is noise, not a finding.
        descend(
            leftIndex: DirectoryTree.rootIndex, rightIndex: DirectoryTree.rootIndex,
            leftPrefix: "", rightPrefix: "", parent: -1)
        while !levels.isEmpty {
            if cancellation.isCanceled { break }
            step()
        }

        return (rows, pending)
    }

    // MARK: - Attributes

    /// Every attribute difference between two items of the same kind.
    ///
    /// Sizes are deliberately only compared for non-directories: a directory's
    /// reported size describes how the volume stores its index, not what is in
    /// it, and would differ constantly for no useful reason.
    static func attributeFlags(
        _ left: FileAttributes, _ right: FileAttributes
    ) -> ComparisonFlags {
        var flags: ComparisonFlags = []
        if left.permissions != right.permissions { flags.insert(.permissions) }
        if left.groupID != right.groupID { flags.insert(.groupID) }
        if left.userID != right.userID { flags.insert(.userID) }
        // A creation date is only compared when both sides actually have one.
        // A volume that does not keep birth times reports the epoch for every
        // item on it, so comparing one against a real date would flag every
        // file on such a volume as differing in a respect neither file system
        // can be asked about.
        if left.creationDate.isRecorded && right.creationDate.isRecorded
            && left.creationDate != right.creationDate {
            flags.insert(.creationDate)
        }
        if left.modificationDate != right.modificationDate {
            flags.insert(.modificationDate)
        }
        if !left.kind.isDirectory {
            if left.dataSize != right.dataSize { flags.insert(.dataSize) }
            if left.resourceSize != right.resourceSize { flags.insert(.resourceSize) }
        }
        return flags
    }

    /// True when any component of the path begins with a dot.
    private static func isHidden(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix(".") || path.contains("/.")
    }
}
