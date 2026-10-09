// MARK: - StorageMedium.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Identifies whether a folder lives on flash, a spinning disk, or a network
// share by consulting the mount table and I/O registry once when a comparison
// starts. That answer decides how many folders and files may usefully be read
// at the same time.

import Foundation
import IOKit
import IOKit.storage

/// What sort of device a folder actually lives on.
///
/// This exists for one reason: how many folders may usefully be read at once,
/// and how many files may usefully be compared at once, depends entirely on
/// what is underneath them. A flash device answers many outstanding requests
/// at once and is barely faster answering one at a time; a spinning disk has a
/// single head, and overlapping requests turn one sequential sweep into a
/// scatter of seeks that is dramatically *slower*.
enum StorageMedium: Sendable {
    case solidState
    case rotational
    /// No local device to ask about — a network share, almost always — or a
    /// device that declines to describe itself.
    case unknown

    /// Identifies the device holding `path`.
    ///
    /// Answered once, when a comparison starts, from the mount table and the
    /// I/O registry. Both are already in memory, so this costs no disk access
    /// and takes microseconds.
    static func atPath(_ path: String) -> StorageMedium {
        guard let device = bsdName(atPath: path) else { return .unknown }
        return medium(ofDevice: device)
    }

    /// The `disk3s1` part of the device a path's volume is mounted from.
    ///
    /// A network mount has no such device — `f_mntfromname` is something like
    /// `//user@host/Share` — which is exactly the case `unknown` is for.
    private static func bsdName(atPath path: String) -> String? {
        var info = statfs()
        guard unsafe path.withCString({ unsafe statfs($0, &info) }) == 0 else { return nil }
        // The name is a fixed-size C array: read up to its terminator, and
        // never past the end of the array should the terminator be missing.
        let source = unsafe withUnsafeBytes(of: &info.f_mntfromname) { raw in
            unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard source.hasPrefix("/dev/") else { return nil }
        return String(source.dropFirst(5))
    }

    /// Asks the I/O registry what kind of medium a device is.
    ///
    /// The answer lives on the physical device, not on the partition the
    /// volume is mounted from, so the search walks *up* the parent chain from
    /// the `IOMedia` object until it finds a device that describes itself.
    /// This is read-only registry access, which the app sandbox permits.
    private static func medium(ofDevice device: String) -> StorageMedium {
        // The C strings here are `device` and IOKit's own plane name, each
        // passed for the duration of the call alone.
        // Apple can kiss my ass; I'll use the word "master" if I damn well please.
        let service = unsafe IOServiceGetMatchingService(
            kIOMasterPortDefault, IOBSDNameMatching(kIOMasterPortDefault, 0, device))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }

        guard let characteristics = unsafe IORegistryEntrySearchCFProperty(
            service, kIOServicePlane,
            kIOPropertyDeviceCharacteristicsKey as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            as? [String: Any],
              let type = characteristics[kIOPropertyMediumTypeKey] as? String
        else { return .unknown }

        switch type {
        case kIOPropertyMediumTypeSolidStateKey: return .solidState
        case kIOPropertyMediumTypeRotationalKey: return .rotational
        default: return .unknown
        }
    }

    // MARK: - What it is for

    /// How many folders to read at once while scanning.
    ///
    /// Note which way round the unknown case falls. A device that cannot be
    /// identified is, in practice, a network share — and a share is bound by
    /// round-trip latency rather than by seeking, so it benefits from several
    /// requests in flight more than anything else does. An external spinning
    /// disk is *not* an unknown: it has a device node and says so plainly.
    /// Narrowing on doubt would therefore slow down the one case that gains
    /// the most, to protect a case that is never actually in doubt.
    ///
    /// Six is where the measurements stop improving — reading Xcode's
    /// `Platforms` folder takes 281 ms one directory at a time, 92 ms at six,
    /// and 106 ms at twelve.
    var scanWidth: Int {
        switch self {
        case .rotational: 1
        case .solidState, .unknown: min(ProcessInfo.processInfo.activeProcessorCount, 6)
        }
    }

    /// How many file pairs to read at once during a byte-for-byte comparison.
    ///
    /// This phase moves the files themselves rather than their names, so on a
    /// *local* device it is bound by bandwidth, which overlapping reads do not
    /// increase, rather than by request latency, which they hide. Over 6,837
    /// files on the internal SSD: 204 ms at two abreast, 140 ms at four,
    /// 124 ms at eight, 125 ms at twelve and 131 ms at sixteen. There is
    /// nothing above eight to take.
    ///
    /// A spinning disk is the case that was being harmed, and it drops to two:
    /// every pair reads from both sides at once, so even this is four streams
    /// under one head.
    ///
    /// A network share is the opposite case and no longer shares the flash
    /// number. Its cost is a round trip per request, not bandwidth under a
    /// head, so the only way to reach the link's capacity is to keep many
    /// requests outstanding at once; at eight it spends most of its time
    /// waiting.
    ///
    /// Sixteen rather than more, for a reason that is not about the share: a
    /// pair now reads its two sides at the same time, so each pair in flight
    /// occupies two threads, and Dispatch's worker pool tops out at 64. Every
    /// parent thread blocks waiting for its partner, so a width that let the
    /// parents fill the pool would leave no thread able to run a partner and
    /// the phase would stop dead. Sixteen pairs is 32 threads — half the pool,
    /// with the whole other half spare — and 4 MB of requests outstanding,
    /// which is already far more than an ordinary link can hold in flight.
    var contentWidth: Int {
        switch self {
        case .rotational: 2
        case .solidState: min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8)
        case .unknown: 16
        }
    }

    /// Whether to read file contents with the unified buffer cache bypassed.
    ///
    /// On a local device this is plainly right: the files are read once and
    /// never looked at again, so caching them evicts everything the user
    /// actually has open in exchange for nothing.
    ///
    /// On a network share it is plainly wrong, and was the single most
    /// expensive thing this phase did. `F_NOCACHE` makes an SMB or NFS client
    /// issue every read as an uncached, synchronous round trip to the server
    /// and stops it reading ahead — which turns a streaming transfer into
    /// stop-and-wait at one buffer per round trip. Since `unknown` *is* the
    /// network case, it keeps the cache.
    var bypassesCache: Bool {
        switch self {
        case .rotational, .solidState: true
        case .unknown: false
        }
    }

    /// The more cautious of two media.
    ///
    /// The two sides of a comparison need not be on the same sort of device —
    /// checking a backup on a spinning disk against a folder on the internal
    /// flash is an ordinary thing to do — and both sides are worked at the
    /// same time. A width that suits the flash would thrash the disk, so the
    /// slower device sets the pace for both.
    static func moreCautious(_ first: StorageMedium, _ second: StorageMedium) -> StorageMedium {
        if first == .rotational || second == .rotational { return .rotational }
        if first == .unknown || second == .unknown { return .unknown }
        return .solidState
    }
}
