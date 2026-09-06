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

@Suite("VarIntBytes")
struct VarIntBytesTests {

    @Test func encodesKnownValues() {
        /// ```
        /// 1     => 00000001
        /// 127   => 01111111
        /// 128   => 10000000 00000001
        /// 255   => 11111111 00000001
        /// 256   => 10000000 00000010
        /// 300   => 10101100 00000010
        /// 16383 => 11111111 01111111
        /// 16384 => 10000000 10000000 00000001
        /// ```
        #expect(Array(UInt64(1).varIntBytes) == [1])
        #expect(Array(UInt64(127).varIntBytes) == [127])
        #expect(Array(UInt64(128).varIntBytes) == [128, 1])
        #expect(Array(UInt64(255).varIntBytes) == [255, 1])
        #expect(Array(UInt64(256).varIntBytes) == [128, 2])
        #expect(Array(UInt64(300).varIntBytes) == [172, 2])
        #expect(Array(UInt64(16383).varIntBytes) == [255, 127])
        #expect(Array(UInt64(16384).varIntBytes) == [128, 128, 1])

        #expect(UInt64(1).varIntBytes.binaryDescription == "00000001")
        #expect(UInt64(127).varIntBytes.binaryDescription == "01111111")
        #expect(UInt64(128).varIntBytes.binaryDescription == "10000000 00000001")
        #expect(UInt64(255).varIntBytes.binaryDescription == "11111111 00000001")
        #expect(UInt64(256).varIntBytes.binaryDescription == "10000000 00000010")
        #expect(UInt64(300).varIntBytes.binaryDescription == "10101100 00000010")
        #expect(UInt64(16383).varIntBytes.binaryDescription == "11111111 01111111")
        #expect(UInt64(16384).varIntBytes.binaryDescription == "10000000 10000000 00000001")
    }

    /// The whole point of the inline storage is that it behaves like any other
    /// collection of bytes, including at the eight byte boundary where the
    /// representation switches from the low word to the high one.
    @Test func behavesAsACollectionAtEveryWidth() {
        for shift in 0..<64 {
            let value = UInt64(1) << shift
            let encoded = value.varIntBytes

            #expect(encoded.count == value.varIntSize)
            #expect(encoded.count == encoded.bytes.count)
            #expect(Array(encoded) == encoded.bytes)
            #expect(encoded.map { $0 } == encoded.bytes)
            #expect(encoded.indices.map { encoded[$0] } == encoded.bytes)
            #expect(Array(encoded.reversed()) == encoded.bytes.reversed())
        }

        #expect(UInt64.max.varIntBytes.count == 10)
        #expect(UInt64.max.varIntBytes.bytes == [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    }

    /// `withUnsafeBytes` has to produce the same bytes, in the same order, as the
    /// collection conformance, a layout or endianness mistake would show up here.
    @Test func unsafeBytesMatchesCollectionOrder() {
        let values: [UInt64] = [0, 1, 127, 128, 16383, 16384, 1 << 55, 1 << 56, 1 << 63, .max]
        for value in values {
            let encoded = value.varIntBytes
            let viaPointer = encoded.withUnsafeBytes { Array($0) }
            #expect(viaPointer == Array(encoded), "pointer/collection mismatch for \(value)")
            #expect(viaPointer.count == encoded.count)
        }
    }

    @Test func sizeMatchesEncodedLength() {
        // Every byte-width boundary, from both sides.
        for width in 1...10 {
            let low = width == 1 ? UInt64(0) : UInt64(1) << (7 * (width - 1))
            #expect(low.varIntSize == width)
            #expect(low.varIntBytes.count == width)

            if width < 10 {
                let high = (UInt64(1) << (7 * width)) - 1
                #expect(high.varIntSize == width)
                #expect(high.varIntBytes.count == width)
            }
        }

        #expect(UInt64.max.varIntSize == 10)
        #expect(VarInt.maximumEncodedSize == 10)
    }

    @Test func encodingIsAvailableOnTheUsualIntegerTypes() {
        #expect(UInt32(300).varIntBytes.bytes == [172, 2])
        #expect(UInt32(300).varIntSize == 2)
        #expect(UInt32.max.varIntSize == 5)
        #expect(UInt(300).varIntBytes.bytes == [172, 2])
        #expect(Int(300).varIntBytes.bytes == [172, 2])
        #expect(Int(300).varIntSize == 2)
    }

    @Test func encodedSizeForValuesUpToALimit() {
        #expect(VarInt.encodedSize(forValuesUpTo: 127) == 1)
        #expect(VarInt.encodedSize(forValuesUpTo: 128) == 2)
        #expect(VarInt.encodedSize(forValuesUpTo: 1024) == 2)
        #expect(VarInt.encodedSize(forValuesUpTo: 16383) == 2)
        #expect(VarInt.encodedSize(forValuesUpTo: 16384) == 3)
        #expect(VarInt.encodedSize(forValuesUpTo: 1 << 20) == 3)
        #expect(VarInt.encodedSize(forValuesUpTo: .max) == 10)
    }

    @Test func descriptionIsReadableHex() {
        #expect(UInt64(1).varIntBytes.description == "[0x01]")
        #expect(UInt64(300).varIntBytes.description == "[0xac 0x02]")
    }
}

@Suite("VarInt.decode")
struct VarIntDecodeTests {

