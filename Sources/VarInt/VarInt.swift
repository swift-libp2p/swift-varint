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

//  This module provides VarInt encodings of 64-bit integers, following the
//  unsigned-LEB128 form used by Google Protocol Buffers and by the multiformats
//  and libp2p specifications.
//
//  The encoding is:
//  -   Unsigned integers are serialized 7 bits at a time, starting with the
//      least significant bits.
//  -   The most significant bit (msb) in each output byte indicates whether a
//      continuation byte follows.
//  -   Signed integers are mapped onto unsigned integers by one of the two
//      conventions modelled by `VarInt.SignedEncoding`.
//
//  For more details see ipfs/QmXJXJMai4p88HMsp2TPP1EtZxfSZQ1vyRtN5dGKvQ6MCw

public enum VarInt {

    /// The largest number of bytes any 64-bit VarInt can occupy.
    ///
    /// Ten bytes, nine of which carry seven bits each, and the tenth carries the 64th bit.
    public static let maximumEncodedSize: Int = 10

    /// The largest number of bytes a minimally encoded VarInt can occupy for any
    /// value in `0...limit`.
    ///
    /// Use this to size a bounded read window when you know the largest value a
    /// field can/should hold.
    @inlinable
    public static func encodedSize(forValuesUpTo limit: UInt64) -> Int {
        limit.varIntSize
    }
}

// MARK: - Signed conventions

extension VarInt {
    /// The strategy to use when mapping a signed integer onto a VarInt
    ///
    /// The two conventions produce different bytes for the same negative number.
    ///
    /// - WARNING:
    /// There is no mechanism for determining which method was used to encode a value,
    /// therefore the encoding and decoding have to both use the same method in order to
    /// preserve the original value. A limitation that unsigned VarInts don't share.
    public enum SignedEncoding: Hashable, Sendable, CaseIterable {
        
        /// Zig-zag: positive `n` becomes `2n`, negative `n` becomes `2|n| - 1`.
        ///
        /// Interleaves the signs, `0, -1, 1, -2, 2, …` map to `0, 1, 2, 3, 4, …`,
        /// so small magnitudes of either sign stay small on the wire. This is
        /// protobuf's `sint32`/`sint64` and the default here.
        case zigZag
        
        /// Sign-extended two's complement: the value's bit pattern, encoded as if
        /// unsigned.
        ///
        /// Every negative value occupies the full ten bytes. This is protobuf's
        /// `int32`/`int64`.
        case twosComplement
        
        /// Converts the signed `value` into it's unsigned equivalent using the chosen encoding method
        @inlinable
        public func unsignedRepresentation(of value: Int64) -> UInt64 {
            switch self {
            case .zigZag:
                // `<<` and `>>` on a FixedWidthInteger are bit-pattern shifts and do
                // not trap, so this is exact across the whole Int64 range. The
                // arithmetic right shift yields all-ones for negatives and
                // all-zeroes otherwise, which flips the doubled value for negatives.
                UInt64(bitPattern: (value << 1) ^ (value >> 63))
            case .twosComplement:
                UInt64(bitPattern: value)
            }
        }
        
        /// The signed value that `bits` represents under this convention.
        ///
        /// The inverse of `unsignedRepresentation(of:)`.
        @inlinable
        public func signedValue(from bits: UInt64) -> Int64 {
            switch self {
            case .zigZag:
                Int64(bitPattern: bits >> 1) ^ -Int64(bitPattern: bits & 1)
            case .twosComplement:
                Int64(bitPattern: bits)
            }
        }

        /// The largest encoded value any signed value in `range` can produce.
        ///
        /// Use this to turn a signed bound into a ceiling the `VarIntDecoder` can
        /// enforce. Nothing inside `range` should encodes above the result.
        @inlinable
        public func encodedCeiling(for range: ClosedRange<Int64>) -> UInt64 {
            switch self {
            case .zigZag:
                // Zig-zag orders by magnitude, so whichever end sits further
                // from zero produces the largest encoding.
                max(
                    self.unsignedRepresentation(of: range.lowerBound),
                    self.unsignedRepresentation(of: range.upperBound)
                )
            case .twosComplement:
                // Sign extension puts every negative in the top half of the
                // UInt64 range, and the negative closest to zero (-1, all ones)
                // is the largest bit pattern of them all. With no negatives in
                // range the upper bound is the ceiling outright.
                range.lowerBound < 0
                    ? UInt64(bitPattern: min(range.upperBound, -1))
                    : UInt64(range.upperBound)
            }
        }
    }
}

// MARK: - Decoding from a byte collection

extension VarInt {

