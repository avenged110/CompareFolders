// MARK: - main.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
//
import Foundation
import Synchronization
import System

// MARK: - Tiny test harness

var failures = 0
var checks = 0

@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL: \(message())")
    }
}

@MainActor func section(_ name: String) { print("\n== \(name)") }

// MARK: - Fixture helpers

let fm = FileManager.default
let base = NSTemporaryDirectory() + "/cf-verify-\(UUID().uuidString)"

@MainActor func mkdir(_ path: String) {
    try! fm.createDirectory(atPath: base + "/" + path,
                            withIntermediateDirectories: true)
}

@MainActor func write(_ path: String, _ contents: String) {
    fm.createFile(atPath: base + "/" + path, contents: Data(contents.utf8))
}

@MainActor func writeBytes(_ path: String, _ data: Data) {
    fm.createFile(atPath: base + "/" + path, contents: data)
}

@MainActor func symlink(_ path: String, to target: String) {
    try! fm.createSymbolicLink(atPath: base + "/" + path, withDestinationPath: target)
}

@MainActor func setModified(_ path: String, _ date: Date) {
    try! fm.setAttributes([.modificationDate: date], ofItemAtPath: base + "/" + path)
}

@MainActor func setPermissions(_ path: String, _ mode: Int) {
    try! fm.setAttributes([.posixPermissions: mode], ofItemAtPath: base + "/" + path)
}

/// Runs a comparison of `base/left` against `base/right`.
@MainActor func run(contents: Bool, left: String = "left", right: String = "right") async -> ComparisonResults {
    try! await ComparisonEngine.run(
        leftRoot: base + "/" + left,
        rightRoot: base + "/" + right,
        options: contents ? [.fileContent] : [],
        progress: { _ in })
}

extension ComparisonResults {
    func row(_ path: String) -> ComparisonRow? {
        rows.first { $0.displayPath == path }
    }
    var paths: [String] { rows.map(\.displayPath) }
}

// MARK: - Fixtures

let epoch = Date(timeIntervalSince1970: 1_700_000_000)

mkdir("left/sub/deep")
mkdir("right/sub/deep")

// Identical on both sides.
for side in ["left", "right"] {
    write("\(side)/same.txt", "hello")
    write("\(side)/sub/nested.txt", "nested")
    write("\(side)/sub/deep/deepest.txt", "deep")
    setModified("\(side)/same.txt", epoch)
    setModified("\(side)/sub/nested.txt", epoch)
    setModified("\(side)/sub/deep/deepest.txt", epoch)
}

// Only on one side.
write("left/only-left.txt", "x")
write("right/only-right.txt", "x")
mkdir("left/only-left-dir/inner")
write("left/only-left-dir/inner/buried.txt", "buried")

// Same size, different bytes, same timestamp: invisible without content mode.
write("left/sneaky.txt", "aaaa")
write("right/sneaky.txt", "bbbb")
setModified("left/sneaky.txt", epoch)
setModified("right/sneaky.txt", epoch)

// Different sizes.
write("left/sized.txt", "short")
write("right/sized.txt", "much longer content")
setModified("left/sized.txt", epoch)
setModified("right/sized.txt", epoch)

// Same content, different modification date.
write("left/touched.txt", "same")
write("right/touched.txt", "same")
setModified("left/touched.txt", epoch)
setModified("right/touched.txt", epoch.addingTimeInterval(3600))

// Same content and date, different permissions.
write("left/perms.txt", "same")
write("right/perms.txt", "same")
setModified("left/perms.txt", epoch)
setModified("right/perms.txt", epoch)
setPermissions("left/perms.txt", 0o644)
setPermissions("right/perms.txt", 0o600)

// A file on one side, a folder on the other.
write("left/swapped", "file")
mkdir("right/swapped")

// Symlinks.
symlink("left/link-same", to: "/tmp")
symlink("right/link-same", to: "/tmp")
symlink("left/link-diff", to: "/tmp")
symlink("right/link-diff", to: "/var")

// Large files that agree until the very last byte: exercises the multi-buffer
// read loop and would be missed by any size-only check.
var bigLeft = Data(repeating: 0x41, count: 900_000)
var bigRight = bigLeft
bigRight[899_999] = 0x42
writeBytes("left/big.bin", bigLeft)
writeBytes("right/big.bin", bigRight)
setModified("left/big.bin", epoch)
setModified("right/big.bin", epoch)

