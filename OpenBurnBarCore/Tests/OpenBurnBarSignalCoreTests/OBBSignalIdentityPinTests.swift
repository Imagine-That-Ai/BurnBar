import Foundation
import LibSignalClient
import OpenBurnBarSignalCore
import XCTest

/// F6: out-of-band identity pinning for the (currently unwired) libsignal session
/// transport. When a trust anchor is configured the store is the SOLE authority and
/// fails closed against any server-supplied identity key that is not pinned —
/// including a key swap arriving under a new identityKeyId (a fresh per-address slot
/// would otherwise trust-on-first-use it). Without an anchor the legacy byte-equality
/// TOFU contract is preserved so existing behavior is unchanged.
final class OBBSignalIdentityPinTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs = []
    }

    private func makeStore(
        identity: IdentityKeyPair = IdentityKeyPair.generate(),
        evaluator: OBBSignalProtocolStore.IdentityTrustEvaluator? = nil
    ) throws -> OBBSignalProtocolStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempDirs.append(dir)
        return try OBBSignalProtocolStore(
            identityKeypair: identity,
            registrationId: UInt32.random(in: 1...0x3FFF),
            keychainService: "com.openburnbar.signal.pin.tests.\(UUID().uuidString)",
            sessionDir: dir,
            identityTrustEvaluator: evaluator
        )
    }

    /// Anchor-less: first contact is trusted-on-first-use, exactly as before.
    func testAnchorlessStorePreservesTOFU() throws {
        let store = try makeStore()
        let address = try ProtocolAddress(name: "peer_1", deviceId: 1)
        let key = IdentityKey(publicKey: IdentityKeyPair.generate().publicKey)
        XCTAssertTrue(try store.isTrustedIdentity(key, for: address, direction: .sending, context: NullContext()))
    }

    /// Anchor present: the pinned key is trusted, an unpinned/swapped key is refused
    /// even on first contact (the TOFU window is closed).
    func testAnchorIsSoleAuthorityAndFailsClosed() throws {
        let pinned = IdentityKey(publicKey: IdentityKeyPair.generate().publicKey)
        let pinnedBytes = Data(pinned.serialize())
        let store = try makeStore(evaluator: { _, advertised in
            Data(advertised.serialize()) == pinnedBytes
        })
        let address = try ProtocolAddress(name: "peer_1", deviceId: 1)
        let attacker = IdentityKey(publicKey: IdentityKeyPair.generate().publicKey)

        XCTAssertTrue(
            try store.isTrustedIdentity(pinned, for: address, direction: .sending, context: NullContext()),
            "the operator-pinned identity is trusted"
        )
        XCTAssertFalse(
            try store.isTrustedIdentity(attacker, for: address, direction: .sending, context: NullContext()),
            "an unpinned (server-swapped) identity is refused even on first contact"
        )
    }

    /// End-to-end: a directory/relay that serves an attacker-held prekey bundle
    /// (fully self-consistent under the attacker's own identity key) cannot
    /// establish a session, because the pin does not match the advertised identity.
    func testServerSwappedBundleIsRefusedByPin() throws {
        let bob = try makeStore()        // the genuine peer the operator pinned
        let attacker = try makeStore()   // attacker builds a valid bundle under ITS key

        let attackerPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: attacker.identityKeypair, preKeyId: 1, signedPreKeyId: 1, kyberPreKeyId: 1
        )
        let attackerBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: attacker.identityKeypair, registrationId: attacker.registrationId,
            deviceId: 1, prekeys: attackerPrekeys
        )

        // Alice pins BOB's real identity out-of-band; the directory serves the
        // attacker bundle under bob's address.
        let bobIdentityBytes = Data(IdentityKey(publicKey: bob.identityKeypair.publicKey).serialize())
        let alice = try makeStore(evaluator: { _, advertised in
            Data(advertised.serialize()) == bobIdentityBytes
        })

        let aliceAddress = try ProtocolAddress(name: "alice_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob_1", deviceId: 1)

        XCTAssertThrowsError(
            try processPreKeyBundle(
                attackerBundle, for: bobAddress, ourAddress: aliceAddress,
                sessionStore: alice, identityStore: alice, context: NullContext()
            ),
            "a swapped identity key (MITM via the directory) must be refused as untrusted"
        )
    }

    /// The genuine peer's bundle, matching the pin, establishes normally.
    func testPinnedBundleEstablishesSession() throws {
        let bob = try makeStore()
        let bobPrekeys = try OBBSignalPreKeyGenerator.generatePreKeys(
            identityKeypair: bob.identityKeypair, preKeyId: 1, signedPreKeyId: 1, kyberPreKeyId: 1
        )
        let bobBundle = try OBBSignalPreKeyGenerator.buildPreKeyBundle(
            identityKeypair: bob.identityKeypair, registrationId: bob.registrationId,
            deviceId: 1, prekeys: bobPrekeys
        )
        let bobIdentityBytes = Data(IdentityKey(publicKey: bob.identityKeypair.publicKey).serialize())
        let alice = try makeStore(evaluator: { _, advertised in
            Data(advertised.serialize()) == bobIdentityBytes
        })
        let aliceAddress = try ProtocolAddress(name: "alice_1", deviceId: 1)
        let bobAddress = try ProtocolAddress(name: "bob_1", deviceId: 1)

        XCTAssertNoThrow(
            try processPreKeyBundle(
                bobBundle, for: bobAddress, ourAddress: aliceAddress,
                sessionStore: alice, identityStore: alice, context: NullContext()
            ),
            "the genuine, pinned peer bundle establishes a session"
        )
    }
}
