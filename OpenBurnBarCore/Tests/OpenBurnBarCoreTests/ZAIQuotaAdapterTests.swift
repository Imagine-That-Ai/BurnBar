import XCTest
@testable import OpenBurnBarCore
// P-13: `ZAIQuotaAdapter` (and its internal `zaiUsageQueryItems(now:)`) moved to
// OpenBurnBarQuota. @testable reaches the internal helper this test asserts on.
@testable import OpenBurnBarQuota

final class ZAIQuotaAdapterTests: XCTestCase {

    // MARK: - Usage query window (Asia/Shanghai)

    /// Z.ai's usage monitor interprets zone-less `yyyy-MM-dd HH:mm:ss` query
    /// timestamps in Beijing time (the same assumption pinned in
    /// `FlexibleQuotaBucketNormalizer.zaiDateFormatter`). The emitted window
    /// must therefore be rendered in Asia/Shanghai regardless of the host
    /// timezone. Expected values below are hardcoded for a fixed instant so
    /// this test is timezone-independent: it passes only when the adapter
    /// computes the window in Asia/Shanghai.
    func test_zaiUsageQueryItems_windowIsRenderedInAsiaShanghai() {
        // 2026-07-06T12:34:56Z == 2026-07-06 20:34:56 Asia/Shanghai (UTC+8, no DST).
        let reference = Date(timeIntervalSince1970: 1_783_341_296)
        let items = ZAIQuotaAdapter().zaiUsageQueryItems(now: reference)

        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        // Window semantics: start = now - 1 day snapped to hour:00:00, end = now at minute 59:59.
        XCTAssertEqual(values["startTime"], "2026-07-05 20:00:00")
        XCTAssertEqual(values["endTime"], "2026-07-06 20:59:59")
        XCTAssertEqual(items.count, 2)
    }

    /// Same contract probed at a Shanghai-midnight boundary: 2026-07-06T16:30:00Z
    /// is 2026-07-07 00:30:00 in Asia/Shanghai, so a host west of UTC+8 that
    /// leaks its local calendar would emit the wrong day, not just the wrong hour.
    func test_zaiUsageQueryItems_shanghaiDayBoundary() {
        let reference = Date(timeIntervalSince1970: 1_783_355_400)
        let items = ZAIQuotaAdapter().zaiUsageQueryItems(now: reference)

        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(values["startTime"], "2026-07-06 00:00:00")
        XCTAssertEqual(values["endTime"], "2026-07-07 00:59:59")
    }
}