    /// Decodes the unsigned VarInt at the front of `bytes`.
    ///
    /// Only the leading VarInt is consumed, anything after it is left for the caller.
    ///
    /// ```swift
    /// let (code, afterCode) = try VarInt.decode(buffer)
    /// let (length, afterLength) = try VarInt.decode(buffer[afterCode...])
    /// let digest = buffer[afterLength...]
    /// ```
    ///
    /// - Parameters:
    ///   - bytes: The bytes to decode from.
    ///   - limit: The largest value to accept. `.exceedsLimit` is thrown as soon
    ///     as the accumulated bits exceed it.
    ///   - requireMinimal: Whether to reject non-minimal encodings. Defaults to
    ///     `true`, matching the Multiformats VarInt spec.
    /// - Returns: The decoded value, and the index after the VarInt's last byte.
    /// - Throws: `VarIntError.needsMoreBytes` if `bytes` ends part way through
    ///   the VarInt, or one of the other `VarIntError` cases if it cannot decode no matter
    ///   how many more bytes arrive.
    @inlinable
    public static func decode<Bytes: Collection<UInt8>>(
        _ bytes: Bytes,
        limit: UInt64 = .max,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> (value: UInt64, end: Bytes.Index) {
        var decoder = VarIntDecoder(limit: limit, requireMinimal: requireMinimal)
        var index = bytes.startIndex

        while index != bytes.endIndex {
            let byte = bytes[index]
            index = bytes.index(after: index)
            if let value = try decoder.push(byte) {
                return (value, index)
            }
        }

        throw VarIntError.needsMoreBytes
    }

    /// Decodes the signed VarInt at the front of `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to decode from.
    ///   - encoding: How the signed value was mapped onto the encoded unsigned
    ///     value. Must match whatever the writer used.
    ///   - allowed: The range of values to accept. `.outOfRange` is thrown as
    ///     soon as the accumulated bits provably fall outside it.
    ///   - requireMinimal: Whether to reject non-minimal encodings or not.
    /// - Returns: The decoded value, and the index after the VarInt's last byte.
    @inlinable
    public static func decodeSigned<Bytes: Collection<UInt8>>(
        _ bytes: Bytes,
        as encoding: SignedEncoding = .zigZag,
        in allowed: ClosedRange<Int64> = .min ... .max,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> (value: Int64, end: Bytes.Index) {
        let bits: UInt64
        let end: Bytes.Index
        do {
            (bits, end) = try decode(
                bytes,
                limit: encoding.encodedCeiling(for: allowed),
                requireMinimal: requireMinimal
            )
        } catch VarIntError.exceedsLimit {
            throw VarIntError.outOfRange(allowed: allowed)
        }
        
        // ensure the decoded value falls within the allowed range
        let value = encoding.signedValue(from: bits)
        guard allowed.contains(value) else { throw .outOfRange(allowed: allowed) }
        return (value, end)
    }
}

// MARK: - Decoding from a byte source

extension VarInt {

    /// Decodes a single unsigned VarInt by reading one byte at a time from `nextByte`.
    ///
    /// Use this method when dealing with streaming inputs instead of collections.
    ///
    /// ```swift
    /// var iterator = bytes.makeIterator()
    /// while let value = try VarInt.decode(readingFrom: { iterator.next() }) {
    ///     // …one message per VarInt, terminating cleanly at end of input
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - limit: The largest value to accept.
    ///   - requireMinimal: Whether to reject non-minimal encodings or not.
    ///   - readingFrom: Produces the next byte, or `nil` at end of input.
    /// - Returns: The decoded value, or `nil` if `nextByte` reported end of input
    ///   before anything was read.
    /// - Throws: `VarIntError.needsMoreBytes` if the input ended part way through
    ///   a VarInt, and rethrows whatever `nextByte` may throw.
    @inlinable
    public static func decode(
        limit: UInt64 = .max,
        requireMinimal: Bool = true,
        readingFrom nextByte: () throws -> UInt8?
    ) throws -> UInt64? {
        var decoder = VarIntDecoder(limit: limit, requireMinimal: requireMinimal)

        while let byte = try nextByte() {
            if let value = try decoder.push(byte) {
                return value
            }
        }

        // Nothing was read at all, so this is the end of the stream rather than a
        // truncated VarInt.
        if decoder.isAtStart { return nil }
        throw VarIntError.needsMoreBytes
    }
}

// MARK: - Exact parsing

extension UInt64 {

    /// Decodes exactly one unsigned VarInt from the entire byte collection and nothing else.
    ///
    /// Use this when the entire collection is a single VarInt, any extra bytes will cause this
    /// initializer to throw `VarIntError.trailingBytes`.
    ///
    /// - Note:
    /// For a VarInt at the front of a larger buffer, use `VarInt.decode(_:)`,
    /// which returns the VarInt's value and where the VarInt ended.
    ///
    /// - Throws: `VarIntError.trailingBytes` if any bytes follow the VarInt, plus
    ///   the usual `VarIntError` cases.
    @inlinable
    public init(varInt bytes: some Collection<UInt8>, requireMinimal: Bool = true) throws(VarIntError) {
        let (value, end) = try VarInt.decode(bytes, requireMinimal: requireMinimal)
        guard end == bytes.endIndex else { throw VarIntError.trailingBytes }
        self = value
    }
}

extension Int64 {

    /// Decodes exactly one signed VarInt from the entire byte collection and nothing else.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to decode.
    ///   - encoding: How the signed value was mapped onto the encoded unsigned
    ///     value. Must match whatever the writer used.
    ///   - requireMinimal: Whether to reject non-minimal encodings or not.
    /// - Throws: `VarIntError.trailingBytes` if any bytes follow the VarInt, plus
    ///   the usual `VarIntError` cases.
    @inlinable
    public init(
        varInt bytes: some Collection<UInt8>,
        encoding: VarInt.SignedEncoding = .zigZag,
        requireMinimal: Bool = true
    ) throws(VarIntError) {
        let val = try UInt64(varInt: bytes, requireMinimal: requireMinimal)
        self = encoding.signedValue(from: val)
    }
}
