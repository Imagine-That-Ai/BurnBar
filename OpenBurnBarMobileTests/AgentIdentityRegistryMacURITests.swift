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
    private var receiveWaiter: CheckedContinuation<HermesRealtimeRelayFrame?, Error>?
    private var isClosed = false

    func send(_ frame: HermesRealtimeRelayFrame) async throws {}

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
