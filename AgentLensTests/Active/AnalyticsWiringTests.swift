import XCTest
@testable import OpenBurnBar

@MainActor
final class AnalyticsIdentityTests: XCTestCase {
    func test_deviceId_isStable_persisted_randomUUID_andPerInstall() {
        let d = UserDefaults(suiteName: "id.\(UUID().uuidString)")!
        let first = AnalyticsIdentity.deviceId(defaults: d)
        let second = AnalyticsIdentity.deviceId(defaults: d)
        XCTAssertEqual(first, second, "device id must be stable within an install")
        XCTAssertNotNil(UUID(uuidString: first), "must be a random UUID, never a hardware identifier")

        let other = AnalyticsIdentity.deviceId(defaults: UserDefaults(suiteName: "id.\(UUID().uuidString)")!)
        XCTAssertNotEqual(first, other, "different installs get different ids")
    }
}

final class AnalyticsSuperPropertiesTests: XCTestCase {
    func test_asDictionary_hasCanonicalSnakeCaseKeys() {
        let sp = AnalyticsSuperProperties(
            platform: "macos", appVersion: "2.4.1", appBuild: "123",
            locale: "en_US", sessionId: "sess-1", consentVersion: "1"
        )
        let d = sp.asDictionary()
        XCTAssertEqual(d["product"], .string("burnbar"))
        XCTAssertEqual(d["platform"], .string("macos"))
        XCTAssertEqual(d["app_version"], .string("2.4.1"))
        XCTAssertEqual(d["app_build"], .string("123"))
        XCTAssertEqual(d["locale"], .string("en_US"))
        XCTAssertEqual(d["session_id"], .string("sess-1"))
        XCTAssertEqual(d["consent_version"], .string("1"))
        // every super-property key must obey the property naming scheme
        for key in d.keys { XCTAssertTrue(AnalyticsName.isValidPropertyKey(key), "bad key \(key)") }
    }

    func test_macOS_factory_setsPlatformMacosAndReadsBundle() {
        let sp = AnalyticsSuperProperties.macOS(sessionId: "s")
        XCTAssertEqual(sp.platform, "macos")
        XCTAssertEqual(sp.sessionId, "s")
        XCTAssertFalse(sp.appVersion.isEmpty)
        XCTAssertEqual(sp.consentVersion, "1")
    }
}
