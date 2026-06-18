import XCTest
@testable import OpenBurnBar

/// The opt-in gate is the spine: no Amplitude init and no egress until `isGranted`
/// is true. These pin that contract — default dark, `unset`/`declined` identical
/// to the gate, persistence, and revoke re-darkening.
@MainActor
final class AnalyticsConsentStoreTests: XCTestCase {

    private func makeDefaults(_ tag: String = "t") -> UserDefaults {
        UserDefaults(suiteName: "analytics.consent.\(tag).\(UUID().uuidString)")!
    }

    func test_default_isUnset_andNotGranted_andUndecided() {
        let store = AnalyticsConsentStore(defaults: makeDefaults())
        XCTAssertEqual(store.consent, .unset)
        XCTAssertFalse(store.isGranted, "A fresh install must never be granted by default")
        XCTAssertFalse(store.hasDecided, "An untouched gate is undecided, so the first-run prompt shows")
    }

    func test_grant_setsGranted_andIsTheOnlyStateThatOpensTheGate() {
        let store = AnalyticsConsentStore(defaults: makeDefaults())
        store.grant()
        XCTAssertEqual(store.consent, .granted)
        XCTAssertTrue(store.isGranted)
        XCTAssertTrue(store.hasDecided)
    }

    func test_grant_persistsAcrossStoreInstances() {
        let defaults = makeDefaults("persist")
        AnalyticsConsentStore(defaults: defaults).grant()
        let reloaded = AnalyticsConsentStore(defaults: defaults)
        XCTAssertEqual(reloaded.consent, .granted)
        XCTAssertTrue(reloaded.isGranted)
    }

    func test_decline_keepsGateClosed_butCountsAsDecided() {
        let store = AnalyticsConsentStore(defaults: makeDefaults())
        store.decline()
        XCTAssertEqual(store.consent, .declined)
        XCTAssertFalse(store.isGranted, "Declined keeps analytics dark, exactly like unset")
        XCTAssertTrue(store.hasDecided, "Declining is a decision; do not re-prompt")
    }

    func test_unsetAndDeclined_areIndistinguishableToTheGate() {
        let unset = AnalyticsConsentStore(defaults: makeDefaults("u"))
        let declined = AnalyticsConsentStore(defaults: makeDefaults("d"))
        declined.decline()
        XCTAssertEqual(unset.isGranted, declined.isGranted)
        XCTAssertFalse(unset.isGranted)
        XCTAssertFalse(declined.isGranted)
    }

    func test_revokeAfterGrant_closesGate_andPersists() {
        let defaults = makeDefaults("revoke")
        let store = AnalyticsConsentStore(defaults: defaults)
        store.grant()
        XCTAssertTrue(store.isGranted)

        store.revoke()
        XCTAssertEqual(store.consent, .declined, "Revoke lands in declined, never back to unset")
        XCTAssertFalse(store.isGranted)

        let reloaded = AnalyticsConsentStore(defaults: defaults)
        XCTAssertFalse(reloaded.isGranted, "A revoked decision survives relaunch")
        XCTAssertEqual(reloaded.consent, .declined)
    }
}
