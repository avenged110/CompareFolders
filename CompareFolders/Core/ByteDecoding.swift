// MARK: - ByteDecoding.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// Reads integers out of the packed record `getattrlist` returns, straight
// from a byte array and with every field bounds-checked, so code decoding a
// reply handles no pointers at all.

extension Array where Element == UInt8 {

    /// The integer stored in host byte order at `offset`.
    ///
    /// The kernel packs its attribute replies with no regard for alignment,
    /// hence an unaligned load. The whole field is checked against the array
    /// first, in every build: a record that claims more than the buffer holds
    /// stops the program rather than reading past it. That check is what
    /// makes the load safe, and it is made once per field rather than once
    /// per byte, which on a scan of a hundred thousand items is the
    /// difference between this costing nothing and it costing half again.
    func loadInteger<T: FixedWidthInteger & BitwiseCopyable>(
        fromByteOffset offset: Int, as _: T.Type = T.self
    ) -> T {
        precondition(offset >= 0 && offset <= count - MemoryLayout<T>.size,
                     "field lies outside the reply")
        return unsafe withUnsafeBytes { bytes in
            unsafe bytes.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
    }

    /// The big-endian `UInt16` at `offset` — the byte order of Finder info.
    func loadBigEndianUInt16(fromByteOffset offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }
}
