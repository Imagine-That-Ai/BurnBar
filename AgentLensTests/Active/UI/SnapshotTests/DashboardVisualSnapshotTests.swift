import XCTest
import SwiftUI
import SnapshotTesting
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Mini Sparkline Visual Regression Tests

/// Guards sparkline rendering across data patterns and color schemes.
@MainActor
final class DashboardVisualSnapshotTests: XCTestCase {

    func test_castleGreatHall_mixedVerdicts() {
        let previousSkin = UserDefaults.standard.string(forKey: AppSkin.storageKey)
        UserDefaults.standard.set(AppSkin.aurora.rawValue, forKey: AppSkin.storageKey)
        defer {
            if let previousSkin {
                UserDefaults.standard.set(previousSkin, forKey: AppSkin.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppSkin.storageKey)
            }
        }

        let view = CastleGreatHallView(
            snapshot: CastleRunSnapshot(workers: [
                CastleWorkerStatus(runtime: "claude", modelArg: "claude-opus-4-8", phase: .landed, landsCommit: true, headSHA: "585c803db1d7"),
                CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "0e333758611d"),
                CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1-pro-preview", phase: .noOp, landsCommit: false, honesty: [.quotaUnknown, .noOp]),
                CastleWorkerStatus(runtime: "cursor-agent", modelArg: "cursor-fast", phase: .failed, landsCommit: false, honesty: [.failed])
            ]),
            failures: [
                CastleStatusLoadFailure(path: "/tmp/castle/run-b/status.json", reason: "bad JSON")
            ],
            lastRefreshed: nil
        )
        .padding(20)
        .background(DesignSystem.Colors.background)

        XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 860, height: 520),
            named: SnapshotName.castleGreatHall,
            precision: 0.92
        )
    }

    func test_miniSparkline_flat() {
        let view = MiniSparkline(
            data: [1, 1, 1, 1, 1, 1, 1],
            color: DesignSystem.Colors.ember,
            width: 120,
            height: 40
        )
        XCTAssertAdaptiveSnapshot(
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
        XCTAssertAdaptiveSnapshot(
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
        XCTAssertAdaptiveSnapshot(
            of: view,
            size: CGSize(width: 140, height: 60),
            named: SnapshotName.miniSparklineFalling
        )
    }
}
