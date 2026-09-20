import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class AgentReplyNotificationBannerTests: XCTestCase {
    func testOpenFieldsNeverInventCurrentUidOrExpiry() {
        let leftover = AgentReplyNotificationBanner(
            id: "evt-a",
            title: "Reply",
            preview: "hi",
            runtime: "hermes",
            threadID: "thr-a",
            provider: nil,
            deepLink: URL(string: "burnbar://assistants/hermes?threadId=thr-a"),
            uid: "uid-a",
            expiresAtMs: 1_700_000_000_000
        )
        let fields = AgentReplyBannerNavigation.openFields(from: leftover)
        XCTAssertEqual(fields["uid"], "uid-a")
        XCTAssertEqual(fields["expires_at_millis"], "1700000000000")
        XCTAssertEqual(fields["event_id"], "evt-a")
        XCTAssertNil(fields["forged"])
    }

    func testOpenFieldsOmitUidWhenBannerHasNone() {
        let banner = AgentReplyNotificationBanner(
            id: "evt-local",
            title: "Reply",
            preview: "hi",
            runtime: "hermes",
            threadID: "thr",
            provider: nil,
            deepLink: nil,
            uid: nil,
            expiresAtMs: nil
        )
        let fields = AgentReplyBannerNavigation.openFields(from: banner)
        XCTAssertNil(fields["uid"])
        XCTAssertNil(fields["expires_at_millis"])
        let decision = MobileOsIntegrationPolicy.navigation(
            envelope: MobileOsIntegrationPolicy.envelope(from: fields),
            activeUid: "uid-b",
            nowMs: 1_700_000_000_000,
            lastConsumedEventId: nil,
            permissionGranted: true
        )
        XCTAssertEqual(decision, .ignoreStale)
    }

    func testConsumedEventsClearOnlyForTheBoundAccount() {
        XCTAssertFalse(
            AgentReplyConsumedScope.shouldClearLastConsumed(tombstonedUid: "uid-a", boundUid: "uid-b")
        )
        XCTAssertTrue(
            AgentReplyConsumedScope.shouldClearLastConsumed(tombstonedUid: "uid-a", boundUid: "uid-a")
        )
    }

    func testDeviceApprovalPushOpensDevicesWithoutUidOrExpiry() {
        let payload: [String: String] = [
            "type": "device_approval_request",
            "device_id": "mac_mini_1",
            "deep_link": "openburnbar://approve-device?deviceId=mac_mini_1"
        ]
        let routed = MobileOsIntegrationPolicy.route(payload: payload)
        XCTAssertEqual(routed.destination, .devices)
        XCTAssertEqual(routed.deviceId, "mac_mini_1")
        XCTAssertEqual(routed.deepLink, "openburnbar://approve-device?deviceId=mac_mini_1")

        let decision = MobileOsIntegrationPolicy.navigation(
            envelope: MobileOsIntegrationPolicy.envelope(from: payload),
            activeUid: "uid-current",
            nowMs: 5_000,
            lastConsumedEventId: nil,
            permissionGranted: true
        )
        XCTAssertEqual(decision, .navigate)
    }
}
