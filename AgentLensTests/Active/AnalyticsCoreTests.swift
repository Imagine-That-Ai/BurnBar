import XCTest
@testable import OpenBurnBar

/// Bucketing is the anti-fingerprinting core: raw counts/durations/amounts are
/// never sent; they map to coarse, canonical buckets identical on every platform.
final class AnalyticsBucketsTests: XCTestCase {

    func test_durationMs_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.durationMs(50), "<100ms")
        XCTAssertEqual(AnalyticsBuckets.durationMs(100), "100-500ms")
        XCTAssertEqual(AnalyticsBuckets.durationMs(499), "100-500ms")
        XCTAssertEqual(AnalyticsBuckets.durationMs(500), "500ms-1s")
        XCTAssertEqual(AnalyticsBuckets.durationMs(1500), "1-3s")
        XCTAssertEqual(AnalyticsBuckets.durationMs(5000), "3-10s")
        XCTAssertEqual(AnalyticsBuckets.durationMs(20000), "10-30s")
        XCTAssertEqual(AnalyticsBuckets.durationMs(45000), ">30s")
        XCTAssertEqual(AnalyticsBuckets.durationMs(-1), "<100ms")
    }

    func test_count_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.count(0), "0")
        XCTAssertEqual(AnalyticsBuckets.count(1), "1")
        XCTAssertEqual(AnalyticsBuckets.count(3), "2-5")
        XCTAssertEqual(AnalyticsBuckets.count(20), "6-20")
        XCTAssertEqual(AnalyticsBuckets.count(50), "21-100")
        XCTAssertEqual(AnalyticsBuckets.count(300), "101-500")
        XCTAssertEqual(AnalyticsBuckets.count(9999), ">500")
        XCTAssertEqual(AnalyticsBuckets.count(-5), "0")
    }

    func test_amountUSD_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.amountUSD(0), "0")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(0.5), "<1")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(5), "1-10")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(25), "10-50")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(75), "50-100")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(250), "100-500")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(1000), ">500")
    }

    func test_percent_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.percent(5), "0-10")
        XCTAssertEqual(AnalyticsBuckets.percent(20), "10-25")
        XCTAssertEqual(AnalyticsBuckets.percent(40), "25-50")
        XCTAssertEqual(AnalyticsBuckets.percent(60), "50-75")
        XCTAssertEqual(AnalyticsBuckets.percent(80), "75-90")
        XCTAssertEqual(AnalyticsBuckets.percent(95), "90-100")
        XCTAssertEqual(AnalyticsBuckets.percent(150), "90-100")
    }

    func test_sizeBytes_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(500), "<1KB")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(50_000), "1-100KB")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(500_000), "100KB-1MB")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(5_000_000), "1-10MB")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(50_000_000), "10-100MB")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(500_000_000), ">100MB")
    }

    func test_durationSeconds_boundaries() {
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(2), "<5s")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(20), "5-30s")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(90), "30s-2m")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(300), "2-10m")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(1800), "10-60m")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(5000), ">60m")
    }

    func test_toolName_knownToolsUseClosedBuckets() {
        XCTAssertEqual(AnalyticsBuckets.toolName("Read"), "file_read")
        XCTAssertEqual(AnalyticsBuckets.toolName("Write"), "file_write")
        XCTAssertEqual(AnalyticsBuckets.toolName("EditFile"), "file_edit")
        XCTAssertEqual(AnalyticsBuckets.toolName("bash"), "terminal")
        XCTAssertEqual(AnalyticsBuckets.toolName("grep-search"), "search")
        XCTAssertEqual(AnalyticsBuckets.toolName("WebFetch"), "web")
        XCTAssertEqual(AnalyticsBuckets.toolName("memory"), "memory")
        XCTAssertEqual(AnalyticsBuckets.toolName("browser_screenshot"), "browser")
        XCTAssertEqual(AnalyticsBuckets.toolName("clipboard_read"), "clipboard")
        XCTAssertEqual(AnalyticsBuckets.toolName("todo_write"), "todo")
    }

    func test_toolName_unknownOrSensitiveValuesDoNotReachAnalytics() {
        XCTAssertEqual(AnalyticsBuckets.toolName(nil), "unknown")
        XCTAssertEqual(AnalyticsBuckets.toolName("   "), "unknown")
        XCTAssertEqual(
            AnalyticsBuckets.toolName("customer_token_/Users/example/private/project.swift"),
            "other"
        )
        XCTAssertEqual(
            AnalyticsBuckets.toolName(String(repeating: "x", count: 2_000)),
            "other"
        )
    }
}

