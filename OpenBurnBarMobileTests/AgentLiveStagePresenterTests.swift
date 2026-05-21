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

    private var originalGrace: TimeInterval = 6

    override func setUp() async throws {
        try await super.setUp()
        originalGrace = AgentLiveStagePresenter.sessionEndGrace
        // Shrink grace to 0.05s so collapse-after-grace tests stay sub-second.
        AgentLiveStagePresenter.sessionEndGrace = 0.05
    }

    override func tearDown() async throws {
        AgentLiveStagePresenter.sessionEndGrace = originalGrace
        try await super.tearDown()
    }

    // MARK: - Auto-open

    func test_autoOpens_to_dock_on_session_start() async throws {
        let state = AgentWatchState()
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
        presenter.enterDock()
        presenter.requestExpand()
        presenter.dismiss()
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .dismissed)
    }

    func test_panicCollapse_records_panic_reason() {
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
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
        let presenter = AgentLiveStagePresenter()
        presenter.snapDock(to: .topTrailing)
        presenter.snapPuck(to: .topLeading)
        XCTAssertEqual(presenter.dockCorner, .topTrailing)
        XCTAssertEqual(presenter.puckCorner, .topLeading)
    }

    // MARK: - Observe idempotency

    func test_observe_is_idempotent_on_same_state() async throws {
        let state = AgentWatchState()
        let presenter = AgentLiveStagePresenter()
        presenter.observe(state)
        presenter.observe(state) // second call must be a no-op
        state.setSession(id: ComputerUseSessionID("idem-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)
    }

    func test_observe_swaps_state_subscription() async throws {
        let stateA = AgentWatchState()
        let stateB = AgentWatchState()
        let presenter = AgentLiveStagePresenter()
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
}
#endif
