import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// The Linux analytics target used to contain only a compile-gate placeholder.
/// Keep this suite self-contained because Package.swift intentionally selects
/// this file as the Linux source list, while the larger shared test helpers are
/// not part of that target on Linux.
@MainActor
private final class LinuxAnalyticsTransport: AnalyticsTransporting {
    struct Event {
        let name: String
        let category: String
        let properties: [String: AnalyticsValue]
    }

    private(set) var isStarted = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [Event] = []
    private(set) var userID: String?

    func start() {
        isStarted = true
        startCount += 1
    }

    func stop() {
        isStarted = false
        stopCount += 1
    }

    func send(name: String, category: String, properties: [String: AnalyticsValue]) {
        sent.append(Event(name: name, category: category, properties: properties))
    }

    func setUserId(_ id: String?) {
        userID = id
    }
}

@MainActor
private func makeLinuxAnalyticsDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "com.openburnbar.tests.linux-analytics.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@MainActor
final class LinuxAnalyticsBehaviorTests: XCTestCase {
    func testConsentGateStaysDarkUntilGrantAndAfterRevoke() {
        let (defaults, suiteName) = makeLinuxAnalyticsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let consent = AnalyticsConsentStore(defaults: defaults)
        let transport = LinuxAnalyticsTransport()
        let analytics = Analytics(
            consent: consent,
            transport: transport,
            superProperties: { ["platform": "linux", "app_build": "test"] }
        )

        analytics.track(.screenViewed, ["surface": "dashboard"])
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertFalse(transport.isStarted)
        XCTAssertEqual(transport.startCount, 0)

        consent.grant()
        analytics.consentDidChange()
        XCTAssertTrue(transport.isStarted)
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0].name, AnalyticsEvent.consentAnalyticsGranted.rawValue)

        analytics.track(.screenViewed, ["surface": "dashboard"])
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual(transport.sent[1].category, AnalyticsCategory.screenView.rawValue)
        XCTAssertEqual(transport.sent[1].properties["platform"], .string("linux"))
        XCTAssertEqual(transport.sent[1].properties["surface"], .string("dashboard"))

        consent.revoke()
        analytics.consentDidChange()
        XCTAssertFalse(transport.isStarted)
        XCTAssertEqual(transport.stopCount, 1)

        let sentBeforeRevokedTrack = transport.sent.count
        analytics.track(.screenViewed, ["surface": "dashboard"])
        XCTAssertEqual(transport.sent.count, sentBeforeRevokedTrack)
    }

    func testConsentPersistsAndExtensionReaderSeesGrantAndRevoke() {
        let (defaults, suiteName) = makeLinuxAnalyticsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AnalyticsConsentStore(defaults: defaults)
        XCTAssertFalse(store.hasDecided)
        XCTAssertFalse(store.isGranted)
        XCTAssertFalse(
            AnalyticsConsentReader.isGranted(
                appGroupIdentifier: suiteName,
                key: AnalyticsConsentStore.key
            )
        )

        store.grant()
        XCTAssertTrue(store.isGranted)
        XCTAssertTrue(store.hasDecided)
        XCTAssertTrue(
            AnalyticsConsentReader.isGranted(
                appGroupIdentifier: suiteName,
                key: AnalyticsConsentStore.key
            )
        )

        let reloaded = AnalyticsConsentStore(defaults: defaults)
        XCTAssertEqual(reloaded.consent, .granted)

        store.revoke()
        XCTAssertFalse(store.isGranted)
        XCTAssertFalse(
            AnalyticsConsentReader.isGranted(
                appGroupIdentifier: suiteName,
                key: AnalyticsConsentStore.key
            )
        )
    }

    func testBucketsAndTaxonomyUseStablePrivacySafeWireValues() {
        XCTAssertEqual(AnalyticsBuckets.durationMs(500), "500ms-1s")
        XCTAssertEqual(AnalyticsBuckets.count(0), "0")
        XCTAssertEqual(AnalyticsBuckets.count(501), ">500")
        XCTAssertEqual(AnalyticsBuckets.amountUSD(25), "10-50")
        XCTAssertEqual(AnalyticsBuckets.percent(75), "75-90")
        XCTAssertEqual(AnalyticsBuckets.sizeBytes(1_000_000), "1-10MB")
        XCTAssertEqual(AnalyticsBuckets.durationSeconds(120), "2-10m")
        XCTAssertEqual(AnalyticsBuckets.toolName("EditFile"), "file_edit")
        XCTAssertEqual(AnalyticsBuckets.toolName("/home/burnbar/private-token"), "other")

        let wireNames = AnalyticsEvent.allCases.map(\.rawValue)
        XCTAssertFalse(wireNames.isEmpty)
        XCTAssertEqual(Set(wireNames).count, wireNames.count)
        for name in wireNames {
            XCTAssertTrue(AnalyticsName.isValidEventName(name), "invalid analytics event: \(name)")
        }

        let values: [AnalyticsValue] = [.string("bucket"), .bool(true), .bool(false)]
        for value in values {
            switch value {
            case .string(let string):
                XCTAssertEqual(value.anyValue as? String, string)
            case .bool(let bool):
                XCTAssertEqual(value.anyValue as? Bool, bool)
            }
        }
    }

    func testDeviceIdentityIsStableAndPersistedPerInstallStore() {
        let (defaults, suiteName) = makeLinuxAnalyticsDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AnalyticsIdentity.deviceId(defaults: defaults)
        let second = AnalyticsIdentity.deviceId(defaults: defaults)

        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(defaults.string(forKey: AnalyticsIdentity.deviceIdKey), first)
    }
}
