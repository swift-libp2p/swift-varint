//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2026 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Testing

@testable import VarInt

/// Swift counterparts of the Go reference implementation's varInt tests.
///
/// Go → Swift API mapping used throughout this suite:
///   - `binary.PutUvarint` / `ToUvarint`  → `UInt64.varIntBytes`
///   - `UvarintSize`                      → `UInt64.varIntSize`
///   - `FromUvarint`                      → `VarInt.decode(_:)`
///   - `ReadUvarint`                      → `VarInt.decode(pullingFrom:)`
///
/// Error mapping:
///   - `ErrOverflow`          → `VarIntError.overflow`
///   - `ErrNotMinimal`        → `VarIntError.notMinimal`
///   - `io.ErrUnexpectedEOF`  → `VarIntError.needsMoreBytes`
///   - `io.EOF`               → a `nil` result from `VarInt.decode(pullingFrom:)`
@Suite("VarInt Go Tests")
struct VarIntGoTests {

    // MARK: Helpers

    /// Mirrors Go's `uvarintSizeReference` helper used to cross-check the
    /// optimised size calculation.
    private func uvarintSizeReference(_ num: UInt64) -> Int {
        let bits = 64 - num.leadingZeroBitCount
        let q = bits / 7
        let r = bits % 7
        var size = q
        if r > 0 || size == 0 {
            size += 1
        }
        return size
    }

    /// Mirrors Go's `checkVarint` helper: encode `x`, verify the reported size
    /// matches the encoded length, and verify it round-trips through decode.
    private func checkVarint(_ x: UInt64) throws {
        let encoded = x.varIntBytes
        let expected = encoded.count

        let size = x.varIntSize
        #expect(size == expected, "expected varIntsize of \(x) to be \(expected), got \(size)")

        let (value, end) = try VarInt.decode(encoded)
        #expect(end == size, "read the wrong size")
        #expect(value == x, "expected a different result")
    }

    /// Reads an unsigned VarInt from a byte array one byte at a time, the way Go's
    /// `ReadUvarint` reads from an `io.Reader`.
    ///
    /// - Returns: `nil` at a clean end of input, matching `io.EOF`.
    private func readUvarint(_ bytes: [UInt8]) throws -> UInt64? {
        var iterator = bytes.makeIterator()
        return try VarInt.decode(readingFrom: { iterator.next() })
    }

    // MARK: TestVarintSize

    /// Counterpart of Go's `TestVarintSize`. Round-trips every value in
    /// `[0, 1 << 16)` through encode/decode and the size calculation.
    @Test func testVarintSize() throws {
        let max: UInt64 = 1 << 16
        for x in UInt64(0)..<max {
            try checkVarint(x)
        }
    }

    // MARK: TestOverflow_9thSignalsMore

    /// Counterpart of Go's `TestOverflow_9thSignalsMore`. A VarInt whose 9th
    /// byte still signals "more" but is followed by EOF must surface as an
    /// error, either overflow (would-be 10th byte cannot fit) or a truncated
    /// VarInt (input ended mid-decode). Either is acceptable per the contract.
    @Test func testOverflow_9thSignalsMore() {
        let bytes: [UInt8] = [
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0x80,
        ]

        #expect(throws: VarIntError.needsMoreBytes) { _ = try readUvarint(bytes) }
        #expect(throws: VarIntError.needsMoreBytes) { _ = try VarInt.decode(bytes) }
    }

    // MARK: TestOverflow_ReadBuffer

    /// Counterpart of Go's `TestOverflow_ReadBuffer`. Reading well more than
    /// 10 continuation bytes should overflow.
    @Test func testOverflow_ReadBuffer() {
        let bytes: [UInt8] = Array(repeating: 0xff, count: 24)

        #expect(throws: VarIntError.overflow) { _ = try readUvarint(bytes) }
        #expect(throws: VarIntError.overflow) { _ = try VarInt.decode(bytes) }
    }

    // MARK: TestOverflow

    /// Counterpart of Go's `TestOverflow`. A VarInt requiring more than 10
    /// bytes overflows, and now reports `VarIntError.overflow` directly rather
    /// than a negative byte count.
    @Test func testOverflow() {
        let bytes: [UInt8] = [
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0x00,
        ]

        #expect(throws: VarIntError.overflow) { _ = try VarInt.decode(bytes) }
    }

    // MARK: TestNotMinimal

    /// Counterpart of Go's `TestNotMinimal`. `[0x81, 0x00]` decodes to `1` but
    /// the trailing 0 byte is redundant, so the decoder rejects it.
    @Test func testNotMinimal() throws {
        let varInt: [UInt8] = [0x81, 0x00]

        #expect(throws: VarIntError.notMinimal) { _ = try VarInt.decode(varInt) }

        // Ensure we can decode it when requireMinimal is false
        #expect(try VarInt.decode(varInt, requireMinimal: false).value == 1)
    }

    // MARK: TestNotMinimalRead

