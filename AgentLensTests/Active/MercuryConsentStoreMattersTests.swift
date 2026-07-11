import Combine
import XCTest
@testable import OpenBurnBar

/// Covers the fix for the formerly-swallowed `try?` on the JSONEncoder write in
/// `MercuryConsentStore.persist()`. That store is the Mac-side mirror consent ledger:
/// it persists the device-scoped auto-accept grants that let a phone mirror this Mac
/// without a fresh prompt. The prior `let data = try? JSONEncoder().encode(grants)`
/// collapsed a genuine encode fault into `nil`, and the following
/// `defaults.set(data, forKey:)` then wrote `nil` — silently erasing the entire
/// persisted consent ledger from disk.
///
/// The corrected `persist()` fails closed: a failed encode leaves the previously
/// stored ledger intact (never overwrites the key with `nil`) and surfaces the fault
/// through `AppLogger.dataStore`. The encode seam is injected through the new
/// `init(defaults:encodeGrants:)` parameter and the static `encodeGrants(_:encode:)`
/// helper, so the failure path is exercised deterministically without needing a real
/// JSONEncoder fault.
@MainActor
final class MercuryConsentStoreMattersTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MercuryConsentStoreMattersTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private struct EncodeError: Error {}

    private func grant(connectionId: String, peer: String) -> MercuryConsentStore.MirrorAutoAcceptGrant {
        MercuryConsentStore.MirrorAutoAcceptGrant(
            key: "\(connectionId)|_|\(peer)",
            connectionId: connectionId,
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: peer,
            requesterName: "Test peer",
            grantedAt: Date(),
            expiresAt: Date().addingTimeInterval(60 * 60),
            lastUsedAt: nil
        )
    }

    // MARK: - Static encode helper

    /// Happy path: a well-formed ledger encodes to non-nil JSON that round-trips back
    /// to the same grants. This guards the contract that a successful encode actually
    /// produces the bytes `persist()` will store.
    func testEncodeGrants_returnsRoundTrippableData() throws {
        let grants = [grant(connectionId: "conn-a", peer: "peer-a")]
        let data = try XCTUnwrap(MercuryConsentStore.encodeGrants(grants),
                                 "Well-formed grants must encode to non-nil data")
        let decoded = try JSONDecoder().decode([MercuryConsentStore.MirrorAutoAcceptGrant].self, from: data)
        XCTAssertEqual(decoded, grants, "Encoded ledger must round-trip unchanged")
    }

    /// Fault path: when the encode closure throws, the helper must return `nil` (so the
    /// caller can fail closed) rather than propagating or crashing.
    func testEncodeGrants_returnsNilWhenEncoderThrows() {
        let grants = [grant(connectionId: "conn-a", peer: "peer-a")]
        let data = MercuryConsentStore.encodeGrants(grants, encode: { _ in throw EncodeError() })
        XCTAssertNil(data, "A throwing encode must return nil so the caller fails closed")
    }

    // MARK: - Store-level fail-closed persistence

    /// The core security property: if the on-write encode fails, the store must NOT
    /// erase the consent ledger that is already on disk. We seed a real persisted
    /// ledger via a healthy store, then construct a second store whose encoder always
    /// throws, mutate it (which triggers `persist()`), and assert the originally
    /// persisted bytes survive untouched in UserDefaults.
    func testPersistFailure_doesNotEraseExistingLedger() throws {
        let key = "mercuryMirrorAutoAcceptGrants.v2"

        // 1. Seed a real ledger with a healthy store.
        let healthy = MercuryConsentStore(defaults: defaults)
        healthy.rememberAcceptedMirrorPeers = true
        healthy.rememberAcceptedPeer(
            connectionId: "conn-a",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-a",
            remotePeerNodeId: "peer-a",
            requesterName: "Phone"
        )
        let seeded = try XCTUnwrap(defaults.data(forKey: key),
                                   "Healthy store must persist the seeded grant")
        XCTAssertEqual(healthy.grants.count, 1)

        // 2. New store with an encoder that always throws on write.
        let failing = MercuryConsentStore(
            defaults: defaults,
            encodeGrants: { _ in throw EncodeError() }
        )
        XCTAssertEqual(failing.grants.count, 1, "Failing store still reads the seeded ledger")

        // 3. Mutate it so persist() runs with the throwing encoder.
        failing.rememberAcceptedMirrorPeers = true
        failing.rememberAcceptedPeer(
            connectionId: "conn-b",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-b",
            remotePeerNodeId: "peer-b",
            requesterName: "Phone 2"
        )

        // 4. The persisted ledger on disk must be UNCHANGED — never wiped to nil.
        let afterFailure = try XCTUnwrap(defaults.data(forKey: key),
                                         "Failed encode must not erase the persisted ledger")
        XCTAssertEqual(afterFailure, seeded,
                       "A failed encode must leave the prior persisted bytes intact (no nil overwrite)")
    }

    /// Counter-proof on the happy path: with a working encoder, the same mutation that
    /// the failing store could not persist DOES update the stored ledger and survives a
    /// reload into a fresh store. This pins that the guard only blocks the failure case.
    func testPersistSuccess_updatesAndReloadsLedger() throws {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedMirrorPeers = true
        store.rememberAcceptedPeer(
            connectionId: "conn-a",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-a",
            remotePeerNodeId: "peer-a",
            requesterName: "Phone"
        )
        XCTAssertEqual(store.grants.count, 1)

        let reloaded = MercuryConsentStore(defaults: defaults)
        XCTAssertEqual(reloaded.grants.count, 1, "Successful persist must survive a reload")
        XCTAssertTrue(
            reloaded.canAutoAccept(
                connectionId: "conn-a",
                viewerDeviceId: nil,
                controlAuthorityPeerNodeId: "peer-a",
                remotePeerNodeId: "peer-a"
            ),
            "Reloaded ledger must still authorize the persisted peer"
        )
    }

    func testActiveGrantCountDoesNotPublishWhileRendering() {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedMirrorPeers = true
        store.rememberAcceptedPeer(
            connectionId: "conn-a",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-a",
            remotePeerNodeId: "peer-a",
            requesterName: "Phone"
        )

        var publishCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            publishCount += 1
        }

        XCTAssertEqual(store.activeGrantCount, 1)
        XCTAssertEqual(store.activeGrantCount, 1)
        XCTAssertEqual(publishCount, 0, "Reading activeGrantCount from a SwiftUI body must not publish")
        cancellable.cancel()
    }

    // MARK: - Remember-by-default + sliding renewal (2026-07-03)

    func test_rememberAcceptedMirrorPeersDefaultsOnWhenUnset() {
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertTrue(store.rememberAcceptedMirrorPeers,
                      "an unset key must default to remembering, so users only Accept once")
    }

    func test_explicitUserOptOutIsRespected() {
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers)
    }

    func test_legacyAlwaysAllowMigratesToRememberOn() {
        defaults.set(true, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertTrue(store.rememberAcceptedMirrorPeers,
                      "the legacy global consent was broader than device-bound grants; carry intent forward")
        XCTAssertTrue(defaults.bool(forKey: "mercuryRememberAcceptedMirrorPeers"),
                      "legacy migration must persist remember-on, not just mutate the launch-time store")
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    func test_legacyAlwaysAllowDoesNotOverrideExplicitRememberOptOut() {
        defaults.set(true, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers,
                       "an explicit remember opt-out must beat the broader legacy allow bit")
        XCTAssertFalse(defaults.bool(forKey: "mercuryRememberAcceptedMirrorPeers"),
                       "legacy migration must not persist remember-on over an explicit opt-out")
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    func test_legacyAlwaysAllowFalseDoesNotOverrideExplicitRememberOptIn() {
        defaults.set(false, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        defaults.set(true, forKey: "mercuryRememberAcceptedMirrorPeers")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertTrue(store.rememberAcceptedMirrorPeers,
                      "an explicit remember opt-in must beat the obsolete legacy opt-out")
        XCTAssertTrue(defaults.bool(forKey: "mercuryRememberAcceptedMirrorPeers"),
                      "legacy migration must preserve the explicit remember-on choice")
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    func test_liveStoresObserveRememberOptOutChanges() async {
        let routerStore = MercuryConsentStore(defaults: defaults)
        let settingsStore = MercuryConsentStore(defaults: defaults)
        XCTAssertTrue(routerStore.rememberAcceptedMirrorPeers)

        settingsStore.rememberAcceptedMirrorPeers = false
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        await Task.yield()

        XCTAssertFalse(routerStore.rememberAcceptedMirrorPeers,
                       "the live router store must observe Settings opt-outs without waiting for restart")
    }

    func test_autoAcceptSlidesGrantExpiryForward() {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedMirrorPeers = true
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        store.rememberAcceptedPeer(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            requesterName: "iPhone",
            now: t0
        )
        let firstExpiry = store.grants.first?.expiresAt
        XCTAssertNotNil(firstExpiry)

        // Auto-accept 200 days later: still inside the window, and the grant
        // must renew so an actively-used device never re-rings the Mac.
        let t1 = t0.addingTimeInterval(200 * 24 * 60 * 60)
        XCTAssertTrue(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            now: t1
        ))
        store.renewAutoAcceptGrant(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            now: t1
        )
        let renewedExpiry = store.grants.first?.expiresAt
        XCTAssertNotNil(renewedExpiry)
        XCTAssertGreaterThan(renewedExpiry!, firstExpiry!,
                             "each auto-accepted session must extend the grant (sliding window)")

        // A device dormant past the TTL expires and must ring again.
        let t2 = t1.addingTimeInterval(400 * 24 * 60 * 60)
        XCTAssertFalse(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            now: t2
        ))
    }
}
