import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - Mission FAB Resurrection Controller Tests
//
// Locks the contract of every resurrect path so a future change can't
// silently regress the dismiss/restore lifecycle:
//   • Settings toggle (manual)
//   • Restore dot (manual)
//   • Long-press path (manual)
//   • Auto-resurrect on approval ask (event-driven)
//   • Auto-resurrect on recent mission failure (event-driven)
//   • Persistence across instances (UserDefaults round-trip)

@MainActor
final class MissionFABResurrectionControllerTests: XCTestCase {

    override func setUp() async throws {
        // Each test gets a clean UserDefaults slate so the persisted
        // state from a prior test doesn't bleed.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "missionFAB.isDismissed.v1")
        defaults.removeObject(forKey: "missionFAB.dismissedAt.v1")
    }

    // MARK: Manual paths

    func testInitialStateIsVisible() {
        let c = MissionFABResurrectionController.offline()
        XCTAssertFalse(c.isDismissed)
        XCTAssertNil(c.dismissedAt)
        XCTAssertFalse(c.wasAutoResurrected)
        XCTAssertNil(c.autoResurrectReason)
    }

    func testDismissStampsTimeAndClearsAutoFlag() {
        let c = MissionFABResurrectionController.offline()
        c.dismiss()
        XCTAssertTrue(c.isDismissed)
        XCTAssertNotNil(c.dismissedAt)
        XCTAssertFalse(c.wasAutoResurrected)
    }

