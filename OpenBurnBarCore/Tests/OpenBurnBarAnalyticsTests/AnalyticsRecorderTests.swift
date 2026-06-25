import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// The recorder is the one wrapper every instrumentation call goes through.
/// These assert the contract guarantees — silent before consent, correct
/// name/category/props after opt-in, silent after revoke, no-key dark — plus
/// lifecycle. Uses `FakeAnalyticsTransport` from AnalyticsTestSupport.
@MainActor
final class AnalyticsRecorderTests: XCTestCase {

    private func makeRecorder(
        granted: Bool,
        authenticatedUserId: @escaping () -> String? = { nil }
    ) -> (Analytics, FakeAnalyticsTransport, AnalyticsConsentStore) {
        let consent = AnalyticsConsentStore(defaults: makeIsolatedAnalyticsDefaults())
        if granted { consent.grant() }
        let transport = FakeAnalyticsTransport()
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { ["platform": "ios", "app_version": "9.9.9"] },
            authenticatedUserId: authenticatedUserId
        )
        return (analytics, transport, consent)
    }

    func test_track_beforeConsent_sendsNothing_andNeverStarts() {
        let (analytics, transport, _) = makeRecorder(granted: false)
        analytics.track(.screenViewed, ["surface": "dashboard_overview"])
        XCTAssertTrue(transport.sent.isEmpty, "ZERO events before affirmative opt-in")
        XCTAssertFalse(transport.isStarted, "SDK transport must never start pre-consent")
        XCTAssertEqual(transport.startCount, 0, "the SDK is never even constructed/started")
    }

    func test_track_afterGrant_sendsWithNameCategoryAndSuperProps() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.track(.mobileTabSelected, ["tab": "dashboard"])
        XCTAssertEqual(transport.sent.count, 1)
        let e = transport.sent[0]
        XCTAssertEqual(e.name, "mobile.tab.selected")
        XCTAssertEqual(e.category, "screen_view")
        XCTAssertEqual(e.properties["tab"], "dashboard")
        XCTAssertEqual(e.properties["platform"], "ios")
        XCTAssertEqual(e.properties["app_version"], "9.9.9")
    }

    func test_consentDidChange_toGranted_startsAndEmitsConsentGrantedOnce() {
        let (analytics, transport, consent) = makeRecorder(granted: false)
        consent.grant()
        analytics.consentDidChange()
        XCTAssertTrue(transport.isStarted)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].name, "consent.analytics.granted")
        XCTAssertEqual(transport.sent[0].category, "lifecycle")
        XCTAssertEqual(transport.sent[0].properties["consent_version"], "1")
        // Idempotent: a second consentDidChange must not re-announce.
        analytics.consentDidChange()
        XCTAssertEqual(transport.sent.filter { $0.name == "consent.analytics.granted" }.count, 1)
    }

    func test_revoke_stopsTransport_andSilencesFurtherTracks() {
        let (analytics, transport, consent) = makeRecorder(granted: true)
        analytics.track(.chatMessageSent, ["backend": "hermes"])
        XCTAssertEqual(transport.sent.count, 1)

        consent.revoke()
        analytics.consentDidChange()
        XCTAssertFalse(transport.isStarted)
        XCTAssertEqual(transport.stopCount, 1, "revoke tears down the client (flushes nothing)")

        let before = transport.sent.count
        analytics.track(.chatMessageSent, ["backend": "hermes"])
        XCTAssertEqual(transport.sent.count, before, "No sends after revoke")
    }

    func test_track_afterSharedStorageRevocation_dropsWithoutConsentCallback() {
        let defaults = makeIsolatedAnalyticsDefaults()
        let consent = AnalyticsConsentStore(defaults: defaults)
        consent.grant()
        let transport = FakeAnalyticsTransport()
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { ["platform": "ios"] }
        )

        analytics.track(.widgetRendered, ["family": "burnbar"])
        XCTAssertEqual(transport.sent.count, 1)

        defaults.set(AnalyticsConsent.declined.rawValue, forKey: AnalyticsConsentStore.key)

        analytics.track(.widgetRendered, ["family": "burnbar"])
        XCTAssertEqual(
            transport.sent.count,
            1,
            "Long-lived widget/keyboard analytics instances must observe host revocation before another byte is sent"
        )
    }

    func test_revoke_emitsNoRevokedEvent() {
        let (analytics, transport, consent) = makeRecorder(granted: true)
        analytics.startIfConsented()
        consent.revoke()
        analytics.consentDidChange()
        XCTAssertFalse(
            transport.sent.contains { $0.name.contains("revoke") || $0.name.contains("declined") },
            "Revoking must emit nothing — a send after revoke would violate the gate"
        )
    }

    func test_track_afterGrant_lazilyStartsTransport() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        XCTAssertFalse(transport.isStarted, "granting consent does not eagerly start; first track does")
        analytics.track(.appSessionStarted, [:])
        XCTAssertTrue(transport.isStarted)
        XCTAssertEqual(transport.startCount, 1)
    }

    func test_booleanProperties_arePreserved() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.track(.appSessionStarted, ["is_first_launch": true, "cold_start": false])
        XCTAssertEqual(transport.sent[0].properties["is_first_launch"], .bool(true))
        XCTAssertEqual(transport.sent[0].properties["cold_start"], .bool(false))
    }

    func test_eventProps_overrideSuperProps() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.track(.screenViewed, ["platform": "ipados"]) // event prop wins
        XCTAssertEqual(transport.sent[0].properties["platform"], "ipados")
    }

    func test_setUserId_onlyForwardsWhenGranted() {
        let (analytics, transport, consent) = makeRecorder(granted: false)
        analytics.setUserId("abc123")
        XCTAssertNil(transport.userId, "No identity before consent")
        consent.grant()
        analytics.setUserId("abc123")
        XCTAssertEqual(transport.userId, "abc123")
    }

    // MARK: - Re-identify on a fresh grant (sign-in BEFORE opt-in)

    /// The bug this guards: a user signs in while consent is unset (so AuthStore's
    /// `setUserId` is a no-op), then grants later. No auth-state change fires on
    /// grant, so without re-identification the authenticated user is never tied to
    /// the account. On grant, the recorder must pull the already-hashed uid and set
    /// it on the transport.
    func test_consentDidChange_toGranted_whenAlreadySignedIn_reidentifies() {
        let (analytics, transport, consent) = makeRecorder(
            granted: false,
            authenticatedUserId: { "hashed-uid-abc" }
        )
        XCTAssertNil(transport.userId, "anonymous before opt-in")
        consent.grant()
        analytics.consentDidChange()
        XCTAssertEqual(transport.userId, "hashed-uid-abc",
                       "a grant while already signed in must re-identify with the account hash")
        XCTAssertTrue(transport.isStarted)
        XCTAssertEqual(transport.sent.filter { $0.name == "consent.analytics.granted" }.count, 1)
    }

    /// Dark-by-default / anonymity: granting while signed OUT (provider yields nil)
    /// must NOT set any user id — the session stays anonymous (`device_id` only).
    func test_consentDidChange_toGranted_whenSignedOut_staysAnonymous() {
        let (analytics, transport, consent) = makeRecorder(
            granted: false,
            authenticatedUserId: { nil }
        )
        consent.grant()
        analytics.consentDidChange()
        XCTAssertNil(transport.userId, "no auth → no user_id; remains anonymous on grant")
        XCTAssertTrue(transport.isStarted)
    }

    /// The provider is only consulted under the granted gate: it must never set an
    /// id while consent is off, even if a session is authenticated.
    func test_consentDidChange_toDeclined_neverReidentifies() {
        let (analytics, transport, consent) = makeRecorder(
            granted: false,
            authenticatedUserId: { "hashed-uid-abc" }
        )
        consent.decline()
        analytics.consentDidChange()
        XCTAssertNil(transport.userId, "declined consent must never identify a user")
        XCTAssertFalse(transport.isStarted)
    }

    func test_startIfConsented_resumesWithoutReemittingGrant() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.startIfConsented()
        XCTAssertTrue(transport.isStarted)
        XCTAssertTrue(transport.sent.isEmpty, "no consent.granted re-emitted on a resumed session")
    }

    func test_startIfConsented_whenNotConsented_staysDark() {
        let (analytics, transport, _) = makeRecorder(granted: false)
        analytics.startIfConsented()
        XCTAssertFalse(transport.isStarted)
        XCTAssertTrue(transport.sent.isEmpty)
    }

    // MARK: - No-key darkness (proved at the transport seam the recorder drives)

    func test_noApiKey_staysDark_evenWhenConsentGranted() {
        let consent = AnalyticsConsentStore(defaults: makeIsolatedAnalyticsDefaults())
        consent.grant()
        let keyless = KeylessAnalyticsTransport()
        let analytics = Analytics(
            consent: consent,
            transport: keyless,
            superProperties: { ["platform": "ios"] }
        )
        analytics.consentDidChange() // would announce grant, but keyless transport never starts
        analytics.track(.appSessionStarted, [:])
        XCTAssertFalse(keyless.isStarted, "no key → the client is never constructed")
        XCTAssertTrue(keyless.sent.isEmpty, "no key → nothing is ever sent, even with consent granted")
    }
}