    @Test func roundTripsThroughEveryWidth() throws {
        for shift in 0..<64 {
            for value in [UInt64(1) << shift, (UInt64(1) << shift) &- 1, (UInt64(1) << shift) &+ 1] {
                let encoded = value.varIntBytes.bytes
                let (decoded, end) = try VarInt.decode(encoded)
                #expect(decoded == value, "round-trip mismatch for \(value)")
                #expect(end == encoded.count)
            }
        }
        #expect(try VarInt.decode(UInt64.max.varIntBytes.bytes).value == UInt64.max)
    }

    @Test func reportsWhereTheVarintEnded() throws {
        let buffer = UInt64(300).varIntBytes.bytes + UInt64(16384).varIntBytes.bytes + [0xAA, 0xBB]

        let (first, afterFirst) = try VarInt.decode(buffer)
        #expect(first == 300)

        let (second, afterSecond) = try VarInt.decode(buffer[afterFirst...])
        #expect(second == 16384)

        #expect(Array(buffer[afterSecond...]) == [0xAA, 0xBB])
    }

    /// Any collection of bytes, with no need for an explicit Array at the call site
    @Test func acceptsAnyByteCollection() throws {
        let encoded = UInt64(16384).varIntBytes.bytes

        #expect(try VarInt.decode(encoded).value == 16384)
        #expect(try VarInt.decode(Data(encoded)).value == 16384)
        #expect(try VarInt.decode(encoded[...]).value == 16384)
        #expect(try VarInt.decode(ContiguousArray(encoded)).value == 16384)

        // A VarInt sitting part way into a larger buffer, decoded from a slice.
        let padded = [0x00, 0x00] + encoded
        #expect(try VarInt.decode(padded.dropFirst(2)).value == 16384)
    }

    @Test func shortInputIsDistinguishableFromMalformedInput() {
        // Ended mid-VarInt, more bytes may result in a valid VarInt.
        #expect(throws: VarIntError.needsMoreBytes) { try VarInt.decode([0x81, 0x81] as [UInt8]) }
        #expect(throws: VarIntError.needsMoreBytes) { try VarInt.decode([] as [UInt8]) }

        // Non-minimal and overflowing, more bytes will never result in a valid VarInt.
        #expect(throws: VarIntError.notMinimal) { try VarInt.decode([0x81, 0x00] as [UInt8]) }
        #expect(throws: VarIntError.overflow) {
            try VarInt.decode([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x02] as [UInt8])
        }
    }