// Empty files on both sides.
write("left/empty.txt", "")
write("right/empty.txt", "")
setModified("left/empty.txt", epoch)
setModified("right/empty.txt", epoch)

// Hidden items.
write("left/.hidden", "h")
write("right/.hidden", "h")
setModified("left/.hidden", epoch)
setModified("right/.hidden", epoch)

// MARK: - Fast mode

section("Fast mode (attributes only)")
let fast = await run(contents: false)

expect(fast.row("only-left.txt")?.flags.contains(.removed) == true,
       "only-left.txt should be Removed")
expect(fast.row("only-right.txt")?.flags.contains(.added) == true,
       "only-right.txt should be Added")
expect(fast.row("only-left-dir")?.flags.contains(.removed) == true,
       "one-sided folder should be a single Removed row")
expect(!fast.paths.contains("only-left-dir/inner"),
       "a one-sided folder must not be expanded into its descendants")
expect(fast.row("same.txt")?.isIdentical == true, "same.txt should be identical")
expect(fast.row("sub/nested.txt")?.isIdentical == true, "nested file should be identical")
expect(fast.row("sub/deep/deepest.txt")?.isIdentical == true,
       "deeply nested file should be identical")
expect(fast.row("sized.txt")?.flags.contains(.dataSize) == true,
       "sized.txt should differ in size")
expect(fast.row("touched.txt")?.flags.contains(.modificationDate) == true,
       "touched.txt should differ in modification date")
expect(fast.row("perms.txt")?.flags == [.permissions],
       "perms.txt should differ in permissions only, got \(String(describing: fast.row("perms.txt")?.flags))")
expect(fast.row("swapped")?.flags.contains(.replaced) == true,
       "file-vs-folder should be Replaced")
expect(fast.row("empty.txt")?.isIdentical == true, "empty files should be identical")
expect(fast.row(".hidden")?.isHidden == true, "dot-file should be marked hidden")
expect(fast.row("sneaky.txt")?.isIdentical == true,
       "fast mode is expected NOT to see equal-size, equal-date content changes")
expect(fast.row("big.bin")?.isIdentical == true,
       "fast mode is expected NOT to see the one-byte change in big.bin")
expect(fast.diagnostics.isEmpty, "fast mode should raise no diagnostics, got \(fast.diagnostics)")

// MARK: - Content mode

section("Content mode (byte-exact)")
let exact = await run(contents: true)

expect(exact.row("sneaky.txt")?.flags.contains(.dataContent) == true,
       "content mode must catch the equal-size, equal-date change")
expect(exact.row("big.bin")?.flags.contains(.dataContent) == true,
       "content mode must catch a single differing byte 900 KB in")
expect(exact.row("same.txt")?.isIdentical == true,
       "identical files must stay identical in content mode")
expect(exact.row("sub/deep/deepest.txt")?.isIdentical == true,
       "identical nested files must stay identical in content mode")
expect(exact.row("empty.txt")?.isIdentical == true,
       "empty files must stay identical in content mode")
expect(exact.row("link-same")?.isIdentical == true,
       "symlinks with the same target must be identical")
expect(exact.row("link-diff")?.flags.contains(.dataContent) == true,
       "symlinks with different targets must differ")
expect(exact.diagnostics.isEmpty,
       "content mode should raise no diagnostics, got \(exact.diagnostics)")

// Every row that fast mode called different must still be different.
for row in fast.rows where !row.isIdentical {
    let match = exact.row(row.displayPath)
    expect(match?.isIdentical == false,
           "\(row.displayPath) was different in fast mode but identical in content mode")
}

// MARK: - Merge-walk regression (the reference implementation loses `y` here)

section("Merge walk: no item may be dropped")
mkdir("mergeL"); mkdir("mergeR")
write("mergeL/a", "1"); write("mergeL/y", "1"); write("mergeL/z", "1")
write("mergeR/a", "1"); write("mergeR/b", "1")
let merge = await run(contents: false, left: "mergeL", right: "mergeR")
expect(Set(merge.paths) == ["a", "b", "y", "z"],
       "every item on both sides must appear exactly once, got \(merge.paths.sorted())")
expect(merge.row("y")?.flags.contains(.removed) == true, "y must be reported as Removed")
expect(merge.row("z")?.flags.contains(.removed) == true, "z must be reported as Removed")
expect(merge.row("b")?.flags.contains(.added) == true, "b must be reported as Added")

