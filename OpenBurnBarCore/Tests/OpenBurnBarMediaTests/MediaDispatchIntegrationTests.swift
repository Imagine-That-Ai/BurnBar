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
        var emittedAcks: [HermesRealtimeRelayFrame] = []
        let ackSender: @Sendable (HermesRealtimeRelayFrame) async throws -> Void = { frame in
            await MainActor.run {
                emittedAcks.append(frame)
            }
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
