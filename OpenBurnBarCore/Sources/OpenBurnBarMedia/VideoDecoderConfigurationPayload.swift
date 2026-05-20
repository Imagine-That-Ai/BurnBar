import Foundation

/// Prefix carried inside keyframe `MediaFrame.payload` values when the sender
/// needs to bootstrap a hardware decoder with codec parameter sets.
public struct VideoDecoderConfigurationPayload: Sendable, Equatable {
    public enum Codec: UInt8, Sendable, Equatable {
        case hevc = 1
        case h264 = 2
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidMagic
        case truncated
        case unknownCodec(UInt8)
        case emptyParameterSets
    }

    public static let magic = Data([0x4F, 0x42, 0x56, 0x43, 0x46, 0x47, 0x31]) // OBVCFG1

    public var codec: Codec
    public var parameterSets: [Data]
    public var samplePayload: Data

    public init(codec: Codec, parameterSets: [Data], samplePayload: Data) {
        self.codec = codec
        self.parameterSets = parameterSets
        self.samplePayload = samplePayload
    }

    public func encoded() throws -> Data {
        guard !parameterSets.isEmpty else { throw DecodeError.emptyParameterSets }
        var data = Data()
        data.append(Self.magic)
        data.append(codec.rawValue)
        data.append(UInt8(min(parameterSets.count, Int(UInt8.max))))
        for parameterSet in parameterSets.prefix(Int(UInt8.max)) {
            appendUInt16BigEndian(UInt16(parameterSet.count), to: &data)
            data.append(parameterSet)
        }
        appendUInt32BigEndian(UInt32(samplePayload.count), to: &data)
        data.append(samplePayload)
        return data
    }

    public static func decodeIfPresent(_ data: Data) throws -> VideoDecoderConfigurationPayload? {
        guard data.count >= magic.count else { return nil }
        guard data.prefix(magic.count) == magic else { return nil }

        var offset = magic.count
        guard data.count >= offset + 2 else { throw DecodeError.truncated }
        let codecByte = data[offset]
        offset += 1
        guard let codec = Codec(rawValue: codecByte) else {
            throw DecodeError.unknownCodec(codecByte)
        }
        let count = Int(data[offset])
        offset += 1
        guard count > 0 else { throw DecodeError.emptyParameterSets }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(count)
        for _ in 0..<count {
            guard data.count >= offset + 2 else { throw DecodeError.truncated }
            let length = Int(readUInt16BigEndian(from: data, at: offset))
            offset += 2
            guard data.count >= offset + length else { throw DecodeError.truncated }
            parameterSets.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }

        guard data.count >= offset + 4 else { throw DecodeError.truncated }
        let sampleLength = Int(readUInt32BigEndian(from: data, at: offset))
        offset += 4
        guard data.count >= offset + sampleLength else { throw DecodeError.truncated }
        let samplePayload = data.subdata(in: offset..<(offset + sampleLength))
        return VideoDecoderConfigurationPayload(
            codec: codec,
            parameterSets: parameterSets,
            samplePayload: samplePayload
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

    private static func readUInt16BigEndian(from data: Data, at offset: Int) -> UInt16 {
        var raw: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 2))
        }
        return UInt16(bigEndian: raw)
    }

    private static func readUInt32BigEndian(from data: Data, at offset: Int) -> UInt32 {
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(bigEndian: raw)
    }
}