// MARK: - Name matching

section("Name matching")
mkdir("caseL"); mkdir("caseR")
write("caseL/ReadMe.txt", "x"); write("caseR/readme.txt", "x")
setModified("caseL/ReadMe.txt", epoch); setModified("caseR/readme.txt", epoch)
// Same name, one precomposed and one decomposed.
write("caseL/caf\u{00E9}.txt", "x")
write("caseR/cafe\u{0301}.txt", "x")
setModified("caseL/caf\u{00E9}.txt", epoch)
setModified("caseR/cafe\u{0301}.txt", epoch)
let names = await run(contents: true, left: "caseL", right: "caseR")
expect(names.rows.count == 2,
       "case- and normalization-variant names must pair up into 2 rows, got \(names.paths)")
expect(names.rows.allSatisfy(\.isIdentical),
       "paired variant names holding the same bytes must be identical")

// MARK: - Names that are NOT the same item

// Numeric collation is for reading order. As a test of identity it says
// IMG_1 and IMG_01 are the same photograph, which turns two folders holding
// the two spellings into one folder whose files have all been edited.
section("Distinct names must not be conflated")
mkdir("numL"); mkdir("numR")
write("numL/IMG_1.jpg", "picture one")
write("numR/IMG_01.jpg", "an entirely different picture")
let padded = await run(contents: true, left: "numL", right: "numR")
expect(padded.row("IMG_1.jpg")?.flags.contains(.removed) == true,
       "IMG_1.jpg exists only on the left and must be reported so")
expect(padded.row("IMG_01.jpg")?.flags.contains(.added) == true,
       "IMG_01.jpg exists only on the right and must be reported so")
expect(padded.rows.count == 2,
       "two differently-named files are two findings, got \(padded.paths)")

// The same names, but both spellings on one side. Conflating them here made
// the tool report the file that *was* on both sides as missing from the right.
mkdir("num2L"); mkdir("num2R")
write("num2L/IMG_1.jpg", "one"); write("num2L/IMG_01.jpg", "padded")
write("num2R/IMG_01.jpg", "padded")
setModified("num2L/IMG_01.jpg", epoch); setModified("num2R/IMG_01.jpg", epoch)
let padded2 = await run(contents: true, left: "num2L", right: "num2R")
expect(padded2.row("IMG_01.jpg")?.isIdentical == true,
       "IMG_01.jpg is on both sides, unchanged, and must be reported identical")
expect(padded2.row("IMG_1.jpg")?.flags.contains(.removed) == true,
       "IMG_1.jpg is only on the left and must be reported so")

// Width and compatibility folds have no basis in the file system: every one
// of these pairs can sit in a single folder at once, so treating either as
// one item makes the app report a file that is on both sides as missing.
mkdir("foldL"); mkdir("foldR")
for (left, right) in [("1", "\u{FF11}"), ("A", "\u{FF21}"), ("file", "\u{FB01}le"),
                      ("Strasse", "Stra\u{00DF}e")] {
    write("foldL/\(left)", "left side")
    write("foldR/\(right)", "right side")
}
let folded = await run(contents: true, left: "foldL", right: "foldR")
expect(folded.rows.count == 8,
       "four distinct names on each side are eight findings, got \(folded.paths)")
expect(folded.rows.allSatisfy { !$0.isIdentical && ($0.existsOnLeft != $0.existsOnRight) },
       "none of these names denote the same item, so every row is one-sided")

// The folds that *are* real must survive: volumes fold case, and volumes
// really do store the same name composed differently.
mkdir("realL"); mkdir("realR")
write("realL/ReadMe.txt", "x"); write("realR/README.TXT", "x")
write("realL/caf\u{00E9}.txt", "x"); write("realR/cafe\u{0301}.txt", "x")
for path in ["realL/ReadMe.txt", "realR/README.TXT", "realL/caf\u{00E9}.txt", "realR/cafe\u{0301}.txt"] {
    setModified(path, epoch)
}
let real = await run(contents: true, left: "realL", right: "realR")
expect(real.rows.count == 2,
       "case and composition variants must still pair up, got \(real.paths)")
expect(real.rows.allSatisfy(\.isIdentical),
       "paired variants holding the same bytes are identical")

