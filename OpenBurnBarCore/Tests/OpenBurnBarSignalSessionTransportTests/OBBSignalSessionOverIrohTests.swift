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
