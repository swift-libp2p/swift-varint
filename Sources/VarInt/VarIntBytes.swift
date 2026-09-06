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

/// The encoded bytes of one VarInt, held inline.
///
/// A VarInt is at most ten bytes, so `VarIntBytes` is a struct that stores them in two
/// integers, the first 8 in a UInt64, and the last 2 in a UInt16, and conforms to
/// `RandomAccessCollection`, which means it's compatible with everything that
/// takes a collection of bytes:
///
/// ```swift
/// // NIO ByteBuffer
/// buffer.writeBytes(length.varIntBytes)
/// // Foundation
/// Data(codec.varIntBytes)
/// // Array concatenation
/// header.varIntBytes + payload
/// ```
///
/// Use `withUnsafeBytes(_:)` when you need a contiguous pointer.
@frozen
public struct VarIntBytes: RandomAccessCollection, Hashable, Sendable {
    public typealias Element = UInt8
    public typealias Index = Int

    /// Bytes `0...7`. Byte `i` occupies bits `8 * i ..< 8 * i + 8`.
    @usableFromInline internal var low: UInt64
    /// Bytes `8...9`, laid out the same way.
    @usableFromInline internal var high: UInt16
    /// The number of significant bytes: `1...10` once encoding has finished.
    @usableFromInline internal var length: UInt8

    /// An empty buffer, ready to be appended to.
    @inlinable
    internal init() {
        self.low = 0
        self.high = 0
        self.length = 0
    }

    /// Appends one byte.
    ///
    /// The caller guarantees fewer than `VarInt.maximumEncodedSize` bytes have
    /// been appended so far, which every encoder in this module does by
    /// construction.
    @inlinable
    internal mutating func append(_ byte: UInt8) {
        assert(self.length < UInt8(VarInt.maximumEncodedSize), "a varInt is at most 10 bytes")
        if self.length < 8 {
            self.low |= UInt64(byte) << (UInt64(self.length) &* 8)
        } else {
            self.high |= UInt16(byte) << (UInt16(self.length - 8) &* 8)
        }
        self.length &+= 1
    }

    /// The minimal unsigned VarInt encoding of `value`.
    @inlinable
    public init(_ value: UInt64) {
        self = value.varIntBytes
    }

    /// The VarInt encoding of `value` under `encoding`.
    @inlinable
    public init(_ value: Int64, _ encoding: VarInt.SignedEncoding = .zigZag) {
        self = value.varIntBytes(encoding)
    }

    @inlinable public var startIndex: Int { 0 }
    @inlinable public var endIndex: Int { Int(self.length) }
    @inlinable public var count: Int { Int(self.length) }

    @inlinable
    public subscript(position: Int) -> UInt8 {
        precondition(position >= 0 && position < self.count, "VarIntBytes index out of range")
        if position < 8 {
            return UInt8(truncatingIfNeeded: self.low >> (UInt64(position) &* 8))
        }
        return UInt8(truncatingIfNeeded: self.high >> (UInt16(position - 8) &* 8))
    }

    /// Calls `body` with a contiguous, wire-ordered view of the encoded bytes.
    ///
    /// The pointer is only valid for the duration of the call.
    ///
    /// - Warning:
    /// It's titled unsafe for a reason! Be careful...
    public func withUnsafeBytes<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        // Converting to little endian puts byte 0 of the varInt at offset 0 of
        // the tuple's storage on every host. `(UInt64, UInt16)` lays out with the
        // UInt16 at offset 8 and no interior padding, so the ten bytes are
        // contiguous and in order.
        var storage = (self.low.littleEndian, self.high.littleEndian)
        return try Swift.withUnsafeBytes(of: &storage) { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return try body(UnsafeBufferPointer(start: base, count: Int(self.length)))
        }
    }

    /// The encoded bytes as an array.
    ///
    /// - Note:
    /// `VarIntBytes` is already a collection of bytes. So you should only use this
    /// if you absolutely need a `[UInt8]`
    @inlinable
    public var bytes: [UInt8] {
        self.withUnsafeBytes { Array($0) }
    }
}

extension VarIntBytes: CustomStringConvertible {
    /// The encoded bytes in hex, e.g. `"[0x80 0x01]"`.
    public var description: String {
        var result = "["
        for (offset, byte) in self.enumerated() {
            if offset > 0 { result += " " }
            result += "0x"
            result += String(byte >> 4, radix: 16)
            result += String(byte & 0x0F, radix: 16)
        }
        return result + "]"
    }

    /// The encoded bytes as space separated binary octets, e.g. `"10000000 00000001"`.
    ///
    /// - Note:
    /// This is a helpful readable form for debugging as you can clearly see the
    /// continuation bit (the leading bit of each octet).
    public var binaryDescription: String {
        self.map { byte -> String in
            var text = String(byte, radix: 2)
            if text.count < 8 { text = String(repeating: "0", count: 8 - text.count) + text }
            return text
        }
        .joined(separator: " ")
    }
}
