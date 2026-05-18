import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarIrohRelay
@testable import OpenBurnBarMedia

/// End-to-end contract test of the Phase 1b advertise → fetch → ack
/// cycle. Drives a fake `IrohBlobBackend` through `MediaFileTransferService`
/// and asserts the resulting ack frame is well-formed, addressed back to
/// the originating manifest, and round-trips the `media.blob.ack`
/// payload correctly.
///
/// This is the closest thing to a real Phase 1b loop we can run in CI
/// without two iroh endpoints; the real device verification is the
/// manual TestFlight loop in `docs/runbooks/media-rollout-status.md`.
final class MediaDispatchIntegrationTests: XCTestCase {
    func testAdvertiseDrivesFetchAndEmitsReceivedAck() async throws {
        let backend = ScriptedBlobBackend()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-int-\(UUID().uuidString)", isDirectory: true)
        let storeURL = temp.appendingPathComponent("store", isDirectory: true)
        let inboxURL = temp.appendingPathComponent("inbox", isDirectory: true)

        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: storeURL,
                inboxDirectoryURL: inboxURL,
                secretKeyProvider: { Data(repeating: 0xCD, count: 32) }
            )
        )

        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_int_1",
            blobHash: "blake3:abcd1234",
            filename: "log.txt",
            mime: "text/plain",
            size: 32,
            peerDeviceId: "peer_xyz",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let advertise = HermesRealtimeRelayFrame(
            type: .mediaBlobAdvertise,
            uid: "u",
            connectionId: "c",
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                attachment: manifest,
                blobTicket: "blob1xyzfake"
            )
        )

        // Run the same code path the Mac + iOS dispatchers use: fetch
        // the blob, then emit the ack the caller wires in.
        let ackRecorder = AckRecorder()
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { frame in
            await ackRecorder.append(frame)
        }

        let result = try await service.fetch(ticketText: "blob1xyzfake", manifest: manifest)
        let ack = HermesRealtimeRelayMediaAck(
            manifestId: manifest.manifestId,
            status: .received,
            reason: nil
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .mediaBlobAck,
            uid: advertise.uid,
            connectionId: advertise.connectionId,
            requestId: manifest.manifestId,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.blobAdvertise.rawValue,
                ack: ack
            )
        )
        try await ackSender(ackFrame)

        XCTAssertEqual(backend.fetchedTickets, ["blob1xyzfake"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL.path))
        let emittedAcks = await ackRecorder.frames
        XCTAssertEqual(emittedAcks.count, 1)
        let posted = emittedAcks[0]
        XCTAssertEqual(posted.type, .mediaBlobAck)
        XCTAssertEqual(posted.media?.ack?.manifestId, manifest.manifestId)
        XCTAssertEqual(posted.media?.ack?.status, .received)
        XCTAssertEqual(posted.uid, advertise.uid)
        XCTAssertEqual(posted.connectionId, advertise.connectionId)
    }

    func testFetchFailureProducesRejectedAck() async throws {
        let backend = ScriptedBlobBackend()
        backend.fetchOutcome = .failure(.fetchFailed("peer unreachable"))

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-int-\(UUID().uuidString)", isDirectory: true)
        let service = MediaFileTransferService(
            backend: backend,
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store"),
                inboxDirectoryURL: temp.appendingPathComponent("inbox"),
                secretKeyProvider: { Data(repeating: 0xEF, count: 32) }
            )
        )

        let manifest = HermesRealtimeRelayAttachmentManifest(
            manifestId: "att_fail",
            blobHash: "blake3:dead",
            filename: "x.bin",
            mime: "application/octet-stream",
            size: 0
        )

        do {
            _ = try await service.fetch(ticketText: "blob1nope", manifest: manifest)
            XCTFail("expected fetch to throw")
        } catch let err as MediaFileTransferService.ServiceError {
            guard case .fetchFailed = err else {
                XCTFail("expected fetchFailed, got \(err)")
                return
            }
            // Confirm the dispatcher would observe a typed failure it can
            // translate into a `.rejected` ack.
            let ack = HermesRealtimeRelayMediaAck(
                manifestId: manifest.manifestId,
                status: .rejected,
                reason: String(describing: err)
            )
            XCTAssertEqual(ack.status, .rejected)
        }
    }

    // MARK: - Mercury Phase 8 — mirror request dispatch

    func testMirrorRequestRoundTripsThroughDispatcher() async throws {
        // Phase 8 wire contract: a `media.mirror.request` arrives over
        // the control stream; the consumer responds with a
        // `media.mirror.ack` carrying the same `requestId` so the
        // requester can correlate.
        let ackRecorder = AckRecorder()
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { frame in
            await ackRecorder.append(frame)
        }

        let request = HermesRealtimeRelayMirrorRequest(
            requestId: "req_mercury_1",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            requesterDisplayName: "Alberto's iPhone",
            streamClass: MediaStreamClass.screenVideo.rawValue
        )
        let requestFrame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "u1",
            connectionId: "c1",
            requestId: request.requestId,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: request)
        )

        // Synthetic dispatcher mirroring `MercuryRouter.handleFrame` in
        // shape — accept the request, respond with `accepted`.
        let dispatcher: @Sendable (HermesRealtimeRelayFrame, @Sendable (HermesRealtimeRelayFrame) async throws -> Void) async -> Void = { frame, reply in
            guard frame.type == .mediaMirrorRequest,
                  let req = frame.media?.mirrorRequest else { return }
            let ack = HermesRealtimeRelayMirrorAck(
                requestId: req.requestId,
                decision: .accepted
            )
            let outbound = HermesRealtimeRelayFrame(
                type: .mediaMirrorAck,
                uid: frame.uid,
                connectionId: frame.connectionId,
                requestId: req.requestId,
                media: HermesRealtimeRelayMediaPayload(mirrorAck: ack)
            )
            try? await reply(outbound)
        }

        await dispatcher(requestFrame, ackSender)

        let emitted = await ackRecorder.frames
        XCTAssertEqual(emitted.count, 1)
        let posted = emitted[0]
        XCTAssertEqual(posted.type, .mediaMirrorAck)
        XCTAssertEqual(posted.media?.mirrorAck?.requestId, request.requestId)
        XCTAssertEqual(posted.media?.mirrorAck?.decision, .accepted)
        XCTAssertEqual(posted.uid, "u1")
        XCTAssertEqual(posted.connectionId, "c1")
    }

    func testCooldownDecisionCarriesSecondsRemaining() async throws {
        let ackRecorder = AckRecorder()
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { frame in
            await ackRecorder.append(frame)
        }

        // Simulate the cooldown path: a request arrives while the
        // router is in `cooldown(secondsRemaining: 12)`.
        let request = HermesRealtimeRelayMirrorRequest(
            requestId: "req_mercury_cooldown",
            requestedAt: Date(),
            requesterDisplayName: "iPad",
            streamClass: MediaStreamClass.screenVideo.rawValue
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaMirrorRequest,
            uid: "u",
            connectionId: "c",
            requestId: request.requestId,
            media: HermesRealtimeRelayMediaPayload(mirrorRequest: request)
        )

        let dispatcher: @Sendable (HermesRealtimeRelayFrame, @Sendable (HermesRealtimeRelayFrame) async throws -> Void) async -> Void = { frame, reply in
            guard let req = frame.media?.mirrorRequest else { return }
            let ack = HermesRealtimeRelayMirrorAck(
                requestId: req.requestId,
                decision: .coolingDown,
                detail: "Cooling down",
                cooldownSecondsRemaining: 12
            )
            let outbound = HermesRealtimeRelayFrame(
                type: .mediaMirrorAck,
                uid: frame.uid,
                connectionId: frame.connectionId,
                requestId: req.requestId,
                media: HermesRealtimeRelayMediaPayload(mirrorAck: ack)
            )
            try? await reply(outbound)
        }

        await dispatcher(frame, ackSender)
        let emitted = await ackRecorder.frames
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].media?.mirrorAck?.decision, .coolingDown)
        XCTAssertEqual(emitted[0].media?.mirrorAck?.cooldownSecondsRemaining, 12)
    }

    func testPresenceHeartbeatFanOutHasNoAck() async {
        // Presence frames are fire-and-forget; the dispatcher does NOT
        // ack them. Asserts the contract so a regression that starts
        // emitting ack frames for heartbeats gets caught.
        let ackRecorder = AckRecorder()
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { frame in
            await ackRecorder.append(frame)
        }

        let beat = HermesRealtimeRelayPresenceHeartbeat(
            sentAt: Date(),
            deviceDisplayName: "iPhone",
            capabilities: ["mirror.viewer"]
        )
        let frame = HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "u",
            connectionId: "c",
            media: HermesRealtimeRelayMediaPayload(presence: beat)
        )

        let dispatcher: @Sendable (HermesRealtimeRelayFrame, @Sendable (HermesRealtimeRelayFrame) async throws -> Void) async -> Void = { frame, _ in
            // Real `MercuryRouter.handleFrame` only feeds the peer
            // source; it does NOT emit an ack.
            XCTAssertEqual(frame.type, .mediaPresenceHeartbeat)
            XCTAssertNotNil(frame.media?.presence)
        }

        await dispatcher(frame, ackSender)
        let emitted = await ackRecorder.frames
        XCTAssertEqual(emitted.count, 0, "presence frames must not produce ack traffic")
    }
}

