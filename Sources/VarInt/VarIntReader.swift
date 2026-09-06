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

/// A reader that consumes a sequence of VarInts and/or VarInt length prefixed fields
/// from a collection of bytes.
///
/// Use this when you have several VarInt fields sitting back to back, such as a
/// multihash's code and digest length, a signed envelope, a handshake's length
/// prefixed payload followed by leftover stream data.
///
/// ```swift
/// var reader = VarIntReader(buffer)
/// let code = try reader.readUVarInt()
/// let digest = try reader.readUVarIntLengthPrefixed()
/// let leftover = reader.remaining
/// ```
///
/// The reader is `~Copyable`, so a cursor cannot be accidentally duplicated and
/// silently read twice from the same position. It is therefore not suitable as a
/// stored property that has to survive across calls, use `VarIntDecoder` for
/// incremental decoding of a byte stream.
///
/// Every read is atomic, on a throw the position is unchanged, so a caller that
/// catches `VarIntError.needsMoreBytes` can retry the same read against a longer
/// collection.
public struct VarIntReader<Bytes: Collection<UInt8>>: ~Copyable {

    /// The bytes being read.
    public let bytes: Bytes

    /// The index of the next unread byte.
    @usableFromInline internal var position: Bytes.Index

    /// Creates a reader positioned at the start of `bytes`.
    @inlinable
    public init(_ bytes: Bytes) {
        self.bytes = bytes
        self.position = bytes.startIndex
    }

    /// The bytes that have not been read yet.
    @inlinable
    public var remaining: Bytes.SubSequence { self.bytes[self.position...] }

    /// Whether every byte has been read.
    @inlinable
    public var isEmpty: Bool { self.position == self.bytes.endIndex }

    /// How many bytes have been read.
    @inlinable
    public var bytesConsumed: Int {
        self.bytes.distance(from: self.bytes.startIndex, to: self.position)
    }

    /// Reads an unsigned VarInt starting at the cursor, and advances past it.
    ///
    /// - Parameters:
    ///   - limit: The largest value to accept.
    ///   - requireMinimal: Whether to reject non-minimal encodings or not.
    /// - Throws: `VarIntError.needsMoreBytes` if we run out of bytes part way
    ///   through the VarInt. The cursor does not move on a throw.
    @inlinable
    public mutating func readUVarInt(
        limit: UInt64 = .max,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> UInt64 {
        let (value, end) = try VarInt.decode(
            self.bytes[self.position...],
            limit: limit,
            requireMinimal: requireMinimal
        )
        self.position = end
        return value
    }

    /// Reads a signed VarInt starting at the cursor, and advances past it.
    ///
    /// - Parameters:
    ///   - encoding: The strategy to use when mapping a signed integer onto a VarInt.
    ///     Must match whatever the writer used.
    ///   - requireMinimal: Whether to reject non-minimal encodings or not.
    /// - Throws: `VarIntError.needsMoreBytes` if we run out of bytes part way
    ///   through the VarInt. The cursor does not move on a throw.
    @inlinable
    public mutating func readVarInt(
        _ encoding: VarInt.SignedEncoding = .zigZag,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> Int64 {
        let bits = try self.readUVarInt(requireMinimal: requireMinimal)
        return encoding.signedValue(from: bits)
    }

    /// Reads an unsigned VarInt length prefix followed by that many bytes, and advances past both.
    ///
    /// - Parameters:
    ///   - limit: The largest length to accept. An announced length over the
    ///     ceiling is rejected while decoding the prefix.
    ///   - requireMinimal: Whether to reject a non-minimally encoded prefix or not.
    /// - Returns: The body, without the prefix. May be empty.
    /// - Throws: `VarIntError.needsMoreBytes` if either the prefix or the body is
    ///   incomplete. The cursor does not move on a throw, so the same read can be
    ///   retried once more bytes are available.
    @inlinable
    public mutating func readUVarIntLengthPrefixed(
        limit: UInt64 = .max,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> Bytes.SubSequence {
        let tail = self.bytes[self.position...]
        let (length, bodyStart) = try VarInt.decode(tail, limit: limit, requireMinimal: requireMinimal)

        return try collectTheBody(tail, length: length, bodyStart: bodyStart)
    }
    
    /// Reads a signed VarInt length prefix followed by that many bytes, and advances past both.
    ///
    /// - Parameters:
    ///   - encoding: The strategy to use when mapping a signed integer onto a VarInt.
    ///     Must match whatever the writer used.
    ///   - limit: The largest length to accept.
    ///   - requireMinimal: Whether to reject a non-minimally encoded prefix or not.
    /// - Returns: The body, without the prefix. May be empty.
    /// - Throws: `VarIntError.needsMoreBytes` if either the prefix or the body is
    ///   incomplete. The cursor does not move on a throw, so the same read can be
    ///   retried once more bytes are available. `.outOfRange` if the prefix
    ///   announces a negative length or one over `limit`.
    @inlinable
    public mutating func readVarIntLengthPrefixed(
        _ encoding: VarInt.SignedEncoding = .zigZag,
        limit: Int64 = .max,
        requireMinimal: Bool = true
    ) throws(VarIntError) -> Bytes.SubSequence {
        let tail = self.bytes[self.position...]
        let (length, bodyStart) = try VarInt.decodeSigned(
            tail,
            as: encoding,
            // lengths must be positive, so clamp it
            in: 0...max(limit, 0),
            requireMinimal: requireMinimal
        )

        return try collectTheBody(tail, length: UInt64(length), bodyStart: bodyStart)
    }
    
    @inlinable
    mutating func collectTheBody(_ tail: Bytes.SubSequence, length: UInt64, bodyStart: Bytes.Index) throws(VarIntError) -> Bytes.SubSequence {
        guard let bodyCount = Int(exactly: length) else { throw VarIntError.overflow }

        // Walk the body rather than slicing on a computed index so this works on
        // any Collection and not just a RandomAccessCollection.
        var end = bodyStart
        var taken = 0
        while taken < bodyCount {
            guard end != tail.endIndex else { throw VarIntError.needsMoreBytes }
            end = tail.index(after: end)
            taken += 1
        }

        self.position = end
        return tail[bodyStart..<end]
    }
}
