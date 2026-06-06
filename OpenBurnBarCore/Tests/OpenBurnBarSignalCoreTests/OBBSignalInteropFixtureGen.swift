import Foundation
import LibSignalClient
import OpenBurnBarSignalCore
import XCTest

/// Cross-language interop fixture GENERATOR (run on demand, not a CI assertion).
///
/// Emits a frozen fixture in which Alice (Swift) establishes an X3DH+PQXDH session
/// from Bob's bundle and encrypts a PreKey message. The companion Android test
/// (`AndroidSignalInteropKatTest`) reconstructs Bob's store from the same key
/// material and decrypts it — proving the Swift and Android `…ProtocolStore`
/// implementations interoperate on the real official-libsignal wire format.
///
/// Run with: `OBB_INTEROP_OUT=/abs/path.json swift test --filter testEmitSwiftAliceToAndroidBobFixture`
/// Then copy the JSON into the committed fixture locations consumed by both sides.
final class OBBSignalInteropFixtureGen: XCTestCase {

    func testEmitSwiftAliceToAndroidBobFixture() throws {
        guard let outPath = ProcessInfo.processInfo.environment["OBB_INTEROP_OUT"] else {
            throw XCTSkip("set OBB_INTEROP_OUT to emit the interop fixture")
        }
        let ctx = NullContext()

        let bobIdentity = IdentityKeyPair.generate()
        let bobReg: UInt32 = 0x0B0B
        let bobDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bobDir) }
        let bob = try OBBSignalProtocolStore(
            identityKeypair: bobIdentity, registrationId: bobReg,
            keychainService: "com.openburnbar.signal.interop.bob.\(UUID().uuidString)", sessionDir: bobDir
        )

        let aliceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: aliceDir) }
        let alice = try OBBSignalProtocolStore(
            identityKeypair: IdentityKeyPair.generate(), registrationId: 0x0A1C,
            keychainService: "com.openburnbar.signal.interop.alice.\(UUID().uuidString)", sessionDir: aliceDir
        )

        // Bob publishes a bundle (prekey ids 1/1/1).
        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 1, signedPreKeyId: 1, kyberPreKeyId: 1
        )
        try OBBSignalPreKeyGenerator.storePreKeys(bobPrekeys, into: bob, context: ctx)
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bobReg, deviceId: 1, prekeys: bobPrekeys
        )

        // Address names MUST match what the Android consumer uses.
        let aliceAddress = try ProtocolAddress(name: "alice", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob", deviceId: 1)

        try processPreKeyBundle(
            bobBundle, for: bobAddress, ourAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        let plaintext = "interop hello from swift alice"
        let cipher = try signalEncrypt(
            message: Array(plaintext.utf8), for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: ctx
        )
        XCTAssertEqual(cipher.messageType, .preKey)

        let fixture: [String: Any] = [
            "schema": "obb-signal-interop-v1",
            "direction": "swift-alice-to-android-bob",
            "aliceAddressName": "alice",
            "bobAddressName": "bob",
            "deviceId": 1,
            "bobRegistrationId": Int(bobReg),
            "bobIdentityKeyPairB64": Data(bob.identityKeypair.serialize()).base64EncodedString(),
            "bobPreKeyId": 1,
            "bobPreKeyRecordB64": Data(bobPrekeys.preKey.serialize()).base64EncodedString(),
            "bobSignedPreKeyId": 1,
            "bobSignedPreKeyRecordB64": Data(bobPrekeys.signedPreKey.serialize()).base64EncodedString(),
            "bobKyberPreKeyId": 1,
            "bobKyberPreKeyRecordB64": Data(bobPrekeys.kyberPreKey.serialize()).base64EncodedString(),
            "ciphertextType": Int(cipher.messageType.rawValue),
            "ciphertextB64": Data(cipher.serialize()).base64EncodedString(),
            "expectedPlaintext": plaintext,
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
    }
}
