import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Pro gating for memory egress reads the daemon's offline membership cache.
/// A stale or non-active cache must fail closed.
final class BurnBarMembershipFreshnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func snapshot(
        state: BurnBarMembershipState = .active,
        ids: [String] = ["burnbar_pro"],
        updatedAt: String?
    ) -> BurnBarMembershipSnapshot {
        BurnBarMembershipSnapshot(
            tier: ids.isEmpty ? "free" : "pro",
            entitlementIds: ids,
            restoreAvailable: true,
            state: state,
            daemonCacheKey: "entitlements/test",
            source: "local_cache",
            updatedAt: updatedAt
        )
    }

    func test_activeFreshProEntitlementIsActive() {
        XCTAssertTrue(BurnBarMembershipFreshness.isProActive(snapshot(updatedAt: iso(now.addingTimeInterval(-86_400))), now: now))
    }

    func test_hostedQuotaSyncAloneCountsAsPro() {
        XCTAssertTrue(BurnBarMembershipFreshness.isProActive(snapshot(ids: ["hosted_quota_sync"], updatedAt: iso(now)), now: now))
    }

    func test_staleCacheFailsClosed() {
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(updatedAt: iso(now.addingTimeInterval(-8 * 86_400))), now: now))
    }

    func test_nonActiveStateFailsClosed() {
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(state: .offline, updatedAt: iso(now)), now: now))
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(state: .cancelled, updatedAt: iso(now)), now: now))
    }

    func test_noProEntitlementFailsClosed() {
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(ids: [], updatedAt: iso(now)), now: now))
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(ids: ["hosted_media_sync"], updatedAt: iso(now)), now: now))
    }

    func test_unparsableOrMissingUpdatedAtFailsClosed() {
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(updatedAt: "yesterday"), now: now))
        XCTAssertFalse(BurnBarMembershipFreshness.isProActive(snapshot(updatedAt: nil), now: now))
    }

    func test_updatedAtParsesWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(BurnBarMembershipFreshness.updatedAtDate(snapshot(updatedAt: "2026-09-01T10:00:00.250Z")))
        XCTAssertNotNil(BurnBarMembershipFreshness.updatedAtDate(snapshot(updatedAt: "2026-09-01T10:00:00Z")))
    }
}