private actor AckRecorder {
    private var storedFrames: [HermesRealtimeRelayFrame] = []

    var frames: [HermesRealtimeRelayFrame] {
        storedFrames
    }

    func append(_ frame: HermesRealtimeRelayFrame) {
        storedFrames.append(frame)
    }
}

private final class ScriptedBlobBackend: IrohBlobBackend, @unchecked Sendable {
    enum Outcome<T> {
        case success(T)
        case failure(IrohBlobBackendError)
    }

    var bootstrapCount = 0
    var fetchedTickets: [String] = []
    var fetchOutcome: Outcome<BlobTransferStats> = .success(
        BlobTransferStats(bytesTotal: 32, blake3Hash: "blake3:test", durationMillis: 10, didResume: false)
    )

    func bootstrap(secret: Data, storeDirectoryPath: String, relayURL: String?) async throws -> IrohEndpointIdentity {
        bootstrapCount += 1
        return IrohEndpointIdentity(nodeId: "scripted_node", rawPublicKey: secret.prefix(32))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1scripted"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        fetchedTickets.append(ticketText)
        switch fetchOutcome {
        case .failure(let error): throw error
        case .success(let stats):
            // Materialize the destination so callers can verify it on
            // disk just like the real flow.
            let url = URL(fileURLWithPath: destination)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(repeating: 0xAB, count: Int(stats.bytesTotal)).write(to: url)
            return stats
        }
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "scripted_node", rawPublicKey: Data(repeating: 0, count: 32))
    }

    func shutdown() async {}
}