    /// Counterpart of Go's `TestNotMinimalRead`. The byte-source reader must
    /// throw `notMinimal` for the same redundant `[0x81, 0x00]` encoding.
    @Test func testNotMinimalRead() {
        #expect(throws: VarIntError.notMinimal) { _ = try readUvarint([0x81, 0x00]) }
    }

    // MARK: TestUnderflow

    /// Counterpart of Go's `TestUnderflow`. A valid buffer that ends mid-VarInt is
    /// reported as `needsMoreBytes`.
    @Test func testUnderflow() {
        #expect(throws: VarIntError.needsMoreBytes) { _ = try VarInt.decode([0x81, 0x81] as [UInt8]) }
        #expect(throws: VarIntError.needsMoreBytes) { _ = try VarInt.decode([0x81] as [UInt8]) }
    }

    // MARK: TestEOF

    /// Counterpart of Go's `TestEOF`. An empty stream is a clean end of input,
    /// reported as `nil` rather than an error.
    @Test func testEOF() throws {
        #expect(try readUvarint([]) == nil)

        // The collection-based entry is reported as a short read.
        #expect(throws: VarIntError.needsMoreBytes) { _ = try VarInt.decode([] as [UInt8]) }
    }

    // MARK: TestUnexpectedEOF

    /// Counterpart of Go's `TestUnexpectedEOF`. A stream that ends partway
    /// through a VarInt (continuation byte then EOF) must surface as an error,
    /// not as a clean end of stream.
    @Test func testUnexpectedEOF() {
        #expect(throws: VarIntError.needsMoreBytes) { _ = try readUvarint([0x81, 0x81]) }
    }

    struct Case {
        let name: String
        let value: UInt64
        let expected: Int
    }

    static let cases: [Case] = [
        .init(name: "zero", value: 0, expected: 1),

        // Single byte values (0-127)
        .init(name: "one", value: 1, expected: 1),
        .init(name: "max_single_byte", value: 127, expected: 1),

        // Two byte values (128-16383)
        .init(name: "min_two_bytes", value: 128, expected: 2),
        .init(name: "max_two_bytes", value: 16383, expected: 2),

        // Boundary values for each byte count
        .init(name: "boundary_1_to_2", value: (1 << 7) - 1, expected: 1),
        .init(name: "boundary_2_start", value: 1 << 7, expected: 2),
        .init(name: "boundary_2_to_3", value: (1 << 14) - 1, expected: 2),
        .init(name: "boundary_3_start", value: 1 << 14, expected: 3),
        .init(name: "boundary_3_to_4", value: (1 << 21) - 1, expected: 3),
        .init(name: "boundary_4_start", value: 1 << 21, expected: 4),
        .init(name: "boundary_4_to_5", value: (1 << 28) - 1, expected: 4),
        .init(name: "boundary_5_start", value: 1 << 28, expected: 5),
        .init(name: "boundary_5_to_6", value: (1 << 35) - 1, expected: 5),
        .init(name: "boundary_6_start", value: 1 << 35, expected: 6),
        .init(name: "boundary_6_to_7", value: (1 << 42) - 1, expected: 6),
        .init(name: "boundary_7_start", value: 1 << 42, expected: 7),
        .init(name: "boundary_7_to_8", value: (1 << 49) - 1, expected: 7),
        .init(name: "boundary_8_start", value: 1 << 49, expected: 8),
        .init(name: "boundary_8_to_9", value: (1 << 56) - 1, expected: 8),
        .init(name: "boundary_9_start", value: 1 << 56, expected: 9),
        .init(name: "boundary_9_to_10", value: (1 << 63) - 1, expected: 9),
        .init(name: "boundary_10_start", value: 1 << 63, expected: 10),

        // Maximum values
        .init(name: "max_uint64", value: UInt64.max, expected: 10),
        .init(name: "max_uint64_minus_1", value: UInt64.max - 1, expected: 10),

        // Powers of 2
        .init(name: "power_2_0", value: 1 << 0, expected: 1),
        .init(name: "power_2_6", value: 1 << 6, expected: 1),
        .init(name: "power_2_7", value: 1 << 7, expected: 2),
        .init(name: "power_2_8", value: 1 << 8, expected: 2),
        .init(name: "power_2_13", value: 1 << 13, expected: 2),
        .init(name: "power_2_14", value: 1 << 14, expected: 3),
        .init(name: "power_2_20", value: 1 << 20, expected: 3),
        .init(name: "power_2_21", value: 1 << 21, expected: 4),
        .init(name: "power_2_27", value: 1 << 27, expected: 4),
        .init(name: "power_2_28", value: 1 << 28, expected: 5),
        .init(name: "power_2_34", value: 1 << 34, expected: 5),
        .init(name: "power_2_35", value: 1 << 35, expected: 6),
        .init(name: "power_2_41", value: 1 << 41, expected: 6),
        .init(name: "power_2_42", value: 1 << 42, expected: 7),
        .init(name: "power_2_48", value: 1 << 48, expected: 7),
        .init(name: "power_2_49", value: 1 << 49, expected: 8),
        .init(name: "power_2_55", value: 1 << 55, expected: 8),
        .init(name: "power_2_56", value: 1 << 56, expected: 9),
        .init(name: "power_2_62", value: 1 << 62, expected: 9),
        .init(name: "power_2_63", value: 1 << 63, expected: 10),

        // Special patterns
        .init(name: "all_ones_32bit", value: 0xFFFF_FFFF, expected: 5),
        .init(name: "all_ones_48bit", value: 0xFFFF_FFFF_FFFF, expected: 7),
        .init(name: "alternating_pattern", value: 0xAAAA_AAAA_AAAA_AAAA, expected: 10),
        .init(name: "alternating_pattern2", value: 0x5555_5555_5555_5555, expected: 9),
    ]