/// The event registry enforces the taxonomy at compile time — call sites can only
/// reference names that exist here, and every name must obey surface.object.action.
final class AnalyticsEventNamingTests: XCTestCase {

    func test_allEventRawValues_matchNamingScheme() {
        for event in AnalyticsEvent.allCases {
            XCTAssertTrue(
                AnalyticsName.isValidEventName(event.rawValue),
                "Event name '\(event.rawValue)' violates the surface.object.action scheme"
            )
        }
    }

    func test_eventNameValidator_rejectsBadNames() {
        XCTAssertFalse(AnalyticsName.isValidEventName("singleword"))
        XCTAssertFalse(AnalyticsName.isValidEventName("Dashboard.Opened"))
        XCTAssertFalse(AnalyticsName.isValidEventName("a..b"))
        XCTAssertFalse(AnalyticsName.isValidEventName("_lead.bar"))
        XCTAssertTrue(AnalyticsName.isValidEventName("mission_console.opened"))
        XCTAssertTrue(AnalyticsName.isValidEventName("auth.sign_in.completed"))
    }

    func test_propertyKeyValidator_acceptsSnakeCase_rejectsOthers() {
        XCTAssertTrue(AnalyticsName.isValidPropertyKey("provider_name"))
        XCTAssertTrue(AnalyticsName.isValidPropertyKey("duration_ms_bucket"))
        XCTAssertFalse(AnalyticsName.isValidPropertyKey("providerName"))
        XCTAssertFalse(AnalyticsName.isValidPropertyKey("Provider_Name"))
        XCTAssertFalse(AnalyticsName.isValidPropertyKey("provider name"))
    }

    func test_coreTier1EventsPresent() {
        XCTAssertEqual(AnalyticsEvent.appSessionStarted.rawValue, "app.session.started")
        XCTAssertEqual(AnalyticsEvent.screenViewed.rawValue, "screen.viewed")
        XCTAssertEqual(AnalyticsEvent.authSignInCompleted.rawValue, "auth.sign_in.completed")
        XCTAssertEqual(AnalyticsEvent.settingsChanged.rawValue, "settings.changed")
        XCTAssertEqual(AnalyticsEvent.errorHandled.rawValue, "error.handled")
        XCTAssertEqual(AnalyticsEvent.consentAnalyticsGranted.rawValue, "consent.analytics.granted")
        XCTAssertEqual(AnalyticsEvent.pageViewed.rawValue, "page.viewed")
        XCTAssertEqual(AnalyticsEvent.appOpened.rawValue, "app.opened")
        XCTAssertEqual(AnalyticsEvent.ctaClicked.rawValue, "cta.clicked")
        XCTAssertEqual(AnalyticsEvent.downloadClicked.rawValue, "download.clicked")
        XCTAssertEqual(AnalyticsEvent.installStarted.rawValue, "install.started")
        XCTAssertEqual(AnalyticsEvent.emailCaptured.rawValue, "email.captured")
    }

    func test_noDuplicateRawValues() {
        let raws = AnalyticsEvent.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "Duplicate event raw values in registry")
    }

    func test_categories_coverAllFiveBranches() {
        XCTAssertEqual(AnalyticsEvent.appSessionStarted.category, .lifecycle)
        XCTAssertEqual(AnalyticsEvent.errorHandled.category, .error)
        XCTAssertEqual(AnalyticsEvent.screenViewed.category, .screenView)
        XCTAssertEqual(AnalyticsEvent.authSignInCompleted.category, .conversionAuth)
        XCTAssertEqual(AnalyticsEvent.dashboardScanRun.category, .primaryAction)
        XCTAssertEqual(AnalyticsCategory.screenView.rawValue, "screen_view")
        XCTAssertEqual(AnalyticsCategory.conversionAuth.rawValue, "conversion_auth")
    }
}
