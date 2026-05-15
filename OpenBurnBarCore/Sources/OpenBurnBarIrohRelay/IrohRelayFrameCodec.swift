import Foundation
import OpenBurnBarCore

/// Length-prefixed JSON codec for `HermesRealtimeRelayFrame`. The Rust crate
/// writes `[u32 big-endian length][JSON payload]` onto the iroh QUIC stream;
/// this Swift type reads/writes the exact same byte layout so the wire format
/// is identical across transports.
public struct IrohRelayFrameCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxFrameBytes: Int

    public init(maxFrameBytes: Int = IrohRelayProtocol.maxFrameBytes) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        // Drop nils so the on-wire shape matches the Cloud Run relay's
        // `serializeFrame` helper which never emits keys with `undefined`.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.maxFrameBytes = maxFrameBytes
    }

    /// Encode a frame into the wire envelope. Throws if the encoded payload
    /// would exceed `maxFrameBytes`.
    public func encode(_ frame: HermesRealtimeRelayFrame) throws -> Data {
        let payload = try encoder.encode(frame)
        guard payload.count <= maxFrameBytes else {
            throw IrohRelayTransportError.streamRejected(
                "iroh relay frame is \(payload.count) bytes, exceeds \(maxFrameBytes)."
            )
        }
        var envelope = Data(capacity: payload.count + IrohRelayProtocol.WireFormat.lengthPrefixBytes)
        var lengthBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { envelope.append(contentsOf: $0) }
        envelope.append(payload)
        return envelope
    }

    /// Decode an inbound envelope. Surface returns the payload byte range we
    /// consumed so the caller can drain a buffered transport that may have
    /// concatenated several frames. Always re-bases the input view to start
    /// index 0 because `Data.removeFirst(_:)` does not normalize indices in
    /// Foundation, and callers like the loopback transport mutate the buffer
    /// in place between frames.
    public func decode(from envelope: Data) throws -> (frame: HermesRealtimeRelayFrame, consumed: Int) {
        let lengthPrefix = IrohRelayProtocol.WireFormat.lengthPrefixBytes
        guard envelope.count >= lengthPrefix else {
            throw IrohRelayTransportError.decodeFailed("iroh frame envelope is shorter than length prefix.")
        }
        let normalized: Data = envelope.withUnsafeBytes { buffer -> Data in
            Data(buffer)
        }
        var lengthBE: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &lengthBE) { dest in
            normalized.copyBytes(to: dest, from: 0..<lengthPrefix)
        }
        let length = Int(UInt32(bigEndian: lengthBE))
        guard length <= maxFrameBytes else {
            throw IrohRelayTransportError.streamRejected(
                "iroh relay inbound frame is \(length) bytes, exceeds \(maxFrameBytes)."
            )
        }
        let totalBytes = lengthPrefix + length
        guard normalized.count >= totalBytes else {
            throw IrohRelayTransportError.decodeFailed("iroh relay envelope is truncated.")
        }
        let payload = normalized.subdata(in: lengthPrefix..<totalBytes)
        do {
            let frame = try decoder.decode(HermesRealtimeRelayFrame.self, from: payload)
            return (frame, totalBytes)
        } catch {
            throw IrohRelayTransportError.decodeFailed(error.localizedDescription)
        }
    }
}