    @Test func minimalityCanBeOverridden() throws {
        let nonMinimal: [UInt8] = [0x81, 0x00]

        #expect(throws: VarIntError.notMinimal) { try VarInt.decode(nonMinimal) }

        let (value, end) = try VarInt.decode(nonMinimal, requireMinimal: false)
        #expect(value == 1)
        #expect(end == 2)

        // A padded zero is the regular case, and should decode when allowed.
        #expect(try VarInt.decode([0x80, 0x00] as [UInt8], requireMinimal: false).value == 0)
    }

    /// A limit is enforced from the accumulated bytes, so a partial VarInt that can only
    /// resolve into a value larger than our limit throws early.
    @Test func limitIsEnforcedEarly() throws {
        let limit: UInt64 = 16383

        #expect(try VarInt.decode(UInt64(16383).varIntBytes.bytes, limit: limit).value == 16383)

        #expect(throws: VarIntError.exceedsLimit(limit: limit)) {
            try VarInt.decode(UInt64(16384).varIntBytes.bytes, limit: limit)
        }
        #expect(throws: VarIntError.exceedsLimit(limit: limit)) {
            try VarInt.decode(UInt64.max.varIntBytes.bytes, limit: limit)
        }

        // A stream of continuation bytes is rejected after 3 bytes rather than 10
        var decoder = VarIntDecoder(limit: limit)
        #expect(try decoder.push(0xFF) == nil)
        #expect(try decoder.push(0xFF) == nil)
        #expect(throws: VarIntError.exceedsLimit(limit: limit)) { try decoder.push(0xFF) }
        #expect(decoder.bytesConsumed == 3)
    }

    @Test func exactParseRejectsTrailingBytes() throws {
        #expect(try UInt64(varInt: UInt64(300).varIntBytes.bytes) == 300)
        #expect(try UInt64(varInt: [0x00] as [UInt8]) == 0)

        #expect(throws: VarIntError.trailingBytes) {
            try UInt64(varInt: UInt64(300).varIntBytes.bytes + [0xAA])
        }
        #expect(throws: VarIntError.needsMoreBytes) { try UInt64(varInt: [0x81] as [UInt8]) }
    }
}

@Suite("VarInt.SignedEncoding")
struct VarIntSignedEncodingTests {

    @Test func zigZagInterleavesTheSigns() {
        // 0 → 0, -1 → 1, 1 → 2, -2 → 3, 2 → 4, …
        #expect(Int64(0).varIntBytes(.zigZag).bytes == [0x00])
        #expect(Int64(-1).varIntBytes(.zigZag).bytes == [0x01])
        #expect(Int64(1).varIntBytes(.zigZag).bytes == [0x02])
        #expect(Int64(-2).varIntBytes(.zigZag).bytes == [0x03])
        #expect(Int64(2).varIntBytes(.zigZag).bytes == [0x04])

        // Zig-zag is the default.
        #expect(Int64(-1).varIntBytes().bytes == [0x01])
    }

    /// Regression coverage for the original `putVarInt(_:)`, which trapped on
    /// every negative `Int64` and could not round-trip through its own decoder.
    @Test func roundTripsAcrossTheWholeRangeUnderBothConventions() throws {
        let values: [Int64] = [
            .min, -(1 << 62), -1_000_000, -65, -64, -1, 0, 1, 64, 65, 1_000_000, 1 << 62, .max,
        ]

        for encoding in VarInt.SignedEncoding.allCases {
            for value in values {
                let encoded = value.varIntBytes(encoding)
                #expect(encoded.count == value.varIntSize(encoding), "size mismatch for \(value) under \(encoding)")

                let (decoded, end) = try VarInt.decodeSigned(encoded.bytes, as: encoding)
                #expect(decoded == value, "round-trip mismatch for \(value) under \(encoding)")
                #expect(end == encoded.count)

                #expect(try Int64(varInt: encoded.bytes, encoding: encoding) == value)
            }
        }
    }

