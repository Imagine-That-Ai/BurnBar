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
        guard case .pinnedFirstUse = result else {
            XCTFail("expected pinnedFirstUse, got \(result)")
            return
        }
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
        guard case .matchesPendingConfirmation = again else {
            XCTFail("expected matchesPendingConfirmation, got \(again)")
            return
        }
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
        guard case .mismatch = result else {
            XCTFail("expected mismatch, got \(result)")
            return
        }
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
        guard case .pinnedFirstUse = result else {
            XCTFail("re-pair should pin the new key, got \(result)")
            return
        }
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
        guard case .unknownKeychainError = result else {
            XCTFail("expected unknownKeychainError, got \(result)")
            return
        }
        XCTAssertFalse(result.admits(requireConfirmation: false), "an unpersisted pin must not admit")
    }

    func testConcurrentFirstPinDuplicateReusesOnlyTheSameDurableKey() {
        let key = newKeyBase64()
        let backing = ConcurrentFirstPinRaceBacking(
            durableRecord: ControllerPinRecord(
                keyBase64: key,
                confirmed: false,
                pinnedAtEpoch: 1
            ),
            saveStatus: -25_299
        )
        let store = IrohHostKeyPinStore(backing: backing)

        let result = store.verifyOrPin(
            advertisedKeyBase64: key,
            uid: "u1",
            roleId: "host"
        )

        guard case .matchesPendingConfirmation = result else {
            XCTFail("the losing concurrent writer should reuse the identical durable pin, got \(result)")
            return
        }
        XCTAssertTrue(result.admits(requireConfirmation: false))
    }

    func testConcurrentFirstPinDuplicateRefusesDifferentDurableKey() {
        let advertised = newKeyBase64()
        let durable = newKeyBase64()
        let backing = ConcurrentFirstPinRaceBacking(
            durableRecord: ControllerPinRecord(
                keyBase64: durable,
                confirmed: false,
                pinnedAtEpoch: 1
            ),
            saveStatus: -25_299
        )
        let store = IrohHostKeyPinStore(backing: backing)

        let result = store.verifyOrPin(
            advertisedKeyBase64: advertised,
            uid: "u1",
            roleId: "host"
        )

        guard case .mismatch = result else {
            XCTFail("a concurrent writer that pinned another key must remain fail-closed, got \(result)")
            return
        }
        XCTAssertFalse(result.admits(requireConfirmation: false))
    }

    func testNonDuplicateFirstPinWriteFailureDoesNotReuseMatchingLaterRead() {
        let key = newKeyBase64()
        let backing = ConcurrentFirstPinRaceBacking(
            durableRecord: ControllerPinRecord(
                keyBase64: key,
                confirmed: true,
                pinnedAtEpoch: 1
            ),
            saveStatus: -34_018
        )
        let store = IrohHostKeyPinStore(backing: backing)

        let result = store.verifyOrPin(
            advertisedKeyBase64: key,
            uid: "u1",
            roleId: "host"
        )

        XCTAssertEqual(result, .unknownKeychainError(status: -34_018))
        XCTAssertFalse(result.admits(requireConfirmation: false))
        XCTAssertEqual(backing.loadCount, 1, "non-duplicate failures must not trigger a durable reread")
    }

    func testUnreadableKeychainFailsClosed() {
        let backing = InMemoryControllerKeyPinBacking()
        backing.failReads(with: -25295) // errSecInteractionNotAllowed-class read failure
        let store = makeStore(backing)
        let result = store.verifyOrPin(advertisedKeyBase64: newKeyBase64(), uid: "u1", roleId: "host")
        guard case .unknownKeychainError = result else {
            XCTFail("expected unknownKeychainError, got \(result)")
            return
        }
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
        guard case .pinnedFirstUse = other else {
            XCTFail("expected per-uid isolation, got \(other)")
            return
        }
    }
}

private final class ConcurrentFirstPinRaceBacking: ControllerKeyPinBacking, @unchecked Sendable {
    private let lock = NSLock()
    private let durableRecord: ControllerPinRecord
    private let saveStatus: Int32
    private var firstLoad = true
    private var storedLoadCount = 0

    init(durableRecord: ControllerPinRecord, saveStatus: Int32) {
        self.durableRecord = durableRecord
        self.saveStatus = saveStatus
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    func load(account: String) -> ControllerKeyPinLoad {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        if firstLoad {
            firstLoad = false
            return .absent
        }
        return .found(durableRecord)
    }

    func save(_ record: ControllerPinRecord, account: String) -> Int32 {
        saveStatus
    }

    func delete(account: String) {}
}