    func testRestoreFromDotClearsDismissed() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        c.restoreFromDot()
        XCTAssertFalse(c.isDismissed)
        XCTAssertNil(c.dismissedAt)
        XCTAssertEqual(c.autoResurrectReason, .manualRestoreDot)
        XCTAssertFalse(c.wasAutoResurrected, "Manual restore must not raise the auto-resurrect signal")
    }

    func testRestoreFromSettingsClearsDismissed() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        c.restoreFromSettings()
        XCTAssertFalse(c.isDismissed)
        XCTAssertEqual(c.autoResurrectReason, .settingsToggle)
        XCTAssertFalse(c.wasAutoResurrected)
    }

    func testRestoreFromLongPressClearsDismissed() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        c.restoreFromLongPress()
        XCTAssertFalse(c.isDismissed)
        XCTAssertEqual(c.autoResurrectReason, .longPressTab)
        XCTAssertFalse(c.wasAutoResurrected)
    }

    func testSetDismissedRoutesToCorrectPath() {
        let c = MissionFABResurrectionController.offline()
        c.setDismissed(true)
        XCTAssertTrue(c.isDismissed)
        c.setDismissed(false)
        XCTAssertFalse(c.isDismissed)
        XCTAssertEqual(c.autoResurrectReason, .settingsToggle)
    }

    func testRestoreOnAlreadyVisibleIsNoOp() {
        let c = MissionFABResurrectionController.offline()
        c.restoreFromDot()
        XCTAssertFalse(c.isDismissed)
        XCTAssertNil(c.autoResurrectReason, "Restore on already-visible should not stamp a reason")
    }

    // MARK: Event-driven paths

    func testApprovalAskTriggersAutoResurrect() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        let snapshot = MissionConsoleSnapshot(
            health: .empty,
            runtimes: [],
            activeTiles: [],
            recentTicker: [],
            approvalAsks: [
                MissionConsoleApprovalAsk(
                    id: "ask-1",
                    missionID: "m-1",
                    title: "Approve shell command",
                    message: "Codex wants to run pnpm test",
                    runtimeID: "codex",
                    runtimeDisplayLabel: "Codex",
                    requestedAt: Date()
                )
            ],
            knownProjects: [],
            recentProjects: []
        )
        c.reconcile(against: snapshot)
        XCTAssertFalse(c.isDismissed, "Approval ask must auto-resurrect a dismissed orb")
        XCTAssertTrue(c.wasAutoResurrected)
        XCTAssertEqual(c.autoResurrectReason, .approvalAsk)
    }

    func testRecentFailureTriggersAutoResurrect() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        let snapshot = MissionConsoleSnapshot(
            health: .empty,
            runtimes: [],
            activeTiles: [
                MissionConsoleActiveTile(
                    id: "m-fail",
                    title: "Refactor router",
                    runtimeID: "claude",
                    runtimeDisplayLabel: "Claude",
                    phase: .failed,
                    phaseDetail: "Process exited with code 1",
                    startedAt: Date().addingTimeInterval(-15) // 15s ago — inside 30s window
                )
            ],
            recentTicker: [],
            approvalAsks: [],
            knownProjects: [],
            recentProjects: []
        )
        c.reconcile(against: snapshot)
        XCTAssertFalse(c.isDismissed)
        XCTAssertEqual(c.autoResurrectReason, .missionFailed)
    }

    func testOldFailureDoesNotAutoResurrect() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        let snapshot = MissionConsoleSnapshot(
            health: .empty,
            runtimes: [],
            activeTiles: [
                MissionConsoleActiveTile(
                    id: "m-old-fail",
                    title: "Stale failure",
                    runtimeID: "claude",
                    runtimeDisplayLabel: "Claude",
                    phase: .failed,
                    phaseDetail: "Old",
                    startedAt: Date().addingTimeInterval(-3600) // 1 hour ago
                )
            ],
            recentTicker: [],
            approvalAsks: [],
            knownProjects: [],
            recentProjects: []
        )
        c.reconcile(against: snapshot)
        XCTAssertTrue(c.isDismissed, "Stale failures must not yank the user back to the orb hours later")
    }

    func testReconcileOnVisibleOrbDoesNothing() {
        let c = MissionFABResurrectionController.offline()
        let snapshot = MissionConsoleSnapshot(
            health: .empty,
            runtimes: [],
            activeTiles: [],
            recentTicker: [],
            approvalAsks: [
                MissionConsoleApprovalAsk(
                    id: "ask-1", missionID: "m", title: "x", message: "y",
                    runtimeID: nil, runtimeDisplayLabel: "?", requestedAt: Date()
                )
            ],
            knownProjects: [], recentProjects: []
        )
        c.reconcile(against: snapshot)
        XCTAssertFalse(c.wasAutoResurrected, "Reconcile must be a no-op when the orb is already visible")
    }

    func testConsumeClearsAutoSignalOnly() {
        let c = MissionFABResurrectionController.offline(initiallyDismissed: true)
        let snapshot = MissionConsoleSnapshot(
            health: .empty, runtimes: [], activeTiles: [], recentTicker: [],
            approvalAsks: [
                MissionConsoleApprovalAsk(
                    id: "a", missionID: "m", title: "x", message: "y",
                    runtimeID: nil, runtimeDisplayLabel: "?", requestedAt: Date()
                )
            ],
            knownProjects: [], recentProjects: []
        )
        c.reconcile(against: snapshot)
        XCTAssertTrue(c.wasAutoResurrected)
        c.consumeAutoResurrectSignal()
        XCTAssertFalse(c.wasAutoResurrected)
        XCTAssertNil(c.autoResurrectReason)
        XCTAssertFalse(c.isDismissed, "Consuming the signal must not re-dismiss the orb")
    }

    // MARK: Persistence

    func testDismissalSurvivesNewControllerInstance() {
        let original = MissionFABResurrectionController()
        original.dismiss()
        // New instance reads from UserDefaults — cold-launch behaviour.
        let revived = MissionFABResurrectionController()
        XCTAssertTrue(revived.isDismissed)
        XCTAssertNotNil(revived.dismissedAt)
    }

    func testRestoreClearsPersistedDismissedAt() {
        let c1 = MissionFABResurrectionController()
        c1.dismiss()
        c1.restoreFromSettings()
        let c2 = MissionFABResurrectionController()
        XCTAssertFalse(c2.isDismissed)
        XCTAssertNil(c2.dismissedAt)
    }
}
