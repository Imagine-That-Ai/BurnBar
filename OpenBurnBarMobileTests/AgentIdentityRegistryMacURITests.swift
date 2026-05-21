import XCTest
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

/// Mercury Phase 8 — locks in the `device://paired-mac/<id>` URI
/// resolution path. The registry synthesizes a `AgentIdentity` for
/// the Mercury Live tile only when `pairedMacPeer` is set, and the
/// returned identity carries the silver palette + macbook glyph.
@MainActor
final class AgentIdentityRegistryMacURITests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testPairedMacURIResolvesToSynthesizedIdentity() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "macbook-pro-alberto",
            displayName: "Alberto's MacBook",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )

        let identity = registry.identity(for: "device://paired-mac/macbook-pro-alberto")
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.displayName, "Alberto's MacBook")
        XCTAssertEqual(identity?.glyph, "🖥")
        XCTAssertEqual(identity?.paletteHex, "8B9DC3")
        XCTAssertEqual(identity?.availability, .online)
        XCTAssertEqual(identity?.tagline, "Mirror, call, or send a file")
    }

    func testPairedMacURIReturnsNilWhenPeerSourceEmpty() {
        let registry = AgentIdentityRegistry(seed: [])
        XCTAssertNil(registry.pairedMacPeer)
        XCTAssertNil(registry.identity(for: "device://paired-mac/anything"))
    }

    func testOfflinePeerYieldsOfflineAvailability() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Backup Mac",
            isOnline: false,
            lastSeenAt: referenceDate,
            capabilities: []
        )

        let identity = registry.identity(for: "device://paired-mac/mac-1")
        XCTAssertEqual(identity?.availability, .offline)
    }

    func testKnownBuiltInURIStillResolvesEvenWithMercuryPeerSet() {
        let registry = AgentIdentityRegistry()
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: []
        )
        // Built-in lookups must keep working alongside the new
        // device path.
        let builtIn = registry.identity(for: AgentIdentity.builtInURI(.hermes))
        XCTAssertNotNil(builtIn)
        XCTAssertEqual(builtIn?.runtimeID, .hermes)
    }
}

