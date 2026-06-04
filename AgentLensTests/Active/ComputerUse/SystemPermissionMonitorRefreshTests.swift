#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
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
        var promptedBundleIds: [String] = []
        let coordinator = PermissionsOnboardingCoordinator(
            monitor: monitor,
            automationPromptRunner: { bundleId in promptedBundleIds.append(bundleId) }
        )
        while coordinator.currentStep?.kind != .automation {
            coordinator.skipCurrent()
        }
        let step = try XCTUnwrap(coordinator.currentStep)

        await coordinator.requestCurrent()

        XCTAssertEqual(step.bundleId, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(step.targetDisplayName, "Cursor")
        XCTAssertEqual(promptedBundleIds, ["com.todesktop.230313mzl4w4u92"])
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
}
#endif