// A file on both sides must never be split into two one-sided findings just
// because a look-alike name shares the folder.
mkdir("sibL"); mkdir("sibR")
for side in ["sibL", "sibR"] {
    write("\(side)/3", "three"); write("\(side)/\u{FF13}", "full width three")
    setModified("\(side)/3", epoch); setModified("\(side)/\u{FF13}", epoch)
}
let siblings = await run(contents: true, left: "sibL", right: "sibR")
expect(siblings.rows.count == 2 && siblings.rows.allSatisfy(\.isIdentical),
       "both names are on both sides, unchanged: two identical rows, got "
       + "\(siblings.rows.map { "\($0.displayPath):\($0.flags.rawValue)" })")

// Ordering ties must keep every spelling of one item together, or the merge
// walk — which only ever looks at the front of each list — steps past a match.
mkdir("tieL"); mkdir("tieR")
write("tieL/FILE1", "same bytes")
write("tieR/FILE01", "other"); write("tieR/File1", "same bytes")
setModified("tieL/FILE1", epoch); setModified("tieR/File1", epoch)
let tie = await run(contents: true, left: "tieL", right: "tieR")
expect(tie.row("FILE1")?.isIdentical == true,
       "FILE1 and File1 differ only in case and must pair up, got \(tie.paths)")
expect(tie.row("FILE01")?.flags.contains(.added) == true,
       "FILE01 is a different item and belongs only to the right")

// The reading order itself must survive all of that.
var natural = ["file10", "file2", "file1", "File1", "file01", "z10", "z9"]
natural.sort { FilenameOrder.sortingCompare($0, $1) == .orderedAscending }
expect(natural.firstIndex(of: "file2")! < natural.firstIndex(of: "file10")!,
       "file2 must still read before file10, got \(natural)")
expect(natural.firstIndex(of: "z9")! < natural.firstIndex(of: "z10")!,
       "z9 must still read before z10, got \(natural)")

// MARK: - Sort/match consistency

section("Ordering")
mkdir("sortL")
for name in ["file10", "file2", "File1", "b", "A", "z10", "z9"] {
    write("sortL/\(name)", "x")
}
let scan = DirectoryScanner.scan(rootPath: base + "/sortL", cancellation: CancellationFlag())
let sorted = scan.tree!.children(of: 0).map { scan.tree![$0].name }
expect(sorted == ["A", "b", "File1", "file2", "file10", "z9", "z10"],
       "natural, case-insensitive ordering expected, got \(sorted)")

// MARK: - The invariants the merge walk rests on

// The walk decides which side to advance from `matchingCompare`, while both
// sides were sorted by `sortingCompare`. These four properties are what make
// that safe; a violation of any one of them loses or duplicates items.
section("Collation invariants")
var corpus: [String] = []
for stem in ["file", "File", "FILE", "img", "a", "z"] {
    for suffix in ["", "0", "1", "01", "001", "2", "10", "010", "09", "9"] {
        corpus.append(stem + suffix)
    }
}
corpus += ["café", "cafe\u{0301}", "CAFÉ", "ﬁle", "Straße", "Strasse", "ss", "ß",
           "Ａ", "A", "a b", "a-b", "ab", ".dot", "~tmp", "v1.0", "v1.00",
           "2024-1-1", "2024-01-01", "track 1", "track 01"]
corpus = Array(Set(corpus)).sorted()

func direction(_ result: ComparisonResult) -> Int {
    result == .orderedSame ? 0 : (result == .orderedAscending ? -1 : 1)
}

var disagreements = 0, asymmetries = 0, intransitives = 0
for a in corpus {
    for b in corpus {
        let match = direction(FilenameOrder.matchingCompare(a, b))
        if match != 0 && match != direction(FilenameOrder.sortingCompare(a, b)) {
            disagreements += 1
        }
        if match != -direction(FilenameOrder.matchingCompare(b, a)) { asymmetries += 1 }
    }
}
for a in corpus {
    for b in corpus where FilenameOrder.matchingCompare(a, b) == .orderedSame {
        for c in corpus
        where FilenameOrder.matchingCompare(b, c) == .orderedSame
            && FilenameOrder.matchingCompare(a, c) != .orderedSame {
            intransitives += 1
        }
    }
}
expect(disagreements == 0,
       "matching and sorting must never point in opposite directions "
       + "(\(disagreements) pairs do)")
