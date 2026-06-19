import XCTest
@testable import OpenBurnBar

/// The transport is the SDK adapter; its send path is verified via real ingestion,
/// not unit tests. What we DO assert here is the critical no-key safety: with no
/// API key, the Amplitude client is never constructed, so the app stays dark.
@MainActor
final class AmplitudeTransportTests: XCTestCase {

    func test_start_withNilKey_doesNotInitialize() {
        let t = AmplitudeTransport(apiKey: nil, deviceId: "dev-1")
        t.start()
        XCTAssertFalse(t.isStarted, "No key → the Amplitude client must not be constructed")
    }

    func test_start_withEmptyKey_doesNotInitialize() {
        let t = AmplitudeTransport(apiKey: "", deviceId: "dev-1")
        t.start()
        XCTAssertFalse(t.isStarted)
    }

    func test_analyticsConfig_isDarkByDefault() {
        // Placeholder unreplaced + no env var → nil, so analytics never initializes.
        if ProcessInfo.processInfo.environment["BURNBAR_AMPLITUDE_API_KEY"] == nil {
            XCTAssertNil(AnalyticsConfig.apiKey)
        }
    }
}
