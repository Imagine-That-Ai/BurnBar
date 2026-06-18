import XCTest
@testable import OpenBurnBar

/// The recorder is the one wrapper every instrumentation call goes through.
/// These assert the three contract guarantees — silent before consent, correct
/// name/category/props after opt-in, silent after revoke — plus lifecycle.
/// Uses `FakeAnalyticsTransport` from AnalyticsTestSupport.
@MainActor
final class AnalyticsRecorderTests: XCTestCase {

    private func makeRecorder(granted: Bool) -> (Analytics, FakeAnalyticsTransport, AnalyticsConsentStore) {
        let consent = AnalyticsConsentStore(defaults: makeIsolatedAnalyticsDefaults())
        if granted { consent.grant() }
        let transport = FakeAnalyticsTransport()
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { ["platform": "macos", "app_version": "9.9.9"] }
        )
        return (analytics, transport, consent)
    }

    func test_track_beforeConsent_sendsNothing_andNeverStarts() {
        let (analytics, transport, _) = makeRecorder(granted: false)
        analytics.track(.dashboardScanRun, ["trigger_source": "toolbar"])
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertFalse(transport.isStarted)
        XCTAssertEqual(transport.startCount, 0)
    }

    func test_track_afterGrant_sendsWithNameCategoryAndSuperProps() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.track(.dashboardScanRun, ["trigger_source": "toolbar"])
        XCTAssertEqual(transport.sent.count, 1)
        let e = transport.sent[0]
        XCTAssertEqual(e.name, "dashboard.scan.run")
        XCTAssertEqual(e.category, "primary_action")
        XCTAssertEqual(e.properties["trigger_source"], "toolbar")
        XCTAssertEqual(e.properties["platform"], "macos")
        XCTAssertEqual(e.properties["app_version"], "9.9.9")
    }

    func test_consentDidChange_toGranted_startsAndEmitsConsentGrantedOnce() {
        let (analytics, transport, consent) = makeRecorder(granted: false)
        consent.grant()
        analytics.consentDidChange()
        XCTAssertTrue(transport.isStarted)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].name, "consent.analytics.granted")
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
        XCTAssertEqual(transport.stopCount, 1)

        let before = transport.sent.count
        analytics.track(.chatMessageSent, ["backend": "hermes"])
        XCTAssertEqual(transport.sent.count, before, "No sends after revoke")
    }

    func test_track_afterGrant_lazilyStartsTransport() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        XCTAssertFalse(transport.isStarted)
        analytics.track(.appSessionStarted, [:])
        XCTAssertTrue(transport.isStarted)
    }

    func test_booleanProperties_arePreserved() {
        let (analytics, transport, _) = makeRecorder(granted: true)
        analytics.track(.appSessionStarted, ["is_first_launch": true, "cold_start": false])
        XCTAssertEqual(transport.sent[0].properties["is_first_launch"], .bool(true))
        XCTAssertEqual(transport.sent[0].properties["cold_start"], .bool(false))
    }

    func test_setUserId_onlyForwardsWhenGranted() {
        let (analytics, transport, consent) = makeRecorder(granted: false)
        analytics.setUserId("abc123")
        XCTAssertNil(transport.userId, "No identity before consent")
        consent.grant()
        analytics.setUserId("abc123")
        XCTAssertEqual(transport.userId, "abc123")
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
    }
}
