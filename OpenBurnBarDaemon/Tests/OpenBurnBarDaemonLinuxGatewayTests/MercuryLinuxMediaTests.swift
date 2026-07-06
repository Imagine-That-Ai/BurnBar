#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarCore
import OpenBurnBarIrohRelay
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

    func testSessionForwardsCapturedFramesAsOutboundRelayMedia() async throws {
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
        XCTAssertNil(streamFrame.media?.sealedFramePosition)

        let encodedBase64 = try XCTUnwrap(streamFrame.media?.encodedFrameBase64)
        let encoded = try XCTUnwrap(Data(base64Encoded: encodedBase64))
        let decoded = try MediaPacketCodec().decode(encoded).frame
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

        let fileListRequest = BurnBarRPCRequestEnvelope(id: "file-list", method: .daemonMediaFileOfferList)
        let fileListResponse: BurnBarRPCResponseEnvelope<DaemonMediaFileOfferListResponse> = try await invoke(
            server: server,
            method: .daemonMediaFileOfferList,
            request: fileListRequest,
            requestData: try JSONEncoder().encode(fileListRequest),
            decoder: decoder
        )
        XCTAssertNotNil(fileListResponse.result)

        let fileAccept = BurnBarRPCRequestEnvelopeWithParams(
            id: "file-accept",
            method: .daemonMediaFileAccept,
            params: DaemonMediaFileAcceptRequest(transferID: "missing")
        )
        let fileAcceptResponse: BurnBarRPCResponseEnvelope<DaemonMediaFileActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaFileAccept,
            request: BurnBarRPCRequestEnvelope(id: fileAccept.id, method: fileAccept.method),
            requestData: try JSONEncoder().encode(fileAccept),
            decoder: decoder
        )
        XCTAssertEqual(fileAcceptResponse.result?.accepted, false)

        let fileDecline = BurnBarRPCRequestEnvelopeWithParams(
            id: "file-decline",
            method: .daemonMediaFileDecline,
            params: DaemonMediaFileDeclineRequest(transferID: "missing", reason: "test")
        )
        let fileDeclineResponse: BurnBarRPCResponseEnvelope<DaemonMediaFileActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaFileDecline,
            request: BurnBarRPCRequestEnvelope(id: fileDecline.id, method: fileDecline.method),
            requestData: try JSONEncoder().encode(fileDecline),
            decoder: decoder
        )
        XCTAssertEqual(fileDeclineResponse.result?.accepted, false)

        let fileSend = BurnBarRPCRequestEnvelopeWithParams(
            id: "file-send",
            method: .daemonMediaFileSend,
            params: DaemonMediaFileSendRequest(path: "/tmp/openburnbar-missing-\(UUID().uuidString)")
        )
        let fileSendResponse: BurnBarRPCResponseEnvelope<DaemonMediaFileActionResponse> = try await invoke(
            server: server,
            method: .daemonMediaFileSend,
            request: BurnBarRPCRequestEnvelope(id: fileSend.id, method: fileSend.method),
            requestData: try JSONEncoder().encode(fileSend),
            decoder: decoder
        )
        XCTAssertEqual(fileSendResponse.result?.accepted, false)

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

    func testFileOfferAcceptDownloadsToCollisionSafePathAndAcknowledges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-file-accept-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: downloads.appendingPathComponent("report.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let received = Data("downloaded from phone".utf8)
        let backend = InMemoryIrohBlobBackend(fetchBodies: ["ticket-in": received])
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: root.appendingPathComponent("BlobStore", isDirectory: true),
                inboxDirectoryURL: root.appendingPathComponent("Inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x11, count: 32) }
            )
        )
        let controller = MercuryLinuxMediaSessionController(
            fileTransferService: service,
            downloadDirectoryProvider: { downloads }
        )
        let replies = RecordingMercuryReplies()

        await controller.ingestMercuryFrame(
            fileAdvertiseFrame(filename: "report.txt", ticket: "ticket-in", size: Int64(received.count))
        ) { frame in
            await replies.append(frame)
        }

        let pendingList = await controller.fileOfferList()
        XCTAssertTrue(pendingList.capabilityAvailable)
        XCTAssertEqual(pendingList.transfers.first?.phase, .pendingAccept)

        let accept = await controller.acceptFile(DaemonMediaFileAcceptRequest(transferID: pendingList.transfers.first?.transferID))
        XCTAssertTrue(accept.accepted)

        let completed = try await waitForTransfer(
            controller: controller,
            transferID: pendingList.transfers.first?.transferID,
            phase: .completed
        )
        XCTAssertEqual(completed.filename, "report.txt")
        XCTAssertEqual(completed.localPath?.hasSuffix("report (1).txt"), true)
        XCTAssertEqual(completed.progress.bytesTransferred, Int64(received.count))
        XCTAssertEqual(completed.progress.fraction, 1.0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(completed.localPath))), received)

        let sent = await replies.frames
        XCTAssertEqual(sent.last?.type, .mediaBlobAck)
        XCTAssertEqual(sent.last?.media?.ack?.status, .received)
        XCTAssertEqual(backend.fetchCallCount, 1)
    }

    func testFileOfferDeclineSendsRejectedAckWithoutFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-file-decline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let backend = InMemoryIrohBlobBackend(fetchBodies: ["ticket-in": Data("unused".utf8)])
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: root.appendingPathComponent("BlobStore", isDirectory: true),
                inboxDirectoryURL: root.appendingPathComponent("Inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x22, count: 32) }
            )
        )
        let controller = MercuryLinuxMediaSessionController(
            fileTransferService: service,
            downloadDirectoryProvider: { root.appendingPathComponent("Downloads", isDirectory: true) }
        )
        let replies = RecordingMercuryReplies()

        await controller.ingestMercuryFrame(fileAdvertiseFrame(ticket: "ticket-in")) { frame in
            await replies.append(frame)
        }
        let transferID = await controller.fileOfferList().transfers.first?.transferID
        let declined = await controller.declineFile(
            DaemonMediaFileDeclineRequest(transferID: transferID, reason: "not now")
        )

        XCTAssertTrue(declined.accepted)
        XCTAssertEqual(declined.transfer?.phase, .declined)
        let sent = await replies.frames
        XCTAssertEqual(sent.last?.media?.ack?.status, .rejected)
        XCTAssertEqual(sent.last?.media?.ack?.reason, "not now")
        XCTAssertEqual(backend.fetchCallCount, 0)
    }

    func testCollisionSafeDownloadNaming() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-file-collision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("photo.png"))
        try Data().write(to: root.appendingPathComponent("photo (1).png"))

        let next = try MercuryLinuxMediaSessionController.collisionSafeDownloadURL(
            filename: "../photo.png",
            in: root
        )
        XCTAssertEqual(next.lastPathComponent, "-photo.png")

        let collided = try MercuryLinuxMediaSessionController.collisionSafeDownloadURL(
            filename: "photo.png",
            in: root
        )
        XCTAssertEqual(collided.lastPathComponent, "photo (2).png")
    }

    func testFileTransferErrorTaxonomy() async throws {
        let noEngine = MercuryLinuxMediaSessionController()
        let noEngineSend = await noEngine.sendFile(DaemonMediaFileSendRequest(path: "/tmp/missing"))
        XCTAssertEqual(noEngineSend.errorCode, .capabilityAbsent)
        XCTAssertFalse(noEngineSend.accepted)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-file-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("send.txt", isDirectory: false)
        try Data("hello".utf8).write(to: localFile)
        let service = MediaFileTransferService(
            backend: InMemoryIrohBlobBackend(fetchBodies: [:]),
            configuration: .init(
                storeDirectoryURL: root.appendingPathComponent("BlobStore", isDirectory: true),
                inboxDirectoryURL: root.appendingPathComponent("Inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0x33, count: 32) }
            )
        )
        let controller = MercuryLinuxMediaSessionController(
            fileTransferService: service,
            downloadDirectoryProvider: { root.appendingPathComponent("Downloads", isDirectory: true) }
        )

        let missingAccept = await controller.acceptFile(DaemonMediaFileAcceptRequest(transferID: "missing"))
        XCTAssertEqual(missingAccept.errorCode, .transferNotFound)

        let missingFile = await controller.sendFile(
            DaemonMediaFileSendRequest(path: root.appendingPathComponent("missing.txt").path)
        )
        XCTAssertEqual(missingFile.errorCode, .localFileMissing)

        let noRoute = await controller.sendFile(DaemonMediaFileSendRequest(path: localFile.path))
        XCTAssertEqual(noRoute.errorCode, .noControlRoute)
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

    private func fileAdvertiseFrame(
        filename: String = "notes.txt",
        ticket: String = "ticket",
        size: Int64 = 0
    ) -> HermesRealtimeRelayFrame {
        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "manifest-\(UUID().uuidString)",
            blobHash: "blob-hash",
            filename: filename,
            mime: "text/plain",
            size: size,
            peerDeviceId: "iphone",
            createdAt: Date()
        )
        return HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: "uid-1",
            connectionId: "conn-1",
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: manifest,
                blobTicket: ticket
            )
        )
    }

    private func waitForTransfer(
        controller: MercuryLinuxMediaSessionController,
        transferID: String?,
        phase: DaemonMediaFileTransferPhase,
        timeout: TimeInterval = 2
    ) async throws -> DaemonMediaFileTransferSnapshot {
        let transferID = try XCTUnwrap(transferID)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let list = await controller.fileOfferList()
            if let transfer = list.transfers.first(where: { $0.transferID == transferID }),
               transfer.phase == phase {
                return transfer
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for transfer \(transferID) to reach \(phase.rawValue)")
        throw CocoaError(.featureUnsupported)
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

private final class InMemoryIrohBlobBackend: IrohBlobBackend, @unchecked Sendable {
    private var fetchBodies: [String: Data]
    private(set) var fetchCallCount = 0
    private(set) var publishedPaths: [String] = []
    private var bootstrapped = false

    init(fetchBodies: [String: Data]) {
        self.fetchBodies = fetchBodies
    }

    func bootstrap(
        secret: Data,
        storeDirectoryPath: String,
        relayURL: String?
    ) async throws -> IrohEndpointIdentity {
        XCTAssertEqual(secret.count, 32)
        try FileManager.default.createDirectory(
            atPath: storeDirectoryPath,
            withIntermediateDirectories: true
        )
        bootstrapped = true
        return IrohEndpointIdentity(
            nodeId: "test-node",
            rawPublicKey: Data(repeating: 0xAB, count: 32),
            relayURL: relayURL
        )
    }

    func publishBlob(localPath: String) async throws -> String {
        guard bootstrapped else { throw IrohBlobBackendError.notInitialized }
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw IrohBlobBackendError.publishFailed("missing")
        }
        publishedPaths.append(localPath)
        return "ticket-\((localPath as NSString).lastPathComponent)"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        guard bootstrapped else { throw IrohBlobBackendError.notInitialized }
        guard let data = fetchBodies[ticketText] else {
            throw IrohBlobBackendError.invalidTicket(ticketText)
        }
        try FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try data.write(to: URL(fileURLWithPath: destination), options: [.atomic])
        fetchCallCount += 1
        return BlobTransferStats(
            bytesTotal: UInt64(data.count),
            blake3Hash: "fake-hash",
            durationMillis: 1,
            didResume: false
        )
    }

    func fetchBlob(
        ticketText: String,
        destination: String,
        expectedSizeBytes: UInt64
    ) async throws -> BlobTransferStats {
        let stats = try await fetchBlob(ticketText: ticketText, destination: destination)
        guard stats.bytesTotal <= expectedSizeBytes else {
            throw IrohBlobBackendError.fetchFailed("too large")
        }
        return stats
    }

    func identity() async throws -> IrohEndpointIdentity {
        guard bootstrapped else { throw IrohBlobBackendError.notInitialized }
        return IrohEndpointIdentity(
            nodeId: "test-node",
            rawPublicKey: Data(repeating: 0xAB, count: 32)
        )
    }

    func shutdown() async {
        bootstrapped = false
    }
}
#endif