    /// The two conventions disagree about negatives, and `varIntSize(_:)` now
    /// reports the size of whichever one you asked for.
    @Test func theTwoConventionsDifferForNegatives() {
        #expect(Int64(-1).varIntBytes(.zigZag).bytes == [0x01])
        #expect(Int64(-1).varIntSize(.zigZag) == 1)

        #expect(Int64(-1).varIntBytes(.twosComplement).count == 10)
        #expect(Int64(-1).varIntSize(.twosComplement) == 10)

        // Non-negative values (for .twosComplement) are encoded identically.
        for value: Int64 in [0, 1, 127, 128, 1 << 40, .max] {
            #expect(value.varIntBytes(.twosComplement).bytes == UInt64(value).varIntBytes.bytes)
        }
    }

    @Test func mappingsAreMutualInverses() {
        for encoding in VarInt.SignedEncoding.allCases {
            for value: Int64 in [.min, -1, 0, 1, .max] {
                let val = encoding.unsignedRepresentation(of: value)
                #expect(encoding.signedValue(from: val) == value)
            }
        }
        #expect(VarInt.SignedEncoding.zigZag.unsignedRepresentation(of: Int64.min) == UInt64.max)
        #expect(VarInt.SignedEncoding.zigZag.signedValue(from: UInt64.max) == Int64.min)
    }
    
    /// A bound is checked against the decoded signed value, not against the
    /// encoded bits, so both ends of a range are enforced under both conventions.
    @Test(arguments: [
        (0 as Int64)...1,
        -1...1,
        0...16383,
        -16384...16383,
        .min ... .max,
    ])
    func boundsAreEnforcedInTheSignedDomain(_ allowed: ClosedRange<Int64>) throws {
        for encoding in VarInt.SignedEncoding.allCases {
            // Both ends of the range are acceptable, however they encode.
            for value in [allowed.lowerBound, allowed.upperBound] {
                let encoded = value.varIntBytes(encoding).bytes
                #expect(try VarInt.decodeSigned(encoded, as: encoding, in: allowed).value == value)
            }

            // And everything just outside it is not.
            for value in [allowed.lowerBound, allowed.upperBound] {
                guard value != .min, value != .max else { continue }
                let outside: Int64 = value == allowed.lowerBound ? value - 1 : value + 1
                #expect(throws: VarIntError.outOfRange(allowed: allowed)) {
                    try VarInt.decodeSigned(outside.varIntBytes(encoding).bytes, as: encoding, in: allowed)
                }
            }
        }
    }

    /// A range is turned into a ceiling that the decoder can enforce, so a
    /// partial VarInt that can only resolve out of range throws before its final byte.
    ///
    /// Only a range that excludes the negatives can be bounded early under
    /// `.twosComplement`, because every negative value uses 10 bytes.
    @Test(arguments: [
        // range, zig-zag ceiling and the byte it is rejected on, then the same for two's complement
        ((0 as Int64)...1, UInt64(2), 1, UInt64(1), 1),
        (0...126, 252, 2, 126, 1),
        (0...127, 254, 2, 127, 2),
        (0...16383, 32766, 3, 16383, 3),
        (-16384...16383, 32767, 3, UInt64.max, 10),
        (.min ... .max, UInt64.max, 10, UInt64.max, 10),
    ])
    func rangesAreTurnedIntoEnforceableCeilings(
        _ testCase: (ClosedRange<Int64>, UInt64, Int, UInt64, Int)
    ) throws {
        let (allowed, zigZagCeiling, zigZagBytes, twosCeiling, twosBytes) = testCase

        for encoding in VarInt.SignedEncoding.allCases {
            let expectedCeiling = encoding == .zigZag ? zigZagCeiling : twosCeiling
            let expectedBytes = encoding == .zigZag ? zigZagBytes : twosBytes

            #expect(encoding.encodedCeiling(for: allowed) == expectedCeiling)

            // No value inside the range may encode above the ceiling, otherwise
            // the ceiling would reject a value the caller asked to accept.
            for value in [allowed.lowerBound, allowed.upperBound] {
                #expect(encoding.unsignedRepresentation(of: value) <= expectedCeiling)
            }

            // A stream of continuation bytes is rejected as soon as possible. The
            // ten byte cases run out of width rather than exceeding the ceiling.
            //
            // 0xFF always carries a continuation bit, so `push` never returns a
            // value here, it either asks for another byte or throws.
            var decoder = VarIntDecoder(limit: expectedCeiling)
            for _ in 0..<VarInt.maximumEncodedSize {
                do { _ = try decoder.push(0xFF) } catch { break }
            }
            #expect(decoder.bytesConsumed == expectedBytes)
        }
    }

    @Test func anUnboundedRangeAcceptsEveryNegative() throws {
        for encoding in VarInt.SignedEncoding.allCases {
            for value: Int64 in [.min, -(1 << 62), -1_000_000, -1] {
                let encoded = value.varIntBytes(encoding).bytes
                #expect(try VarInt.decodeSigned(encoded, as: encoding).value == value)
            }
        }
    }

    @Test func int32ConveniencesAgreeWithInt64() {
        for value: Int32 in [.min, -1, 0, 1, .max] {
            #expect(value.varIntBytes().bytes == Int64(value).varIntBytes().bytes)
            #expect(value.varIntSize() == Int64(value).varIntSize())
        }
    }
}

