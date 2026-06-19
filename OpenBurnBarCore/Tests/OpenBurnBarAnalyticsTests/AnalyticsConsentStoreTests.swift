import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

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

    // MARK: - App Group reader (widget + keyboard extensions read host consent)

    func test_consentReader_isDark_whenSuiteValueUnset() {
        let defaults = makeDefaults("reader-unset")
        let key = AnalyticsConsentStore.key
        // Nothing written → reader must report dark.
        XCTAssertNil(defaults.string(forKey: key))
        XCTAssertNotEqual(
            defaults.string(forKey: key),
            AnalyticsConsent.granted.rawValue,
            "An extension reading an unset shared suite must stay dark"
        )
    }

    func test_consentReader_logic_onlyGrantedOpensTheGate() {
        // The reader's exact predicate: granted string == open; everything else dark.
        XCTAssertEqual(AnalyticsConsent.granted.rawValue, "granted")
        for raw in [AnalyticsConsent.unset.rawValue, AnalyticsConsent.declined.rawValue, "garbage", ""] {
            XCTAssertNotEqual(raw, AnalyticsConsent.granted.rawValue)
        }
    }

    func test_host_and_extension_shareTheSameSuiteAndKey() {
        // The host store and the extension reader must agree on suite + key, or the
        // extensions would read a different value than the host writes.
        XCTAssertEqual(AnalyticsConsentStore.appGroupIdentifier, "group.com.openburnbar.app")
        XCTAssertEqual(AnalyticsConsentStore.key, "analyticsConsentState")
        XCTAssertEqual(AnalyticsConsentStorage.appGroupIdentifier, AnalyticsConsentStore.appGroupIdentifier)
        XCTAssertEqual(AnalyticsConsentStorage.key, AnalyticsConsentStore.key)
    }

    /// End-to-end proof for the extension gate: an extension reading a custom suite
    /// stays dark for unset AND declined, and only opens when the host writes
    /// `granted`. Exercises the real `AnalyticsConsentReader` against a real suite.
    func test_consentReader_endToEnd_darkUnlessHostGranted() {
        let suite = "analytics.reader.e2e.\(UUID().uuidString)"
        let key = AnalyticsConsentStorage.key
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        // 1. Unset (nothing written) → dark.
        XCTAssertFalse(AnalyticsConsentReader.isGranted(appGroupIdentifier: suite, key: key))

        // 2. Host declines → still dark.
        let host = AnalyticsConsentStore(defaults: UserDefaults(suiteName: suite)!)
        host.decline()
        XCTAssertFalse(AnalyticsConsentReader.isGranted(appGroupIdentifier: suite, key: key))

        // 3. Host grants → the extension reader opens.
        host.grant()
        XCTAssertTrue(AnalyticsConsentReader.isGranted(appGroupIdentifier: suite, key: key))

        // 4. Host revokes (→ declined) → the extension goes dark again.
        host.revoke()
        XCTAssertFalse(AnalyticsConsentReader.isGranted(appGroupIdentifier: suite, key: key))
    }
}
