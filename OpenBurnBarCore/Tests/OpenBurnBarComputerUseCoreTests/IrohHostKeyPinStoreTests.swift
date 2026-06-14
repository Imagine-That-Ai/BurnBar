import CryptoKit
import XCTest
@testable import OpenBurnBarComputerUseCore

/// T-TRN-01 / T-PTR-03 — phone-side iroh host-key pinning. Drives every branch of
/// the pure pin decision through the in-memory backing so the fail-closed logic is
/// verifiable without a Keychain entitlement (CI runner / unsigned simulator).
final class IrohHostKeyPinStoreTests: XCTestCase {
    private func newKeyBase64() -> String {
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    private func makeStore(
        _ backing: InMemoryControllerKeyPinBacking,
        local: String? = nil
    ) -> IrohHostKeyPinStore {
        IrohHostKeyPinStore(backing: backing, localPublicKeyBase64: local)
    }

    // MARK: First use

    func testFirstUsePinsAndAdmitsWhenConfirmationNotRequired() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, local: newKeyBase64())
        let key = newKeyBase64()

        let result = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        guard case .pinnedFirstUse = result else { return XCTFail("expected pinnedFirstUse, got \(result)") }
        XCTAssertTrue(result.admits(requireConfirmation: false), "first use admits with the safety-number gate off")
        XCTAssertFalse(result.admits(requireConfirmation: true), "first use must be confirmed when the gate is on")
        XCTAssertNotNil(result.safetyCodeForConfirmation, "first use surfaces a code to compare")
        let record = store.pinnedRecord(uid: "u1", roleId: "host")
        XCTAssertEqual(record?.keyBase64, key)
        XCTAssertEqual(record?.confirmed, false)
    }

    func testSecondFetchOfSameKeyMatchesPendingUntilConfirmed() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, local: newKeyBase64())
        let key = newKeyBase64()
        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        let again = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        guard case .matchesPendingConfirmation = again else { return XCTFail("expected matchesPendingConfirmation, got \(again)") }
        XCTAssertTrue(again.admits(requireConfirmation: false))
        XCTAssertFalse(again.admits(requireConfirmation: true))
    }

    func testConfirmPromotesToConfirmedAndAdmitsUnderEnforcement() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, local: newKeyBase64())
        let key = newKeyBase64()
        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        XCTAssertTrue(store.confirm(advertisedKeyBase64: key, uid: "u1", roleId: "host"))
        let result = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        XCTAssertEqual(result, .matchesConfirmedPin)
        XCTAssertTrue(result.admits(requireConfirmation: true), "a confirmed pin admits even under enforcement")
    }

    // MARK: The keystone — a swapped host key is ALWAYS refused (closes T-TRN-01)

    func testMismatchedAdvertisedKeyIsAlwaysRefused() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, local: newKeyBase64())
        let pinned = newKeyBase64()
        let attacker = newKeyBase64()
        _ = store.verifyOrPin(advertisedKeyBase64: pinned, uid: "u1", roleId: "host")
        // A malicious cloud now serves a different host key for the same account.
        let result = store.verifyOrPin(advertisedKeyBase64: attacker, uid: "u1", roleId: "host")
        guard case .mismatch = result else { return XCTFail("expected mismatch, got \(result)") }
        XCTAssertTrue(result.isRefusal)
        XCTAssertFalse(result.admits(requireConfirmation: false), "a key change is refused even with the gate off")
        XCTAssertFalse(result.admits(requireConfirmation: true))
        // The pin is unchanged — the relay-advertised key cannot overwrite it.
        XCTAssertEqual(store.pinnedRecord(uid: "u1", roleId: "host")?.keyBase64, pinned)
    }

    func testRePairClearsPinAndAllowsANewKey() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing, local: newKeyBase64())
        let first = newKeyBase64()
        let second = newKeyBase64()
        _ = store.verifyOrPin(advertisedKeyBase64: first, uid: "u1", roleId: "host")
        store.clearPin(uid: "u1", roleId: "host") // deliberate operator re-pair
        let result = store.verifyOrPin(advertisedKeyBase64: second, uid: "u1", roleId: "host")
        guard case .pinnedFirstUse = result else { return XCTFail("re-pair should pin the new key, got \(result)") }
        XCTAssertEqual(store.pinnedRecord(uid: "u1", roleId: "host")?.keyBase64, second)
    }

    // MARK: Fail-closed

    func testMalformedAdvertisedKeyIsRefusedAndNotPinned() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing)
        for bad in ["", "not-base64!!", Data(repeating: 0, count: 31).base64EncodedString()] {
            let result = store.verifyOrPin(advertisedKeyBase64: bad, uid: "u1", roleId: "host")
            XCTAssertEqual(result, .malformedAdvertisedKey, "rejected: \(bad)")
            XCTAssertFalse(result.admits(requireConfirmation: false))
        }
        XCTAssertNil(store.pinnedRecord(uid: "u1", roleId: "host"), "a malformed key must never be pinned")
    }

    func testFirstPinWriteFailureFailsClosed() {
        let backing = InMemoryControllerKeyPinBacking()
        backing.failWrites(with: -25300) // errSecItemNotFound-class write failure
        let store = makeStore(backing)
        let result = store.verifyOrPin(advertisedKeyBase64: newKeyBase64(), uid: "u1", roleId: "host")
        guard case .unknownKeychainError = result else { return XCTFail("expected unknownKeychainError, got \(result)") }
        XCTAssertFalse(result.admits(requireConfirmation: false), "an unpersisted pin must not admit")
    }

    func testUnreadableKeychainFailsClosed() {
        let backing = InMemoryControllerKeyPinBacking()
        backing.failReads(with: -25295) // errSecInteractionNotAllowed-class read failure
        let store = makeStore(backing)
        let result = store.verifyOrPin(advertisedKeyBase64: newKeyBase64(), uid: "u1", roleId: "host")
        guard case .unknownKeychainError = result else { return XCTFail("expected unknownKeychainError, got \(result)") }
        XCTAssertFalse(result.admits(requireConfirmation: false))
    }

    // MARK: Account scoping

    func testPinIsScopedByUid() {
        let backing = InMemoryControllerKeyPinBacking()
        let store = makeStore(backing)
        let key = newKeyBase64()
        _ = store.verifyOrPin(advertisedKeyBase64: key, uid: "u1", roleId: "host")
        // A different signed-in user has no pin yet — same key is a fresh first use.
        let other = store.verifyOrPin(advertisedKeyBase64: key, uid: "u2", roleId: "host")
        guard case .pinnedFirstUse = other else { return XCTFail("expected per-uid isolation, got \(other)") }
    }
}
