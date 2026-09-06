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

extension Collection where Element == UInt8 {

    /// These bytes, preceded by their count as an unsigned VarInt.
    ///
    /// The most common framing in libp2p and multiformats, a uVarInt
    /// length, then that many bytes...
    ///
    /// ```swift
    /// let signed = domain.utf8.uVarIntLengthPrefixed
    ///     + payloadType.uVarIntLengthPrefixed
    ///     + payload.uVarIntLengthPrefixed
    /// ```
    ///
    /// - Note:
    ///   Recover the body with `VarIntReader.readUVarIntLengthPrefixed()`.
    @inlinable
    public var uVarIntLengthPrefixed: [UInt8] {
        let length = self.count
        let prefix = UInt64(length).varIntBytes

        var result = [UInt8]()
        result.reserveCapacity(prefix.count + length)
        result.append(contentsOf: prefix)
        result.append(contentsOf: self)
        return result
    }

    /// These bytes, preceded by their count as an signed VarInt.
    ///
    /// - Note:
    ///   Recover the body with `VarIntReader.readVarIntLengthPrefixed()`.
    @inlinable
    public func varIntLengthPrefixed(_ encoding: VarInt.SignedEncoding) -> [UInt8] {
        let length = self.count
        let prefix = Int64(length).varIntBytes(encoding)

        var result = [UInt8]()
        result.reserveCapacity(prefix.count + length)
        result.append(contentsOf: prefix)
        result.append(contentsOf: self)
        return result
    }
}
