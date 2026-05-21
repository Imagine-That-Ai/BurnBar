import Foundation

public struct MediaFrameV2: Sendable, Equatable {
    public struct Kind: RawRepresentable, Sendable, Codable, Equatable, Hashable {
        public var rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let videoNAL = Kind(rawValue: 0x01)
        public static let audioOpus = Kind(rawValue: 0x02)
        public static let videoDatagram = Kind(rawValue: 0x03)
        public static let rtcSenderReport = Kind(rawValue: 0x11)
        public static let rtcReceiverReport = Kind(rawValue: 0x12)
        public static let rpsRecoveryRequest = Kind(rawValue: 0x13)
        public static let codecNegotiation = Kind(rawValue: 0x14)
    }

    public var kind: Kind
    public var flags: UInt16
    public var gopID: UInt32
    public var frameIndex: UInt32
    public var presentationTimestampMillis: UInt64
    public var metadata: Data
    public var payload: Data

    public init(
        kind: Kind,
        flags: UInt16 = 0,
        gopID: UInt32 = 0,
        frameIndex: UInt32 = 0,
        presentationTimestampMillis: UInt64 = 0,
        metadata: Data = Data(),
        payload: Data = Data()
    ) {
        self.kind = kind
        self.flags = flags
        self.gopID = gopID
        self.frameIndex = frameIndex
        self.presentationTimestampMillis = presentationTimestampMillis
        self.metadata = metadata
        self.payload = payload
    }
}

public struct MediaFrameV2Metadata: Codable, Sendable, Equatable {
    /// Codec used for this frame. This is descriptive metadata for receivers
    /// and benchmark traces; codec selection still happens during negotiation.
    public var codec: MercuryVideoCodec?
    /// VideoToolbox LTR acknowledgement token returned on the encoded sample.
    /// Receivers ACK this value only after successful receipt/decode.
    public var longTermReferenceToken: MercuryLTRToken?

    public init(
        codec: MercuryVideoCodec? = nil,
        longTermReferenceToken: MercuryLTRToken? = nil
    ) {
        self.codec = codec
        self.longTermReferenceToken = longTermReferenceToken
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MediaFrameV2Metadata {
        guard !data.isEmpty else { return MediaFrameV2Metadata() }
        return try JSONDecoder().decode(MediaFrameV2Metadata.self, from: data)
    }
}

public struct MediaFrameV2Codec: Sendable {
    public enum CodecError: Error, Equatable, Sendable {
        case notNegotiated
        case envelopeTooShort
        case invalidMagic
        case unsupportedVersion(UInt8)
        case payloadTooLarge(actual: Int, max: Int)
        case headerTruncated
    }

    public static let magic = Data([0x4F, 0x42, 0x4D, 0x46, 0x56, 0x32]) // OBMFV2
    public static let version: UInt8 = 2
    public static let fixedHeaderByteCount = 34
    public static let defaultMaxPayloadBytes: Int = 256 * 1024

    public let maxPayloadBytes: Int

    public init(maxPayloadBytes: Int = MediaFrameV2Codec.defaultMaxPayloadBytes) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    public static func isEncodedEnvelope(_ envelope: Data) -> Bool {
        let headerStart = 4
        guard envelope.count >= headerStart + Self.magic.count else { return false }
        let normalized: Data = envelope.withUnsafeBytes { Data($0) }
        return normalized.subdata(in: headerStart..<(headerStart + Self.magic.count)) == Self.magic
    }

    public func encode(
        _ frame: MediaFrameV2,
        negotiatedVersion: MercuryMediaFrameWireVersion
    ) throws -> Data {
        guard negotiatedVersion == .v2 else { throw CodecError.notNegotiated }
        let totalPayloadCount = Self.fixedHeaderByteCount + frame.metadata.count + frame.payload.count
        guard totalPayloadCount <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(actual: totalPayloadCount, max: maxPayloadBytes)
        }

        var envelope = Data(capacity: 4 + totalPayloadCount)
        appendUInt32BigEndian(UInt32(totalPayloadCount), to: &envelope)
        envelope.append(Self.magic)
        envelope.append(Self.version)
        envelope.append(frame.kind.rawValue)
        appendUInt16BigEndian(frame.flags, to: &envelope)
        appendUInt32BigEndian(frame.gopID, to: &envelope)
        appendUInt32BigEndian(frame.frameIndex, to: &envelope)
        appendUInt64BigEndian(frame.presentationTimestampMillis, to: &envelope)
        appendUInt32BigEndian(UInt32(frame.metadata.count), to: &envelope)
        appendUInt32BigEndian(UInt32(frame.payload.count), to: &envelope)
        envelope.append(frame.metadata)
        envelope.append(frame.payload)
        return envelope
    }

    public func decode(_ envelope: Data) throws -> (frame: MediaFrameV2, consumed: Int) {
        let lengthPrefixBytes = 4
        guard envelope.count >= lengthPrefixBytes + Self.fixedHeaderByteCount else {
            throw CodecError.envelopeTooShort
        }

        let normalized: Data = envelope.withUnsafeBytes { Data($0) }
        let totalPayloadCount = Int(readUInt32BigEndian(from: normalized, at: 0))
        guard totalPayloadCount <= maxPayloadBytes else {
            throw CodecError.payloadTooLarge(actual: totalPayloadCount, max: maxPayloadBytes)
        }
        let totalEnvelopeBytes = lengthPrefixBytes + totalPayloadCount
        guard normalized.count >= totalEnvelopeBytes else {
            throw CodecError.headerTruncated
        }

        let headerStart = lengthPrefixBytes
        guard normalized.subdata(in: headerStart..<(headerStart + Self.magic.count)) == Self.magic else {
            throw CodecError.invalidMagic
        }
        let version = normalized[headerStart + Self.magic.count]
        guard version == Self.version else { throw CodecError.unsupportedVersion(version) }

        let kindOffset = headerStart + Self.magic.count + 1
        let kind = MediaFrameV2.Kind(rawValue: normalized[kindOffset])
        let flags = readUInt16BigEndian(from: normalized, at: kindOffset + 1)
        let gopID = readUInt32BigEndian(from: normalized, at: kindOffset + 3)
        let frameIndex = readUInt32BigEndian(from: normalized, at: kindOffset + 7)
        let pts = readUInt64BigEndian(from: normalized, at: kindOffset + 11)
        let metadataCount = Int(readUInt32BigEndian(from: normalized, at: kindOffset + 19))
        let payloadCount = Int(readUInt32BigEndian(from: normalized, at: kindOffset + 23))
        let metadataStart = headerStart + Self.fixedHeaderByteCount
        let metadataEnd = metadataStart + metadataCount
        let payloadEnd = metadataEnd + payloadCount
        guard payloadEnd <= totalEnvelopeBytes else {
            throw CodecError.headerTruncated
        }

        return (
            MediaFrameV2(
                kind: kind,
                flags: flags,
                gopID: gopID,
                frameIndex: frameIndex,
                presentationTimestampMillis: pts,
                metadata: normalized.subdata(in: metadataStart..<metadataEnd),
                payload: normalized.subdata(in: metadataEnd..<payloadEnd)
            ),
            totalEnvelopeBytes
        )
    }

    private func appendUInt16BigEndian(_ value: UInt16, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt32BigEndian(_ value: UInt32, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func appendUInt64BigEndian(_ value: UInt64, to data: inout Data) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private func readUInt16BigEndian(from data: Data, at offset: Int) -> UInt16 {
        var raw: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 2))
        }
        return UInt16(bigEndian: raw)
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
