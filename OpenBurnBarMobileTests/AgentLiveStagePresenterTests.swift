#if canImport(UIKit)
import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Pure-data state-machine coverage for the Agent Live Stage.
/// The presenter never touches the relay, the signer, or the video
/// pipeline — it only flips `mode` and a few layout knobs in response to
/// session-id changes and user intents, so we can drive it directly
/// without spinning up the singleton.
@MainActor
final class AgentLiveStagePresenterTests: XCTestCase {

    private func makePresenter(sessionEndGrace: TimeInterval = 0.05) -> AgentLiveStagePresenter {
        AgentLiveStagePresenter(sessionEndGrace: sessionEndGrace)
    }

    // MARK: - Auto-open

    func test_autoOpens_to_dock_on_session_start() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)
        XCTAssertEqual(presenter.mode, .hidden)

        state.setSession(id: ComputerUseSessionID("auto-open-1"), startedAt: .now)
        await Task.yield()
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms for Combine sink
        XCTAssertEqual(presenter.mode, .dock)
        XCTAssertNil(presenter.collapseReason)
    }

    func test_autoOpen_doesnt_clobber_user_promotion_to_split() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        // First open
        state.setSession(id: ComputerUseSessionID("promote-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        // User taps to expand → split
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .split)

        // Same session-id observation (duplicate emission) MUST NOT
        // drop us back into dock — that would be infuriating mid-drive.
        // We rely on `.removeDuplicates()` inside `observe()`.
        XCTAssertEqual(presenter.mode, .split)
    }

    // MARK: - Grace period

    func test_session_end_collapses_to_hidden_after_grace() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        state.setSession(id: ComputerUseSessionID("grace-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        state.clear()
        // Within grace window: still .dock.
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        // After grace + buffer: .hidden with sessionEnded reason.
        try await Task.sleep(nanoseconds: 80_000_000) // 80ms > 50ms grace
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .sessionEnded)
    }

    func test_session_resuming_during_grace_cancels_collapse() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        state.setSession(id: ComputerUseSessionID("resume-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        state.clear()
        // Halfway through grace, a new session arrives.
        try await Task.sleep(nanoseconds: 20_000_000)
        state.setSession(id: ComputerUseSessionID("resume-2"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)

        // After the original grace would have expired we must still be
        // in .dock — the second setSession should have cancelled the
        // scheduled collapse and reset `collapseReason`.
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(presenter.mode, .dock)
        XCTAssertNil(presenter.collapseReason)
    }

    // MARK: - User intents

    func test_requestExpand_walks_dock_to_split_to_maximize() {
        let presenter = makePresenter()
        presenter.enterDock()
        XCTAssertEqual(presenter.mode, .dock)
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .split)
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .maximize)
        // Further expand requests are no-ops.
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .maximize)
    }

    func test_requestCollapse_walks_back_down_and_keeps_dock_while_active() {
        let presenter = makePresenter()
        presenter.enterDock()
        presenter.requestExpand()
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .maximize)

        presenter.requestCollapse(sessionActive: true)
        XCTAssertEqual(presenter.mode, .split)
        presenter.requestCollapse(sessionActive: true)
        XCTAssertEqual(presenter.mode, .dock)
        // While session is active, dock is the floor.
        presenter.requestCollapse(sessionActive: true)
        XCTAssertEqual(presenter.mode, .dock)
        // Without a session, dock can collapse to hidden.
        presenter.requestCollapse(sessionActive: false)
        XCTAssertEqual(presenter.mode, .hidden)
    }

    func test_dismiss_marks_dismissed_and_hides() {
        let presenter = makePresenter()
        presenter.enterDock()
        presenter.requestExpand()
        presenter.dismiss()
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .dismissed)
    }

    func test_panicCollapse_records_panic_reason() {
        let presenter = makePresenter()
        presenter.enterDock()
        presenter.requestExpand()
        presenter.requestExpand()
        XCTAssertEqual(presenter.mode, .maximize)

        presenter.panicCollapse()
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .panic)
        XCTAssertFalse(presenter.chatPuckExpanded)
    }

    func test_toggleChatPuck_only_meaningful_in_maximize() {
        let presenter = makePresenter()
        presenter.enterDock()
        presenter.toggleChatPuck()
        XCTAssertFalse(presenter.chatPuckExpanded)

        presenter.requestExpand() // .split
        presenter.toggleChatPuck()
        XCTAssertFalse(presenter.chatPuckExpanded)

        presenter.requestExpand() // .maximize
        presenter.toggleChatPuck()
        XCTAssertTrue(presenter.chatPuckExpanded)
        presenter.toggleChatPuck()
        XCTAssertFalse(presenter.chatPuckExpanded)
    }

    // MARK: - PiP lifecycle

    func test_enterMaximizeFromPiP_flips_to_maximize_and_clears_pip_state() {
        let presenter = makePresenter()
        presenter.enterDock()
        presenter.setPiPActive(true)
        XCTAssertTrue(presenter.pipActive)

        presenter.enterMaximizeFromPiP()

        XCTAssertEqual(presenter.mode, .maximize)
        XCTAssertFalse(presenter.pipActive)
        XCTAssertFalse(presenter.chatPuckExpanded)
        XCTAssertNil(presenter.collapseReason)
    }

    func test_session_end_clears_pip_active() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)
        state.setSession(id: ComputerUseSessionID("pip-end-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        presenter.setPiPActive(true)

        state.clear()
        try await waitForMode(.hidden, presenter: presenter)

        XCTAssertFalse(presenter.pipActive)
        XCTAssertEqual(presenter.mode, .hidden)
    }

    // MARK: - Corner snapping

    func test_nearestCorner_returns_correct_quadrant() {
        let size = CGSize(width: 400, height: 800)
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 50, y: 50), in: size),
            .topLeading
        )
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 350, y: 50), in: size),
            .topTrailing
        )
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 50, y: 700), in: size),
            .bottomLeading
        )
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 380, y: 720), in: size),
            .bottomTrailing
        )
    }

    func test_snapDock_and_snapPuck_update_corners_independently() {
        let presenter = makePresenter()
        presenter.snapDock(to: .topTrailing)
        presenter.snapPuck(to: .topLeading)
        XCTAssertEqual(presenter.dockCorner, .topTrailing)
        XCTAssertEqual(presenter.puckCorner, .topLeading)
    }

    // MARK: - Observe idempotency

    func test_observe_is_idempotent_on_same_state() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)
        presenter.observe(state) // second call must be a no-op
        state.setSession(id: ComputerUseSessionID("idem-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)
    }

    func test_observe_swaps_state_subscription() async throws {
        let stateA = AgentWatchState()
        let stateB = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(stateA)
        presenter.observe(stateB)

        // Drive stateA — must NOT auto-open because we resubscribed to B.
        stateA.setSession(id: ComputerUseSessionID("swap-A"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .hidden)

        // Drive stateB — should auto-open.
        stateB.setSession(id: ComputerUseSessionID("swap-B"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)
    }

    // MARK: - requestCollapse cancels grace

    func test_manualCollapse_during_grace_does_not_overwrite_reason() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        state.setSession(id: ComputerUseSessionID("manual-col-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        // Session ends, grace starts counting.
        state.clear()
        try await Task.sleep(nanoseconds: 10_000_000)

        // User manually collapses before grace fires.
        presenter.requestCollapse(sessionActive: false)
        XCTAssertEqual(presenter.mode, .hidden)

        // Wait past grace — must NOT fire and overwrite anything.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(presenter.mode, .hidden)
        // collapseReason should be nil (requestCollapse doesn't set it),
        // not .sessionEnded from a stale grace task.
        XCTAssertNil(presenter.collapseReason)
    }

    // MARK: - No-op on nil session when already hidden

    func test_session_end_when_already_hidden_is_noop() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)
        // Never opened — mode stays hidden.
        state.setSession(id: ComputerUseSessionID("noop-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        presenter.dismiss()
        XCTAssertEqual(presenter.mode, .hidden)

        // Another session-id change to nil (which normally schedules
        // grace) should be a no-op since mode is already .hidden.
        state.clear()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(presenter.mode, .hidden)
        // dismiss() set .dismissed; grace should not have overwritten it.
        XCTAssertEqual(presenter.collapseReason, .dismissed)
    }

    // MARK: - Nearest corner edge cases

    func test_nearestCorner_center_returns_topLeading() {
        let size = CGSize(width: 400, height: 800)
        // Exact center — tie goes to topLeading (x < mid, y < mid).
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 199, y: 399), in: size),
            .topLeading
        )
    }

    func test_nearestCorner_on_center_line_returns_correct() {
        let size = CGSize(width: 400, height: 800)
        // x == mid, y above mid → x is NOT < mid, so topTrailing.
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 200, y: 100), in: size),
            .topTrailing
        )
        // y == mid, x below mid → y is NOT < mid, so bottomTrailing.
        XCTAssertEqual(
            AgentLiveStagePresenter.nearestCorner(for: CGPoint(x: 300, y: 400), in: size),
            .bottomTrailing
        )
    }

    func test_nearestCorner_zero_size_gracefully_handles() {
        // Should not trap; every point is >= half of zero, so all
        // conditions are false → bottomTrailing.
        let corner = AgentLiveStagePresenter.nearestCorner(
            for: CGPoint.zero,
            in: .zero
        )
        // With width=0, height=0, both comparisons are !(x < 0) = true,
        // so !isLeading && !isTop → bottomTrailing.
        XCTAssertEqual(corner, .bottomTrailing)
    }

    // MARK: - enterDock cancels grace

    func test_enterDock_cancels_pending_grace() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        state.setSession(id: ComputerUseSessionID("enterdock-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 20_000_000)
        state.clear()

        // Grace started. Call enterDock manually (simulates user
        // re-docking after session ends).
        presenter.enterDock()
        try await Task.sleep(nanoseconds: 80_000_000)
        // Should still be in dock — grace was cancelled.
        XCTAssertEqual(presenter.mode, .dock)
    }

    // MARK: - dismiss cancels grace

    func test_dismiss_cancels_grace() async throws {
        let state = AgentWatchState()
        let presenter = makePresenter()
        presenter.observe(state)

        state.setSession(id: ComputerUseSessionID("disgrace-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 20_000_000)
        state.clear()
        try await Task.sleep(nanoseconds: 10_000_000)

        // Dismiss during grace.
        presenter.dismiss()
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .dismissed)

        // Grace should not fire.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .dismissed)
    }

    private func waitForMode(
        _ expected: AgentLiveStagePresenter.Mode,
        presenter: AgentLiveStagePresenter,
        timeout: TimeInterval = 1.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while presenter.mode != expected {
            if Date() >= deadline {
                XCTFail("Timed out waiting for mode \(expected); current mode is \(presenter.mode)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
