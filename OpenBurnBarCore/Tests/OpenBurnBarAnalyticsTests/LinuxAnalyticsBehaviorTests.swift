import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// The Linux analytics target used to contain only a compile-gate placeholder.
/// Keep this suite self-contained because Package.swift intentionally selects
/// this file as the Linux source list, while the larger shared test helpers are
/// not part of that target on Linux.
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

private func makeLinuxAnalyticsDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "com.openburnbar.tests.linux-analytics.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

final class LinuxAnalyticsBehaviorTests: XCTestCase {
    func testConsentGateStaysDarkUntilGrantAndAfterRevoke() async {
        let observation = await MainActor.run {
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
            let dark = (
                transport.sent.isEmpty,
                !transport.isStarted,
                transport.startCount == 0
            )

            consent.grant()
            analytics.consentDidChange()
            let granted = (
                transport.isStarted,
                transport.sent.count == 1,
                transport.sent.first?.name == AnalyticsEvent.consentAnalyticsGranted.rawValue
            )

            analytics.track(.screenViewed, ["surface": "dashboard"])
            let tracked = (
                transport.sent.count == 2,
                transport.sent[safe: 1]?.category == AnalyticsCategory.screenView.rawValue,
                transport.sent[safe: 1]?.properties["platform"] == .string("linux"),
                transport.sent[safe: 1]?.properties["surface"] == .string("dashboard")
            )

            consent.revoke()
            analytics.consentDidChange()
            let sentBeforeRevokedTrack = transport.sent.count
            analytics.track(.screenViewed, ["surface": "dashboard"])
            return LinuxAnalyticsGateObservation(
                dark: dark.0 && dark.1 && dark.2,
                granted: granted.0 && granted.1 && granted.2,
                tracked: tracked.0 && tracked.1 && tracked.2 && tracked.3,
                revoked: !transport.isStarted && transport.stopCount == 1
                    && transport.sent.count == sentBeforeRevokedTrack
            )
        }

        XCTAssertTrue(observation.dark)
        XCTAssertTrue(observation.granted)
        XCTAssertTrue(observation.tracked)
        XCTAssertTrue(observation.revoked)
    }

    func testConsentPersistsAndExtensionReaderSeesGrantAndRevoke() async {
        let observation = await MainActor.run {
            let (defaults, suiteName) = makeLinuxAnalyticsDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let store = AnalyticsConsentStore(defaults: defaults)
            let key = AnalyticsConsentStore.key
            let initial = !store.hasDecided && !store.isGranted
                && !AnalyticsConsentReader.isGranted(
                    appGroupIdentifier: suiteName,
                    key: key
                )

            store.grant()
            let granted = store.isGranted && store.hasDecided
                && AnalyticsConsentReader.isGranted(
                    appGroupIdentifier: suiteName,
                    key: key
                )

            let reloaded = AnalyticsConsentStore(defaults: defaults)
            let reloadedGranted = reloaded.consent == .granted

            store.revoke()
            let revoked = !store.isGranted
                && !AnalyticsConsentReader.isGranted(
                    appGroupIdentifier: suiteName,
                    key: key
                )
            return (initial, granted, reloadedGranted, revoked)
        }

        XCTAssertTrue(observation.0)
        XCTAssertTrue(observation.1)
        XCTAssertTrue(observation.2)
        XCTAssertTrue(observation.3)
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

private struct LinuxAnalyticsGateObservation: Sendable {
    let dark: Bool
    let granted: Bool
    let tracked: Bool
    let revoked: Bool
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
