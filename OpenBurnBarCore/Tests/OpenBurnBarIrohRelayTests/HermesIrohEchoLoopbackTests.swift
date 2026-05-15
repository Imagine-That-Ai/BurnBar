import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

final class HermesIrohEchoLoopbackTests: XCTestCase {
    /// The spine: iOS-shaped client encrypts a payload, the Mac-shaped host
    /// decrypts it through `HermesRelayCrypto`, encrypts a reply with the
    /// same symmetric key, and the client decrypts cleanly. End-to-end
    /// ciphertext envelope is exercised over the in-process iroh transport.
    func testEchoRoundTripThroughLoopbackTransport() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let macTransport = LoopbackIrohRelayTransport(nodeId: "mac-loopback", rendezvous: rendezvous)
        let iOSTransport = LoopbackIrohRelayTransport(nodeId: "ios-loopback", rendezvous: rendezvous)

        let macIdentity = try await macTransport.start()
        _ = try await iOSTransport.start()
        XCTAssertEqual(macIdentity.nodeId, "mac-loopback")

        let relayPrivateKey = HermesRelayCrypto.generatePrivateKey()
        let host = HermesIrohEchoHost(privateKey: relayPrivateKey)
        let client = HermesIrohEchoClient()

        let hostTask = Task<Void, Error> {
            let inboundStream = try await macTransport.accept(timeout: 5)
            try await host.serve(on: inboundStream)
        }

        let outboundStream = try await iOSTransport.connect(to: "mac-loopback", timeout: 5)
        let response = try await client.roundTrip(
            request: .init(
                uid: "u-1",
                connectionId: "relay-mac",
                requestId: "req-spine-1",
                plaintextBody: "hello iroh"
            ),
            on: outboundStream,
            recipientPublicKeyBase64: relayPrivateKey.publicKeyBase64
        )

        XCTAssertEqual(response.body, "hello iroh")
        XCTAssertEqual(response.chunkCount, 1)
        XCTAssertEqual(response.requestId, "req-spine-1")

        try await hostTask.value
        await iOSTransport.shutdown()
        await macTransport.shutdown()
    }

    func testHostRejectsTamperedCiphertext() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let macTransport = LoopbackIrohRelayTransport(nodeId: "mac-tamper", rendezvous: rendezvous)
        let iOSTransport = LoopbackIrohRelayTransport(nodeId: "ios-tamper", rendezvous: rendezvous)
        _ = try await macTransport.start()
        _ = try await iOSTransport.start()

        let relayPrivateKey = HermesRelayCrypto.generatePrivateKey()
        let host = HermesIrohEchoHost(privateKey: relayPrivateKey)

        let hostTask = Task {
            let stream = try await macTransport.accept(timeout: 5)
            do {
                try await host.serve(on: stream)
                XCTFail("expected host to throw on tampered ciphertext")
            } catch {
                // The host throws when AES.GCM open fails on tampered payload.
            }
        }

        let outbound = try await iOSTransport.connect(to: "mac-tamper", timeout: 5)
        let badFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: "u-1",
            connectionId: "relay-mac",
            requestId: "req-tamper-1",
            payload: HermesRealtimeRelayPayload(
                method: "POST",
                payloadCiphertext: Data("not-a-real-ciphertext".utf8).base64EncodedString(),
                wrappedKey: Data(repeating: 0x42, count: 96).base64EncodedString(),
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: HermesRelayCrypto.keyVersion
            )
        )
        try await outbound.send(badFrame)

        try await hostTask.value
        await iOSTransport.shutdown()
        await macTransport.shutdown()
    }

    func testConnectFailsOnUnknownPeer() async throws {
        let rendezvous = LoopbackIrohRelayRendezvous()
        let iOSTransport = LoopbackIrohRelayTransport(nodeId: "ios-only", rendezvous: rendezvous)
        _ = try await iOSTransport.start()

        do {
            _ = try await iOSTransport.connect(to: "nobody-home", timeout: 0.25)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? IrohRelayTransportError, .timedOut)
        }
        await iOSTransport.shutdown()
    }
}
