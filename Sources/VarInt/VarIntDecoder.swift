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

/// A resumable, byte-at-a-time **unsigned** VarInt decoder.
///
/// Every decoding entry point in this module is built on this one type, so there
/// is a single definition of what a well formed uVarInt is. It consumes one
/// `UInt8` at a time until it can either decode a uVartInt or determine it's
/// invalid, at which point it'll throw the appropriate error.
///
/// ```swift
/// extension ByteBuffer {
///     mutating func readVarInt(limit: UInt64 = .max) throws(VarIntError) -> UInt64? {
///         let start = self.readerIndex
///         var decoder = VarIntDecoder(limit: limit)
///         while let byte: UInt8 = self.readInteger() {
///             if let value = try decoder.push(byte) { return value }
///         }
///         self.moveReaderIndex(to: start)   // incomplete: consume nothing
///         return nil
///     }
/// }
/// ```
///
/// State survives across reads, so a framing decoder that receives a VarInt
/// split over two packets neither buffers nor re-parses.
///
/// A decoder decodes exactly one uVarInt. Call `reset()` before decoding another,
/// or make a new one.
///
/// - Warning:
///   This decoder operates on UNSIGNED VarInts, if you're expected a stream of signed VarInts,
///   you need to convert the returned `UInt64` into the `SignedEncoding` you're expecting...
///   ```
///   VarInt.SignedEncoding.zigzag.signedValue(from: value)
///   ```
///   And derive `limit` from the whole range of signed values you accept...
///   ```
///   VarInt.SignedEncoding.zigZag.encodedCeiling(for: 0...maxLength)
///   ```
///   Do not map the signed limit alone with `unsignedRepresentation(of:)`, it is
///   not a ceiling. See `encodedCeiling(for:)`, or use `VarInt.decodeSigned(_:as:in:)`
///   which handles both halves.
public struct VarIntDecoder: Hashable, Sendable {

    /// The largest value this decoder will accept.
    public let limit: UInt64

    /// Whether non-minimal encodings are rejected.
    public let requireMinimal: Bool

    /// The bits decoded so far, excluding the byte currently being pushed.
    @usableFromInline internal var partialValue: UInt64

    /// The bit position the next byte's payload occupies.
    @usableFromInline internal var shift: UInt64

    /// How many bytes have been pushed.
    @usableFromInline internal var byteCount: Int

    /// - Parameters:
    ///   - limit: The largest value to accept. Defaults to no limit.
    ///   - requireMinimal: Whether to reject non-minimal encodings. Defaults to `true`.
    @inlinable
    public init(limit: UInt64 = .max, requireMinimal: Bool = true) {
        self.limit = limit
        self.requireMinimal = requireMinimal
        self.partialValue = 0
        self.shift = 0
        self.byteCount = 0
    }

    /// How many bytes have been pushed into this decoder.
    @inlinable public var bytesConsumed: Int { self.byteCount }

    /// Whether no bytes have been pushed yet.
    ///
    /// Distinguishes "the input ended cleanly" from "the input ended part way
    /// through a VarInt" when a byte source finishes.
    @inlinable public var isAtStart: Bool { self.byteCount == 0 }

    /// Discards any partially decoded uVarInt, leaving `limit` and
    /// `requireMinimal` in place.
    @inlinable
    public mutating func reset() {
        self.partialValue = 0
        self.shift = 0
        self.byteCount = 0
    }

    /// Feeds the next byte of the uVarInt.
    ///
    /// - Returns: The decoded value if `byte` terminated the uVarInt (its
    ///   continuation bit is clear), `nil` if more bytes are needed.
    /// - Throws: `VarIntError.overflow` if the uVarInt cannot fit in 64 bits,
    ///   `.notMinimal` if it is non-minimally encoded and `requireMinimal` is
    ///   set, or `.exceedsLimit` if the value exceeds `limit`. A throw is
    ///   terminal, the uVarInt is malformed, and the decoder must be `reset()`
    ///   before reuse.
    @inlinable
    public mutating func push(_ byte: UInt8) throws(VarIntError) -> UInt64? {
        self.byteCount += 1
        let payload = UInt64(byte & 0x7F)

        if byte & 0x80 == 0 {
            // Terminator byte. On the tenth byte `shift` is 63, so the payload
            // can contribute exactly one more bit before overflowing a UInt64.
            if self.byteCount == VarInt.maximumEncodedSize && payload > 1 {
                throw VarIntError.overflow
            }
            // A terminator of zero after at least one continuation byte adds no
            // bits, so a shorter encoding of the same value exists.
            if self.requireMinimal && payload == 0 && self.byteCount > 1 {
                throw VarIntError.notMinimal
            }
            let value = self.partialValue | (payload << self.shift)
            if value > self.limit {
                throw VarIntError.exceedsLimit(limit: self.limit)
            }
            return value
        }

        // A continuation bit on the tenth byte would require an eleventh, which
        // cannot fit in a UInt64.
        if self.byteCount >= VarInt.maximumEncodedSize {
            throw VarIntError.overflow
        }

        self.partialValue |= payload << self.shift
        self.shift += 7

        // Remaining bytes only add higher-order bits, so once the partial value
        // is over the ceiling the final value must be too.
        if self.partialValue > self.limit {
            throw VarIntError.exceedsLimit(limit: self.limit)
        }

        return nil
    }
}