@Suite("VarIntDecoder")
struct VarIntDecoderTests {

    /// A byte source that only yields one byte at a time, split at an arbitrary boundary,
    /// decodes without the caller buffering or re-parsing.
    @Test func resumesAcrossASplitInput() throws {
        let encoded = UInt64(1 << 45).varIntBytes.bytes

        for splitPoint in 0...encoded.count {
            var decoder = VarIntDecoder()
            var result: UInt64?

            // Only the last byte of the encoding terminates the VarInt, so every
            // earlier push must ask for more.
            for (offset, byte) in encoded[..<splitPoint].enumerated() {
                result = try decoder.push(byte)
                #expect(
                    (result == nil) == (offset < encoded.count - 1),
                    "wrong termination point at split \(splitPoint), offset \(offset)"
                )
            }
            #expect(decoder.bytesConsumed == splitPoint)

            for byte in encoded[splitPoint...] where result == nil {
                result = try decoder.push(byte)
            }

            #expect(result == 1 << 45, "failed to resume at split \(splitPoint)")
            #expect(decoder.bytesConsumed == encoded.count)
        }
    }

    @Test func isAtStartDistinguishesCleanEndOfInput() throws {
        var fresh = VarIntDecoder()
        #expect(fresh.isAtStart)
        #expect(fresh.bytesConsumed == 0)

        #expect(try fresh.push(0x81) == nil)
        #expect(!fresh.isAtStart)
        #expect(fresh.bytesConsumed == 1)

        fresh.reset()
        #expect(fresh.isAtStart)
        #expect(fresh.bytesConsumed == 0)

        // Reset keeps the configuration, and the decoder is reusable.
        var configured = VarIntDecoder(limit: 100, requireMinimal: false)
        _ = try? configured.push(0xFF)
        configured.reset()
        #expect(configured.limit == 100)
        #expect(configured.requireMinimal == false)
        #expect(try configured.push(0x01) == 1)
    }

    @Test func rejectsTenByteOverflow() throws {
        // Nine continuation bytes plus a terminator carrying two bits: the 65th
        // bit has nowhere to go.
        var terminatorTooLarge = VarIntDecoder()
        for _ in 0..<9 { #expect(try terminatorTooLarge.push(0xFF) == nil) }
        #expect(throws: VarIntError.overflow) { try terminatorTooLarge.push(0x02) }

        // A tenth continuation byte would require an eleventh.
        var continuesTooFar = VarIntDecoder()
        for _ in 0..<9 { #expect(try continuesTooFar.push(0xFF) == nil) }
        #expect(throws: VarIntError.overflow) { try continuesTooFar.push(0x80) }

        // The largest legal VarInt is exactly ten bytes.
        var maximal = VarIntDecoder()
        for _ in 0..<9 { #expect(try maximal.push(0xFF) == nil) }
        #expect(try maximal.push(0x01) == UInt64.max)
    }
}

@Suite("VarInt.decode(readingFrom:)")
struct VarIntDecodeReadingTests {

    @Test func decodesFromAByteSource() throws {
        var iterator = UInt64(300).varIntBytes.bytes.makeIterator()
        #expect(try VarInt.decode(readingFrom: { iterator.next() }) == 300)
    }

    /// A reader of back-to-back VarInts needs to stop cleanly at the end of the
    /// stream but fail on a truncated one.
    @Test func distinguishesCleanEndOfStreamFromTruncation() throws {
        var empty = [UInt8]().makeIterator()
        #expect(try VarInt.decode(readingFrom: { empty.next() }) == nil)

        var truncated = ([0x81, 0x81] as [UInt8]).makeIterator()
        #expect(throws: VarIntError.needsMoreBytes) {
            try VarInt.decode(readingFrom: { truncated.next() })
        }
    }

    @Test func readsBackToBackVarIntsUntilTheStreamEnds() throws {
        let expected: [UInt64] = [1, 300, 16384, UInt64.max, 0]
        var iterator = expected.flatMap { $0.varIntBytes }.makeIterator()

        var decoded: [UInt64] = []
        while let value = try VarInt.decode(readingFrom: { iterator.next() }) {
            decoded.append(value)
        }

        #expect(decoded == expected)
    }
    
    @Test func readsBackToBackSignedVarIntsUntilTheStreamEnds() throws {
        let expected: [Int64] = [1, 300, 16384, Int64.max, 0]
        
        for encoding in VarInt.SignedEncoding.allCases {
            var iterator = expected.flatMap { $0.varIntBytes(encoding) }.makeIterator()

            var decoded: [Int64] = []
            while let value = try VarInt.decode(readingFrom: { iterator.next() }) {
                decoded.append(encoding.signedValue(from: value))
            }

            #expect(decoded == expected)
        }
    }

    @Test func propagatesErrorsFromTheSource() {
        struct SourceFailure: Error {}
        #expect(throws: SourceFailure.self) {
            try VarInt.decode(readingFrom: { throw SourceFailure() })
        }
    }
}

