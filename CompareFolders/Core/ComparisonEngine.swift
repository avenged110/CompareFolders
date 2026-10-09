// MARK: - ComparisonEngine.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Top-level orchestrator of a comparison: scans both folders, matches them,
// optionally reads matched file contents in parallel, and publishes throttled
// progress. Also defines the progress-reporting types and the shared atomic
// counters the worker threads tally into.

import Foundation
import Synchronization

/// What the engine is currently doing, for the progress readout.
enum ComparisonProgress: Sendable {
    case scanning(items: Int)
    case matching
    /// Both units matter and neither is enough alone. The file count is what
    /// the user recognizes the job by; the byte count is what the time is
    /// actually spent on, and is the only one of the two that moves while a
    /// single very large file is being read.
    case readingContents(
        completed: Int, total: Int, bytes: UInt64, totalBytes: UInt64)
}

/// A simple shared tally, written from a scanning thread and read from another.
private final class Counter: Sendable {
    private let storage = Atomic<Int>(0)
    func set(_ value: Int) { storage.store(value, ordering: .relaxed) }
    func increment() -> Int { storage.wrappingAdd(1, ordering: .relaxed).newValue }
    var value: Int { storage.load(ordering: .relaxed) }
}

/// A shared running total of bytes, added to from every reading thread.
private final class ByteCounter: Sendable {
    private let storage = Atomic<UInt64>(0)
    func add(_ amount: UInt64) { storage.wrappingAdd(amount, ordering: .relaxed) }
    var value: UInt64 { storage.load(ordering: .relaxed) }
}

/// Lets through one report per interval, however many threads offer one.
///
/// The content phase reports from every reading thread at once, and a report
/// costs a hop onto the main actor. Rationing by elapsed time rather than by
/// counting files is what keeps the readout both cheap and honest: it cannot
/// flood the main actor no matter how many small files fly past, and it cannot
/// fall silent for minutes on end while one enormous file is read.
private final class ReportRation: Sendable {
    private let interval: UInt64
    private let last: Atomic<UInt64>

    init(milliseconds: UInt64) {
        interval = milliseconds * 1_000_000
        last = Atomic<UInt64>(DispatchTime.now().uptimeNanoseconds)
    }

    /// `true` at most once per interval; the caller then makes the report.
    func due() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let previous = last.load(ordering: .relaxed)
        guard now &- previous >= interval else { return false }
        // Whoever wins the exchange reports; the rest of the threads that
        // arrived at the same moment simply carry on reading.
        return last.compareExchange(
            expected: previous, desired: now, ordering: .relaxed).exchanged
    }
}

/// Runs a full comparison, off the main actor.
enum ComparisonEngine {

