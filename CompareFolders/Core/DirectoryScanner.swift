// MARK: - DirectoryScanner.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Walks one folder hierarchy iteratively, recording every object's attributes
// in a single pass, and returns a flat `DirectoryTree` plus any diagnostics. It
// never throws: unreadable objects are reported and skipped.

import Darwin
import Foundation

/// The result of walking one folder hierarchy.
struct ScanOutcome: Sendable {
    var tree: DirectoryTree?
    var diagnostics: [Diagnostic]
}

/// Walks a folder hierarchy and records every object's attributes in one pass.
///
/// The walk is iterative rather than recursive: a deeply nested hierarchy
/// would otherwise be able to overflow the stack, and a work list is no more
/// complicated to read than the recursion it replaces.
enum DirectoryScanner {

    /// Scans `rootPath`, returning a flat arena of every item beneath it.
    ///
    /// Never throws. Objects that cannot be read are reported as diagnostics
    /// and omitted; only a failure to read the root itself yields a `nil` tree.
    ///
    /// - Parameter progress: Invoked periodically with the running item count.
    ///   Called from a scanning thread, so it must be cheap and thread-safe.
    static func scan(
        rootPath: String,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) -> ScanOutcome {
        var diagnostics: [Diagnostic] = []
        let root = (rootPath as NSString).standardizingPath

        let rootAttributes: FileAttributes
        switch lookUpAttributes(ofPath: root) {
        case .found(let attributes) where attributes.kind.isDirectory:
            rootAttributes = attributes
        case .found, .unsupportedKind:
            // The object is there and readable; it simply is not a folder.
            // `errno` says nothing about that, and would be left over from
            // some unrelated call if it were consulted here.
            diagnostics.append(Diagnostic(
                path: root, summary: rootFailureSummary(ENOTDIR), code: ENOTDIR))
            return ScanOutcome(tree: nil, diagnostics: diagnostics)
        case .failed(let code):
            diagnostics.append(Diagnostic(
                path: root, summary: rootFailureSummary(code), code: code))
            return ScanOutcome(tree: nil, diagnostics: diagnostics)
        }

        let state = ScanState(root: ScanNode(
            name: (root as NSString).lastPathComponent,
            attributes: rootAttributes,
            parent: -1,
            childrenStart: 0,
            childrenCount: 0), rootPath: root)

        // How many folders may usefully be open at once depends on the device
        // underneath them, which is asked about once, here — see `StorageMedium`.
        let width = StorageMedium.atPath(root).scanWidth

        if width <= 1 {
            walk(state, cancellation: cancellation, progress: progress)
        } else {
            let group = DispatchGroup()
            for _ in 0 ..< width {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    walk(state, cancellation: cancellation, progress: progress)
                }
            }
            group.wait()
        }

        let (nodes, childIndices, found) = state.finished()
        diagnostics.append(contentsOf: found)
        progress(max(nodes.count - 1, 0))