@MainActor
final class MediaControlStreamPresenceTests: XCTestCase {
    func testHeartbeatAdvertisesLiveV2ReceiverSupport() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        let sentFrames = await stream.sentFrames
        let heartbeat = try XCTUnwrap(sentFrames.first { $0.type == .mediaPresenceHeartbeat })
        let versions = try XCTUnwrap(heartbeat.media?.presence?.streamingCapabilities?.mediaFrameVersions)
        XCTAssertTrue(versions.supportsV1)
        XCTAssertTrue(versions.supportsV2)
        await coordinator.stop()
    }

    func testReadLoopForwardsMacPresenceHeartbeatToInstalledHandler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )

        let received = expectation(description: "presence heartbeat forwarded")
        coordinator.presenceHeartbeatHandler = { heartbeat in
            XCTAssertEqual(heartbeat.deviceDisplayName, "Alberto's Mac")
            XCTAssertEqual(heartbeat.capabilities, [
                MercuryPeer.Feature.mirrorHost.rawValue,
                MercuryPeer.Feature.fileReceive.rawValue
            ])
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)

        await stream.pushInbound(HermesRealtimeRelayFrame(
            type: .mediaPresenceHeartbeat,
            uid: "user-1",
            connectionId: "conn-1",
            media: HermesRealtimeRelayMediaPayload(
                presence: HermesRealtimeRelayPresenceHeartbeat(
                    sentAt: Date(timeIntervalSince1970: 1_700_000_000),
                    deviceDisplayName: "Alberto's Mac",
                    capabilities: [
                        MercuryPeer.Feature.mirrorHost.rawValue,
                        MercuryPeer.Feature.fileReceive.rawValue
                    ]
                )
            )
        ))

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    func testReadLoopRoutesV2ScreenFramesToV2Handler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        let expected = MediaFrameV2(
            kind: .videoNAL,
            flags: 0x0001,
            gopID: 41,
            frameIndex: 7,
            presentationTimestampMillis: 1_777,
            metadata: try MediaFrameV2Metadata(
                codec: .hevc,
                longTermReferenceToken: MercuryLTRToken(value: 12)
            ).encode(),
            payload: Data([0x01, 0x02, 0x03])
        )
        let encoded = try MediaFrameV2Codec().encode(expected, negotiatedVersion: .v2)

        let received = expectation(description: "v2 stream frame routed")
        coordinator.mirrorFrameV2Handler = { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }
        coordinator.mirrorFrameHandler = { _ in
            XCTFail("v2 envelope must not be decoded by the v1 media packet path")
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        await stream.pushInbound(screenVideoFrame(uid: "user-1", connectionID: "conn-1", encoded: encoded))

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    func testReadLoopKeepsRoutingLegacyScreenFramesToV1Handler() async throws {
        let stream = MediaControlFakeStream()
        let receiver = makeReceiver()
        let coordinator = MediaControlStreamCoordinator(
            dialer: { _, _ in stream },
            receiver: receiver,
            initialBackoff: 0.01,
            maxBackoff: 0.01
        )
        let expected = MediaFrame(
            kind: .videoNAL,
            flags: [.keyframe],
            gopID: 42,
            frameIndex: 8,
            presentationTimestampMillis: 1_778,
            payload: Data([0x04, 0x05, 0x06])
        )
        let encoded = try MediaPacketCodec().encode(expected)

        let received = expectation(description: "v1 stream frame routed")
        coordinator.mirrorFrameV2Handler = { _ in
            XCTFail("v1 envelope must not be routed to the MediaFrame v2 path")
        }
        coordinator.mirrorFrameHandler = { frame in
            XCTAssertEqual(frame, expected)
            received.fulfill()
        }

        coordinator.start(uid: "user-1", connectionID: "conn-1")
        try await waitUntilLive(coordinator)
        await stream.pushInbound(screenVideoFrame(uid: "user-1", connectionID: "conn-1", encoded: encoded))

        await fulfillment(of: [received], timeout: 1.0)
        await coordinator.stop()
    }

    private func waitUntilLive(_ coordinator: MediaControlStreamCoordinator) async throws {
        let deadline = Date().addingTimeInterval(1.0)
        while coordinator.phase != .live {
            if Date() > deadline {
                XCTFail("media control stream did not become live")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func screenVideoFrame(uid: String, connectionID: String, encoded: Data) -> HermesRealtimeRelayFrame {
        HermesRealtimeRelayFrame(
            type: .mediaStreamFrame,
            uid: uid,
            connectionId: connectionID,
            media: HermesRealtimeRelayMediaPayload(
                streamClass: MediaStreamClass.screenVideo.rawValue,
                encodedFrameBase64: encoded.base64EncodedString()
            )
        )
    }

    private func makeReceiver() -> iOSFileTransferService {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mercury-mobile-tests-\(UUID().uuidString)", isDirectory: true)
        let service = MediaFileTransferService(
            backend: MediaControlFakeBlobBackend(),
            configuration: .init(
                storeDirectoryURL: temp.appendingPathComponent("store", isDirectory: true),
                inboxDirectoryURL: temp.appendingPathComponent("inbox", isDirectory: true),
                secretKeyProvider: { Data(repeating: 0xAB, count: 32) }
            )
        )
        return iOSFileTransferService(service: service, settingsProvider: { true })
    }
}

private actor MediaControlFakeStream: IrohRelayStream {
    private var inboundFrames: [HermesRealtimeRelayFrame] = []
    private var outboundFrames: [HermesRealtimeRelayFrame] = []
    private var receiveWaiter: CheckedContinuation<HermesRealtimeRelayFrame?, Error>?
    private var isClosed = false

    var sentFrames: [HermesRealtimeRelayFrame] { outboundFrames }

    func send(_ frame: HermesRealtimeRelayFrame) async throws {
        outboundFrames.append(frame)
    }

    func receive() async throws -> HermesRealtimeRelayFrame? {
        if !inboundFrames.isEmpty { return inboundFrames.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            receiveWaiter = continuation
        }
    }

    func close() async {
        isClosed = true
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func pushInbound(_ frame: HermesRealtimeRelayFrame) {
        if let receiveWaiter {
            self.receiveWaiter = nil
            receiveWaiter.resume(returning: frame)
            return
        }
        inboundFrames.append(frame)
    }
}

private final class MediaControlFakeBlobBackend: IrohBlobBackend, @unchecked Sendable {
    func bootstrap(secret: Data, storeDirectoryPath: String, relayURL: String?) async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "fake-node", rawPublicKey: Data(secret.prefix(32)))
    }

    func publishBlob(localPath: String) async throws -> String {
        "blob1fake"
    }

    func fetchBlob(ticketText: String, destination: String) async throws -> BlobTransferStats {
        BlobTransferStats(
            bytesTotal: 0,
            blake3Hash: "blake3:fake",
            durationMillis: 0,
            didResume: false
        )
    }

    func identity() async throws -> IrohEndpointIdentity {
        IrohEndpointIdentity(nodeId: "fake-node", rawPublicKey: Data(repeating: 0, count: 32))
    }

    func shutdown() async {}
}
