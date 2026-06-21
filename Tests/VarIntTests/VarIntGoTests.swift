//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing

@testable import VarInt

/// Swift counterparts of the Go reference implementation's varint tests.
///
/// Go → Swift API mapping used throughout this suite:
///   - `binary.PutUvarint` / `ToUvarint`  → `putUVarInt(_:)`
///   - `UvarintSize`                      → `encodedSize(of:)`
///   - `FromUvarint`                      → `uVarInt(_:)`
///   - `ReadUvarint`                      → `readUVarInt(_:)` (uses `InputStream`)
///
/// Error mapping:
///   - `ErrOverflow`                  → `VarIntError.overflow`
///   - `ErrNotMinimal`              → `VarIntError.notMinimal`
///   - `io.EOF`                              → `VarIntError.eof`
///   - `io.ErrUnexpectedEOF` → `VarIntError.unexpectedEOF`
///
/// Buffer-based `uVarInt(_:)` uses sentinel `bytesRead` values rather than
/// throwing: `bytesRead == 0` signals "buffer too small" *or* a non-minimal
/// encoding (Go distinguishes these via the error, Swift does not); `bytesRead
/// < 0` signals overflow.
@Suite("VarInt Go Tests")
struct VarIntGoTests {

    // MARK: Helpers

    /// Mirrors Go's `uvarintSizeReference` helper used to cross-check the
    /// optimised `encodedSize(of:)` implementation.
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
    private func checkVarint(_ x: UInt64) {
        let encoded = putUVarInt(x)
        let expected = encoded.count

        let size = encodedSize(of: x)
        #expect(size == expected, "expected varintsize of \(x) to be \(expected), got \(size)")

        let (xi, n) = uVarInt(encoded)
        #expect(n == size, "read the wrong size")
        #expect(xi == x, "expected a different result")
    }

    // MARK: TestVarintSize

    /// Counterpart of Go's `TestVarintSize`. Round-trips every value in
    /// `[0, 1 << 16)` through encode/decode and `encodedSize(of:)`.
    @Test func testVarintSize() {
        let max: UInt64 = 1 << 16
        for x in UInt64(0)..<max {
            checkVarint(x)
        }
    }

    // MARK: TestOverflow_9thSignalsMore

