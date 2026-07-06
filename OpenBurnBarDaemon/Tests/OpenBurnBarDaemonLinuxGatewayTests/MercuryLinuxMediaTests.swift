#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBarDaemon
import XCTest

final class MercuryLinuxMediaTests: XCTestCase {
    func testMediaChannelWritesLengthPrefixedShellFrames() throws {
        let socketPath = "/tmp/obb-media-\(UUID().uuidString).sock"
        let channel = try MercuryLinuxMediaChannel(socketPath: socketPath, maxQueuedFrames: 4)
        try channel.start()
        defer { channel.stop() }

        let client = try connectUnixSocket(path: socketPath)
        defer { close(client) }

        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            presentationTimestampMillis: 0x0102_0304_0506_0708,
            payload: payload
        )
        XCTAssertTrue(channel.offer(frame))

        let bytes = try readExact(fileDescriptor: client, count: 4 + 1 + 1 + 8 + payload.count)
        XCTAssertEqual(readUInt32BE(bytes, at: 0), UInt32(1 + 1 + 8 + payload.count))
        XCTAssertEqual(bytes[4], MediaFrame.Kind.videoNAL.rawValue)
        XCTAssertEqual(bytes[5], MediaFrame.Flags.keyframe.rawValue)
        XCTAssertEqual(readUInt64BE(bytes, at: 6), 0x0102_0304_0506_0708)
        XCTAssertEqual(bytes.suffix(payload.count), payload)
    }

    func testSessionPhaseTransitionsAndAckEmission() async throws {
        let channel = try MercuryLinuxMediaChannel(
            socketPath: "/tmp/obb-media-\(UUID().uuidString).sock",
            maxQueuedFrames: 4
        )
        let controller = MercuryLinuxMediaSessionController(channel: channel)
        try await controller.start()
        defer { channel.stop() }

        let replies = RecordingMercuryReplies()
        let request = mirrorRequestFrame()
        await controller.ingestMercuryFrame(request, remotePeerNodeID: "phone-node") { frame in
            await replies.append(frame)
        }

        var snapshot = await controller.sessionSnapshot()
        XCTAssertEqual(snapshot.phase, .ringing)
        XCTAssertEqual(snapshot.kind, .mirror)
        XCTAssertEqual(snapshot.requestID, "mirror-1")
        XCTAssertEqual(snapshot.peer?.displayName, "Alberto iPhone")

        let accept = await controller.accept(DaemonMediaCallAcceptRequest(requestID: "mirror-1", sessionID: "session-1"))
        XCTAssertTrue(accept.accepted)
        snapshot = await controller.sessionSnapshot()
        XCTAssertEqual(snapshot.phase, .streaming)
        XCTAssertEqual(snapshot.sessionID, "session-1")

        let sent = await replies.frames
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.type, .mediaMirrorAck)
        XCTAssertEqual(sent.first?.media?.mirrorAck?.decision, .accepted)
        XCTAssertEqual(sent.first?.media?.mirrorAck?.sessionId, "session-1")

        let ended = await controller.end(DaemonMediaCallEndRequest(sessionID: "session-1", reason: "test"))
        XCTAssertTrue(ended.accepted)
        XCTAssertEqual(ended.session.phase, .cooldown)
    }

    // Fail closed: with no established media seal key, a captured frame must
    // NOT egress as plaintext — the session drops to cooldown instead.
    func testCapturedFrameWithoutSealKeyFailsClosedAndDoesNotEgressPlaintext() async throws {
        let channel = try MercuryLinuxMediaChannel(
            socketPath: "/tmp/obb-media-\(UUID().uuidString).sock",
            maxQueuedFrames: 4
        )
        let controller = MercuryLinuxMediaSessionController(channel: channel)
        try await controller.start()
        defer { channel.stop() }

        let replies = RecordingMercuryReplies()
        await controller.ingestMercuryFrame(mirrorRequestFrame(), remotePeerNodeID: "phone-node") { frame in
            await replies.append(frame)
        }
        let accept = await controller.accept(DaemonMediaCallAcceptRequest(requestID: "mirror-1", sessionID: "session-1"))
        XCTAssertTrue(accept.accepted)

        await controller.ingestCapturedFrame(MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            presentationTimestampMillis: 777,
            payload: Data([0xAB, 0xCD, 0xEF])
        ))

        // Only the mirror ack was ever sent — no stream frame egressed.
        let sent = await replies.frames
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.type, .mediaMirrorAck)
        XCTAssertFalse(sent.contains { $0.type == .mediaStreamFrame })
        let snapshot = await controller.sessionSnapshot()
        XCTAssertEqual(snapshot.phase, .cooldown)
    }

    // With an established seal key, captured frames egress SEALED (AEAD), never
    // plaintext — the sealed envelope opens back to the original frame.
    func testSessionForwardsCapturedFramesSealed() async throws {
        let channel = try MercuryLinuxMediaChannel(
            socketPath: "/tmp/obb-media-\(UUID().uuidString).sock",
            maxQueuedFrames: 4
        )
        let controller = MercuryLinuxMediaSessionController(channel: channel)
        try await controller.start()
        defer { channel.stop() }

        let replies = RecordingMercuryReplies()
        await controller.ingestMercuryFrame(mirrorRequestFrame(), remotePeerNodeID: "phone-node") { frame in
            await replies.append(frame)
        }
        let accept = await controller.accept(DaemonMediaCallAcceptRequest(requestID: "mirror-1", sessionID: "session-1"))
        XCTAssertTrue(accept.accepted)

        let sealKey = PlatformSymmetricKey(size: .bits256)
        await controller.setMediaFrameSealKey(sealKey)

        let payload = Data([0xAB, 0xCD, 0xEF])
        await controller.ingestCapturedFrame(MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            presentationTimestampMillis: 777,
            payload: payload
        ))

        let sent = await replies.frames
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?.type, .mediaMirrorAck)

        let streamFrame = try XCTUnwrap(sent.last)
        XCTAssertEqual(streamFrame.type, .mediaStreamFrame)
        XCTAssertEqual(streamFrame.uid, "uid-1")
        XCTAssertEqual(streamFrame.connectionId, "conn-1")
        XCTAssertEqual(streamFrame.media?.streamClass, "media.screen.video")
        // Sealed egress: the position marker is present (not plaintext).
        XCTAssertNotNil(streamFrame.media?.sealedFramePosition)

        // The sealed envelope opens back to the original frame with the key.
        let envelopeBase64 = try XCTUnwrap(streamFrame.media?.encodedFrameBase64)
        let envelope = try XCTUnwrap(Data(base64Encoded: envelopeBase64))
        let opened = try MediaFrameAEAD().open(
            envelope: envelope,
            key: sealKey,
            streamClass: "media.screen.video",
            kind: MediaFrame.Kind.videoNAL.rawValue,
            gopID: 1,
            frameIndex: 0
        )
        let decoded = try MediaPacketCodec().decode(opened).frame
        XCTAssertEqual(decoded.kind, .videoNAL)
        XCTAssertEqual(decoded.flags, [.keyframe])
        XCTAssertEqual(decoded.gopID, 1)
        XCTAssertEqual(decoded.frameIndex, 0)
        XCTAssertEqual(decoded.presentationTimestampMillis, 777)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testRPCDecodeAndDispatchForMediaMethods() async throws {
        let server = BurnBarDaemonServer()
        let decoder = JSONDecoder()

        let stateRequest = BurnBarRPCRequestEnvelope(id: "state", method: .daemonMediaSessionState)
        let stateData = try JSONEncoder().encode(stateRequest)
        let stateResponse: BurnBarRPCResponseEnvelope<DaemonMediaSessionStateResponse> = try await invoke(
            server: server,
            method: .daemonMediaSessionState,
            request: stateRequest,
            requestData: stateData,
            decoder: decoder
        )
        XCTAssertEqual(stateResponse.result?.session.phase, .idle)

        let capabilityRequest = BurnBarRPCRequestEnvelope(id: "cap", method: .daemonMediaCapabilityGet)
        let capabilityResponse: BurnBarRPCResponseEnvelope<DaemonMediaCapabilityResponse> = try await invoke(
            server: server,
            method: .daemonMediaCapabilityGet,
            request: capabilityRequest,
            requestData: try JSONEncoder().encode(capabilityRequest),
            decoder: decoder
        )
        XCTAssertEqual(capabilityResponse.result?.platform, "linux")

        let statusRequest = BurnBarRPCRequestEnvelope(id: "status", method: .daemonMediaStatus)
        let statusResponse: BurnBarRPCResponseEnvelope<DaemonMediaStatusResponse> = try await invoke(
            server: server,
            method: .daemonMediaStatus,
            request: statusRequest,
            requestData: try JSONEncoder().encode(statusRequest),
            decoder: decoder
        )
        XCTAssertEqual(statusResponse.result?.session.phase, .idle)

        let accept = BurnBarRPCRequestEnvelopeWithParams(
            id: "accept",
            method: .daemonMediaCallAccept,
            params: DaemonMediaCallAcceptRequest(requestID: "missing")
        )
        let acceptResponse: BurnBarRPCResponseEnvelope<DaemonMediaCallActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaCallAccept,
            request: BurnBarRPCRequestEnvelope(id: accept.id, method: accept.method),
            requestData: try JSONEncoder().encode(accept),
            decoder: decoder
        )
        XCTAssertEqual(acceptResponse.result?.accepted, false)

        let decline = BurnBarRPCRequestEnvelopeWithParams(
            id: "decline",
            method: .daemonMediaCallDecline,
            params: DaemonMediaCallDeclineRequest(requestID: "missing", reason: "test")
        )
        let declineResponse: BurnBarRPCResponseEnvelope<DaemonMediaCallActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaCallDecline,
            request: BurnBarRPCRequestEnvelope(id: decline.id, method: decline.method),
            requestData: try JSONEncoder().encode(decline),
            decoder: decoder
        )
        XCTAssertEqual(declineResponse.result?.accepted, false)

        let end = BurnBarRPCRequestEnvelopeWithParams(
            id: "end",
            method: .daemonMediaCallEnd,
            params: DaemonMediaCallEndRequest(sessionID: "missing", reason: "test")
        )
        let endResponse: BurnBarRPCResponseEnvelope<DaemonMediaCallActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaCallEnd,
            request: BurnBarRPCRequestEnvelope(id: end.id, method: end.method),
            requestData: try JSONEncoder().encode(end),
            decoder: decoder
        )
        XCTAssertEqual(endResponse.result?.accepted, true)
        XCTAssertEqual(endResponse.result?.session.phase, .cooldown)
    }

    func testCapabilityProbeReportsConservativeDefaults() {
        let capability = MercuryLinuxCapabilityProbe.snapshot(mediaSocketPath: "/run/user/501/openburnbar-media.sock")
        XCTAssertTrue(capability.available)
        XCTAssertEqual(capability.mediaSocketPath, "/run/user/501/openburnbar-media.sock")
        XCTAssertTrue(capability.supportsDaemonToShellFrames)
        XCTAssertFalse(capability.supportsShellToDaemonControl)
        XCTAssertTrue(capability.codecsKnown)
        XCTAssertNotNil(capability.codecs["vp9"])
        XCTAssertNotNil(capability.codecs["opus"])
        XCTAssertEqual(capability.codecs["h264"], false)
        XCTAssertNotNil(capability.codecs["av1"])
        XCTAssertEqual(capability.source, "COpenBurnBarMediaCapture.media_capability_probe")
    }

    private func invoke<Response: Decodable>(
        server: BurnBarDaemonServer,
        method: BurnBarRPCMethod,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data,
        decoder: JSONDecoder
    ) async throws -> BurnBarRPCResponseEnvelope<Response> {
        let data = try await server.handleMediaRPC(
            method: method,
            decoder: decoder,
            request: request,
            requestData: requestData
        )
        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: data)
    }

    private func mirrorRequestFrame() -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "uid-1",
            connectionId: "conn-1",
            requestId: "mirror-1",
            media: HermesRealtimeRelayMediaPayload(
                mirrorRequest: HermesRealtimeRelayMirrorRequest(
                    requestId: "mirror-1",
                    requestedAt: Date(),
                    requesterDisplayName: "Alberto iPhone",
                    streamClass: "media.screen.video"
                )
            )
        )
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let fileDescriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fileDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.connect(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        return fileDescriptor
    }

    private func readExact(fileDescriptor: Int32, count: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: count)
        while data.count < count {
            let bytesRead = Glibc.read(fileDescriptor, &buffer, count - data.count)
            if bytesRead < 0 {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                throw POSIXError(.EPIPE)
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        var raw: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return UInt32(bigEndian: raw)
    }

    private func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        var raw: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &raw) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + 8))
        }
        return UInt64(bigEndian: raw)
    }
}

private actor RecordingMercuryReplies {
    private var stored: [HermesRealtimeRelayFrame] = []

    var frames: [HermesRealtimeRelayFrame] {
        stored
    }

    func append(_ frame: HermesRealtimeRelayFrame) {
        stored.append(frame)
    }
}
#endif
