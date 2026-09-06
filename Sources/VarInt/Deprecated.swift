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

//
//  Deprecated.swift
//
//  Compatibility shims for the pre-0.3.0 API
//

#if canImport(Foundation)
import Foundation
#endif

@available(*, deprecated, message: "Consider using VarInt.decode(_:) instead.")
public typealias DecodedUVarInt = (value: UInt64, bytesRead: Int)

@available(*, deprecated, message: "Consider using VarInt.decodeSigned(_:as:) instead.")
public typealias DecodedVarInt = (value: Int64, bytesRead: Int)

// MARK: - Encoding

@available(*, deprecated, message: "Use `value.varIntBytes`.")
public func putUVarInt(_ value: UInt64) -> [UInt8] {
    value.varIntBytes.bytes
}

@available(*, deprecated, message: "Use `value.varIntBytes(.zigZag)`.")
public func putVarInt(_ value: Int64) -> [UInt8] {
    value.varIntBytes(.zigZag).bytes
}

// MARK: - Decoding

/// The pre 0.3.0 decoding response with the new decoding logic.
///
/// Reports failure through a non-positive `bytesRead`.
internal func _legacyDecode(_ buffer: [UInt8]) -> (value: UInt64, bytesRead: Int) {
    var decoder = VarIntDecoder()
    var consumed = 0

    for byte in buffer {
        consumed += 1
        do {
            if let value = try decoder.push(byte) { return (value, consumed) }
        } catch VarIntError.overflow {
            return (0, -consumed)
        } catch {
            return (0, 0)
        }
    }

    return (0, 0)
}

@available(*, deprecated, message: "Use `VarInt.decode(_:)`.")
public func uVarInt(_ buffer: [UInt8]) -> (value: UInt64, bytesRead: Int) {
    _legacyDecode(buffer)
}

@available(*, deprecated, message: "Use `VarInt.decodeSigned(_:as:)`.")
public func varInt(_ buffer: [UInt8]) -> (value: Int64, bytesRead: Int) {
    let (bits, bytesRead) = _legacyDecode(buffer)
    return (VarInt.SignedEncoding.zigZag.signedValue(from: bits), bytesRead)
}

// MARK: - Sizing

@available(*, deprecated, message: "Use `value.varIntSize`.")
public func encodedSize(of value: UInt64) -> Int {
    value.varIntSize
}

@available(*, deprecated, message: "Use `value.varIntSize`.")
public func encodedSize(of value: UInt32) -> Int {
    value.varIntSize
}

@available(
    *,
    deprecated,
    message:
        "Use `value.varIntSize(.twosComplement)`. Note this function measured the two's-complement encoding, which does NOT match the zig-zag bytes `putVarInt(_:)` produced."
)
public func encodedSize(of value: Int64) -> Int {
    value.varIntSize(.twosComplement)
}

@available(
    *,
    deprecated,
    message:
        "Use `value.varIntSize(.twosComplement)`. Note this function measured the two's-complement encoding, which does NOT match the zig-zag bytes `putVarInt(_:)` produced."
)
public func encodedSize(of value: Int32) -> Int {
    // Preserves the original, non-negative values were measured as UInt32,
    // negatives were sign-extended to 64 bits first.
    if value >= 0 {
        return UInt32(bitPattern: value).varIntSize
    }
    return Int64(value).varIntSize(.twosComplement)
}

extension VarInt {

    @available(*, deprecated, message: "Use `value.varIntBytes`.")
    public static func putUVarInt(_ value: UInt64) -> [UInt8] {
        value.varIntBytes.bytes
    }

    @available(*, deprecated, message: "Use `value.varIntBytes(.zigZag)`.")
    public static func putVarInt(_ value: Int64) -> [UInt8] {
        value.varIntBytes(.zigZag).bytes
    }

    @available(*, deprecated, message: "Use `VarInt.decode(_:)`.")
    public static func uVarInt(_ buffer: [UInt8]) -> (value: UInt64, bytesRead: Int) {
        _legacyDecode(buffer)
    }

    @available(*, deprecated, message: "Use `VarInt.decodeSigned(_:as:)`.")
    public static func varInt(_ buffer: [UInt8]) -> (value: Int64, bytesRead: Int) {
        let (bits, bytesRead) = _legacyDecode(buffer)
        return (VarInt.SignedEncoding.zigZag.signedValue(from: bits), bytesRead)
    }
}

// MARK: - Foundation

#if canImport(Foundation)
extension UInt64 {
    @available(
        *,
        deprecated,
        message:
            "Use `Data(value.varIntBytes)`. VarIntBytes is a collection of bytes, so Data initialises from it directly."
    )
    public func varIntData() -> Data {
        Data(self.varIntBytes)
    }
}
#endif

// MARK: - Debug helpers

extension Array where Element == UInt8 {
    /// Returns the array as a string of space separated binary octets.
    ///
    /// ```
    /// [1].asBinaryChunks() == "00000001"
    /// ```
    ///
    /// - Note: `VarIntBytes.binaryDescription` is the equivalent for encoded
    ///   varInts and does not require an intermediate array.
    internal func asBinaryChunks() -> String {
        self.map {
            var text = String($0, radix: 2)
            if text.count < 8 { text = String(repeating: "0", count: 8 - text.count) + text }
            return text
        }
        .joined(separator: " ")
    }
}