        if cancellation.isCanceled {
            return ScanOutcome(tree: nil, diagnostics: diagnostics)
        }
        let tree = DirectoryTree(rootPath: root, nodes: nodes, childIndices: childIndices)
        return ScanOutcome(tree: tree, diagnostics: diagnostics)
    }

    // MARK: - The walk

    /// Reads directories out of `state` until there are none left.
    ///
    /// Several of these run at once on anything but a spinning disk. They
    /// share nothing but the work list and the arena they append to, and the
    /// expensive part — opening a directory and reading its entries — happens
    /// outside the lock, with each worker holding its own read buffer.
    private static func walk(
        _ state: ScanState,
        cancellation: CancellationFlag,
        progress: @Sendable (Int) -> Void
    ) {
        // One reader, and so one buffer, per worker: the buffer is written by
        // the kernel on each call and cannot be shared between threads.
        let bulk = BulkDirectoryReader()
        var diagnostics: [Diagnostic] = []

        while let (parentIndex, parentPath) = state.nextDirectory(cancellation) {
            var entries = listDirectory(
                atPath: parentPath, parent: parentIndex, bulk: bulk,
                diagnostics: &diagnostics)

            // Both sides of a comparison must be ordered identically for the
            // merge walk to line them up correctly. Sorting here, rather than
            // after everything is gathered, is also what makes the concurrent
            // walk produce exactly the tree the serial one does: workers may
            // finish in any order, but each parent's children are one
            // contiguous, sorted run whoever laid them down.
            entries.sort { FilenameOrder.sortingCompare($0.name, $1.name) == .orderedAscending }

            if let items = state.attach(
                entries, to: parentIndex, at: parentPath,
                diagnostics: &diagnostics) {
                progress(items)
            }
        }

        state.collect(diagnostics)
    }

    /// The arena being built, and the list of folders still to be opened.
    ///
    /// Everything here is guarded by one lock. That is enough because the only
    /// thing done under it is appending to three arrays — the reading itself,
    /// which is where all the time goes, happens outside it.
    private final class ScanState: @unchecked Sendable {
        private let lock = NSCondition()
        private var nodes: [ScanNode]
        private var childIndices: [Int32] = []
        private var diagnostics: [Diagnostic] = []
        /// Directories still to be expanded, paired with their absolute path so
        /// it never has to be rebuilt by walking back up the parent chain.
        private var pending: [(index: Int32, path: String)]
        /// Workers currently reading a directory. The walk is finished only
        /// when nothing is pending *and* nobody is still producing more.
        private var active = 0
        private var lastReported = 0

        init(root: ScanNode, rootPath: String) {
            nodes = [root]
            pending = [(DirectoryTree.rootIndex, rootPath)]
        }

        /// Claims the next directory, waiting while other workers might still
        /// discover one. Returns `nil` when the walk is over or canceled.
        func nextDirectory(_ cancellation: CancellationFlag) -> (Int32, String)? {
            lock.lock()
            defer { lock.unlock() }
            while true {
                if cancellation.isCanceled {
                    // Every worker has to be woken, not just this one, or the
                    // ones already waiting would sit there until a directory
                    // that is never coming turns up.
                    lock.broadcast()
                    return nil
                }
                if let job = pending.popLast() {
                    active += 1
                    return job
                }
                if active == 0 {
                    lock.broadcast()
                    return nil
                }
                lock.wait()
            }
        }

        /// Records one directory's children and queues the folders among them.
        ///
        /// - Returns: The running item count when it is time to report progress,
        ///   and `nil` otherwise. Reporting every single item would cost more
        ///   than the scan.
        func attach(
            _ entries: [ScanNode],
            to parentIndex: Int32,
            at parentPath: String,
            diagnostics found: inout [Diagnostic]
        ) -> Int? {
            lock.lock()
            defer { lock.unlock() }

            let start = Int32(childIndices.count)
            nodes[Int(parentIndex)].childrenStart = start
            nodes[Int(parentIndex)].childrenCount = Int32(entries.count)

            for entry in entries {
                let index = Int32(nodes.count)
                nodes.append(entry)
                childIndices.append(index)
                if entry.kind.isDirectory {
                    pending.append((index, parentPath + "/" + entry.name))
                }
            }

            if !found.isEmpty {
                diagnostics.append(contentsOf: found)
                found.removeAll(keepingCapacity: true)
            }

            active -= 1
            lock.broadcast()

            guard nodes.count - lastReported >= 2048 else { return nil }
            lastReported = nodes.count
            return nodes.count - 1
        }

        /// Hands over diagnostics a worker raised outside `attach` — one from a
        /// directory it could not open at all, which produced no entries.
        func collect(_ found: [Diagnostic]) {
            guard !found.isEmpty else { return }
            lock.lock()
            diagnostics.append(contentsOf: found)
            lock.unlock()
        }

        /// The finished arena. Called once every worker has stopped.
        ///
        /// Diagnostics come back in `Diagnostic.ordered`'s stable order, so a
        /// scan reports the same list however its threads were scheduled.
        func finished() -> ([ScanNode], [Int32], [Diagnostic]) {
            (nodes, childIndices, Diagnostic.ordered(diagnostics))
        }
    }

    /// A failure to read the chosen folder itself deserves a better
    /// explanation than `strerror` gives. Under the sandbox, `EPERM` here
    /// almost always means the folder's security-scoped access was not held,
    /// which looks nothing like a permissions problem to the person using it.
    private static func rootFailureSummary(_ code: Int32) -> String {
        switch code {
        case EPERM, EACCES:
            "Not permitted to read this folder. Choose it again with Select Folder."
        case ENOENT:
            "This folder no longer exists"
        case ENOTDIR:
            "This is not a folder"
        default:
            "Could not read folder"
        }
    }

    // MARK: - One directory

    /// Reads the immediate children of one directory. `.` and `..` are skipped,
    /// as is anything that is not a directory, regular file or symbolic link.
    ///
    /// `getattrlistbulk` answers this in a handful of system calls rather than
    /// three per item, so it is tried first. Volumes that do not implement it —
    /// network shares, chiefly — fall through to the `readdir` walk below,
    /// which asks the same questions the slow way and gives the same answers.
    private static func listDirectory(
        atPath path: String,
        parent: Int32,
        bulk: BulkDirectoryReader,
        diagnostics: inout [Diagnostic]
    ) -> [ScanNode] {
        if let entries = bulk.read(
            atPath: path, parent: parent, diagnostics: &diagnostics) {
            return entries
        }
        return enumerateDirectory(
            atPath: path, parent: parent, diagnostics: &diagnostics)
    }

    /// The `readdir` plus `lstat` walk: one call for each name, one more for
    /// each item's attributes, and a third for each file's resource fork.
    private static func enumerateDirectory(
        atPath path: String,
        parent: Int32,
        diagnostics: inout [Diagnostic]
    ) -> [ScanNode] {
        guard let handle = unsafe path.withCString({ unsafe opendir($0) }) else {
            diagnostics.append(Diagnostic(
                path: path, summary: "Could not open folder", code: errno))
            return []
        }
        defer { unsafe closedir(handle) }

        var entries: [ScanNode] = []
        while true {
            // `readdir` returns nil both at the end of the directory and on a
            // failure, and only `errno` tells the two apart. Without this, a
            // directory that stopped being readable half way through would be
            // silently truncated — and every item after the failure reported
            // as missing from this side, which looks exactly like a real
            // finding.
            errno = 0
            guard let entry = unsafe readdir(handle) else {
                if errno != 0 {
                    diagnostics.append(Diagnostic(
                        path: path, summary: "Could not finish reading folder",
                        code: errno))
                }
                break
            }
            guard let name = unsafe filename(from: entry) else { continue }
            let childPath = path + "/" + name
            let attributes: FileAttributes
            switch lookUpAttributes(ofPath: childPath) {
            case .found(let found):
                attributes = found
            case .unsupportedKind:
                // A socket, FIFO or device node. Deliberately ignored — and
                // deliberately *not* reported, because it was read perfectly
                // well and a diagnostic here would claim a hole in the
                // comparison that does not exist.
                continue
            case .failed(let code):
                diagnostics.append(Diagnostic(
                    path: childPath, summary: "Could not read item", code: code))
                continue
            }
            entries.append(ScanNode(
                name: name, attributes: attributes,
                parent: parent, childrenStart: 0, childrenCount: 0))
        }
        return entries
    }

    /// Extracts a filename from a `dirent`, skipping `.` and `..`.
    ///
    /// `readdir` hands back a pointer into the directory stream's own buffer,
    /// valid until the next call — so the record is copied out at once, and
    /// the name read from that copy through a buffer no longer than the name
    /// field, whatever `d_namlen` claims.
    private static func filename(from entry: UnsafeMutablePointer<dirent>) -> String? {
        var record = unsafe entry.pointee
        let length = Int(record.d_namlen)
        if length == 0 { return nil }

        return unsafe withUnsafeBytes(of: &record.d_name) { raw -> String? in
            let name = unsafe raw.prefix(length)
            // Skip "." and ".."
            let dot = UInt8(ascii: ".")
            if unsafe name.first == dot {
                if length == 1 { return nil }
                if unsafe length == 2 && name.last == dot { return nil }
            }
            return unsafe FileManager.default.string(
                withFileSystemRepresentation: raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                length: name.count)
        }
    }

    // MARK: - Attributes

    /// What reading one object's attributes produced.
    ///
    /// The three outcomes are kept apart because they mean entirely different
    /// things to the caller: only `failed` is a hole in the comparison worth
    /// telling the user about, and only `failed` carries a meaningful `errno`.
    enum AttributeLookup {
        case found(FileAttributes)
        /// Read successfully, but it is a socket, FIFO or device node.
        case unsupportedKind
        case failed(Int32)
    }

    /// Reads every attribute the engine compares, without following symlinks.
    ///
    /// `lstat` supplies all of them but the resource fork size, and on Darwin
    /// that includes `st_birthtimespec` for the creation date. The resource
    /// fork — long obsolete, but still occasionally present, and the reference
    /// implementation does check it — is sized by a second call, which is only
    /// worth making for regular files.
    static func lookUpAttributes(ofPath path: String) -> AttributeLookup {
        var info = stat()
        guard unsafe path.withCString({ unsafe lstat($0, &info) }) == 0 else { return .failed(errno) }
        guard let kind = FileKind(mode: info.st_mode) else { return .unsupportedKind }

        let fileInfo = kind.isFile
            ? forkAndFinderInfo(ofPath: path)
            : (resourceSize: UInt64(0), isAlias: false)

        return .found(FileAttributes(
            kind: kind,
            permissions: UInt16(info.st_mode) & FileAttributes.allPermissions,
            userID: info.st_uid,
            groupID: info.st_gid,
            creationDate: Timestamp(info.st_birthtimespec),
            modificationDate: Timestamp(info.st_mtimespec),
            dataSize: kind.isDirectory ? 0 : UInt64(max(info.st_size, 0)),
            resourceSize: fileInfo.resourceSize,
            isAlias: fileInfo.isAlias))
    }

    /// A file's resource fork size, and whether it is a Finder alias.
    ///
    /// Both answers come out of one `getattrlist`, which is why they are asked
    /// for together: the alias flag lives in the Finder info, and requesting it
    /// alongside the fork length costs one more field in a call that is already
    /// being made rather than a second trip into the file system.
    ///
    /// The fork is asked for with `getattrlist` rather than `getxattr`, which
    /// is the same answer for a great deal less work: sizing the fork as an
    /// extended attribute measured four times the cost of the `lstat` beside it
    /// and dominated the whole scan, while the file-system attribute call costs
    /// about what the `lstat` does. Over a folder of a hundred thousand items
    /// that is the difference between a scan spent listing files and one spent
    /// asking after a fork that virtually nothing has had since the nineties.
    private static func forkAndFinderInfo(
        ofPath path: String
    ) -> (resourceSize: UInt64, isAlias: Bool) {
        var list = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
            commonattr: attrgroup_t(ATTR_CMN_FNDRINFO), volattr: 0, dirattr: 0,
            fileattr: attrgroup_t(ATTR_FILE_RSRCLENGTH), forkattr: 0)

        // The reply is a packed record: its own length, then the attributes
        // asked for, in the order the header declares them — common attributes
        // before file attributes, so the 32 bytes of Finder info precede the
        // fork length. Nothing may be assumed about alignment, hence the
        // unaligned loads, and an attribute the volume does not answer for is
        // simply absent — which the length is what reveals.
        var reply = [UInt8](repeating: 0, count: 64)
        let status = unsafe path.withCString { cPath in
            unsafe reply.withUnsafeMutableBytes { buffer in
                unsafe getattrlist(cPath, &list, buffer.baseAddress, buffer.count,
                                   UInt32(FSOPT_NOFOLLOW))
            }
        }
        let header = MemoryLayout<UInt32>.size
        let finderInfoSize = 32
        let expected = header + finderInfoSize + MemoryLayout<off_t>.size
        let returned = status == 0
            ? Int(reply.loadInteger(fromByteOffset: 0, as: UInt32.self))
            : 0
        if returned >= expected {
            // `FileInfo.finderFlags` is a big-endian UInt16 eight bytes
            // into the Finder info, and `kIsAliasFile` is its 0x8000 bit.
            let flags = reply.loadBigEndianUInt16(fromByteOffset: header + 8)
            let size = reply.loadInteger(
                fromByteOffset: header + finderInfoSize, as: off_t.self)
            return (size > 0 ? UInt64(size) : 0, flags & 0x8000 != 0)
        }

        // Some volumes — network shares in particular — do not implement
        // `getattrlist`, and one that does may still decline one of these
        // attributes and answer with a shorter record. Rather than guess which
        // of the two is missing from a record whose layout has moved, both fall
        // back: the fork to the extended attribute, which is the older, more
        // widely answered question and gives the identical figure, and the
        // alias flag to "not an alias", which is what all but a handful of
        // files are.
        let size = unsafe path.withCString { cPath in
            unsafe XATTR_RESOURCEFORK_NAME.withCString { name in
                // No buffer: asked this way, `getxattr` only reports the size.
                unsafe getxattr(cPath, name, nil, 0, 0, noFollowOption)
            }
        }
        return (size > 0 ? UInt64(size) : 0, false)
    }

    /// `XATTR_RESOURCEFORK_NAME` and `XATTR_NOFOLLOW` from <sys/xattr.h>,
    /// neither of which imports into Swift.
    private static let XATTR_RESOURCEFORK_NAME = "com.apple.ResourceFork"
    private static let noFollowOption: Int32 = 0x0001
}
