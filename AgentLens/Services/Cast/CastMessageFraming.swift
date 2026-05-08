import Foundation

// MARK: - Cast V2 Wire Format
//
// Each frame is a 4-byte big-endian length prefix followed by a `CastMessage`
// protobuf. We hand-encode/decode the protobuf instead of pulling in
// swift-protobuf — the schema is small and stable, and the alternative is
// adding a build-time codegen step for one .proto file.
//
// Reference: https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/cast_channel/proto/cast_channel.proto
//
// Fields we use (proto2):
//   1: protocol_version (enum, varint)            — always CASTV2_1_0 = 0
//   2: source_id        (string)
//   3: destination_id   (string)
//   4: namespace        (string)
//   5: payload_type     (enum, varint)            — STRING = 0, BINARY = 1
//   6: payload_utf8     (string)
//   7: payload_binary   (bytes)                   — unused

struct CastMessage: Equatable {
    enum PayloadType: Int { case string = 0, binary = 1 }

    var sourceId: String
    var destinationId: String
    var namespace: String
    var payloadUTF8: String
    var payloadType: PayloadType = .string

    static let defaultSource = "sender-0"
    static let defaultDestination = "receiver-0"
}

enum CastFraming {

    /// Encode a `CastMessage` into the on-the-wire framed bytes:
    /// 4-byte big-endian length + protobuf body.
    static func encode(_ message: CastMessage) -> Data {
        var body = Data()

        // Field 1: protocol_version = CASTV2_1_0 (0). Tag = (1<<3)|0 = 0x08.
        body.append(0x08)
        body.append(0x00)

        // Field 2: source_id (string). Tag = (2<<3)|2 = 0x12.
        appendLengthDelimited(&body, tag: 0x12, value: message.sourceId.data(using: .utf8) ?? Data())
        // Field 3: destination_id.
        appendLengthDelimited(&body, tag: 0x1A, value: message.destinationId.data(using: .utf8) ?? Data())
        // Field 4: namespace.
        appendLengthDelimited(&body, tag: 0x22, value: message.namespace.data(using: .utf8) ?? Data())
        // Field 5: payload_type = enum varint. Tag = (5<<3)|0 = 0x28.
        body.append(0x28)
        appendVarint(&body, UInt64(message.payloadType.rawValue))
        // Field 6: payload_utf8.
        if message.payloadType == .string {
            appendLengthDelimited(&body, tag: 0x32, value: message.payloadUTF8.data(using: .utf8) ?? Data())
        }

        var prefix = Data(count: 4)
        let len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: len) { src in
            prefix.replaceSubrange(0..<4, with: src)
        }
        return prefix + body
    }

    /// Attempt to decode one full frame from the head of `buffer`. Returns
    /// `nil` if not enough bytes are present yet. On success, slices the
    /// consumed bytes out of `buffer`.
    static func decode(from buffer: inout Data) -> CastMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let body = buffer.subdata(in: 4..<(4 + Int(length)))
        buffer.removeSubrange(0..<(4 + Int(length)))
        return decodeBody(body)
    }

    /// Decode a `CastMessage` body (post-length-prefix). Visible for tests.
    static func decodeBody(_ data: Data) -> CastMessage? {
        var sourceId = CastMessage.defaultDestination
        var destinationId = CastMessage.defaultSource
        var namespace = ""
        var payloadType: CastMessage.PayloadType = .string
        var payloadUTF8 = ""

        var index = 0
        while index < data.count {
            let tag = data[index]
            index += 1
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)

            switch (fieldNumber, wireType) {
            case (1, 0): // protocol_version
                _ = readVarint(data, index: &index)
            case (2, 2):
                sourceId = readString(data, index: &index) ?? sourceId
            case (3, 2):
                destinationId = readString(data, index: &index) ?? destinationId
            case (4, 2):
                namespace = readString(data, index: &index) ?? namespace
            case (5, 0):
                if let raw = readVarint(data, index: &index),
                   let pt = CastMessage.PayloadType(rawValue: Int(raw)) {
                    payloadType = pt
                }
            case (6, 2):
                payloadUTF8 = readString(data, index: &index) ?? payloadUTF8
            case (7, 2):
                // payload_binary — skip; we don't use it.
                if let raw = readLengthDelimited(data, index: &index) {
                    _ = raw
                }
            default:
                if !skipUnknown(data, index: &index, wireType: wireType) {
                    return nil
                }
            }
        }

        return CastMessage(
            sourceId: sourceId,
            destinationId: destinationId,
            namespace: namespace,
            payloadUTF8: payloadUTF8,
            payloadType: payloadType
        )
    }
}

// MARK: - Varint / wire helpers

private func appendVarint(_ data: inout Data, _ value: UInt64) {
    var v = value
    while v >= 0x80 {
        data.append(UInt8(v & 0x7F) | 0x80)
        v >>= 7
    }
    data.append(UInt8(v))
}

private func appendLengthDelimited(_ data: inout Data, tag: UInt8, value: Data) {
    data.append(tag)
    appendVarint(&data, UInt64(value.count))
    data.append(value)
}

private func readVarint(_ data: Data, index: inout Int) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while index < data.count {
        let byte = data[index]
        index += 1
        result |= UInt64(byte & 0x7F) << shift
        if (byte & 0x80) == 0 { return result }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

private func readLengthDelimited(_ data: Data, index: inout Int) -> Data? {
    guard let len = readVarint(data, index: &index) else { return nil }
    let end = index + Int(len)
    guard end <= data.count else { return nil }
    let slice = data.subdata(in: index..<end)
    index = end
    return slice
}

private func readString(_ data: Data, index: inout Int) -> String? {
    guard let bytes = readLengthDelimited(data, index: &index) else { return nil }
    return String(data: bytes, encoding: .utf8)
}

private func skipUnknown(_ data: Data, index: inout Int, wireType: Int) -> Bool {
    switch wireType {
    case 0: _ = readVarint(data, index: &index); return true
    case 2: _ = readLengthDelimited(data, index: &index); return true
    case 5: index += 4; return index <= data.count
    case 1: index += 8; return index <= data.count
    default: return false
    }
}