expect(asymmetries == 0, "matching must be symmetric (\(asymmetries) pairs are not)")
expect(intransitives == 0,
       "being the same item must be transitive (\(intransitives) triples are not)")

// Every spelling of one item must be contiguous in the sorted order: the walk
// compares only the two names at the front of each list, so a foreign name
// seated between two spellings of the same item hides the match behind it.
let ordered = corpus.sorted { FilenameOrder.sortingCompare($0, $1) == .orderedAscending }
var gaps = 0
for i in ordered.indices {
    for k in ordered.indices
    where k > i + 1
        && FilenameOrder.matchingCompare(ordered[i], ordered[k]) == .orderedSame {
        for j in (i + 1) ..< k
        where FilenameOrder.matchingCompare(ordered[i], ordered[j]) != .orderedSame {
            gaps += 1
        }
    }
}
expect(gaps == 0,
       "a name that is not the same item must never sort between two that are "
       + "(\(gaps) do)")

// The sort must also be a total order, or `Array.sort` is entitled to produce
// anything at all — including a listing the other side cannot be merged with.
var orderViolations = 0
for a in corpus {
    for b in corpus {
        if direction(FilenameOrder.sortingCompare(a, b))
            != -direction(FilenameOrder.sortingCompare(b, a)) { orderViolations += 1 }
        for c in corpus {
            let ab = direction(FilenameOrder.sortingCompare(a, b))
            let bc = direction(FilenameOrder.sortingCompare(b, c))
            let ac = direction(FilenameOrder.sortingCompare(a, c))
            if ab < 0 && bc < 0 && !(ac < 0) { orderViolations += 1 }
            if ab == 0 && bc == 0 && ac != 0 { orderViolations += 1 }
        }
    }
}
expect(orderViolations == 0,
       "the sort must be antisymmetric and transitive (\(orderViolations) violations)")

// MARK: - Identical trees

section("Identical trees")
let self1 = await run(contents: true, left: "left", right: "left")
expect(self1.rows.allSatisfy(\.isIdentical),
       "a tree compared against itself must show no differences")
expect(self1.rows.count > 5, "self-comparison should still enumerate everything")

// MARK: - Filters

section("Filters")
var filter = ComparisonFilter()
filter.hideIdentical = true
let differing = filter.apply(to: exact.rows)
expect(differing.allSatisfy { !$0.isIdentical }, "hideIdentical must drop identical rows")
expect(differing.count == exact.rows.filter { !$0.isIdentical }.count, "count must match")

// "Treat as identical" clears the difference rather than hiding the row: the
// item becomes identical in every respect the rest of the app asks about, and
// it is then "Hide identical items" alone that decides whether it is shown.
var permsOnly = ComparisonFilter()
permsOnly.ignorePermissions = true
let permsRow = permsOnly.apply(to: exact.rows).first { $0.displayPath == "perms.txt" }
expect(permsRow != nil,
       "ignorePermissions must not hide a row that differs only in permissions")
expect(permsRow?.isIdentical == true,
       "ignorePermissions must report a permissions-only difference as identical, "
       + "got \(String(describing: permsRow?.flags))")
expect(permsOnly.apply(to: exact.rows).contains { $0.displayPath == "sized.txt" },
       "ignorePermissions must not hide a row that differs in other ways")
expect(permsOnly.apply(to: exact.rows).first { $0.displayPath == "sized.txt" }?
        .flags.contains(.dataSize) == true,
       "ignorePermissions must leave every other difference in place")

var permsHidden = permsOnly
permsHidden.hideIdentical = true
expect(!permsHidden.apply(to: exact.rows).contains { $0.displayPath == "perms.txt" },
       "with identical items hidden too, a permissions-only difference must go")

// And the status line has to agree with the list it sits under.
let ignoringPerms = ComparisonSummary(rows: exact.rows, ignoring: permsOnly.ignoredFlags)
expect(ignoringPerms.differences.permissions == 0,
       "a discounted difference must not still be counted in the summary")
expect(ignoringPerms.total == exact.rows.count,
       "discounting a difference must not change how many items were compared")
expect(ignoringPerms.identical > ComparisonSummary(rows: exact.rows).identical,
       "a row whose only difference is discounted must count as identical")