/// - Note: `VarIntReader` is `~Copyable`, and swift-testing's `#expect` macro
///   cannot take a noncopyable value in its expression. Every assertion here therefore
///   binds the reader's state to a local var first.
@Suite("VarIntReader")
struct VarIntReaderTests {

    /// The multihash shape: a code, a digest length, then the digest
    @Test func readsBackToBackFields() throws {
        let digest: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let buffer = UInt64(0x12).varIntBytes.bytes + digest.uVarIntLengthPrefixed + [0xFF]

        var reader = VarIntReader(buffer)
        let consumedAtStart = reader.bytesConsumed
        #expect(consumedAtStart == 0)

        let code = try reader.readUVarInt()
        #expect(code == 0x12)

        let body = Array(try reader.readUVarIntLengthPrefixed())
        #expect(body == digest)

        let remaining = Array(reader.remaining)
        let consumed = reader.bytesConsumed
        let isEmpty = reader.isEmpty
        #expect(remaining == [0xFF])
        #expect(consumed == buffer.count - 1)
        #expect(!isEmpty)
    }

    @Test func readsAnEmptyLengthPrefixedBody() throws {
        var reader = VarIntReader([UInt8]().uVarIntLengthPrefixed)
        let body = Array(try reader.readUVarIntLengthPrefixed())
        let isEmpty = reader.isEmpty
        #expect(body.isEmpty)
        #expect(isEmpty)
    }

