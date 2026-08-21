#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

final class SystemPermissionMonitorRefreshTests: XCTestCase {
    @MainActor
    func testRefreshNowSeedsCurrentMacPermissionSnapshots() async {
        let monitor = SystemPermissionMonitor()

        await monitor.refreshNow(emitting: false)

        XCTAssertNotNil(monitor.snapshots["camera|"])
        XCTAssertNotNil(monitor.snapshots["microphone|"])
        XCTAssertNotNil(monitor.snapshots["screenRecording|"])
        XCTAssertNotNil(monitor.snapshots["accessibility|"])
        XCTAssertNotNil(monitor.snapshots["fullDiskAccess|"])
    }

    @MainActor
    func testOnboardingWizardForcesLivePermissionRefreshBeforeReadingSnapshots() async throws {
        let monitor = FakeSystemPermissionMonitor()
        let coordinator = PermissionsOnboardingCoordinator(monitor: monitor)
        let step = try XCTUnwrap(coordinator.currentStep)
        monitor.onRefresh = { fake in
            fake.snapshots["\(step.kind.rawValue)|\(step.bundleId ?? "")"] = SystemPermissionMonitor.Snapshot(
                kind: step.kind,
                bundleId: step.bundleId,
                status: .granted
            )
        }

        await coordinator.refreshCurrentPermissionState()

        XCTAssertEqual(monitor.refreshCalls, [true])
        XCTAssertEqual(coordinator.liveStatus(for: step), .granted)
        XCTAssertEqual(coordinator.currentIndex, 1)
    }

    @MainActor
    func testOnboardingAutomationActionUsesPreflightBundleTargets() async throws {
        let targetByBundleId = Dictionary(
            uniqueKeysWithValues: OnboardingAutomationTargets.preflightTargets.map { ($0.bundleId, $0.displayName) }
        )
        XCTAssertEqual(targetByBundleId["com.todesktop.230313mzl4w4u92"], "Cursor")
        XCTAssertEqual(targetByBundleId["com.apple.Safari"], "Safari")
        XCTAssertEqual(targetByBundleId["com.google.Chrome"], "Google Chrome")
        XCTAssertEqual(targetByBundleId["com.apple.finder"], "Finder")

        let monitor = FakeSystemPermissionMonitor()
        let promptedBundleIds = BundleIdRecorder()
        // The wizard now asks through the ladder, so the fake ladder both records what
        // reached macOS and proves the explanation ran first.
        let ladder = FirstRunPermissionLadder(
            prompter: { _, bundleId in if let bundleId { promptedBundleIds.append(bundleId) } },
            statusReader: { _, _ in .needsAccess }
        )
        var explainedKinds: [SystemPermissionKind] = []
        ladder.explainer = { kind, _ in
            explainedKinds.append(kind)
            return true
        }
        let coordinator = PermissionsOnboardingCoordinator(
            monitor: monitor,
            permissionLadder: ladder
        )
        coordinator.acknowledgeTrustOverview()
        while coordinator.currentStep?.kind != .automation {
            coordinator.skipCurrent()
        }
        let step = try XCTUnwrap(coordinator.currentStep)

        await coordinator.requestCurrent()

        XCTAssertEqual(step.bundleId, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(step.targetDisplayName, "Cursor")
        XCTAssertEqual(promptedBundleIds.values, ["com.todesktop.230313mzl4w4u92"])
        XCTAssertEqual(explainedKinds, [.automation], "macOS must not be reached before BurnBar explains")
        XCTAssertEqual(monitor.refreshCalls, [true])
    }

    func testMacAppDeclaresAppleEventsUsageDescription() throws {
        let usage = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String)

        XCTAssertTrue(usage.contains("Cursor"))
        XCTAssertTrue(usage.contains("Safari"))
        XCTAssertTrue(usage.contains("Chrome"))
        XCTAssertTrue(usage.contains("Finder"))
    }

    @MainActor
    private final class FakeSystemPermissionMonitor: SystemPermissionMonitoring {
        var snapshots: [String: SystemPermissionMonitor.Snapshot] = [:]
        private(set) var refreshCalls: [Bool] = []
        private(set) var startedIntervals: [TimeInterval] = []
        private(set) var trackedBundleIds: [String] = []
        var onRefresh: ((FakeSystemPermissionMonitor) -> Void)?

        func start(pollInterval: TimeInterval) {
            startedIntervals.append(pollInterval)
        }

        func stop() {}

        func trackAutomation(bundleId: String) {
            trackedBundleIds.append(bundleId)
        }

        func refreshNow(emitting: Bool) async {
            refreshCalls.append(emitting)
            onRefresh?(self)
        }
    }

    /// The trust overview is a gate. If it ever becomes skippable, the wizard can hand
    /// a user straight to "OpenBurnBar wants to record this computer's screen" with no
    /// explanation -- the exact experience this work exists to remove.
    @MainActor
    func testTrustOverviewBlocksAnyPermissionRequestUntilAcknowledged() async {
        let promptedBundleIds = BundleIdRecorder()
        let ladder = FirstRunPermissionLadder(
            prompter: { _, bundleId in promptedBundleIds.append(bundleId ?? "none") },
            statusReader: { _, _ in .needsAccess }
        )
        ladder.explainer = { _, _ in true }
        let coordinator = PermissionsOnboardingCoordinator(
            monitor: FakeSystemPermissionMonitor(),
            permissionLadder: ladder
        )

        XCTAssertTrue(coordinator.isShowingTrustOverview, "the overview must come first")
        await coordinator.requestCurrent()
        XCTAssertTrue(
            promptedBundleIds.values.isEmpty,
            "no permission may be requested while the trust overview is still showing"
        )

        coordinator.acknowledgeTrustOverview()
        XCTAssertFalse(coordinator.isShowingTrustOverview)
        await coordinator.requestCurrent()
        XCTAssertFalse(promptedBundleIds.values.isEmpty, "after acknowledging, asks proceed normally")
    }
}

#endif

/// Reference box so the `@Sendable` ladder prompter can record without capturing a
/// mutable local.
private final class BundleIdRecorder: @unchecked Sendable {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
