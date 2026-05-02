import XCTest
import SwiftUI
import SnapshotTesting
import GRDB
@testable import OpenBurnBar

// MARK: - Mini Sparkline Visual Regression Tests

/// Guards sparkline rendering across data patterns and color schemes.
@MainActor
final class DashboardVisualSnapshotTests: XCTestCase {

    func test_miniSparkline_flat() {
        let view = MiniSparkline(
            data: [1, 1, 1, 1, 1, 1, 1],
            color: DesignSystem.Colors.ember,
            width: 120,
            height: 40
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 140, height: 60),
            named: SnapshotName.miniSparklineFlat
        )
    }

    func test_miniSparkline_rising() {
        let view = MiniSparkline(
            data: [1, 2, 3, 5, 8, 13, 21],
            color: DesignSystem.Colors.success,
            width: 120,
            height: 40
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 140, height: 60),
            named: SnapshotName.miniSparklineRising
        )
    }

    func test_miniSparkline_falling() {
        let view = MiniSparkline(
            data: [21, 13, 8, 5, 3, 2, 1],
            color: DesignSystem.Colors.error,
            width: 120,
            height: 40
        )
        assertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 140, height: 60),
            named: SnapshotName.miniSparklineFalling
        )
    }
}
