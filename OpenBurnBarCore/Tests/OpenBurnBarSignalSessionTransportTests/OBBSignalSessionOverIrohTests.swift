import Foundation
import LibSignalClient
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import OpenBurnBarSignalCore
@testable import OpenBurnBarSignalSessionTransport
import XCTest

final class OBBSignalSessionOverIrohTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    func testLoopbackSignalSessionRoundTrip() async throws {
        let uid = "signal-user"
        let alicePeer = OBBSignalSessionPeer(
            uid: uid,
            deviceId: "ios-device",
            identityKeyId: "ios-device_1",
            keyVersion: 1,
            signalDeviceId: 1,
            registrationId: 0x3F01
        )
        let bobPeer = OBBSignalSessionPeer(
            uid: uid,
            deviceId: "mac-device",
            identityKeyId: "mac-device_1",
            keyVersion: 1,
            signalDeviceId: 1,
            registrationId: 0x3F02
        )
        let aliceAddress = try alicePeer.protocolAddress()
        let bobAddress = try bobPeer.protocolAddress()
        let aliceStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: alicePeer.registrationId)
        let bobStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: bobPeer.registrationId)

        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bobStore.identityKeypair,
            preKeyId: 31337,
            signedPreKeyId: 22,
            kyberPreKeyId: 8,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bobStore, context: NullContext())
        let claimedBobBundle = try claimedBundle(
            uid: uid,
            peer: bobPeer,
            store: bobStore,
            prekeys: bobPrekeys
        )

        let rendezvous = LoopbackIrohRelayRendezvous()
        let macTransport = LoopbackIrohRelayTransport(nodeId: "mac-signal-loopback", rendezvous: rendezvous)
        let iosTransport = LoopbackIrohRelayTransport(nodeId: "ios-signal-loopback", rendezvous: rendezvous)
        _ = try await macTransport.start()
        _ = try await iosTransport.start()

        let aliceCipherTransport = OBBSignalSessionCipherTransport(store: aliceStore, localAddress: aliceAddress)
        let bobCipherTransport = OBBSignalSessionCipherTransport(store: bobStore, localAddress: bobAddress)

        let hostTask = Task<(OBBSignalSessionReceivedMessage, HermesRealtimeRelayFrame), Error> {
            let inbound = try await macTransport.accept(timeout: 5)
            let received = try await bobCipherTransport.receive(from: inbound, remoteAddress: aliceAddress)
            let replyFrame = try await bobCipherTransport.send(
                Data("ratchet reply over iroh".utf8),
                to: aliceAddress,
                on: inbound,
                uid: uid,
                connectionId: "session-conn",
                requestId: "session-req"
            )
            return (received, replyFrame)
        }

        let outbound = try await iosTransport.connect(to: "mac-signal-loopback", timeout: 5)
        let firstFrame = try await aliceCipherTransport.establishOutbound(
            claimSignalPrekeyBundle: { claimedBobBundle },
            plaintext: Data("hello over signal+iroh".utf8),
            on: outbound,
            uid: uid,
            connectionId: "session-conn",
            requestId: "session-req"
        )
        XCTAssertEqual(firstFrame.type, .signalSessionMessage)
        XCTAssertEqual(firstFrame.signalMessageType, Int(CiphertextMessage.MessageType.preKey.rawValue))
        XCTAssertNotNil(firstFrame.signalSessionCiphertextB64)

        let reply = try await aliceCipherTransport.receive(from: outbound, remoteAddress: bobAddress)
        XCTAssertEqual(reply.messageType, Int(CiphertextMessage.MessageType.whisper.rawValue))
        XCTAssertEqual(reply.plaintext, Data("ratchet reply over iroh".utf8))

        let (hostReceived, replyFrame) = try await hostTask.value
        XCTAssertEqual(hostReceived.messageType, Int(CiphertextMessage.MessageType.preKey.rawValue))
        XCTAssertEqual(hostReceived.plaintext, Data("hello over signal+iroh".utf8))
        XCTAssertEqual(replyFrame.signalMessageType, Int(CiphertextMessage.MessageType.whisper.rawValue))

        await outbound.close()
        await iosTransport.shutdown()
        await macTransport.shutdown()
    }

    func testGatewayV4EnvelopeRoundTripUsesSignalCiphertext() async throws {
        let uid = "signal-gateway-user"
        let alicePeer = OBBSignalSessionPeer(
            uid: uid, deviceId: "ios-gateway", identityKeyId: "ios-gateway_1",
            keyVersion: 1, signalDeviceId: 1, registrationId: 0x4101
        )
        let bobPeer = OBBSignalSessionPeer(
            uid: uid, deviceId: "mac-gateway", identityKeyId: "mac-gateway_1",
            keyVersion: 1, signalDeviceId: 1, registrationId: 0x4102
        )
        let aliceAddress = try alicePeer.protocolAddress()
        let bobAddress = try bobPeer.protocolAddress()
        let aliceStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: alicePeer.registrationId)
        let bobStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: bobPeer.registrationId)
        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bobStore.identityKeypair,
            preKeyId: 51001, signedPreKeyId: 51, kyberPreKeyId: 51,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bobStore, context: NullContext())
        let claimedBobBundle = try claimedBundle(uid: uid, peer: bobPeer, store: bobStore, prekeys: bobPrekeys)
        let alice = OBBSignalSessionCipherTransport(store: aliceStore, localAddress: aliceAddress)
        let bob = OBBSignalSessionCipherTransport(store: bobStore, localAddress: bobAddress)

        let envelope = try await alice.sealGatewayEnvelope(
            Data("gateway v4 text".utf8),
            context: OBBSignalGatewayEnvelopeContext(uid: uid, clientId: "client-1", slotId: "text"),
            claimSignalPrekeyBundle: { claimedBobBundle }
        )
        XCTAssertEqual(envelope.mode, "transport")
        // The shared TS sanitizer hard-requires relayKeyVersion == 4 on every
        // transport envelope; a nil stamp makes Functions reject the event.
        XCTAssertEqual(envelope.relayKeyVersion, HermesRelayCrypto.gatewayRelayKeyVersionSignalV4)
        XCTAssertEqual(envelope.binding.scope, "gateway")
        XCTAssertEqual(envelope.binding.clientId, "client-1")
        XCTAssertEqual(envelope.keyDelivery.scheme, "signal-doubleratchet-pqxdh-v1")
        XCTAssertEqual(envelope.keyDelivery.signalMessageType, Int(CiphertextMessage.MessageType.preKey.rawValue))
        XCTAssertNotNil(envelope.keyDelivery.signalMessageB64)

        // The same concrete provider used by a shipping client must be able to
        // reopen the canonical envelope after it has crossed Firestore. This
        // also proves the provider's identity pin is enforced on the open path,
        // not only while establishing the outbound session.
        let alicePrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: aliceStore.identityKeypair,
            preKeyId: 61001,
            signedPreKeyId: 61,
            kyberPreKeyId: 61
        )
        try OBBSignalPreKeyGenerator.storePreKeys(alicePrekeys, into: aliceStore, context: NullContext())
        let claimedAliceBundle = try claimedBundle(
            uid: uid,
            peer: alicePeer,
            store: aliceStore,
            prekeys: alicePrekeys
        )
        let provider = OBBSignalSessionGatewayEnvelopeProvider(
            transport: bob,
            peerBundle: claimedAliceBundle,
            pinnedIdentityPublicKey: Data(aliceStore.identityKeypair.publicKey.serialize())
        )
        let reopened = try await provider.open(
            envelopeData: JSONEncoder().encode(envelope),
            uid: uid,
            clientId: "client-1",
            slotId: "text"
        )
        XCTAssertEqual(reopened, Data("gateway v4 text".utf8))
    }

    func testPeerMappingIsDeterministic() throws {
        let first = OBBSignalSessionPeer(
            uid: "u",
            deviceId: "phone/one",
            identityKeyId: "phone/one_1",
            keyVersion: 1
        )
        let second = OBBSignalSessionPeer(
            uid: "u",
            deviceId: "phone/one",
            identityKeyId: "phone/one_1",
            keyVersion: 1
        )

        XCTAssertEqual(first.protocolAddressName, second.protocolAddressName)
        XCTAssertEqual(first.signalDeviceId, second.signalDeviceId)
        XCTAssertEqual(first.registrationId, second.registrationId)
        XCTAssertEqual(try first.protocolAddress().name, try second.protocolAddress().name)
        XCTAssertEqual(try first.protocolAddress().deviceId, try second.protocolAddress().deviceId)
    }

    func testSignalSessionFrameFieldsRoundTrip() throws {
        let frame = HermesRealtimeRelayFrame(
            type: .signalSessionMessage,
            uid: "u",
            connectionId: "c",
            requestId: "r",
            signalSessionCiphertextB64: Data([1, 2, 3]).base64EncodedString(),
            signalMessageType: Int(CiphertextMessage.MessageType.preKey.rawValue)
        )

        let encoded = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: encoded)
        XCTAssertEqual(decoded.type, .signalSessionMessage)
        XCTAssertEqual(decoded.signalSessionCiphertextB64, "AQID")
        XCTAssertEqual(decoded.signalMessageType, Int(CiphertextMessage.MessageType.preKey.rawValue))
    }

    /// Concurrency contract: with the cipher transport actor-isolated, firing many
    /// `send(...)` calls concurrently on one session advances the libsignal Double
    /// Ratchet under serialized, compiler-enforced isolation. The peer must be able
    /// to decrypt every message (in any order, via skipped-message keys) — proof the
    /// ratchet state was never corrupted by interleaved mutation.
    func testConcurrentSendsSerializeRatchetWithoutCorruption() async throws {
        let uid = "signal-user"
        let alicePeer = OBBSignalSessionPeer(
            uid: uid, deviceId: "ios-device", identityKeyId: "ios-device_1",
            keyVersion: 1, signalDeviceId: 1, registrationId: 0x3F11
        )
        let bobPeer = OBBSignalSessionPeer(
            uid: uid, deviceId: "mac-device", identityKeyId: "mac-device_1",
            keyVersion: 1, signalDeviceId: 1, registrationId: 0x3F12
        )
        let aliceAddress = try alicePeer.protocolAddress()
        let bobAddress = try bobPeer.protocolAddress()
        let aliceStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: alicePeer.registrationId)
        let bobStore = try makeStore(identity: IdentityKeyPair.generate(), registrationId: bobPeer.registrationId)

        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bobStore.identityKeypair,
            preKeyId: 41337, signedPreKeyId: 23, kyberPreKeyId: 9,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bobStore, context: NullContext())
        let claimedBobBundle = try claimedBundle(uid: uid, peer: bobPeer, store: bobStore, prekeys: bobPrekeys)

        let rendezvous = LoopbackIrohRelayRendezvous()
        let macTransport = LoopbackIrohRelayTransport(nodeId: "mac-concurrent-loopback", rendezvous: rendezvous)
        let iosTransport = LoopbackIrohRelayTransport(nodeId: "ios-concurrent-loopback", rendezvous: rendezvous)
        _ = try await macTransport.start()
        _ = try await iosTransport.start()

        let alice = OBBSignalSessionCipherTransport(store: aliceStore, localAddress: aliceAddress)
        let bob = OBBSignalSessionCipherTransport(store: bobStore, localAddress: bobAddress)

        // Host accepts and decrypts the initial preKey message to establish its
        // receiving session, then keeps the inbound stream open for the burst.
        let acceptTask = Task<any IrohRelayStream, Error> {
            try await macTransport.accept(timeout: 5)
        }
        let outbound = try await iosTransport.connect(to: "mac-concurrent-loopback", timeout: 5)
        let firstFrame = try await alice.establishOutbound(
            claimSignalPrekeyBundle: { claimedBobBundle },
            plaintext: Data("session-init".utf8),
            on: outbound,
            uid: uid, connectionId: "c", requestId: "r0"
        )
        let inbound = try await acceptTask.value
        // Drain the establishOutbound frame off the loopback stream and decrypt it
        // so Bob's session is live before the concurrent burst.
        _ = try await inbound.receive()
        let initial = try await bob.decrypt(frame: firstFrame, from: aliceAddress)
        XCTAssertEqual(initial.plaintext, Data("session-init".utf8))

        // Fire 16 concurrent sends. The actor serializes the ratchet advances; we
        // keep each returned frame (the stream write is an ignored side effect).
        let payloads = (0 ..< 16).map { "concurrent-message-\($0)" }
        let frames = try await withThrowingTaskGroup(of: HermesRealtimeRelayFrame.self) { group -> [HermesRealtimeRelayFrame] in
            for payload in payloads {
                group.addTask {
                    try await alice.send(
                        Data(payload.utf8), to: bobAddress, on: outbound,
                        uid: uid, connectionId: "c", requestId: "burst"
                    )
                }
            }
            var collected: [HermesRealtimeRelayFrame] = []
            for try await frame in group { collected.append(frame) }
            return collected
        }
        XCTAssertEqual(frames.count, payloads.count)

        // Bob decrypts every frame (out-of-order delivery handled by skipped keys).
        var decrypted: Set<String> = []
        for frame in frames {
            let message = try await bob.decrypt(frame: frame, from: aliceAddress)
            decrypted.insert(String(decoding: message.plaintext, as: UTF8.self))
        }
        XCTAssertEqual(decrypted, Set(payloads), "every concurrently-sent message must decrypt exactly once")

        await outbound.close()
        await iosTransport.shutdown()
        await macTransport.shutdown()
    }

    private func makeStore(
        identity: IdentityKeyPair,
        registrationId: UInt32,
        service: String = "com.openburnbar.signal.iroh.tests.\(UUID().uuidString)",
        sessionDir: URL? = nil
    ) throws -> OBBSignalProtocolStore {
        let dir = sessionDir ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDirs.append(dir)
        return try OBBSignalProtocolStore.testingTOFU(
            identityKeypair: identity,
            registrationId: registrationId,
            keychainService: service,
            sessionDir: dir
        )
    }

    private func claimedBundle(
        uid: String,
        peer: OBBSignalSessionPeer,
        store: OBBSignalProtocolStore,
        prekeys: OBBSignalPreKeyGenerator.GeneratedPreKeys
    ) throws -> OBBSignalClaimedPreKeyBundle {
        OBBSignalClaimedPreKeyBundle(
            peerUid: uid,
            identityKeyId: peer.identityKeyId,
            deviceId: peer.deviceId,
            keyVersion: peer.keyVersion ?? 1,
            identityPublicKeyData: store.identityKeypair.publicKey.serialize().base64EncodedString(),
            signedPreKey: OBBSignalClaimedSignedPreKey(
                id: "spk-\(prekeys.signedPreKey.id)",
                numericId: prekeys.signedPreKey.id,
                publicKeyB64: try prekeys.signedPreKey.publicKey().serialize().base64EncodedString(),
                signatureB64: Data(prekeys.signedPreKey.signature).base64EncodedString()
            ),
            kyberPreKey: OBBSignalClaimedKyberPreKey(
                id: "kpk-\(prekeys.kyberPreKey.id)",
                numericId: prekeys.kyberPreKey.id,
                publicKeyB64: try prekeys.kyberPreKey.publicKey().serialize().base64EncodedString(),
                signatureB64: Data(prekeys.kyberPreKey.signature).base64EncodedString()
            ),
            oneTimePreKey: OBBSignalClaimedOneTimePreKey(
                id: "otpk-\(prekeys.preKey.id)",
                numericId: prekeys.preKey.id,
                publicKeyB64: try prekeys.preKey.publicKey().serialize().base64EncodedString()
            ),
            signalDeviceId: peer.signalDeviceId,
            signalRegistrationId: peer.registrationId
        )
    }
}
