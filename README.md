# VarInt encoding of 64-bit integers

[![](https://img.shields.io/badge/made%20by-Breth-blue.svg?style=flat-square)](https://breth.app)
[![](https://img.shields.io/badge/project-multiformats-blue.svg?style=flat-square)](https://github.com/multiformats/multiformats)
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-blue.svg?style=flat-square)](https://github.com/apple/swift-package-manager)
![Build & Test (macos and linux)](https://github.com/swift-libp2p/swift-varint/actions/workflows/build+test.yml/badge.svg)

> Swift implementation of the Google Protocol Buffers VarInt specification

## Table of Contents

- [Overview](#overview)
- [Install](#install)
- [Usage](#usage)
  - [Encoding](#encoding)
  - [Decoding](#decoding)
  - [Length prefixed fields](#length-prefixed-fields)
  - [Reading several fields](#reading-several-fields)
  - [Streaming and framing](#streaming-and-framing)
  - [Signed values](#signed-values)
  - [API](#api)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Overview
This package is based on the Go implementation of the Google Protocol Buffers VarInt specification.
- VarInts are a method of serializing integers using one or more bytes.
- Smaller numbers take a smaller number of bytes.

#### For more details see 
- [https://github.com/multiformats/go-varint](https://github.com/multiformats/go-varint)
- [ipfs/QmXJXJMai4p88HMsp2TPP1EtZxfSZQ1vyRtN5dGKvQ6MCw](ipfs/QmXJXJMai4p88HMsp2TPP1EtZxfSZQ1vyRtN5dGKvQ6MCw)

#### The encoding rules are:
-   Unsigned integers are serialized 7 bits at a time, starting with the least significant bits.
-   The most significant bit (msb) in each output byte indicates if there is a continuation byte.
-   Signed integers are mapped to unsigned integers by one of two conventions, modelled by
    `VarInt.SignedEncoding`:
    - `.zigZag`: positive `n` becomes `2n`, negative `n` becomes `2|n| - 1`, so small magnitudes of
      either sign stay short. This is protobuf's `sint64`, and the default.
    - `.twosComplement`: the value's bit pattern, encoded as if unsigned. Every negative occupies
      the full ten bytes. This is protobuf's `int64`.
-   Encodings must be **minimal** by default, a trailing byte that contributes no bits is rejected,
    so each value has exactly one valid representation. Override with `requireMinimal: false`.

## Install

Include the following dependency in your Package.swift file
```Swift
let package = Package(
    ...
    dependencies: [
        ...
        .package(url: "https://github.com/swift-libp2p/swift-varint.git", .upToNextMinor(from: "0.3.0"))
    ],
     ...
        .target(
            ...
            dependencies: [
                ...
                .product(name: "VarInt", package: "swift-varint"),
            ]),
        ...
    ...
)
```

## Usage

### Encoding

`varIntBytes` returns a `VarIntBytes`, the encoded bytes held inline, with no
heap allocation. It conforms to `RandomAccessCollection<UInt8>`, so anything
that accepts a collection of bytes takes it directly.

```Swift
import VarInt

UInt64(300).varintBytes                 // [0xac 0x02]
UInt64(300).varintSize                  // 2

buffer.writeBytes(length.varIntBytes)   // NIO ByteBuffer
Data(codec.varIntBytes)                 // Foundation
header.varIntBytes + payload            // Array concatenation
Array(value.varIntBytes)                // or `.bytes`
```

Also available on `UInt32`, `UInt` and `Int` (the last requires a non-negative
value, use `Int64.varIntBytes(_:)` for signed encodings).

### Decoding

`VarInt.decode(_:)` accepts any `Collection<UInt8>` and returns the value along with the index one past
the VarInt's last byte, so the remainder is just `bytes[end...]` without requiring a copy.

```Swift
let (value, end) = try VarInt.decode(bytes)
let rest = bytes[end...]
```

Failures are typed, and a short read is a **distinct case** from malformed
input, which is what distinguishes the "need more data" case from an
"invalid VarInt byte stream" without having to inspect the bytes manually.

```Swift
public enum VarIntError: Error, Hashable, Sendable {
    case needsMoreBytes            // ended mid-VarInt; more bytes may fix it
    case overflow                  // doesn't fit in 64 bits
    case notMinimal                // valid LEB128, but non-minmal (trailing padded byte)
    case exceedsLimit(limit: UInt64)  // over the ceiling the caller supplied
    case outOfRange(allowed: ClosedRange<Int64>)  // the signed equivalent of `exceedsLimit`
    case trailingBytes             // only thrown from the exact byte parsing initialisers
}
```

Pass `limit:` when a field has a known ceiling. It is enforced from the
*accumulated* bits, so an oversized announcement is rejected as soon as it is
provably too large, before any body is buffered, and without the caller sizing
a read window first:

```Swift
let length = try VarInt.decode(bytes, limit: 1 << 20).value
```

Signed decoding takes the whole range it accepts, as `in:`, and reports
`.outOfRange` in those same terms. A range rather than a ceiling, because
neither convention orders the encoded values the way it orders the signed ones:
under `.zigZag` the negatives interleave with the positives, and under
`.twosComplement` every negative encodes *above* every positive. Both ends are
needed to know what the widest encoding in range can be:

```Swift
let length = try VarInt.decodeSigned(bytes, as: .zigZag, in: 0...(1 << 20)).value
```

When a field *is* a VarInt rather than merely beginning with one:

```Swift
let codec = try UInt64(varInt: prefixBytes)   // throws .trailingBytes on leftovers
```

### Length prefixed fields

`uVarInt(count) || bytes`, the framing used throughout libp2p and multiformats:

```Swift
let framed = payload.uVarIntLengthPrefixed          // any Collection<UInt8>

let signed = domain.utf8.uVarIntLengthPrefixed
    + codec.uVarIntLengthPrefixed
    + payload.uVarIntLengthPrefixed
```

### Reading several fields

`VarIntReader` maintains a curson to help with reading mulitple back-to-back VarInts or VarInt prefixed fields. It hands back subsequences,
so nothing is copied, and every read is atomic, on a throw the position is
unchanged, so a `needsMoreBytes` can be retried against a longer collection (once  more bytes arrive).

```Swift
var reader = VarIntReader(buffer)
let code = try reader.readUVarInt()
let digest = try reader.readUVarIntLengthPrefixed()
let leftover = reader.remaining
```

It is `~Copyable`, so a cursor cannot be accidentally duplicated and silently
read twice from the same position. That also means it can't be stored as a
property that survives across calls, use `VarIntDecoder` for that.

### Streaming and framing

`VarIntDecoder` is the byte-at-a-time state machine every VarInt is decoded from. It's byte collection agnostic, so just feed it a UInt8 at a time and it'll decode VarInts:

```Swift
extension ByteBuffer {
    mutating func readVarint(limit: UInt64 = .max) throws(VarintError) -> UInt64? {
        let start = self.readerIndex
        var decoder = VarIntDecoder(limit: limit)
        while let byte: UInt8 = self.readInteger() {
            if let value = try decoder.push(byte) { return value }
        }
        self.moveReaderIndex(to: start)   // incomplete: consume nothing
        return nil
    }
}
```

State survives across reads, so a VarInt split over two packets is neither
buffered nor re-parsed.

For use with Iterators, there is a VarInt.decode(readingFrom:) method that 
returns `nil` at a clean end of input and throws `.needsMoreBytes` on a 
truncated varint.

```Swift
var iterator = bytes.makeIterator()
while let value = try VarInt.decode(readingFrom: { iterator.next() }) {
    // …one value per VarInt, terminating at the end of the input
}
```

### Signed values

The two signed conventions produce different bytes for the same negative number,
and nothing on the wire distinguishes them, so the choice is always explicit:

```Swift
Int64(-1).varIntBytes(.zigZag)          // [0x01]         — 1 byte
Int64(-1).varIntBytes(.twosComplement)  // [0xff … 0x01]  — 10 bytes

Int64(-1).varIntSize(.zigZag)           // 1
Int64(-1).varIntSize(.twosComplement)   // 10

let (value, end) = try VarInt.decodeSigned(bytes, as: .zigZag)
let exact = try Int64(varInt: bytes, encoding: .zigZag)
```

### API

```Swift
/// Encoding
extension UInt64 { var varIntBytes: VarIntBytes; var varIntSize: Int }
extension UInt32 { var varIntBytes: VarIntBytes; var varIntSize: Int }
extension UInt   { var varIntBytes: VarIntBytes; var varIntSize: Int }
extension Int    { var varIntBytes: VarIntBytes; var varIntSize: Int }   // non-negative only
extension Int64  { func varIntBytes(_: VarInt.SignedEncoding = .zigZag) -> VarIntBytes
                   func varIntSize(_: VarInt.SignedEncoding = .zigZag) -> Int }
extension Int32  { func varIntBytes(_: VarInt.SignedEncoding = .zigZag) -> VarIntBytes
                   func varIntSize(_: VarInt.SignedEncoding = .zigZag) -> Int }

struct VarIntBytes: RandomAccessCollection<UInt8>, Hashable, Sendable
    var bytes: [UInt8]
    func withUnsafeBytes<R>((UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R
    var description: String              // "[0xac 0x02]"
    var binaryDescription: String        // "10101100 00000010"

/// Decoding
enum VarInt
    static let maximumEncodedSize: Int                                  // 10
    static func encodedSize(forValuesUpTo: UInt64) -> Int
    static func decode<C: Collection<UInt8>>(_: C, limit: UInt64 = .max, requireMinimal: Bool = true)
        throws(VarIntError) -> (value: UInt64, end: C.Index)
    static func decodeSigned<C: Collection<UInt8>>(_: C, as: Varint.SignedEncoding = .zigZag,
        in: ClosedRange<Int64> = .min ... .max,
        requireMinimal: Bool = true) throws(VarIntError) -> (value: Int64, end: C.Index)
    static func decode(limit: UInt64 = .max, requireMinimal: Bool = true,
        readingFrom: () throws -> UInt8?) throws -> UInt64?

extension UInt64 { init(varInt: some Collection<UInt8>, requireMinimal: Bool = true) throws(VarIntError) }
extension Int64  { init(varInt: some Collection<UInt8>, encoding: VarInt.SignedEncoding = .zigZag,
                        requireMinimal: Bool = true) throws(VarIntError) }

/// Incremental decoding
struct VarIntDecoder: Hashable, Sendable
    init(limit: UInt64 = .max, requireMinimal: Bool = true)
    mutating func push(_: UInt8) throws(VarIntError) -> UInt64?
    var bytesConsumed: Int
    var isAtStart: Bool
    mutating func reset()

/// Cursor over back-to-back fields
struct VarIntReader<Bytes: Collection<UInt8>>: ~Copyable
    init(_: Bytes)
    mutating func readUVarInt(limit: UInt64 = .max, requireMinimal: Bool = true) throws(VarIntError) -> UInt64
    mutating func readVarInt(_: VarInt.SignedEncoding = .zigZag, requireMinimal: Bool = true) throws(VarIntError) -> Int64
    mutating func readUVarIntLengthPrefixed(limit: UInt64 = .max, requireMinimal: Bool = true) throws(VarIntError) -> Bytes.SubSequence
    mutating func readVarIntLengthPrefixed(_: VarInt.SignedEncoding = .zigZag, limit: Int64 = .max, requireMinimal: Bool = true) throws(VarIntError) -> Bytes.SubSequence
    var remaining: Bytes.SubSequence
    var bytesConsumed: Int
    var isEmpty: Bool

/// Length prefixed framing
extension Collection where Element == UInt8 { 
    var varIntLengthPrefixed: [UInt8]
    var uVarIntLengthPrefixed: [UInt8]
}

/// Signed conventions
enum SignedEncoding: Hashable, Sendable, CaseIterable
    case zigZag, twosComplement
    func unsignedRepresentation(of: Int64) -> UInt64
    func signedValue(from: UInt64) -> Int64
    func encodedCeiling(for: ClosedRange<Int64>) -> UInt64

/// Errors
enum VarIntError: Error, Hashable, Sendable
    case needsMoreBytes, overflow, notMinimal, exceedsLimit(limit: UInt64)
    case outOfRange(allowed: ClosedRange<Int64>), trailingBytes
```

## Contributing

Contributions are welcomed! This code is very much a proof of concept. I can guarantee you there's a better / safer way to accomplish the same results. Any suggestions, improvements, or even just critques, are welcome! 

Let's make this code better together! 🤝

## Credits

[https://github.com/multiformats/go-varint](https://github.com/multiformats/go-varint)

## License

[MIT](LICENSE) © 2026 Breth Inc.
