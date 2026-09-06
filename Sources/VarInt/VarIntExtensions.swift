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

// MARK: - Unsigned encoding

extension UInt64 {

    /// The minimal unsigned VarInt (LEB128) encoding of this value.
    @inlinable
    public var varIntBytes: VarIntBytes {
        var encoded = VarIntBytes()
        var value = self
        while value >= 0x80 {
            encoded.append(UInt8(truncatingIfNeeded: value) | 0x80)
            value >>= 7
        }
        encoded.append(UInt8(truncatingIfNeeded: value))
        return encoded
    }

    /// The number of bytes `varIntBytes` occupies.
    @inlinable
    public var varIntSize: Int {
        let significantBits = UInt64.bitWidth - self.leadingZeroBitCount
        // Seven payload bits per byte, and zero still needs one byte.
        return significantBits <= 7 ? 1 : (significantBits + 6) / 7
    }
}

extension UInt32 {
    /// The minimal unsigned VarInt encoding of this value.
    @inlinable public var varIntBytes: VarIntBytes { UInt64(self).varIntBytes }
    
    /// The number of bytes `varIntBytes` occupies.
    @inlinable public var varIntSize: Int { UInt64(self).varIntSize }
}

extension UInt {
    /// The minimal unsigned varInt encoding of this value.
    @inlinable public var varIntBytes: VarIntBytes { UInt64(self).varIntBytes }
    
    /// The number of bytes `varIntBytes` occupies.
    @inlinable public var varIntSize: Int { UInt64(self).varIntSize }
}

extension Int {

    /// The minimal unsigned VarInt encoding of this value.
    ///
    /// - Precondition: The value is non-negative. There is no unsigned encoding
    ///   of a negative number; use `Int64.varIntBytes(_:)`, which requires you to
    ///   name the signed convention.
    @inlinable
    public var varIntBytes: VarIntBytes {
        precondition(
            self >= 0,
            "Int.varIntBytes requires a non-negative value, use Int64.varIntBytes(_:) to encode a signed value"
        )
        return UInt64(self).varIntBytes
    }

    /// The number of bytes `varIntBytes` occupies.
    ///
    /// - Precondition: The value is non-negative.
    @inlinable
    public var varIntSize: Int {
        precondition(
            self >= 0,
            "Int.varIntSize requires a non-negative value, use Int64.varIntSize(_:) to measure a signed value"
        )
        return UInt64(self).varIntSize
    }
}

// MARK: - Signed encoding

extension Int64 {

    /// The VarInt of this value using the specified `encoding`.
    ///
    /// - Parameter encoding: The strategy to use when mapping a signed integer
    ///   onto a VarInt. Defaults to `.zigZag`, which keeps small magnitudes of
    ///   either sign short. Use `.twosComplement` for protobuf `int64` framing.
    @inlinable
    public func varIntBytes(_ encoding: VarInt.SignedEncoding = .zigZag) -> VarIntBytes {
        encoding.unsignedRepresentation(of: self).varIntBytes
    }

    /// The number of bytes `varIntBytes(_:)` occupies under `encoding`.
    ///
    /// - Parameter encoding: The strategy to use when mapping a signed integer
    ///   onto a VarInt. Defaults to `.zigZag`, which keeps small magnitudes of
    ///   either sign short. Use `.twosComplement` for protobuf `int64` framing.
    @inlinable
    public func varIntSize(_ encoding: VarInt.SignedEncoding = .zigZag) -> Int {
        encoding.unsignedRepresentation(of: self).varIntSize
    }
}

extension Int32 {
    /// The VarInt of this value using the specified `encoding`.
    ///
    /// - Parameter encoding: The strategy to use when mapping a signed integer
    ///   onto a VarInt. Defaults to `.zigZag`, which keeps small magnitudes of
    ///   either sign short. Use `.twosComplement` for protobuf `int64` framing.
    @inlinable
    public func varIntBytes(_ encoding: VarInt.SignedEncoding = .zigZag) -> VarIntBytes {
        Int64(self).varIntBytes(encoding)
    }

    /// The number of bytes `varIntBytes(_:)` occupies under `encoding`.
    ///
    /// - Parameter encoding: The strategy to use when mapping a signed integer
    ///   onto a VarInt. Defaults to `.zigZag`, which keeps small magnitudes of
    ///   either sign short. Use `.twosComplement` for protobuf `int64` framing.
    @inlinable
    public func varIntSize(_ encoding: VarInt.SignedEncoding = .zigZag) -> Int {
        Int64(self).varIntSize(encoding)
    }
}
