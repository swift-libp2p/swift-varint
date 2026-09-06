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

public enum VarIntError: Error, Hashable, Sendable {

    /// The input ended part way through a VarInt.
    ///
    /// This is a short read, not corruption: the same input plus more bytes may
    /// decode successfully.
    case needsMoreBytes

    /// The VarInt's value does not fit in 64 bits.
    case overflow

    /// The VarInt is valid LEB128 but non-minimally encoded. Its final byte
    /// contributes no bits (aka a redundant trailing zero).
    ///
    /// Only reported when decoding with `requireMinimal: true`, the default.
    case notMinimal

    /// The VarInt's value exceeds the `limit` the decoder was given.
    ///
    /// Reported as soon as the bits read so far exceed `limit`, which
    /// may be before the VarInt's final byte has been read.
    case exceedsLimit(limit: UInt64)

    /// The signed VarInt's value falls outside the range the caller allowed.
    ///
    /// The signed equivalent of `exceedsLimit`.
    case outOfRange(allowed: ClosedRange<Int64>)

    /// Bytes remained after the VarInt, but the caller required the input to
    /// hold exactly one VarInt and nothing more.
    ///
    /// Only produced by the exact-parse entry points such as
    /// `UInt64.init(varInt:requireMinimal:)`.
    case trailingBytes
}

extension VarIntError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .needsMoreBytes:
            "the input ended part way through a VarInt, more bytes are needed"
        case .overflow:
            "the VarInt does not fit in 64 bits"
        case .notMinimal:
            "the VarInt is non-minimally encoded (its final byte contributes no bits)"
        case .exceedsLimit(let limit):
            "the VarInt's value exceeds the limit of \(limit)"
        case .outOfRange(let allowed):
            "the VarInt's value falls outside the allowed range of \(allowed.lowerBound)...\(allowed.upperBound)"
        case .trailingBytes:
            "bytes remained after the VarInt was read"
        }
    }
}
