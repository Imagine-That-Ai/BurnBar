import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// Wave 3.4 union pins: the macOS entry point stays dark without an injected
/// key, and the iOS entry point resolves env-provided keys while rejecting
/// every placeholder spelling. The test bundle ships no `amplitude.apiKey`
/// Info.plist value and no `GoogleService-Info.plist`, so the bundle slots
/// fall through to the injected environment in every case below.
final class AnalyticsConfigTests: XCTestCase {

    func test_macOSApiKey_isDarkWithoutInjection() {
        // Sentinel unreplaced in source + no env var → nil, so the transport
        // never constructs the SDK client.
        if ProcessInfo.processInfo.environment[AnalyticsConfig.environmentKey] == nil {
            XCTAssertNil(AnalyticsConfig.apiKey)
        }
    }

    func test_bundleApiKey_returnsTrimmedEnvironmentKey() {
        let key = AnalyticsConfig.apiKeyFromBundle(
            environment: [AnalyticsConfig.environmentKey: "  abc123  "]
        )
        XCTAssertEqual(key, "abc123")
    }

    func test_bundleApiKey_rejectsPlaceholders() {
        for placeholder in ["", "   ", "$(BURNBAR_AMPLITUDE_API_KEY)", "__AMPLITUDE_API_KEY__"] {
            XCTAssertNil(
                AnalyticsConfig.apiKeyFromBundle(
                    environment: [AnalyticsConfig.environmentKey: placeholder]
                ),
                "placeholder must never resolve as a key: \(placeholder)"
            )
        }
    }

    func test_bundleApiKey_returnsNilWithoutAnySource() {
        XCTAssertNil(AnalyticsConfig.apiKeyFromBundle(environment: [:]))
    }
}
