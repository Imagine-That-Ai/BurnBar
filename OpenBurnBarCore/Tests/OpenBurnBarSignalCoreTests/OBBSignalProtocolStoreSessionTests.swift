import Foundation
import LibSignalClient
import OpenBurnBarSignalCore
import XCTest

/// Proves the durable L41 client stores (item 4) work end-to-end with real libsignal:
/// a full X3DH + PQXDH (Kyber) session establishes between two OBBSignalProtocolStore
/// instances, messages encrypt/decrypt both directions, and the session survives a
/// store round-trip (Keychain + file persistence).
final class OBBSignalProtocolStoreSessionTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeStore(
        identity: IdentityKeyPair = IdentityKeyPair.generate(),
        registrationId: UInt32 = UInt32.random(in: 1...0x3FFF),
        service: String = "com.openburnbar.signal.tests.\(UUID().uuidString)",
        sessionDir: URL? = nil
    ) throws -> OBBSignalProtocolStore {
        let dir = sessionDir ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDirs.append(dir)
        return try OBBSignalProtocolStore(
            identityKeypair: identity,
            registrationId: registrationId,
            keychainService: service,
            sessionDir: dir
        )
    }

    func testFullPQXDHSessionEncryptDecrypt() throws {
        let ctx = NullContext()
        let alice = try makeStore()
        let bob = try makeStore()

        // Bob publishes a prekey bundle (signed prekey + one-time prekey + mandatory Kyber).
        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 1, signedPreKeyId: 1, kyberPreKeyId: 1
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bob, context: ctx)
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bob.registrationId, deviceId: 1, prekeys: bobPrekeys
        )

        let aliceAddress = try ProtocolAddress(name: "alice-device_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob-device_1", deviceId: 1)

        // Alice establishes a session from Bob's bundle (X3DH + PQXDH).
        try processPreKeyBundle(
            bobBundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )

        // Alice -> Bob: first message is a PreKey message.
        let plaintext1 = Array("hello bob, pqxdh".utf8)
        let cipher1 = try signalEncrypt(
            message: plaintext1, for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        XCTAssertEqual(cipher1.messageType, .preKey)

        let preKeyMessage = try PreKeySignalMessage(bytes: cipher1.serialize())
        let decrypted1 = try signalDecryptPreKey(
            message: preKeyMessage, from: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, preKeyStore: bob,
            signedPreKeyStore: bob, kyberPreKeyStore: bob, context: ctx
        )
        XCTAssertEqual(Array(decrypted1), plaintext1)

        // Bob -> Alice: ratchet reply is a normal (whisper) message.
        let plaintext2 = Array("hi alice, ratcheted".utf8)
        let cipher2 = try signalEncrypt(
            message: plaintext2, for: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, context: ctx
        )
        XCTAssertEqual(cipher2.messageType, .whisper)

        let signalMessage = try SignalMessage(bytes: cipher2.serialize())
        let decrypted2 = try signalDecrypt(
            message: signalMessage, from: bobAddress, to: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        XCTAssertEqual(Array(decrypted2), plaintext2)
    }

    func testReplayedPQXDHPreKeyMessageIsRejected() throws {
        let ctx = NullContext()
        let alice = try makeStore()
        let bob = try makeStore()

        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 11, signedPreKeyId: 11, kyberPreKeyId: 11
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bob, context: ctx)
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bob.registrationId, deviceId: 1, prekeys: bobPrekeys
        )

        let aliceAddress = try ProtocolAddress(name: "alice-replay_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob-replay_1", deviceId: 1)
        try processPreKeyBundle(
            bobBundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )

        let plaintext = Array("one valid prekey message".utf8)
        let cipher = try signalEncrypt(
            message: plaintext, for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        XCTAssertEqual(cipher.messageType, .preKey)

        let message = try PreKeySignalMessage(bytes: cipher.serialize())
        let decrypted = try signalDecryptPreKey(
            message: message, from: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, preKeyStore: bob,
            signedPreKeyStore: bob, kyberPreKeyStore: bob, context: ctx
        )
        XCTAssertEqual(Array(decrypted), plaintext)

        XCTAssertThrowsError(
            try signalDecryptPreKey(
                message: message, from: aliceAddress, localAddress: bobAddress,
                sessionStore: bob, identityStore: bob, preKeyStore: bob,
                signedPreKeyStore: bob, kyberPreKeyStore: bob, context: ctx
            ),
            "replaying the same PQXDH base key must be rejected"
        )
    }

    func testChangedRemoteIdentityIsUntrustedForPinnedAddress() throws {
        let ctx = NullContext()
        let alice = try makeStore()
        let bob = try makeStore()

        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 21, signedPreKeyId: 21, kyberPreKeyId: 21
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bob, context: ctx)
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bob.registrationId, deviceId: 1, prekeys: bobPrekeys
        )

        let aliceAddress = try ProtocolAddress(name: "alice-identity_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob-identity_1", deviceId: 1)
        try processPreKeyBundle(
            bobBundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )

        XCTAssertTrue(
            try alice.isTrustedIdentity(
                bob.identityKeypair.identityKey, for: bobAddress, direction: .sending, context: ctx
            )
        )

        let replacementIdentity = IdentityKeyPair.generate().identityKey
        XCTAssertFalse(
            try alice.isTrustedIdentity(replacementIdentity, for: bobAddress, direction: .sending, context: ctx),
            "a different identity key for the same Signal address must not be silently trusted"
        )
    }

    func testSessionSurvivesStoreRoundTrip() throws {
        let ctx = NullContext()
        // Stable backing so a fresh store instance reloads the same session + identities.
        let aliceIdentity = IdentityKeyPair.generate()
        let aliceReg = UInt32.random(in: 1...0x3FFF)
        let aliceService = "com.openburnbar.signal.tests.\(UUID().uuidString)"
        let aliceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let alice = try makeStore(identity: aliceIdentity, registrationId: aliceReg, service: aliceService, sessionDir: aliceDir)
        let bob = try makeStore()

        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 7, signedPreKeyId: 7, kyberPreKeyId: 7
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bob, context: ctx)
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bob.registrationId, deviceId: 1, prekeys: bobPrekeys
        )
        let aliceAddress = try ProtocolAddress(name: "alice-rt_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob-rt_1", deviceId: 1)

        try processPreKeyBundle(
            bobBundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        // Establish: Alice -> Bob (so Bob has the session too).
        let first = try signalEncrypt(
            message: Array("establish".utf8), for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        _ = try signalDecryptPreKey(
            message: try PreKeySignalMessage(bytes: first.serialize()), from: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, preKeyStore: bob,
            signedPreKeyStore: bob, kyberPreKeyStore: bob, context: ctx
        )

        // Reopen Alice's store from the SAME Keychain service + session dir + identity.
        let aliceReloaded = try OBBSignalProtocolStore(
            identityKeypair: aliceIdentity, registrationId: aliceReg, keychainService: aliceService, sessionDir: aliceDir
        )
        XCTAssertNotNil(try aliceReloaded.loadSession(for: bobAddress, context: ctx), "session must persist to disk")

        // Bob -> Alice; the reloaded store decrypts via the persisted session + identity.
        let reply = try signalEncrypt(
            message: Array("persisted ratchet".utf8), for: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, context: ctx
        )
        let decrypted = try signalDecrypt(
            message: try SignalMessage(bytes: reply.serialize()), from: bobAddress, to: aliceAddress,
            sessionStore: aliceReloaded, identityStore: aliceReloaded, context: ctx
        )
        XCTAssertEqual(Array(decrypted), Array("persisted ratchet".utf8))
    }
}