    @Test func readsSignedFields() throws {
        let digest: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let buffer = Int64(-5).varIntBytes(.zigZag).bytes
                     + Int64(-5).varIntBytes(.twosComplement).bytes
                     + digest.varIntLengthPrefixed(.zigZag)
                     + digest.varIntLengthPrefixed(.twosComplement)
                     + [0xFF]

        var reader = VarIntReader(buffer)
        let zigZag = try reader.readVarInt() // default is zigzag
        let twos = try reader.readVarInt(.twosComplement)
        let bodyZigZag = Array(try reader.readVarIntLengthPrefixed()) //default is zigzag
        let bodyTwos = Array(try reader.readVarIntLengthPrefixed(.twosComplement))
        let remaining = Array(reader.remaining)
        let isEmpty = reader.isEmpty
        #expect(zigZag == -5)
        #expect(twos == -5)
        #expect(bodyZigZag == digest)
        #expect(bodyTwos == digest)
        #expect(!isEmpty)
        #expect(remaining == [0xFF])
    }

    @Test func rejectsANegativeLengthPrefix() throws {
        for encoding in VarInt.SignedEncoding.allCases {
            let negativeLength = Int64(-1).varIntBytes(encoding).bytes + [0xDE, 0xAD]

            var reader = VarIntReader(negativeLength)
            do {
                _ = try reader.readVarIntLengthPrefixed(encoding)
                Issue.record("expected the negative length to be rejected under \(encoding)")
            } catch {
                #expect(error == VarIntError.outOfRange(allowed: 0...Int64.max))
            }
            
            let consumed = reader.bytesConsumed
            #expect(consumed == 0)
        }
    }
    
    @Test func rejectsANegativeLengthPrefixEvenWithANegativeLimit() throws {
        for encoding in VarInt.SignedEncoding.allCases {
            let negativeLength = Int64(-1).varIntBytes(encoding).bytes + [0xDE, 0xAD]

            var reader = VarIntReader(negativeLength)
            do {
                _ = try reader.readVarIntLengthPrefixed(encoding, limit: -10)
                Issue.record("expected the negative length to be rejected under \(encoding)")
            } catch {
                #expect(error == VarIntError.outOfRange(allowed: 0...0))
            }
            
            let consumed = reader.bytesConsumed
            #expect(consumed == 0)
        }
    }

    @Test func enforcesASignedLengthPrefixLimit() throws {
        for encoding in VarInt.SignedEncoding.allCases {
            let oversized = [UInt8](repeating: 0xAA, count: 64).varIntLengthPrefixed(encoding)

            var reader = VarIntReader(oversized)
            do {
                _ = try reader.readVarIntLengthPrefixed(encoding, limit: 16)
                Issue.record("expected the oversized body to be rejected under \(encoding)")
            } catch {
                #expect(error == VarIntError.outOfRange(allowed: 0...16))
            }
            let consumed = reader.bytesConsumed
            #expect(consumed == 0)
        }
    }

    /// A failed read shouldn't more the cursor, so a caller that catches
    /// `needsMoreBytes` can retry the identical read once more bytes arrive.
    @Test func aFailedReadLeavesTheCursorUntouched() throws {
        // The length prefix decodes but the body is short.
        let truncated = UInt64(0x12).varIntBytes.bytes + [0x04, 0xDE, 0xAD]

        var reader = VarIntReader(truncated)
        let code = try reader.readUVarInt()
        #expect(code == 0x12)
        let positionBefore = reader.bytesConsumed

        do {
            _ = try reader.readUVarIntLengthPrefixed()
            Issue.record("expected the short body to be reported")
        } catch {
            #expect(error == VarIntError.needsMoreBytes)
        }
        let positionAfter = reader.bytesConsumed
        #expect(positionAfter == positionBefore, "a throwing read consumed bytes")

        // A malformed VarInt likewise leaves the cursor where it was.
        var malformed = VarIntReader([0x81, 0x00] as [UInt8])
        do {
            _ = try malformed.readUVarInt()
            Issue.record("expected the non-minimal varInt to be rejected")
        } catch {
            #expect(error == VarIntError.notMinimal)
        }
        let malformedPosition = malformed.bytesConsumed
        #expect(malformedPosition == 0)
    }