var hidden = ComparisonFilter()
hidden.hideHidden = true
expect(!hidden.apply(to: exact.rows).contains { $0.displayPath == ".hidden" },
       "hideHidden must drop dot-files")

var search = ComparisonFilter()
search.searchText = "SNEAK"
expect(search.apply(to: exact.rows).map(\.displayPath) == ["sneaky.txt"],
       "search must be case-insensitive substring matching")

// MARK: - Unrecorded creation dates

// A volume that keeps no birth times answers with the epoch for everything on
// it. Read as a date, that makes every file on such a volume differ from its
// counterpart in a respect neither file system can actually be asked about.
section("Unrecorded creation dates")

@MainActor func attributes(created: Int64, modified: Int64 = 1_000) -> FileAttributes {
    FileAttributes(
        kind: .file, permissions: 0o644, userID: 501, groupID: 20,
        creationDate: Timestamp(seconds: created),
        modificationDate: Timestamp(seconds: modified),
        dataSize: 10, resourceSize: 0)
}

expect(!FolderComparator.attributeFlags(
        attributes(created: 0), attributes(created: 0))
        .contains(.creationDate),
       "two items that both have no creation date must not differ in one")
expect(!FolderComparator.attributeFlags(
        attributes(created: 0), attributes(created: 5_000))
        .contains(.creationDate),
       "an unrecorded creation date must not be compared against a real one")
expect(FolderComparator.attributeFlags(
        attributes(created: 4_000), attributes(created: 5_000))
        .contains(.creationDate),
       "two recorded creation dates that differ must still be reported")
expect(FolderComparator.attributeFlags(
        attributes(created: 0, modified: 1), attributes(created: 0, modified: 2))
        .contains(.modificationDate),
       "an unrecorded creation date must not suppress any other difference")

// MARK: - The status line's counts

// Every count is recomputed here from the rows by a second, independent
// route. The status line is the only place most people read the result off,
// so a count that drifts from the list underneath it is a wrong answer in the
// most visible place there is.
section("Summary counts")
let counted = ComparisonSummary(rows: exact.rows)
expect(counted.total == exact.rows.count,
       "total \(counted.total) must equal the row count \(exact.rows.count)")
expect(counted.identical == exact.rows.filter(\.isIdentical).count,
       "identical count must match the rows that are identical")
expect(counted.added == exact.rows.filter { $0.flags.contains(.added) }.count,
       "added count must match the rows only on the right")
expect(counted.removed == exact.rows.filter { $0.flags.contains(.removed) }.count,
       "removed count must match the rows only on the left")
expect(counted.identical + counted.modified + counted.added + counted.removed
       == exact.rows.count,
       "the four headline counts must partition the rows exactly once each")
expect(counted.differingItems == exact.rows.count - counted.identical,
       "differing items must be everything that is not identical")

// Each individual difference counter against its own flag.
func rowsWith(_ flag: ComparisonFlags) -> Int { exact.rows.filter { $0.flags.contains(flag) }.count }
expect(counted.differences.modificationDate == rowsWith(.modificationDate),
       "modification-date count must match the flag")
expect(counted.differences.creationDate == rowsWith(.creationDate),
       "creation-date count must match the flag")
expect(counted.differences.permissions == rowsWith(.permissions),
       "permissions count must match the flag")
expect(counted.differences.owner == rowsWith(.userID), "owner count must match the flag")
expect(counted.differences.group == rowsWith(.groupID), "group count must match the flag")
expect(counted.differences.replaced == rowsWith(.replaced), "replaced count must match the flag")
expect(counted.differences.leftExclusive == rowsWith(.removed),
       "left-exclusive count must match the flag")
expect(counted.differences.rightExclusive == rowsWith(.added),
       "right-exclusive count must match the flag")
// `contents` supersedes `size` rather than double-counting it.
expect(counted.differences.contents == rowsWith(.dataContent),
       "contents count must match the flag")
expect(counted.differences.size
       == exact.rows.filter { $0.flags.contains(.dataSize) && !$0.flags.contains(.dataContent) }.count,
       "size must count only rows that byte comparison did not already claim")
expect(counted.differences.resourceFork
       == exact.rows.filter { !$0.flags.isDisjoint(with: [.resourceSize, .resourceContent]) }.count,
       "resource-fork count must match either fork flag")
// An empty comparison must not invent anything.
let blank = ComparisonSummary(rows: [])
expect(blank.total == 0 && blank.differingItems == 0 && blank.differences.described.isEmpty,
       "an empty result must report nothing at all")

