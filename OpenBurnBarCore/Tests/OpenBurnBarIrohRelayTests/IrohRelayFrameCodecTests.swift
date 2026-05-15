import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

final class IrohRelayFrameCodecTests: XCTestCase {
    func testRoundTripPreservesEveryField() throws {
        let codec = IrohRelayFrameCodec()
        let frame = HermesRealtimeRelayFrame(
            type: .responseChunk,
            uid: "u-1",
            connectionId: "relay-mac",
            requestId: "req-42",
            protocolVersion: 1,
            runtime: "hermes",
            payload: HermesRealtimeRelayPayload(
                sequence: 7,
                kind: .sse,
                ciphertext: "ABC=="
            )
        )

        let envelope = try codec.encode(frame)
        XCTAssertGreaterThan(envelope.count, IrohRelayProtocol.WireFormat.lengthPrefixBytes)

        let (decoded, consumed) = try codec.decode(from: envelope)
        XCTAssertEqual(consumed, envelope.count)
        XCTAssertEqual(decoded, frame)
    }

    func testEncodeRejectsOversizedFrames() {
        let codec = IrohRelayFrameCodec(maxFrameBytes: 256)
        let frame = HermesRealtimeRelayFrame(
            type: .responseChunk,
            uid: "u",
            connectionId: "c",
            requestId: "r",
            payload: HermesRealtimeRelayPayload(
                sequence: 0,
                kind: .data,
                ciphertext: String(repeating: "A", count: 1024)
            )
        )

        XCTAssertThrowsError(try codec.encode(frame)) { error in
            guard let transportError = error as? IrohRelayTransportError,
                  case .streamRejected = transportError else {
                XCTFail("expected streamRejected, got \(error)")
                return
            }
        }
    }

    func testDecodeIsTransparentToBigEndianLengthPrefix() throws {
        let codec = IrohRelayFrameCodec()
        let frame = HermesRealtimeRelayFrame(
            type: .ping,
            uid: "u-1",
            connectionId: "relay-mac",
            protocolVersion: 1
        )
        let envelope = try codec.encode(frame)
        // First 4 bytes must be big-endian length.
        let length = envelope.prefix(4).reduce(0 as UInt32) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(length), envelope.count - 4)
    }

    func testDecodeRejectsTruncatedEnvelope() {
        let codec = IrohRelayFrameCodec()
        var envelope = Data([0x00, 0x00, 0x00, 0x10])
        envelope.append(contentsOf: Array(repeating: UInt8(0x7B), count: 4)) // only 4 of the promised 16
        XCTAssertThrowsError(try codec.decode(from: envelope)) { error in
            guard let transportError = error as? IrohRelayTransportError,
                  case .decodeFailed = transportError else {
                XCTFail("expected decodeFailed, got \(error)")
                return
            }
        }
    }

    func testDecodeRejectsOversizedLengthPrefix() {
        let codec = IrohRelayFrameCodec(maxFrameBytes: 32)
        let envelope = Data([0x00, 0x00, 0x10, 0x00]) // 4096 > 32
        XCTAssertThrowsError(try codec.decode(from: envelope)) { error in
            guard let transportError = error as? IrohRelayTransportError,
                  case .streamRejected = transportError else {
                XCTFail("expected streamRejected, got \(error)")
                return
            }
        }
    }
}
