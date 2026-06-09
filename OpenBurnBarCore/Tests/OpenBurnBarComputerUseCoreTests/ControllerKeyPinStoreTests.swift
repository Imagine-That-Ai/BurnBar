import CryptoKit
import XCTest
@testable import OpenBurnBarComputerUseCore

/// F1 keystone — Mac-side controller-key pinning. Drives every branch of the
/// pure pin decision through the in-memory backing so the fail-closed logic is
/// verifiable without a Keychain entitlement.
final class ControllerKeyPinStoreTests: XCTestCase {
    private func newKeyBase64() -> String {
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    private func makeStore(
        _ backing: InMemoryControllerKeyPinBacking,
        host: String? = "aG9zdC1rZXk="
    ) -> ControllerKeyPinStore {
        // host param only feeds the safety-code display; use a real Ed25519 key
        // when a code is asserted, otherwise a placeholder is fine (code is nil).
        ControllerKeyPinStore(backing: backing, hostPublicKeyBase64: host)
    }

    // MARK: First use

    func testFirstUsePinsAndAdmitsWhenConfirmationNotRequired() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, host: newKeyBase64())
        let key = newKeyBase64()

        let result = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "ios-phone-aabb")
        guard case .pinnedFirstUse = result else { return XCTFail("expected pinnedFirstUse, got \(result)") }
        XCTAssertTrue(result.admits(requireConfirmation: false), "first use admits with the gate off")
        XCTAssertFalse(result.admits(requireConfirmation: true), "first use must be confirmed when the gate is on")
        XCTAssertNotNil(result.safetyCodeForConfirmation, "first use surfaces a code to compare")

        let record = store.pinnedRecord(uid: "u1", peerNodeId: "ios-phone-aabb")
        XCTAssertEqual(record?.keyBase64, key)
        XCTAssertEqual(record?.confirmed, false)
    }

    func testSecondAdmissionOfSameKeyMatchesPendingUntilConfirmed() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, host: newKeyBase64())
        let key = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p")
        let again = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p")
        guard case .matchesPendingConfirmation = again else { return XCTFail("expected pending, got \(again)") }
        XCTAssertTrue(again.admits(requireConfirmation: false))
        XCTAssertFalse(again.admits(requireConfirmation: true))
    }

    // MARK: Confirmation

    func testConfirmPromotesToConfirmedAndAdmitsUnderEnforcement() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, host: newKeyBase64())
        let key = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p")
        XCTAssertTrue(store.confirm(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p"))

        let result = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p")
        XCTAssertEqual(result, .matchesConfirmedPin)
        XCTAssertTrue(result.admits(requireConfirmation: true), "a confirmed pin admits even under enforcement")
        XCTAssertTrue(store.pinnedRecord(uid: "u1", peerNodeId: "p")?.confirmed == true)
    }

    func testConfirmIsIdempotentAndRejectsWrongKey() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing)
        let key = newKeyBase64()
        let other = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u", peerNodeId: "p")
        XCTAssertTrue(store.confirm(advertisedKeyBase64: key, uid: "u", peerNodeId: "p"))
        XCTAssertTrue(store.confirm(advertisedKeyBase64: key, uid: "u", peerNodeId: "p"), "idempotent")
        XCTAssertFalse(store.confirm(advertisedKeyBase64: other, uid: "u", peerNodeId: "p"),
                       "cannot confirm a key that differs from the pin")
        XCTAssertFalse(store.confirm(advertisedKeyBase64: key, uid: "u", peerNodeId: "absent"),
                       "cannot confirm a peer with no pin")
    }

    // MARK: The keystone — key change is always refused

    func testKeySwapIsAlwaysRefusedRegardlessOfEnforcement() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, host: newKeyBase64())
        let real = newKeyBase64()
        let attacker = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: real, uid: "u", peerNodeId: "p")
        _ = store.confirm(advertisedKeyBase64: real, uid: "u", peerNodeId: "p")

        let swapped = store.verifyOrPin(advertisedKeyBase64: attacker, uid: "u", peerNodeId: "p")
        guard case .mismatch = swapped else { return XCTFail("expected mismatch, got \(swapped)") }
        XCTAssertFalse(swapped.admits(requireConfirmation: false), "key swap refused even with the gate off")
        XCTAssertFalse(swapped.admits(requireConfirmation: true))
        // The pin is NOT overwritten by the attacker key.
        XCTAssertEqual(store.pinnedRecord(uid: "u", peerNodeId: "p")?.keyBase64, real)
    }

    func testRepairClearsPinAndAllowsNewKey() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing)
        let oldKey = newKeyBase64()
        let newKey = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: oldKey, uid: "u", peerNodeId: "p")
        // A rotated key is refused until the operator deliberately re-pairs.
        guard case .mismatch = store.verifyOrPin(advertisedKeyBase64: newKey, uid: "u", peerNodeId: "p") else {
            return XCTFail("rotated key should be refused before re-pair")
        }
        store.clearPin(uid: "u", peerNodeId: "p")
        guard case .pinnedFirstUse = store.verifyOrPin(advertisedKeyBase64: newKey, uid: "u", peerNodeId: "p") else {
            return XCTFail("after re-pair the new key pins fresh")
        }
    }

    // MARK: Malformed input & fail-closed Keychain errors

    func testMalformedAdvertisedKeyIsRefused() {
        let store = makeStore(InMemoryControllerKeyPinBacking())
        for bad in ["", "   ", "not-base64!!!", Data(repeating: 7, count: 16).base64EncodedString()] {
            XCTAssertEqual(store.verifyOrPin(advertisedKeyBase64: bad, uid: "u", peerNodeId: "p"),
                           .malformedAdvertisedKey, "rejected: \(bad)")
        }
    }

    func testKeychainReadFailureFailsClosed() {
        let backing = InMemoryControllerKeyPinBacking()
        backing.failReads(with: -25300) // errSecItemNotFound is .absent; use a generic read error
        let store = makeStore(backing)
        let result = store.verifyOrPin(advertisedKeyBase64: newKeyBase64(), uid: "u", peerNodeId: "p")
        guard case .unknownKeychainError = result else { return XCTFail("expected keychain error, got \(result)") }
        XCTAssertFalse(result.admits(requireConfirmation: false))
        XCTAssertFalse(result.admits(requireConfirmation: true))
    }

    func testKeychainWriteFailureOnFirstPinFailsClosed() {
        let backing = InMemoryControllerKeyPinBacking()
        backing.failWrites(with: -34018) // errSecMissingEntitlement
        let store = makeStore(backing)
        let result = store.verifyOrPin(advertisedKeyBase64: newKeyBase64(), uid: "u", peerNodeId: "p")
        guard case .unknownKeychainError = result else { return XCTFail("expected keychain error, got \(result)") }
        XCTAssertFalse(result.admits(requireConfirmation: false), "a phantom (unpersisted) pin must not admit")
    }

    // MARK: Account scoping

    func testPinsAreScopedByUidAndPeer() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing)
        let key = newKeyBase64()

        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "p")
        // Same peer string, different uid → independent pin (no cross-account match).
        guard case .pinnedFirstUse = store.verifyOrPin(advertisedKeyBase64: key, uid: "u2", peerNodeId: "p") else {
            return XCTFail("different uid must be an independent pin")
        }
        // Same uid, different peer → independent pin.
        guard case .pinnedFirstUse = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", peerNodeId: "q") else {
            return XCTFail("different peer must be an independent pin")
        }
    }

    // MARK: Enforcement flag

    func testEnforcementFlagDefaultsOffAndHonorsOverride() {
        let suite = UserDefaults(suiteName: "controller-pin-flag-\(UUID().uuidString)")!
        XCTAssertFalse(ControllerKeyPinEnforcementFlag.isEnabled(defaults: suite), "default off pending UI rollout")
        suite.set(true, forKey: ControllerKeyPinEnforcementFlag.userDefaultsKey)
        XCTAssertTrue(ControllerKeyPinEnforcementFlag.isEnabled(defaults: suite))
        suite.set(false, forKey: ControllerKeyPinEnforcementFlag.userDefaultsKey)
        XCTAssertFalse(ControllerKeyPinEnforcementFlag.isEnabled(defaults: suite))
    }
}
