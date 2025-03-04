//===----------------------------------------------------------------------===//
//
// This source file is part of the swift-libp2p open source project
//
// Copyright (c) 2022-2025 swift-libp2p project authors
// Licensed under MIT
//
// See LICENSE for license information
// See CONTRIBUTORS for the list of swift-libp2p project authors
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

// Sources/SwiftProtobuf/BinaryEncoder.swift - Binary encoding support
//
// Copyright (c) 2014 - 2016 Apple Inc. and the project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See LICENSE.txt for license information:
// https://github.com/apple/swift-protobuf/blob/main/LICENSE.txt
//
// -----------------------------------------------------------------------------
///
/// Core support for protobuf binary encoding.  Note that this is built
/// on the general traversal machinery.
///
// -----------------------------------------------------------------------------

import Foundation

/// Encoder for Binary Protocol Buffer format
public struct BinaryEncoder {
    private var pointer: UnsafeMutablePointer<UInt8>

    init(forWritingInto pointer: UnsafeMutablePointer<UInt8>) {
        self.pointer = pointer
    }

    private mutating func append(_ byte: UInt8) {
        pointer.pointee = byte
        pointer = pointer.successor()
    }

    private mutating func append(contentsOf data: Data) {
        let count = data.count
        data.copyBytes(to: pointer, count: count)
        pointer = pointer.advanced(by: count)
    }

    private mutating func append(contentsOf bufferPointer: UnsafeBufferPointer<UInt8>) {
        let count = bufferPointer.count
        pointer.assign(from: bufferPointer.baseAddress!, count: count)
        pointer = pointer.advanced(by: count)
    }

    func distance(pointer: UnsafeMutablePointer<UInt8>) -> Int {
        pointer.distance(to: self.pointer)
    }

    mutating func appendUnknown(data: Data) {
        append(contentsOf: data)
    }

    mutating func putVarInt(value: UInt64) {
        var v = value
        while v > 127 {
            append(UInt8(v & 0x7f | 0x80))
            v >>= 7
        }
        append(UInt8(v))
    }

    mutating func putVarInt(value: Int64) {
        putVarInt(value: UInt64(bitPattern: value))
    }

    mutating func putVarInt(value: Int) {
        putVarInt(value: Int64(value))
    }

    mutating func putBoolValue(value: Bool) {
        append(value ? 1 : 0)
    }

    mutating func putFixedUInt64(value: UInt64) {
        var v = value.littleEndian
        let n = MemoryLayout<UInt64>.size
        memcpy(pointer, &v, n)
        pointer = pointer.advanced(by: n)
    }

    mutating func putFixedUInt32(value: UInt32) {
        var v = value.littleEndian
        let n = MemoryLayout<UInt32>.size
        memcpy(pointer, &v, n)
        pointer = pointer.advanced(by: n)
    }

    mutating func putFloatValue(value: Float) {
        let n = MemoryLayout<Float>.size
        var v = value
        var nativeBytes: UInt32 = 0
        memcpy(&nativeBytes, &v, n)
        var littleEndianBytes = nativeBytes.littleEndian
        memcpy(pointer, &littleEndianBytes, n)
        pointer = pointer.advanced(by: n)
    }

    mutating func putDoubleValue(value: Double) {
        let n = MemoryLayout<Double>.size
        var v = value
        var nativeBytes: UInt64 = 0
        memcpy(&nativeBytes, &v, n)
        var littleEndianBytes = nativeBytes.littleEndian
        memcpy(pointer, &littleEndianBytes, n)
        pointer = pointer.advanced(by: n)
    }

    // Write a string field, including the leading index/tag value.
    mutating func putStringValue(value: String) {
        let count = value.utf8.count
        putVarInt(value: count)
        for b in value.utf8 {
            pointer.pointee = b
            pointer = pointer.successor()
        }
    }

    mutating func putBytesValue(value: Data) {
        putVarInt(value: value.count)
        append(contentsOf: value)
    }
}

extension UInt64 {
    public func varIntData() -> Data {
        let byteCount = encodedSize(of: self)  //Varint.encodedSize(of: self)
        var buffer = Data(count: byteCount)
        buffer.withUnsafeMutableBytes { (unsafePointer: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = unsafePointer.baseAddress, unsafePointer.count > 0 else { return }
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var encoder = BinaryEncoder(forWritingInto: pointer)
            encoder.putVarInt(value: self)
        }
        return buffer
    }
}
