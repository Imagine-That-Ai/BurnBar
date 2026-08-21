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

    // MARK: - Consent must fail closed on the stored truth

    /// The regression guard for the Liquid Glass slider crash.
    ///
    /// The defaults observer used to branch on `Thread.isMainThread` and call
    /// `MainActor.assumeIsolated` on the true side, so that a main-thread write
    /// synchronized *inline* and no caller could observe a revoked opt-in while the
    /// store still said "yes". That branch was unsound — `isMainThread` is about the
    /// thread and `assumeIsolated` asserts on the executor — and it trapped the moment
    /// SwiftUI's `@AppStorage` setter posted the notification from a nonisolated
    /// context, which is every frame of a slider drag.
    ///
    /// Removing the branch means the mirror is refreshed by an async hop, so the
    /// invariant it was protecting has to hold without it: a revoke that has landed in
    /// `defaults` must take effect on the very next read, with no runloop turn in
    /// between. This test never pumps the runloop, so it fails if `canAutoAccept` ever
    /// goes back to trusting the in-memory mirror.
    func testCanAutoAccept_failsClosedOnARevokeThatHasNotBeenObservedYet() {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedMirrorPeers = true
        store.rememberAcceptedPeer(
            connectionId: "conn-a",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-a",
            remotePeerNodeId: "peer-a",
            requesterName: "Phone"
        )
        XCTAssertTrue(
            store.canAutoAccept(
                connectionId: "conn-a",
                viewerDeviceId: nil,
                controlAuthorityPeerNodeId: "peer-a",
                remotePeerNodeId: "peer-a"
            ),
            "Baseline: a live grant under a live opt-in auto-accepts"
        )

        // Revoke straight in `defaults`, exactly as another writer would — and do NOT
        // give the notification hop a chance to run.
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")

        XCTAssertFalse(
            store.canAutoAccept(
                connectionId: "conn-a",
                viewerDeviceId: nil,
                controlAuthorityPeerNodeId: "peer-a",
                remotePeerNodeId: "peer-a"
            ),
            "A revoke on disk must fail closed immediately, not one main-actor hop later"
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

    // MARK: - Explicit remembered-peer consent (2026-07-03)

    func test_rememberAcceptedMirrorPeersDefaultsOffWhenUnset() {
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers,
                       "an unset key must not silently turn one normal Accept into a remembered grant")
    }

    func test_explicitUserOptOutIsRespected() {
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers)
    }

    func test_normalAcceptDoesNotCreateGrantWhenRememberPreferenceUnset() {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedPeer(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            requesterName: "iPhone"
        )
        XCTAssertEqual(store.grants.count, 0,
                       "the default Mac-side Accept must not silently create a remembered grant")
    }

    func test_legacyAlwaysAllowTrueMigratesToRememberOnWhenNewPreferenceIsUnset() {
        defaults.set(true, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertTrue(store.rememberAcceptedMirrorPeers,
                      "an affirmative legacy choice may migrate only when the user has not chosen the new setting")
        XCTAssertTrue(defaults.bool(forKey: "mercuryRememberAcceptedMirrorPeers"))
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    func test_legacyAlwaysAllowPresenceDoesNotOverrideExplicitNewOptOut() {
        defaults.set(true, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers,
                       "an explicit new opt-out must beat the legacy key")
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    func test_legacyAlwaysAllowFalseDoesNotMigrateToRememberOn() {
        defaults.set(false, forKey: "mercuryAlwaysAllowMyIPhoneToMirror")
        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertFalse(store.rememberAcceptedMirrorPeers,
                       "legacy key presence alone is not consent")
        XCTAssertFalse(defaults.bool(forKey: "mercuryRememberAcceptedMirrorPeers"))
        XCTAssertNil(defaults.object(forKey: "mercuryAlwaysAllowMyIPhoneToMirror"))
    }

    /// Upgrade path from the previous default-on build: a grant was persisted
    /// by a normal Accept, but the user never explicitly chose the remember
    /// preference. With the preference resolving to off, that stored grant has
    /// no consent backing it and must be dropped, not silently honored.
    func test_persistedGrantsAreClearedWhenRememberPreferenceWasNeverSet() throws {
        let grants = [grant(connectionId: "conn-legacy", peer: "peer-legacy")]
        defaults.set(try JSONEncoder().encode(grants), forKey: "mercuryMirrorAutoAcceptGrants.v2")

        let store = MercuryConsentStore(defaults: defaults)

        XCTAssertFalse(store.rememberAcceptedMirrorPeers)
        XCTAssertEqual(store.grants.count, 0,
                       "grants persisted without an explicit opt-in must be cleared on load")
        XCTAssertFalse(store.canAutoAccept(
            connectionId: "conn-legacy",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-legacy",
            remotePeerNodeId: "peer-legacy"
        ), "a pre-opt-in grant must not bypass the approval UI")

        let reloaded = MercuryConsentStore(defaults: defaults)
        XCTAssertEqual(reloaded.grants.count, 0, "the cleared ledger must be persisted, not just hidden")
    }

    func test_persistedGrantsAreClearedWhenUserExplicitlyOptedOut() throws {
        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        let grants = [grant(connectionId: "conn-a", peer: "peer-a")]
        defaults.set(try JSONEncoder().encode(grants), forKey: "mercuryMirrorAutoAcceptGrants.v2")

        let store = MercuryConsentStore(defaults: defaults)
        XCTAssertEqual(store.grants.count, 0, "an explicit opt-out must clear remembered grants")
    }

    func test_autoAcceptRequiresLiveOptIn() {
        let store = MercuryConsentStore(defaults: defaults)
        store.rememberAcceptedMirrorPeers = true
        store.rememberAcceptedPeer(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            requesterName: "iPhone"
        )
        XCTAssertTrue(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123"
        ))

        store.rememberAcceptedMirrorPeers = false
        XCTAssertFalse(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123"
        ), "turning the preference off must immediately stop auto-accepts")
    }

    func test_externalSettingsOptOutImmediatelyUpdatesLiveStoreAndClearsGrants() async {
        let liveStore = MercuryConsentStore(defaults: defaults)
        liveStore.rememberAcceptedMirrorPeers = true
        liveStore.rememberAcceptedPeer(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "peer-1",
            remotePeerNodeId: "peer-1",
            requesterName: "iPhone"
        )
        XCTAssertEqual(liveStore.grants.count, 1)

        defaults.set(false, forKey: "mercuryRememberAcceptedMirrorPeers")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        // The defaults observer hops the main dispatch queue and then a
        // MainActor task; a single yield does not deterministically cover
        // both hops, so poll with a bounded deadline. The flag and the
        // grants clear in the same synchronize pass, so the flag flipping
        // means the whole external opt-out has been applied.
        let deadline = Date().addingTimeInterval(5)
        while liveStore.rememberAcceptedMirrorPeers, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(liveStore.rememberAcceptedMirrorPeers)
        XCTAssertTrue(liveStore.grants.isEmpty)
        XCTAssertFalse(liveStore.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "peer-1",
            remotePeerNodeId: "peer-1"
        ))
    }

    /// Grants serialized by the prior 365-day sliding implementation must not
    /// keep auto-accepting for up to a year: on load each grant is capped to
    /// `grantedAt + 30 days`.
    func test_overlongPersistedGrantIsCappedToCurrentTTLOnLoad() throws {
        defaults.set(true, forKey: "mercuryRememberAcceptedMirrorPeers")
        let now = Date()
        let staleGrant = MercuryConsentStore.MirrorAutoAcceptGrant(
            key: "conn-old|_|peer-old",
            connectionId: "conn-old",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-old",
            requesterName: "Old phone",
            grantedAt: now.addingTimeInterval(-40 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(300 * 24 * 60 * 60),
            lastUsedAt: nil
        )
        let freshOverlongGrant = MercuryConsentStore.MirrorAutoAcceptGrant(
            key: "conn-new|_|peer-new",
            connectionId: "conn-new",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-new",
            requesterName: "New phone",
            grantedAt: now.addingTimeInterval(-1 * 24 * 60 * 60),
            expiresAt: now.addingTimeInterval(364 * 24 * 60 * 60),
            lastUsedAt: nil
        )
        defaults.set(
            try JSONEncoder().encode([staleGrant, freshOverlongGrant]),
            forKey: "mercuryMirrorAutoAcceptGrants.v2"
        )

        let store = MercuryConsentStore(defaults: defaults)

        XCTAssertEqual(store.grants.map(\.key), [freshOverlongGrant.key],
                       "a grant older than the TTL must be pruned once capped")
        let capped = try XCTUnwrap(store.grants.first)
        XCTAssertEqual(
            capped.expiresAt.timeIntervalSince1970,
            freshOverlongGrant.grantedAt.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970,
            accuracy: 0.001,
            "a surviving overlong grant must expire 30 days after its original grant time"
        )
        XCTAssertFalse(store.canAutoAccept(
            connectionId: "conn-old",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-old",
            remotePeerNodeId: "peer-old"
        ))
        XCTAssertTrue(store.canAutoAccept(
            connectionId: "conn-new",
            viewerDeviceId: nil,
            controlAuthorityPeerNodeId: "peer-new",
            remotePeerNodeId: "peer-new"
        ))
    }

    func test_autoAcceptDoesNotSlideGrantExpiryForward() {
        // Pin the store's clock to the test epoch: the defaults observer
        // prunes grants against that clock on every persist, and this test's
        // timeline lives years away from the wall clock.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let store = MercuryConsentStore(defaults: defaults, clock: { t0 })
        store.rememberAcceptedMirrorPeers = true
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

        // Auto-accept inside the 30-day window: the grant is usable, but
        // usage must not renew it into an indefinite authorization.
        let t1 = t0.addingTimeInterval(10 * 24 * 60 * 60)
        XCTAssertTrue(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            now: t1
        ))
        let renewedExpiry = store.grants.first?.expiresAt
        XCTAssertNotNil(renewedExpiry)
        XCTAssertEqual(renewedExpiry!, firstExpiry!,
                       "auto-accepted sessions must not extend the grant")

        // A device dormant past the TTL expires and must ring again.
        let t2 = t0.addingTimeInterval(31 * 24 * 60 * 60)
        XCTAssertFalse(store.canAutoAccept(
            connectionId: "conn-1",
            viewerDeviceId: "device-1",
            controlAuthorityPeerNodeId: "abc123",
            remotePeerNodeId: "ABC123",
            now: t2
        ))
    }
}
