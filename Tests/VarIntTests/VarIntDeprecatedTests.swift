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

import Foundation
import Testing

@testable import VarInt

/// Pins the pre-1.0 compatibility shims to the behaviour they had before the
/// API revamp, so downstream packages can be migrated one at a time without
/// their existing call sites changing meaning underneath them.
///
/// Exercising the shims warns, by design — that is what tells the downstream
/// packages they have migration work to do. The warnings in this file are
/// expected and will disappear along with the shims.
@Suite("Deprecated API")
struct VarIntDeprecatedTests {

    @Test func encodingMatchesTheNewAPI() {
        for value: UInt64 in [0, 1, 127, 128, 255, 300, 16383, 16384, 1 << 63, .max] {
            #expect(putUVarInt(value) == value.varIntBytes.bytes)
        }

        // `putVarInt(_:)` was zig-zag, and stays zig-zag.
        #expect(putVarInt(0) == [0x00])
        #expect(putVarInt(-1) == [0x01])
        #expect(putVarInt(1) == [0x02])
        #expect(putVarInt(-2) == [0x03])
        #expect(putVarInt(2) == [0x04])
        for value: Int64 in [.min, -1_000_000, -1, 0, 1, 1_000_000, .max] {
            #expect(putVarInt(value) == value.varIntBytes(.zigZag).bytes)
        }
    }

    @Test func decodingKeepsTheSentinelContract() {
        // Success: a positive byte count.
        let (value, bytesRead) = uVarInt(putUVarInt(300))
        #expect(value == 300)
        #expect(bytesRead == 2)

        // Buffer too small: (0, 0).
        #expect(uVarInt([0x81, 0x81]) == (0, 0))
        #expect(uVarInt([]) == (0, 0))

        // Non-minimal: also (0, 0) — the conflation this API could not avoid.
        #expect(uVarInt([0x81, 0x00]) == (0, 0))

        // Overflow: a negative byte count.
        let (overflowValue, overflowBytes) = uVarInt(Array(repeating: 0xFF, count: 12))
        #expect(overflowValue == 0)
        #expect(overflowBytes < 0)
    }

    @Test func signedDecodingRoundTripsThroughTheShims() {
        for value: Int64 in [.min, -1_000_000, -65, -1, 0, 1, 65, 1_000_000, .max] {
            let encoded = putVarInt(value)
            let (decoded, bytesRead) = varInt(encoded)
            #expect(decoded == value, "round-trip mismatch for \(value)")
            #expect(bytesRead == encoded.count, "bytesRead mismatch for \(value)")
        }
    }

    @Test func sizingMatchesTheOriginalConventions() {
        for value: UInt64 in [0, 1, 127, 128, 16383, 16384, 1 << 63, .max] {
            #expect(encodedSize(of: value) == putUVarInt(value).count)
        }

        for value: UInt32 in [0, 1, 127, 128, 16383, .max] {
            #expect(encodedSize(of: value) == putUVarInt(UInt64(value)).count)
        }

        // `encodedSize(of:)` measured the *two's complement* encoding, so it
        // reports 10 for every negative — which never matched `putVarInt(_:)`'s
        // zig-zag output. Preserved here deliberately; the replacement,
        // `varIntSize(_:)`, requires you to name the convention.
        #expect(encodedSize(of: Int64(-1)) == 10)
        #expect(putVarInt(-1).count == 1)

        #expect(encodedSize(of: Int64(0)) == 1)
        #expect(encodedSize(of: Int64(127)) == 1)
        #expect(encodedSize(of: Int64(128)) == 2)
        #expect(encodedSize(of: Int32(-1)) == 10)
        #expect(encodedSize(of: Int32(300)) == 2)
        #expect(encodedSize(of: Int32.max) == 5)
    }

    @Test func varIntDataMatchesTheNewAPI() {
        for value: UInt64 in [0, 1, 127, 128, 300, 16384, .max] {
            #expect(value.varIntData() == Data(value.varIntBytes))
        }
    }

    @Test func binaryChunkHelperStillFormatsBytes() {
        #expect(putUVarInt(1).asBinaryChunks() == "00000001")
        #expect(putUVarInt(127).asBinaryChunks() == "01111111")
        #expect(putUVarInt(128).asBinaryChunks() == "10000000 00000001")
        #expect(putUVarInt(16384).asBinaryChunks() == "10000000 10000000 00000001")

        // The replacement produces the same text without an intermediate array.
        #expect(UInt64(16384).varIntBytes.binaryDescription == putUVarInt(16384).asBinaryChunks())
    }

    /// The original README's worked example, unchanged.
    @Test func lengthPrefixWorkedExample() {
        let bytes = [UInt8]("Hello World".utf8)
        let framed = putUVarInt(UInt64(bytes.count)) + bytes

        let lengthPrefix = uVarInt(framed)
        #expect(lengthPrefix.value == 11)
        #expect(lengthPrefix.bytesRead == 1)
        #expect([UInt8](framed.dropFirst(lengthPrefix.bytesRead)) == bytes)

        // The replacement is a single expression in each direction.
        #expect(bytes.uVarIntLengthPrefixed == framed)
    }
}
