import BurnBarCore
import XCTest

@testable import BurnBar

@MainActor
final class ChatSessionControllerFleetShareTests: ChatSessionControllerOrchestratorTestCase {
    func test_prepareOrchestratorChatSurvivesLoadPersistedMessages() {
        let controller = makeController(snapshot: freshSnapshot())
        controller.startNewChatThread()
        let realThread = controller.activeThreadID
        XCTAssertNotEqual(realThread, DataStore.legacyChatThreadID)

        // First Fleet open: controller is still on the unused legacy id.
        controller.activateThread(DataStore.legacyChatThreadID)
        controller.setActiveChatMode(.analyst)

        controller.prepareOrchestratorChat()
        XCTAssertEqual(controller.mode, .orchestrator)
        XCTAssertEqual(controller.activeThreadID, realThread)

        controller.loadPersistedMessages()
        XCTAssertEqual(controller.mode, .orchestrator)
        XCTAssertEqual(controller.activeThreadID, realThread)
    }

    func test_prepareOrchestratorChatDoesNotReloadALiveThread() {
        let controller = makeController(snapshot: freshSnapshot())
        controller.startNewChatThread()
        controller.messages = [ChatMessageRecord(role: .user, content: "in-memory only")]
        let threadID = controller.activeThreadID

        controller.prepareOrchestratorChat()
        XCTAssertEqual(controller.mode, .orchestrator)
        XCTAssertEqual(controller.activeThreadID, threadID)
        XCTAssertEqual(controller.messages.first?.content, "in-memory only")
    }

    func test_chatContextFetchDoesNotStartPoller() {
        let snapshot = freshSnapshot()
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in snapshot })
        let controller = makeController(snapshot: snapshot, fleetService: service)

        XCTAssertFalse(service.isPolling)
        controller.setMode(.orchestrator)
        XCTAssertFalse(service.isPolling)
        XCTAssertEqual(service.loadState, .ready(snapshot))
    }

    func test_stopDoesNotBreakLaterChatContextFetch() async {
        let snapshot = freshSnapshot()
        let service = FleetService(socketURL: socketURL, fetchSnapshot: { _ in snapshot })
        let controller = makeController(
            snapshot: snapshot,
            cliBridge: makeFakeCLIBridge(mode: "answer"),
            fleetService: service
        )
        service.start()
        service.stop()
        XCTAssertFalse(service.isPolling)

        controller.setMode(.orchestrator)
        XCTAssertFalse(service.isPolling)
        controller.inputText = "who is running?"
        await controller.send()
        await waitForStream(controller)
        XCTAssertFalse(service.isPolling)
        XCTAssertNotNil(service.loadState.snapshot)
    }

    func test_sharedPollerIgnoresLaggingNoneEmbedFromChatRefresh() async {
        let ready = freshSnapshot()
        let lagging = FleetTestFixtures.makeSnapshot(
            generatedAt: ready.generatedAt.addingTimeInterval(-120)
        )
        let laggingNone = BurnBarFleetSnapshot(
            schemaVersion: lagging.schemaVersion,
            generatedAt: lagging.generatedAt,
            cadenceSeconds: lagging.cadenceSeconds,
            machine: lagging.machine,
            agents: lagging.agents,
            repos: lagging.repos,
            runningCount: lagging.runningCount,
            countsByAgent: lagging.countsByAgent,
            orchestrator: BurnBarOrchestratorState(designation: .none),
            probeHealth: lagging.probeHealth,
            persistenceHealth: lagging.persistenceHealth
        )
        var next = ready
        let service = FleetService(
            socketURL: socketURL,
            fetchSnapshot: { _ in next },
            setOrchestratorState: { designation, _ in
                BurnBarOrchestratorState(
                    designation: designation,
                    setAt: Date(),
                    pendingDirectives: 0
                )
            }
        )
        let controller = makeController(snapshot: ready, fleetService: service)
        service.start()
        await service.setDesignation(.hermesDesignation)
        let acknowledged = service.orchestratorState
        next = laggingNone
        controller.prepareOrchestratorChat()

        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(service.loadState, .ready(ready))
        XCTAssertEqual(service.orchestratorState, acknowledged)
        service.stop()
    }
}

private extension BurnBarOrchestratorDesignation {
    static var hermesDesignation: BurnBarOrchestratorDesignation {
        .agent(id: .hermes, sessionRef: .absent)
    }
}