// MARK: - Missing folder

section("Missing folder")
let missing = try! await ComparisonEngine.run(
    leftRoot: base + "/does-not-exist", rightRoot: base + "/right",
    options: [], progress: { _ in })
expect(missing.rows.isEmpty, "a missing root must produce no rows")
expect(!missing.diagnostics.isEmpty, "a missing root must be reported as a diagnostic")

// MARK: - Resource forks

// The fork is sized with `getattrlist`, which is a great deal cheaper than
// asking for the extended attribute but has to give exactly the same figure.
section("Resource forks")
@MainActor func writeFork(_ path: String, bytes: Int) {
    let written: Int? = try? {
        let fork = try FileDescriptor.open(
            FilePath(base + "/" + path + "/..namedfork/rsrc"), .writeOnly,
            options: .create, permissions: [.ownerReadWrite, .groupRead, .otherRead])
        return try fork.closeAfter {
            try fork.writeAll([UInt8](repeating: 42, count: bytes))
        }
    }()
    expect(written == bytes, "the fixture fork must be written")
}
@MainActor func forkSizeViaXattr(_ path: String) -> UInt64 {
    let size = unsafe (base + "/" + path).withCString { cPath in
        unsafe "com.apple.ResourceFork".withCString { name in
            unsafe getxattr(cPath, name, nil, 0, 0, 0x0001)
        }
    }
    return size > 0 ? UInt64(size) : 0
}

mkdir("forkL"); mkdir("forkR")
for side in ["forkL", "forkR"] {
    write("\(side)/none.txt", "x")
    write("\(side)/tiny.txt", "x")
    write("\(side)/big.txt", "x")
    symlink("\(side)/link", to: "none.txt")
    setModified("\(side)/none.txt", epoch)
    setModified("\(side)/tiny.txt", epoch)
    setModified("\(side)/big.txt", epoch)
    writeFork("\(side)/tiny.txt", bytes: 1)
    writeFork("\(side)/big.txt", bytes: 300_000)
}

let forkTree = DirectoryScanner.scan(
    rootPath: base + "/forkL", cancellation: CancellationFlag()).tree!
for index in forkTree.nodes.indices.dropFirst() {
    let node = forkTree.nodes[index]
    let expected = node.kind == .file ? forkSizeViaXattr("forkL/" + node.name) : 0
    expect(node.attributes.resourceSize == expected,
           "\(node.name): fork sized \(node.attributes.resourceSize), "
           + "but the extended attribute says \(expected)")
}

// And a fork difference must still be found.
writeFork("forkR/tiny.txt", bytes: 9)
let forks = await run(contents: true, left: "forkL", right: "forkR")
expect(forks.row("tiny.txt")?.flags.contains(.resourceSize) == true,
       "a fork of a different length must be reported")
expect(forks.row("big.txt")?.isIdentical == true,
       "identical forks must not be reported as a difference")
expect(forks.row("none.txt")?.isIdentical == true,
       "files with no fork at all must be identical")

// MARK: - Objects that are not files, folders or links

section("Unsupported kinds")
mkdir("fifoL"); mkdir("fifoR")
write("fifoL/plain.txt", "x"); write("fifoR/plain.txt", "x")
setModified("fifoL/plain.txt", epoch); setModified("fifoR/plain.txt", epoch)
expect(unsafe mkfifo(base + "/fifoL/pipe", 0o644) == 0, "the fixture FIFO must be created")
let fifos = await run(contents: true, left: "fifoL", right: "fifoR")
expect(fifos.paths == ["plain.txt"],
       "a FIFO must be ignored rather than compared, got \(fifos.paths)")
// It was read perfectly well; claiming otherwise would report a hole in the
// comparison that does not exist.
expect(fifos.diagnostics.isEmpty,
       "an ignored FIFO must raise no diagnostic, got \(fifos.diagnostics)")

// MARK: - A root that is not a folder

section("Root that is not a folder")
write("notAFolder", "x")
let notFolder = try! await ComparisonEngine.run(
    leftRoot: base + "/notAFolder", rightRoot: base + "/right",
    options: [], progress: { _ in })
expect(notFolder.rows.isEmpty, "a non-folder root must produce no rows")
expect(notFolder.diagnostics.first?.code == ENOTDIR,
       "a file chosen as a root must be reported as ENOTDIR, not a stale errno: "
       + "\(notFolder.diagnostics)")
