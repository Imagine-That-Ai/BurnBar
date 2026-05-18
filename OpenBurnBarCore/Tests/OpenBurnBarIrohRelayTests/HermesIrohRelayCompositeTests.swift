import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

/// Drives the iroh transport contract through the same loopback transport
/// the host adapter will use in dev builds (before the xcframework binary
/// is linked). Exercises the `HermesRelayCrypto` envelope, the frame
/// ordering, and the pairing-record discovery loop end-to-end so the
/// composite transport behaves exactly like the production adapter without
/// reaching for Firebase.
final class HermesIrohRelayCompositeTests: XCTestCase {
    func testPairingDiscoveryThenEchoRoundTrip() async throws {
        // Mac side bootstraps an iroh endpoint, publishes its signed
        // pairing record, and starts the accept loop.
        let rendezvous = LoopbackIrohRelayRendezvous()
        let macTransport = LoopbackIrohRelayTransport(nodeId: "mac-spine", rendezvous: rendezvous)
        let iosTransport = LoopbackIrohRelayTransport(nodeId: "ios-spine", rendezvous: rendezvous)
        _ = try await macTransport.start()
        _ = try await iosTransport.start()

        let pairingKeypair = IrohPairingKeypair()
        let directory = InMemoryIrohPairingDirectory()
        let publisher = IrohPairingPublisher(directory: directory)
        _ = try await publisher.publish(
            uid: "u-spine",
            connectionId: "c-spine",
            nodeId: "mac-spine",
            with: pairingKeypair
        )

        // iOS side discovers + verifies.
        let verified = try await publisher.fetchAndVerify(
            uid: "u-spine",
            connectionId: "c-spine",
            publicKey: pairingKeypair.publicKeyRaw,
            now: Date()
        )
        XCTAssertEqual(verified.nodeId, "mac-spine")

        // Run one encrypted echo round trip through that NodeId.
        let relayPrivateKey = HermesRelayCrypto.generatePrivateKey()
        let host = HermesIrohEchoHost(privateKey: relayPrivateKey)
        let client = HermesIrohEchoClient()

        let hostTask = Task<Void, Error> {
            let stream = try await macTransport.accept(timeout: 5)
            try await host.serve(on: stream)
        }
        let stream = try await iosTransport.connect(to: verified, timeout: 5)
        let response = try await client.roundTrip(
            request: .init(
                uid: "u-spine",
                connectionId: "c-spine",
                requestId: "r-spine-1",
                plaintextBody: "spine works"
            ),
            on: stream,
            recipientPublicKeyBase64: relayPrivateKey.publicKeyBase64
        )
        XCTAssertEqual(response.body, "spine works")
        XCTAssertEqual(response.chunkCount, 1)
        try await hostTask.value

        // Revoking the pairing record makes future verifies fail.
        try await directory.revoke(uid: "u-spine", connectionId: "c-spine")
        await XCTAssertThrowsErrorAsync({
            _ = try await publisher.fetchAndVerify(
                uid: "u-spine",
                connectionId: "c-spine",
                publicKey: pairingKeypair.publicKeyRaw,
                now: Date()
            )
        }, expected: IrohPairingDirectoryError.recordNotFound)

        await iosTransport.shutdown()
        await macTransport.shutdown()
    }
}