    /// Compares two folders and returns every row, in tree order.
    ///
    /// - Throws: `CancellationError` if the surrounding task is canceled.
    static func run(
        leftRoot: String,
        rightRoot: String,
        options: ComparisonOptions,
        progress: @escaping @Sendable (ComparisonProgress) -> Void
    ) async throws -> ComparisonResults {
        let cancellation = CancellationFlag()

        return try await withTaskCancellationHandler {
            let leftCount = Counter()
            let rightCount = Counter()

            @Sendable func reportScanning() {
                progress(.scanning(items: leftCount.value + rightCount.value))
            }

            // Both sides are scanned at once. When they live on different
            // volumes this is close to a straight halving of the wall time,
            // and when they share one it costs nothing measurable.
            async let leftScan = blocking {
                DirectoryScanner.scan(rootPath: leftRoot, cancellation: cancellation) {
                    leftCount.set($0)
                    reportScanning()
                }
            }
            async let rightScan = blocking {
                DirectoryScanner.scan(rootPath: rightRoot, cancellation: cancellation) {
                    rightCount.set($0)
                    reportScanning()
                }
            }

            let left = await leftScan
            let right = await rightScan
            try Task.checkCancellation()

            var diagnostics = left.diagnostics + right.diagnostics
            guard let leftTree = left.tree, let rightTree = right.tree else {
                return ComparisonResults(
                    leftRoot: leftRoot, rightRoot: rightRoot, rows: [],
                    diagnostics: diagnostics)
            }

            progress(.matching)
            let walk = await blocking {
                FolderComparator.compare(
                    left: leftTree, right: rightTree,
                    options: options, cancellation: cancellation)
            }
            try Task.checkCancellation()

            var rows = walk.rows
            if !walk.pending.isEmpty {
                // Each pair reads one file from either side at once, so the
                // slower of the two devices is what the width has to suit.
                let outcome = try await compareContents(
                    walk.pending, into: &rows,
                    medium: StorageMedium.moreCautious(
                        StorageMedium.atPath(leftTree.rootPath),
                        StorageMedium.atPath(rightTree.rootPath)),
                    cancellation: cancellation, progress: progress)
                diagnostics.append(contentsOf: outcome)
            }

            return ComparisonResults(
                leftRoot: leftTree.rootPath, rightRoot: rightTree.rootPath,
                rows: rows,
                // Ordered once over the whole set. Each side's scan sorts its
                // own, but the content phase appends in whatever order the
                // reads finished in, and the two sides' lists are simply
                // concatenated — so without this the bar the user reads is
                // partly ordered by chance.
                diagnostics: Diagnostic.ordered(diagnostics))
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Byte-exact phase

    /// One result of reading a matched pair of files.
    private struct ContentOutcome: Sendable {
        let rowIndex: Int
        let flags: ComparisonFlags
        let diagnostics: [Diagnostic]
    }

    /// Reads every matched pair of files and folds the findings back into `rows`.
    ///
    /// Cancellation is checked before every file, and the flag is handed down
    /// into the reads themselves, so pressing Stop during a byte-for-byte pass
    /// over a large folder stops the disk immediately rather than at the end of
    /// however many thousand files were left.
    ///
    /// The reads run several at a time. File comparison is almost entirely
    /// spent waiting on the disk, so overlapping a handful of them keeps the
    /// device queue busy — how many is a property of the device, and
    /// `StorageMedium.contentWidth` explains each of the three answers.
    private static func compareContents(
        _ jobs: [PendingContentCheck],
        into rows: inout [ComparisonRow],
        medium: StorageMedium,
        cancellation: CancellationFlag,
        progress: @escaping @Sendable (ComparisonProgress) -> Void
    ) async throws -> [Diagnostic] {
        // Smallest first. The same files get read either way and the run takes
        // exactly as long, but the count climbs immediately instead of sitting
        // still behind whichever large file the walk happened to reach first —
        // and a user watching a readout that has not moved cannot tell a slow
        // comparison from a stuck one.
        let jobs = jobs.sorted { bytesToRead(of: $0) < bytesToRead(of: $1) }

        let total = jobs.count
        let totalBytes = jobs.reduce(UInt64(0)) { $0 + bytesToRead(of: $1) }
        let width = medium.contentWidth
        let done = Counter()
        let bytes = ByteCounter()
        let ration = ReportRation(milliseconds: 100)
        var diagnostics: [Diagnostic] = []

        @Sendable func report() {
            progress(.readingContents(
                completed: done.value, total: total,
                bytes: bytes.value, totalBytes: totalBytes))
        }

        report()

        try await withThrowingTaskGroup(of: ContentOutcome.self) { group in
            var next = 0

            func addTask(_ job: PendingContentCheck) {
                let expected = bytesToRead(of: job)
                group.addTask {
                    let result = await blocking {
                        ContentComparison.compare(
                            left: job.leftPath, right: job.rightPath,
                            attributes: job.leftAttributes,
                            otherAttributes: job.rightAttributes,
                            medium: medium,
                            cancellation: cancellation,
                            onBytesCompared: { amount in
                                bytes.add(amount)
                                if ration.due() { report() }
                            })
                    }
                    // A pair that differed part-way through stopped reading
                    // there, so the bytes it never looked at are credited now.
                    // Without this the total the bar is measured against could
                    // never be reached and the bar would stall short of full.
                    bytes.add(expected - min(expected, result.bytesCompared))
                    let completed = done.increment()
                    if completed == total || ration.due() { report() }
                    return ContentOutcome(
                        rowIndex: job.rowIndex,
                        flags: result.flags,
                        diagnostics: result.diagnostics)
                }
            }

            while next < min(width, total) {
                addTask(jobs[next])
                next += 1
            }
            while let outcome = try await group.next() {
                try Task.checkCancellation()
                rows[outcome.rowIndex].flags.formUnion(outcome.flags)
                diagnostics.append(contentsOf: outcome.diagnostics)
                if next < total {
                    addTask(jobs[next])
                    next += 1
                }
            }
        }

        return diagnostics
    }

    /// How many bytes a pair will actually be read for.
    ///
    /// Zero on either fork whose two sides are already of different sizes:
    /// that is proof of a difference on its own and the fork is never opened.
    /// Counting it would put work into the total that nobody ever does.
    private static func bytesToRead(of job: PendingContentCheck) -> UInt64 {
        guard !job.leftAttributes.kind.isSymbolicLink else { return 0 }
        var count: UInt64 = 0
        if job.leftAttributes.dataSize == job.rightAttributes.dataSize {
            count += job.leftAttributes.dataSize
        }
        if job.leftAttributes.resourceSize == job.rightAttributes.resourceSize {
            count += job.leftAttributes.resourceSize
        }
        return count
    }
}

/// Runs blocking file-system work away from the cooperative thread pool.
///
/// The scanner and the byte comparator both sit in blocking `read` calls for
/// long stretches. Left on Swift's cooperative pool those would occupy — and
/// with enough of them, exhaust — the small, fixed number of threads the whole
/// concurrency runtime shares.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}
