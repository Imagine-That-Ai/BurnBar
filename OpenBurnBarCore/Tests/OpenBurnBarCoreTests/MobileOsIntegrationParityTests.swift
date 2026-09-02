import XCTest
@testable import OpenBurnBarCore

final class MobileOsIntegrationParityTests: XCTestCase {
    // Walks every fixture vector:
    // os.notification.denied-not-delivered, os.notification.granted-may-deliver,
    // os.push.agent-reply-route, os.push.inbox-route, os.push.quota-route,
    // os.push.mercury-call-route, os.push.mission-route, os.push.device-approval-route,
    // os.push.device-approval-navigate-without-uid,
    // os.push.device-approval-honor-uid-mismatch, os.push.device-approval-honor-expiry,
    // os.push.unknown-type-no-route,
    // os.push.omit-uid-expiry-no-navigate, os.push.evil-https-deep-link-ignored,
    // os.push.navigate-happy-path, os.push.stale-expired-no-navigate,
    // os.push.account-mismatch-no-navigate, os.push.duplicate-tap-idempotent,
    // os.deeplink.cold-inbox, os.deeplink.warm-assistants,
    // os.deeplink.mixed-case-inbox-id, os.deeplink.encoded-thread-id,
    // os.deeplink.approve-device-openburnbar, os.deeplink.devices-burnbar,
    // os.widget.no-raw-uid, os.widget.no-secret, os.widget.no-conversation-text,
    // os.widget.aggregate-snapshot-safe, os.background.retry-attempt-0,
    // os.background.retry-attempt-1, os.background.retry-attempt-2,
    // os.background.retry-bounded, os.background.cancel-stops-retry,
    // os.state.pending-claim-once, os.lifecycle.foreground-same-thread-suppress,
    // os.lifecycle.foreground-other-thread-delivers
    func testWalksEveryOsIntegrationVector() throws {
        let vectors = try osVectors()
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            switch string(vector["kind"]) {
            case "notificationDelivery":
                assertDelivery(vector)
            case "pushRoute":
                assertRoute(vector)
            case "navigation":
                assertNavigation(vector)
            case "urlRoute":
                assertURL(vector)
            case "widgetPrivacy":
                assertPrivacy(vector)
            case "widgetSnapshot":
                assertSnapshot(vector)
            case "backgroundRetry":
                assertRetry(vector)
            case "duplicateTap":
                assertClaim(vector)
            case "foregroundSuppress":
                assertSuppress(vector)
            default:
                XCTFail("unknown os vector kind \(string(vector["id"]))")
            }
        }
    }

    func testPulseWindowMetricsIsLinearOverFixtureSize() {
        let count = 4_000
        let usages = (0..<count).map { index in
            MobilePulseUsageEvent(
                startMs: Int64(index),
                endMs: Int64(index),
                tokens: 1,
                costUsd: 0.01
            )
        }
        let result = MobilePulseWindowPolicy.metrics(
            scope: .day,
            rollups: [:],
            usages: usages,
            nowMs: 3_999
        )
        XCTAssertEqual(result.total.requests, count)
        XCTAssertEqual(result.total.tokens, Int64(count))
    }

    private func assertDelivery(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let granted = bool(vector["permissionGranted"])
        XCTAssertEqual(MobileOsIntegrationPolicy.delivery(permissionGranted: granted).rawValue, string(expected["delivery"]))
        XCTAssertEqual(MobileOsIntegrationPolicy.mayDeliver(permissionGranted: granted), bool(expected["mayDeliver"]))
        if granted == false {
            XCTAssertNotEqual(MobileOsIntegrationPolicy.delivery(permissionGranted: false), .delivered)
        }
    }

    private func assertRoute(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let routed = MobileOsIntegrationPolicy.route(payload: stringMap(vector["payload"]))
        XCTAssertEqual(routed.destination.rawValue, string(expected["destination"]))
        if let link = expected["deepLink"] as? String {
            XCTAssertEqual(routed.deepLink, link)
        }
    }

    private func assertNavigation(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let envelope = MobileOsIntegrationPolicy.envelope(from: stringMap(vector["payload"]))
        let decision = MobileOsIntegrationPolicy.navigation(
            envelope: envelope,
            activeUid: vector["activeUid"] as? String,
            nowMs: int64(vector["nowMs"]),
            lastConsumedEventId: vector["lastConsumedEventId"] as? String,
            permissionGranted: bool(vector["permissionGranted"])
        )
        XCTAssertEqual(decision.rawValue, string(expected["decision"]))
        XCTAssertEqual(decision == .navigate, bool(expected["navigates"]))
    }

    private func assertURL(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let url = URL(string: string(vector["url"]))!
        let routed = MobileOsIntegrationPolicy.route(url: url)
        XCTAssertEqual(routed.destination.rawValue, string(expected["destination"]))
        if let item = expected["itemId"] as? String {
            XCTAssertEqual(routed.itemId, item)
        }
        if let thread = expected["threadId"] as? String {
            XCTAssertEqual(routed.threadId, thread)
        }
        if let runtime = expected["runtime"] as? String {
            XCTAssertEqual(routed.runtime, runtime)
        }
        if let deviceId = expected["deviceId"] as? String {
            XCTAssertEqual(routed.deviceId, deviceId)
        }
    }

    private func assertPrivacy(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        let scan = MobileOsIntegrationPolicy.scanWidgetFields(stringMap(vector["fields"]))
        if expected["hasRawUid"] != nil {
            XCTAssertEqual(scan.hasRawUid, bool(expected["hasRawUid"]))
        }
        if expected["hasSecret"] != nil {
            XCTAssertEqual(scan.hasSecret, bool(expected["hasSecret"]))
        }
        if expected["hasConversationText"] != nil {
            XCTAssertEqual(scan.hasConversationText, bool(expected["hasConversationText"]))
        }
        XCTAssertEqual(scan.isPrivacySafe, bool(expected["isPrivacySafe"]))
    }

    private func assertSnapshot(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        XCTAssertEqual(
            MobileOsIntegrationPolicy.widgetSnapshotIsPrivacySafe(
                heroTotalCost: double(vector["heroTotalCost"]),
                heroTotalTokens: int(vector["heroTotalTokens"]),
                topProviders: strings(vector["topProviders"])
            ),
            bool(expected["isPrivacySafe"])
        )
        XCTAssertEqual(
            MobileOsIntegrationPolicy.widgetRefreshCadenceSeconds,
            int64(expected["refreshCadenceSeconds"])
        )
        XCTAssertEqual(MobileOsIntegrationPolicy.widgetAppGroup, "group.com.openburnbar.app")
    }

    private func assertClaim(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        XCTAssertEqual(
            MobileOsIntegrationPolicy.shouldConsumeTap(
                eventId: string(vector["eventId"]),
                lastConsumedEventId: vector["lastConsumedEventId"] as? String
            ),
            bool(expected["shouldConsume"])
        )
        XCTAssertFalse(
            MobileOsIntegrationPolicy.shouldConsumeTap(
                eventId: string(vector["eventId"]),
                lastConsumedEventId: string(vector["eventId"])
            )
        )
    }

    private func assertSuppress(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        XCTAssertEqual(
            MobileOsIntegrationPolicy.shouldSuppressForegroundSameThread(
                foreground: bool(vector["foreground"]),
                activeRuntime: vector["activeRuntime"] as? String,
                activeThreadId: vector["activeThreadId"] as? String,
                payloadRuntime: vector["payloadRuntime"] as? String,
                payloadThreadId: vector["payloadThreadId"] as? String
            ),
            bool(expected["suppress"])
        )
    }

    private func assertRetry(_ vector: [String: Any]) {
        let expected = dict(vector["expected"])
        XCTAssertEqual(
            MobileOsIntegrationPolicy.shouldRetryBackground(
                attempt: int(vector["attempt"]),
                cancelled: bool(vector["cancelled"])
            ),
            bool(expected["shouldRetry"])
        )
        XCTAssertEqual(
            MobileOsIntegrationPolicy.maxBackgroundRetryAttempts,
            int(expected["maxAttempts"])
        )
    }

    private func osVectors() throws -> [[String: Any]] {
        let url = repoRoot().appendingPathComponent("docs/mobile-parity/fixtures/product/os-integration-vectors.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return json?["vectors"] as? [[String: Any]] ?? []
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func strings(_ value: Any?) -> [String] { (value as? [String]) ?? [] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
    private func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    private func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
    private func double(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    private func bool(_ value: Any?) -> Bool { value as? Bool ?? false }

    private func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var mapped: [String: String] = [:]
        for (key, raw) in dict {
            mapped[key] = String(describing: raw)
        }
        return mapped
    }
}
