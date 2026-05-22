#if canImport(UIKit)
import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// Integration coverage for the wires `AgentLiveStage` relies on:
///   • `AgentWatchOverlaySingleton.evaluate(...)` gates correctly on
///     auth + Hermes connection state.
///   • `AgentLiveStagePresenter.observe(...)` actually picks up the
///     singleton's `state.sessionId` changes (the auto-open contract).
///
/// We never let the singleton attempt a real iroh dial. The
/// "missing prerequisite" branches stop before any `coordinator.start`
/// call, which keeps these tests hermetic.
@MainActor
final class AgentLiveStageWiringTests: XCTestCase {

    // MARK: - Singleton gating

    func test_evaluate_with_no_auth_uid_sets_signin_message_and_noops() async {
        let provider = StubPairingKeyProvider()
        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: provider
        )
        let service = HermesService()
        singleton.evaluate(authUID: nil, hermesService: service)

        XCTAssertEqual(
            singleton.connectionMessage,
            "Sign in to watch the Mac agent."
        )
        XCTAssertEqual(provider.fetchCalls, 0)
    }

    func test_evaluate_with_local_default_relay_sets_relay_message_and_noops() async {
        let provider = StubPairingKeyProvider()
        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: provider
        )
        let service = HermesService() // defaults to localDefault
        singleton.evaluate(authUID: "user-1", hermesService: service)

        XCTAssertEqual(
            singleton.connectionMessage,
            "Select an online Mac Remote Relay in Hermes to watch the agent live."
        )
        XCTAssertEqual(provider.fetchCalls, 0)
    }

    func test_evaluate_clears_message_when_inputs_become_valid_then_resets_on_signout() async {
        let provider = StubPairingKeyProvider()
        provider.scheduledKey = Data(repeating: 0x42, count: 32)
        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: provider
        )
        let service = HermesService()
        service.selectedConnection = HermesConnectionRecord(
            id: "test-relay",
            displayName: "Test Mac",
            mode: .relayLink,
            status: .online,
            relayPublicKey: "test-key"
        )
        singleton.evaluate(authUID: "user-1", hermesService: service)

        // Wait briefly so the dial task fires fetchPublicKey.
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(provider.fetchCalls, 1)
        XCTAssertNil(singleton.connectionMessage)

        // Sign-out path: nil uid should trigger stop + reset message.
        singleton.evaluate(authUID: nil, hermesService: service)
        XCTAssertEqual(
            singleton.connectionMessage,
            "Sign in to watch the Mac agent."
        )
    }

    // MARK: - Presenter + state wiring

    func test_presenter_observes_session_id_for_auto_open() async throws {
        let originalGrace = AgentLiveStagePresenter.sessionEndGrace
        AgentLiveStagePresenter.sessionEndGrace = 0.05
        defer { AgentLiveStagePresenter.sessionEndGrace = originalGrace }

        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: StubPairingKeyProvider()
        )
        let presenter = AgentLiveStagePresenter()
        presenter.observe(singleton.state)
        XCTAssertEqual(presenter.mode, .hidden)

        singleton.state.setSession(
            id: ComputerUseSessionID("wiring-1"),
            startedAt: .now
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        singleton.state.clear()
        try await Task.sleep(nanoseconds: 90_000_000) // > 50ms grace
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .sessionEnded)
    }

    func test_panic_collapse_is_independent_of_state_clear() async throws {
        let originalGrace = AgentLiveStagePresenter.sessionEndGrace
        AgentLiveStagePresenter.sessionEndGrace = 0.5 // long enough we can verify panic short-circuits it
        defer { AgentLiveStagePresenter.sessionEndGrace = originalGrace }

        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: StubPairingKeyProvider()
        )
        let presenter = AgentLiveStagePresenter()
        presenter.observe(singleton.state)

        singleton.state.setSession(id: ComputerUseSessionID("panic-1"), startedAt: .now)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(presenter.mode, .dock)

        presenter.panicCollapse()
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .panic)

        // Even after another session-id change, we don't accidentally
        // resurrect a stale grace task.
        singleton.state.clear()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(presenter.mode, .hidden)
        XCTAssertEqual(presenter.collapseReason, .panic)
    }

    func test_singleton_attaches_pip_to_shared_video_layer_on_first_frame() async throws {
        let videoCoordinator = AgentWatchVideoCoordinator()
        let pipController = ScreenSharePiPController(isPictureInPictureSupported: { true })
        let singleton = AgentWatchOverlaySingleton(
            coordinator: AgentWatchOverlayCoordinator(),
            pairingKeyProvider: StubPairingKeyProvider(),
            videoCoordinator: videoCoordinator,
            pipController: pipController
        )

        XCTAssertTrue(singleton.videoCoordinator === videoCoordinator)
        XCTAssertFalse(pipController.didRequestAutomaticInlinePiP)

        singleton.configurePictureInPicture(onDidStart: {}, onDidStop: {})
        singleton.state.ingestSurfaceFrame(
            MediaFrame(kind: .videoNAL, flags: [.keyframe], payload: Data([0x00, 0x00, 0x01]))
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(pipController.didRequestAutomaticInlinePiP)
    }
}

// MARK: - Test doubles

private final class StubPairingKeyProvider: IrohPairingPublicKeyProviding, @unchecked Sendable {
    var fetchCalls = 0
    var scheduledKey: Data = Data(repeating: 0x42, count: 32)
    var scheduledError: Error?

    func fetchPublicKey(uid: String) async throws -> Data {
        fetchCalls += 1
        if let scheduledError { throw scheduledError }
        return scheduledKey
    }
}
#endif