    /// Counterpart of Go's `TestUvarintSizeEdgeCases`. Cross-checks the
    /// optimised size calculation against the reference implementation and
    /// against the actual encoded length for a curated list of edge cases.
    @Test(arguments: Self.cases)
    func testUvarintSizeEdgeCases(_ tc: Case) {
        let original = uvarintSizeReference(tc.value)
        #expect(
            original == tc.expected,
            "Reference implementation is wrong for \(tc.name) (\(tc.value)): got \(original), expected \(tc.expected)"
        )

        let actualSize = tc.value.varIntSize
        #expect(
            actualSize == tc.expected,
            "Our implementation is wrong for \(tc.name) (\(tc.value)): got \(actualSize), expected \(tc.expected)"
        )

        #expect(
            original == actualSize,
            "Implementations differ for \(tc.name) (\(tc.value)): original=\(original), actualSize=\(actualSize)"
        )

        // Verify against the actual encoded length.
        let encoded = tc.value.varIntBytes
        #expect(
            encoded.count == tc.expected,
            "Actual encoding length differs for \(tc.name) (\(tc.value)): got \(encoded.count), expected \(tc.expected)"
        )

        #expect(
            actualSize == encoded.count,
            "varIntSize doesn't match actual encoding for \(tc.name) (\(tc.value)): varIntSize=\(actualSize), actual=\(encoded.count)"
        )
    }

    // MARK: TestUvarintSizeExhaustive

    /// Counterpart of Go's `TestUvarintSizeExhaustive`. Walks the first million
    /// values and verifies the reference and optimised sizes agree with the
    /// actually encoded length.
    @Test func testUvarintSizeExhaustive() {
        for i in UInt64(0)..<1_000_000 {
            let original = uvarintSizeReference(i)
            let actualSize = i.varIntSize

            #expect(
                original == actualSize,
                "Mismatch at \(i): original=\(original), actualSize=\(actualSize)"
            )

            #expect(
                actualSize == i.varIntBytes.count,
                "varIntSize doesn't match actual encoding at \(i): varIntSize=\(actualSize), actual=\(i.varIntBytes.count)"
            )
        }
    }

    // MARK: TestUvarintSizeRandom

    /// Counterpart of Go's `TestUvarintSizeRandom`. Covers a curated set of
    /// values across the entire UInt64 range plus every power-of-two boundary
    /// and its neighbors.
    @Test func testUvarintSizeRandom() {
        var testValues: [UInt64] = [
            // 1 byte
            42, 100, 126,
            // 2 bytes
            200, 1_000, 10_000, 16_000,
            // 3 bytes
            20_000, 100_000, 1_000_000, 2_000_000,
            // 4 bytes
            10_000_000, 100_000_000, 200_000_000,
            // 5 bytes
            1_000_000_000, 10_000_000_000, 30_000_000_000,
            // 6 bytes
            100_000_000_000, 1_000_000_000_000,
            // 7 bytes
            10_000_000_000_000, 100_000_000_000_000,
            // 8 bytes
            1_000_000_000_000_000, 10_000_000_000_000_000,
            // 9 bytes
            100_000_000_000_000_000, 1_000_000_000_000_000_000,
            // 10 bytes
            10_000_000_000_000_000_000,
        ]

        // Add bit-shifting values for better coverage across the full range.
        for shift in 0..<64 {
            let base = UInt64(1) << shift
            testValues.append(base)
            if base > 2 {
                testValues.append(base - 1)
                testValues.append(base - 2)
            }
            if base < UInt64.max - 2 {
                testValues.append(base + 1)
                testValues.append(base + 2)
            }
        }

        for v in testValues {
            let original = uvarintSizeReference(v)
            let actualSize = v.varIntSize

            #expect(
                original == actualSize,
                "Mismatch for \(v): original=\(original), actualSize=\(actualSize)"
            )

            #expect(
                actualSize == v.varIntBytes.count,
                "varIntSize doesn't match actual encoding for \(v): varIntSize=\(actualSize), actual=\(v.varIntBytes.count)"
            )
        }
    }
}
