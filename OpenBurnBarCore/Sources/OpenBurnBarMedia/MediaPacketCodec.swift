import Foundation

/// Length-prefixed binary codec for Mercury media frames. Same outer layout
/// as `IrohRelayFrameCodec` (4-byte big-endian length prefix) so the two
/// codecs can share the underlying QUIC stream framing and an audit reader
/// can locate frame boundaries without knowing whether the payload is JSON
/// chat or a binary media frame.
///
/// ```
/// [ u32 BE total payload length ][ MediaFrame.headerByteCount header ][ payload ]
/// ```
public struct MediaPacketCodec: Sendable {
    public enum CodecError: Error, Equatable, Sendable {
        case envelopeTooShort
        case payloadTooLarge(actual: Int, max: Int)
        case headerTruncated
        case unknownKind(UInt8)
    }

    /// Hard ceiling on a single media frame. Matches the iroh-blobs default
    /// chunk size so a packet that exceeds it is almost certainly a producer
    /// bug or a hostile peer.
    public static let defaultMaxPayloadBytes: Int = 256 * 1024

    public let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = MediaPacketCodec.defaultMaxPayloadBytes) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public func encode(_ frame: MediaFrame) throws -> Data {
        let totalPayloadCount = MediaFrame.headerByteCount + frame.payload.count
        guard totalPayloadCount <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(actual: totalPayloadCount, max: maxPayloadBytes)
        }

        var envelope = Data(capacity: 4 + totalPayloadCount)
        appendUInt32BigEndian(UInt32(totalPayloadCount), to: &envelope)

        // Header
        envelope.append(frame.kind.rawValue)
        envelope.append(frame.flags.rawValue)
        appendUInt32BigEndian(frame.gopID, to: &envelope)
        appendUInt32BigEndian(frame.frameIndex, to: &envelope)
        appendUInt64BigEndian(frame.presentationTimestampMillis, to: &envelope)
        envelope.append(frame.payload)

        return envelope
    }

    public func decode(_ envelope: Data) throws -> (frame: MediaFrame, consumed: Int) {
        let lengthPrefixBytes = 4
        guard envelope.count >= lengthPrefixBytes + MediaFrame.headerByteCount else {
            throw CodecError.envelopeTooShort
        }

        // Re-base the input view so byte indices start at zero. Foundation's
        // `Data.removeFirst(_:)` does not normalize indices and the same
        // bug bit `IrohRelayFrameCodec` historically — copying through a
        // raw-buffer view is the canonical fix in this repo.
        let normalized: Data = envelope.withUnsafeBytes { buffer in
            Data(buffer)
        }

        let totalPayloadCount = Int(readUInt32BigEndian(from: normalized, at: 0))
        guard totalPayloadCount <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(actual: totalPayloadCount, max: maxPayloadBytes)
        }
        let totalEnvelopeBytes = lengthPrefixBytes + totalPayloadCount
        guard normalized.count >= totalEnvelopeBytes else {
            throw CodecError.headerTruncated
        }

        let headerStart = lengthPrefixBytes
        let kindByte = normalized[headerStart]
        guard let kind = MediaFrame.Kind(rawValue: kindByte) else {
            throw CodecError.unknownKind(kindByte)
        }
        let flags = MediaFrame.Flags(rawValue: normalized[headerStart + 1])
        let gopID = readUInt32BigEndian(from: normalized, at: headerStart + 2)
        let frameIndex = readUInt32BigEndian(from: normalized, at: headerStart + 6)
        let pts = readUInt64BigEndian(from: normalized, at: headerStart + 10)

        let payloadStart = headerStart + MediaFrame.headerByteCount
        let payloadEnd = lengthPrefixBytes + totalPayloadCount
        let payload = normalized.subdata(in: payloadStart..<payloadEnd)

        let frame = MediaFrame(
            kind: kind,
            flags: flags,
            gopID: gopID,
            frameIndex: frameIndex,
            presentationTimestampMillis: pts,
            payload: payload
        )
        return (frame, totalEnvelopeBytes)
    }

    // MARK: Wire helpers

    private func appendUInt32BigEndian(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt64BigEndian(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func readUInt32BigEndian(from data: Data, at offset: Int) -> UInt32 {
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(bigEndian: raw)
    }

    private func readUInt64BigEndian(from data: Data, at offset: Int) -> UInt64 {
        var raw: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 8))
        }
        return UInt64(bigEndian: raw)
    }
}
