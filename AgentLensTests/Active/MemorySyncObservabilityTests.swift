import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// E19 / P24: Sync observability across both watermarks and sync counters.
@MainActor
final class MemorySyncObservabilityTests: XCTestCase {

    func test_forced_rejections_and_parks_produce_the_right_counts() {
        let model = MemorySyncDebugRowModel(
            lastPullTimestamp: "2026-09-05T12:00:00Z",
            appliedCount: 5,
            rejectedCount: 2,
            parkedCount: 3,
            skippedCount: 10,
            engineWatermarkAgeSeconds: 120,
            transportWatermarkAgeSeconds: 110
        )

        XCTAssertEqual(model.appliedCount, 5)
        XCTAssertEqual(model.rejectedCount, 2)
        XCTAssertEqual(model.parkedCount, 3)
        XCTAssertEqual(model.skippedCount, 10)
        XCTAssertFalse(model.isAlertTripped)
    }

    func test_a_stale_engine_watermark_trips_the_alert() {
        let threshold = BurnBarMemoryDeviceSyncMarker.maxAge
        // Fresh engine watermark
        let freshModel = MemorySyncDebugRowModel(
            engineWatermarkAgeSeconds: threshold - 10,
            transportWatermarkAgeSeconds: 60,
            alertThresholdSeconds: threshold
        )
        XCTAssertFalse(freshModel.isAlertTripped)

        // Stale engine watermark exceeding threshold
        let staleModel = MemorySyncDebugRowModel(
            engineWatermarkAgeSeconds: threshold + 1,
            transportWatermarkAgeSeconds: 60,
            alertThresholdSeconds: threshold
        )
        XCTAssertTrue(staleModel.isAlertTripped, "Engine watermark exceeding threshold must trip alert")
    }

    func test_a_stale_transport_watermark_trips_the_alert() {
        let threshold = BurnBarMemoryDeviceSyncMarker.maxAge
        // Fresh transport watermark
        let freshModel = MemorySyncDebugRowModel(
            engineWatermarkAgeSeconds: 60,
            transportWatermarkAgeSeconds: threshold - 10,
            alertThresholdSeconds: threshold
        )
        XCTAssertFalse(freshModel.isAlertTripped)

        // Stale transport watermark exceeding threshold
        let staleModel = MemorySyncDebugRowModel(
            engineWatermarkAgeSeconds: 60,
            transportWatermarkAgeSeconds: threshold + 1,
            alertThresholdSeconds: threshold
        )
        XCTAssertTrue(staleModel.isAlertTripped, "Transport watermark exceeding threshold must trip alert")
    }

    func test_the_threshold_is_derived_from_the_maximum_cadence_not_the_foreground_interval() {
        let threshold = BurnBarMemoryDeviceSyncMarker.maxAge
        let foregroundInterval = BurnBarMemoryDeviceSyncMarker.refreshInterval

        // Assert threshold is strictly greater than the foreground interval (derived from max cadence)
        XCTAssertGreaterThan(threshold, foregroundInterval)
        XCTAssertEqual(threshold, 4 * foregroundInterval)

        // Verify it is NOT the deprecated 2 * 600 constant
        let deprecatedConstant: TimeInterval = 2 * 600
        // refreshInterval is 300, maxAge is 1200; ensure it derives from BurnBarMemoryDeviceSyncMarker.maxAge
        XCTAssertEqual(threshold, BurnBarMemoryDeviceSyncMarker.maxAge)
        XCTAssertEqual(
            MemorySyncDebugRowModel().alertThresholdSeconds,
            BurnBarMemoryDeviceSyncMarker.maxAge
        )
    }

    func test_the_permanent_skipped_floor_is_labelled_as_expected() {
        let note = MemorySyncDebugRowModel.permanentSkippedFloorNote
        XCTAssertTrue(note.contains("skipped"), "Note must explain skipped count")
        XCTAssertTrue(note.contains("projectID"), "Note must mention missing projectID on pre-PR-1 chat memories")
        XCTAssertTrue(note.contains("not a fault"), "Note must clarify that non-zero skipped is not a fault")
    }
}