    /// Counterpart of Go's `TestOverflow_9thSignalsMore`. A varint whose 9th
    /// byte still signals "more" but is followed by EOF must surface as an
    /// error — either overflow (would-be 10th byte cannot fit) or unexpected
    /// EOF (stream ended mid-varint). Either is acceptable per the contract.
    @Test func testOverflow_9thSignalsMore() {
        let bytes: [UInt8] = [
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0x80,
        ]
        let stream = InputStream(data: Data(bytes))
        stream.open()
        defer { stream.close() }

        #expect(throws: VarIntError.unexpectedEOF) {
            _ = try readUVarInt(stream)
        }
    }

    // MARK: TestOverflow_ReadBuffer

    /// Counterpart of Go's `TestOverflow_ReadBuffer`. Reading well more than
    /// 10 continuation bytes via the stream API should overflow.
    @Test func testOverflow_ReadBuffer() {
        let bytes: [UInt8] = Array(repeating: 0xff, count: 24)
        let stream = InputStream(data: Data(bytes))
        stream.open()
        defer { stream.close() }

        #expect(throws: VarIntError.overflow) {
            _ = try readUVarInt(stream)
        }
    }

    // MARK: TestOverflow

    /// Counterpart of Go's `TestOverflow`. A varint requiring more than 10
    /// bytes should overflow when decoded from a byte buffer.
    ///
    /// NOTE: Swift's `uVarInt(_:)` reports overflow by returning `bytesRead < 0`
    /// (specifically `-(consumed + 1)`) and `value == 0`, rather than the
    /// Go `(value: 0, n: 0, err: ErrOverflow)` triple.
    @Test func testOverflow() {
        let bytes: [UInt8] = [
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0xff,
            0xff, 0xff, 0xff, 0x00,
        ]
        let (i, n) = uVarInt(bytes)
        #expect(i == 0, "expected value == 0 on overflow")
        #expect(n < 0, "expected bytesRead < 0 (Swift's overflow signal)")
    }

    // MARK: TestNotMinimal

    /// Counterpart of Go's `TestNotMinimal`. `[0x81, 0x00]` decodes to `1` but
    /// the trailing 0 byte is redundant, so the buffer decoder must reject it.
    /// Swift signals this with `bytesRead == 0` (sharing the underflow code).
    @Test func testNotMinimal() {
        let varint: [UInt8] = [0x81, 0x00]
        let (i, n) = uVarInt(varint)
        #expect(i == 0, "expected value == 0 on non-minimal encoding")
        #expect(n == 0, "expected bytesRead == 0 to signal non-minimal encoding")
    }

    // MARK: TestNotMinimalRead

    /// Counterpart of Go's `TestNotMinimalRead`. The stream-based reader must
    /// throw `notMinimal` for the same redundant `[0x81, 0x00]` encoding.
    @Test func testNotMinimalRead() {
        let stream = InputStream(data: Data([0x81, 0x00]))
        stream.open()
        defer { stream.close() }

        #expect(throws: VarIntError.notMinimal) {
            _ = try readUVarInt(stream)
        }
    }

    // MARK: TestUnderflow

    /// Counterpart of Go's `TestUnderflow`. A buffer that ends mid-varint
    /// should be reported as underflow.
    ///
    /// Swift signals "buffer too small" with `bytesRead == 0`, which lines up
    /// directly with the Go `FromUvarint` underflow triple `(0, 0, _)`.
    @Test func testUnderflow() {
        let (i, n) = uVarInt([0x81, 0x81])
        #expect(i == 0, "expected value == 0 on underflow")
        #expect(n == 0, "expected bytesRead == 0 to signal underflow")
    }

    // MARK: TestEOF

    /// Counterpart of Go's `TestEOF`. An empty stream must surface as `eof`.
    @Test func testEOF() {
        let stream = InputStream(data: Data())
        stream.open()
        defer { stream.close() }

        #expect(throws: VarIntError.eof) {
            _ = try readUVarInt(stream)
        }
    }

    // MARK: TestUnexpectedEOF

    /// Counterpart of Go's `TestUnexpectedEOF`. A stream that ends partway
    /// through a varint (continuation byte then EOF) must surface as
    /// `unexpectedEOF`.
    @Test func testUnexpectedEOF() {
        let stream = InputStream(data: Data([0x81, 0x81]))
        stream.open()
        defer { stream.close() }

        #expect(throws: VarIntError.unexpectedEOF) {
            _ = try readUVarInt(stream)
        }
    }

    // MARK: TestUvarintSizeEdgeCases

    /// Counterpart of Go's `TestUvarintSizeEdgeCases`. Cross-checks the
    /// optimised `encodedSize(of:)` against the reference implementation and
    /// against the actual encoded length for a curated list of edge cases.
    @Test func testUvarintSizeEdgeCases() {
        struct Case {
            let name: String
            let value: UInt64
            let expected: Int
        }

        let cases: [Case] = [
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

        for tc in cases {
            let original = uvarintSizeReference(tc.value)
            #expect(
                original == tc.expected,
                "Reference implementation wrong for \(tc.name) (\(tc.value)): got \(original), expected \(tc.expected)"
            )

            let actualSize = encodedSize(of: tc.value)
            #expect(
                actualSize == tc.expected,
                "Optimised implementation wrong for \(tc.name) (\(tc.value)): got \(actualSize), expected \(tc.expected)"
            )

            #expect(
                original == actualSize,
                "Implementations differ for \(tc.name) (\(tc.value)): original=\(original), actualSize=\(actualSize)"
            )

            // Verify against the actual encoded length.
            let encoded = putUVarInt(tc.value)
            #expect(
                encoded.count == tc.expected,
                "Actual encoding length differs for \(tc.name) (\(tc.value)): got \(encoded.count), expected \(tc.expected)"
            )

            #expect(
                actualSize == encoded.count,
                "encodedSize doesn't match actual encoding for \(tc.name) (\(tc.value)): encodedSize=\(actualSize), actual=\(encoded.count)"
            )
        }
    }

    // MARK: TestUvarintSizeExhaustive

    /// Counterpart of Go's `TestUvarintSizeExhaustive`. Walks the first million
    /// values and verifies the reference and optimised sizes agree with the
    /// actually encoded length.
    @Test func testUvarintSizeExhaustive() {
        for i in UInt64(0)..<1_000_000 {
            let original = uvarintSizeReference(i)
            let actualSize = encodedSize(of: i)

            #expect(
                original == actualSize,
                "Mismatch at \(i): original=\(original), actualSize=\(actualSize)"
            )

            let encoded = putUVarInt(i)
            #expect(
                actualSize == encoded.count,
                "encodedSize doesn't match actual encoding at \(i): encodedSize=\(actualSize), actual=\(encoded.count)"
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
            let actualSize = encodedSize(of: v)

            #expect(
                original == actualSize,
                "Mismatch for \(v): original=\(original), actualSize=\(actualSize)"
            )

            let encoded = putUVarInt(v)
            #expect(
                actualSize == encoded.count,
                "encodedSize doesn't match actual encoding for \(v): encodedSize=\(actualSize), actual=\(encoded.count)"
            )
        }
    }

    // MARK: Benchmarks
    //
    // The Go suite includes benchmark functions (`BenchmarkReadUvarint`,
    // `BenchmarkFromUvarint`, `BenchmarkUvarintSizeOriginal`,
    // `BenchmarkUvarintSizeCurrent`). Swift Testing does not provide a built-in
    // benchmarking harness analogous to Go's `testing.B`. Performance work
    // belongs in a dedicated XCTest performance harness (e.g. `measure { ... }`)
    // or a tool like swift-benchmark; intentionally not ported here.
}