expect(notFolder.diagnostics.first?.summary == "This is not a folder",
       "the explanation must say what is actually wrong, got "
       + "\(notFolder.diagnostics.first?.summary ?? "nothing")")

// MARK: - Cancellation

section("Cancellation")
let task = Task {
    try await ComparisonEngine.run(
        leftRoot: base + "/left", rightRoot: base + "/right",
        options: [.fileContent], progress: { _ in })
}
task.cancel()
do {
    _ = try await task.value
    // Finishing before the cancellation lands is legitimate for a tree this small.
    print("  (comparison completed before cancellation took effect)")
} catch is CancellationError {
    print("  (canceled cleanly)")
} catch {
    expect(false, "cancellation raised an unexpected error: \(error)")
}

// MARK: - Canceling the byte-for-byte phase

// Stopping has to stop the reads, not merely throw away what they produce:
// a byte-for-byte pass over a large folder that ignored cancellation would
// keep the disk busy for minutes after the user pressed Stop.
section("Canceling during content reads")
mkdir("bulkL"); mkdir("bulkR")
let payload = Data(repeating: 7, count: 400_000)
for i in 0..<400 {
    writeBytes("bulkL/f\(i).bin", payload)
    writeBytes("bulkR/f\(i).bin", payload)
}

final class ReadTally: Sendable {
    private struct State {
        var stopped = false
        var readsAfterStop = 0
        var task: Task<ComparisonResults, Error>?
    }
    private let state = Mutex(State())

    func adopt(_ task: Task<ComparisonResults, Error>) {
        state.withLock { $0.task = task }
    }
    /// Records one finished file, and stops the run at the first one.
    func sawRead() {
        let toCancel = state.withLock { state -> Task<ComparisonResults, Error>? in
            let alreadyStopped = state.stopped
            if alreadyStopped { state.readsAfterStop += 1 }
            state.stopped = true
            return alreadyStopped ? nil : state.task
        }
        toCancel?.cancel()
    }
    var afterStop: Int { state.withLock { $0.readsAfterStop } }
}

let tally = ReadTally()
let bulk = Task {
    try await ComparisonEngine.run(
        leftRoot: base + "/bulkL", rightRoot: base + "/bulkR",
        options: [.fileContent],
        progress: { if case .readingContents(let done, _, _, _) = $0, done > 0 { tally.sawRead() } })
}
tally.adopt(bulk)
var stoppedCleanly = false
do { _ = try await bulk.value } catch is CancellationError { stoppedCleanly = true } catch {}
expect(stoppedCleanly,
       "a comparison canceled during the content phase must throw CancellationError")
// A handful already in flight is unavoidable; hundreds means it never stopped.
expect(tally.afterStop < 32,
       "reads must stop promptly after cancellation, but \(tally.afterStop) files "
       + "were still compared afterwards")

section("Very deep nesting")

// As deep as the file system allows, which is past where absolute paths stop
// working: the matcher must not recurse its way off the end of its stack.
let depth = 600
for side in ["deepL", "deepR"] {
    mkdir(side)
    let saved = fm.currentDirectoryPath
    fm.changeCurrentDirectoryPath(base + "/" + side)
    for _ in 0 ..< depth where Darwin.mkdir("a", 0o755) == 0 && chdir("a") == 0 {}
    fm.changeCurrentDirectoryPath(saved)
}
let deep = await run(contents: true, left: "deepL", right: "deepR")
expect(deep.rows.count > 400,
       "a hierarchy hundreds of levels deep should be matched, got \(deep.rows.count) rows")
// Folders' dates may straddle a second between the two builds, so only the
// structure is asserted: every level must have paired with its twin.
expect(deep.rows.allSatisfy { !$0.flags.contains(.added) && !$0.flags.contains(.removed) },
       "identical deep hierarchies should pair every level")
// `removeItem` cannot reach past PATH_MAX; `rm` walks it relatively.
let rm = Process()
rm.executableURL = URL(fileURLWithPath: "/bin/rm")
rm.arguments = ["-rf", base + "/deepL", base + "/deepR"]
try? rm.run()
rm.waitUntilExit()

// MARK: - Report

try? fm.removeItem(atPath: base)
print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 { exit(1) }