    @Test func enforcesALengthPrefixLimit() throws {
        let oversized = [UInt8](repeating: 0xAA, count: 64).uVarIntLengthPrefixed

        var reader = VarIntReader(oversized)
        do {
            _ = try reader.readUVarIntLengthPrefixed(limit: 16)
            Issue.record("expected the oversized body to be rejected")
        } catch {
            #expect(error == VarIntError.exceedsLimit(limit: 16))
        }
        let consumed = reader.bytesConsumed
        #expect(consumed == 0)
    }

    @Test func readsFromASliceAndFromData() throws {
        let buffer = UInt64(300).varIntBytes.bytes + [0x01, 0x02]

        var fromSlice = VarIntReader(buffer[...])
        let sliceValue = try fromSlice.readUVarInt()
        let sliceRemaining = Array(fromSlice.remaining)
        #expect(sliceValue == 300)
        #expect(sliceRemaining == [0x01, 0x02])

        var fromData = VarIntReader(Data(buffer))
        let dataValue = try fromData.readUVarInt()
        let dataRemaining = Array(fromData.remaining)
        #expect(dataValue == 300)
        #expect(dataRemaining == [0x01, 0x02])
    }
}

@Suite("uVarIntLengthPrefixed")
struct VarIntLengthPrefixedTests {

    @Test func prefixesBytesWithTheirCount() throws {
        let bytes = Array("Hello World".utf8)
        let framed = bytes.uVarIntLengthPrefixed

        #expect(framed.count == bytes.count + 1)  // 11 fits in a single byte
        #expect(framed.first == 11)

        var reader = VarIntReader(framed)
        let body = Array(try reader.readUVarIntLengthPrefixed())
        let isEmpty = reader.isEmpty
        #expect(body == bytes)
        #expect(isEmpty)
    }

    @Test func worksOnAnyByteCollection() throws {
        let expected: [UInt8] = [11] + Array("Hello World".utf8)

        #expect("Hello World".utf8.uVarIntLengthPrefixed == expected)
        #expect(Array("Hello World".utf8).uVarIntLengthPrefixed == expected)
        #expect(Data("Hello World".utf8).uVarIntLengthPrefixed == expected)
        #expect(Array("xxHello World".utf8).dropFirst(2).uVarIntLengthPrefixed == expected)
    }

    @Test func handlesEmptyAndMultiBytePrefixes() throws {
        #expect([UInt8]().uVarIntLengthPrefixed == [0x00])

        let large = [UInt8](repeating: 0x5A, count: 300)
        let framed = large.uVarIntLengthPrefixed
        #expect(Array(framed.prefix(2)) == UInt64(300).varIntBytes.bytes)
        #expect(framed.count == 302)

        var reader = VarIntReader(framed)
        let body = Array(try reader.readUVarIntLengthPrefixed())
        #expect(body == large)
    }

    /// A round trip of the concatenated-prefixed-fields shape that PeerRecord's
    /// signing payload and the plaintext handshake both build by hand.
    @Test func roundTripsConcatenatedFields() throws {
        let domain = "libp2p-peer-record"
        let codec: [UInt8] = [0x03, 0x01]
        let payload = [UInt8](repeating: 0x42, count: 200)

        let signed = domain.utf8.uVarIntLengthPrefixed + codec.uVarIntLengthPrefixed + payload.uVarIntLengthPrefixed

        var reader = VarIntReader(signed)
        let decodedDomain = String(decoding: Array(try reader.readUVarIntLengthPrefixed()), as: UTF8.self)
        let decodedCodec = Array(try reader.readUVarIntLengthPrefixed())
        let decodedPayload = Array(try reader.readUVarIntLengthPrefixed())
        let isEmpty = reader.isEmpty
        #expect(decodedDomain == domain)
        #expect(decodedCodec == codec)
        #expect(decodedPayload == payload)
        #expect(isEmpty)
    }
}
