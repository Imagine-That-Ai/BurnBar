import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

// MARK: - AgentBrandZoneStore behavior (audit wave 4, item 15)
//
// The brand zone's quick-action persistence/networking moved out of
// `AgentBrandZoneView` into `AgentBrandZoneStore`. These tests lock the moved
// behavior through the store's injected seams: chat history reads for the
// forward context, the pending-prompt stash for native handoffs, and the
// `MissionConsoleHost` dispatch for relay forwards.

@MainActor
final class AgentBrandZoneStoreTests: XCTestCase {

    // MARK: - runtimeToken

    func test_runtimeToken_prefersRuntimeID_thenMacRelay_thenNil() {
        // Built-ins carry a runtime id.
        XCTAssertEqual(AgentBrandZoneStore.runtimeToken(for: .builtIn(.claude)), "claude")
        XCTAssertEqual(AgentBrandZoneStore.runtimeToken(for: .builtIn(.hermes)), "hermes")

        // Third-party mac-relay identity: the relay runtime string wins
        // (whitespace-trimmed, matching the original in-view helper).
        let relay = AgentIdentity(
            id: "agent://vendor/custom",
            displayName: "Custom",
            glyph: "C",
            paletteHex: "112233",
            dispatchTransport: .macRelay(runtime: " droid ")
        )
        XCTAssertEqual(AgentBrandZoneStore.runtimeToken(for: relay), "droid")

        // Blank relay runtime and non-relay transports resolve to nil.
        let blankRelay = AgentIdentity(
            id: "agent://vendor/blank",
            displayName: "Blank",
            glyph: "B",
            paletteHex: "112233",
            dispatchTransport: .macRelay(runtime: "   ")
        )
        XCTAssertNil(AgentBrandZoneStore.runtimeToken(for: blankRelay))

        let native = AgentIdentity(
            id: "agent://vendor/native",
            displayName: "Native",
            glyph: "N",
            paletteHex: "112233",
            dispatchTransport: .nativeRelay
        )
        XCTAssertNil(AgentBrandZoneStore.runtimeToken(for: native))
    }

    // MARK: - forwardContextSnapshot

    func test_forwardContextSnapshot_nativeRuntime_readsLatestMobileThread() async {
        let history = makeHistory()
        history.upsert(MobileChatThread(
            id: "hermes-thread-1",
            runtime: AssistantRuntimeID.hermes.rawValue,
            title: "Burn audit",
            preview: "",
            modelName: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            messages: [
                MobileChatMessage(role: "user", text: "How hot did we run?", timestamp: Date(timeIntervalSince1970: 150))
            ]
        ))
        let store = makeStore(history: history)

        let context = await store.forwardContextSnapshot(for: .builtIn(.hermes))

        XCTAssertEqual(context?.title, "Burn audit")
        // Empty persisted preview falls back to the last message text.
        XCTAssertEqual(context?.preview, "How hot did we run?")
        XCTAssertEqual(context?.sourceLabel, "mobile thread")
        // `MobileChatHistoryStore.upsert` re-stamps `updatedAt`; the context
        // must mirror whatever the store holds (same as the old in-view read).
        XCTAssertEqual(context?.updatedAt, history.threads(for: .hermes).first?.updatedAt)
    }

    func test_forwardContextSnapshot_cliRuntime_refreshesAndUsesMirroredSession() async {
        let source = StubCLISource()
        source.allSessions = [
            CLIAgentSessionRecord(
                id: "codex-1",
                agent: .codex,
                title: "Refactor sweep",
                preview: "Moved views to stores.",
                createdAt: Date(timeIntervalSince1970: 300),
                updatedAt: Date(timeIntervalSince1970: 400)
            )
        ]
        let reader = CLIAgentChatReader(remote: source, observeAuthChanges: false)
        let store = makeStore(reader: reader)

        let context = await store.forwardContextSnapshot(for: .builtIn(.codex))

        XCTAssertEqual(context?.title, "Refactor sweep")
        XCTAssertEqual(context?.preview, "Moved views to stores.")
        XCTAssertEqual(context?.sourceLabel, "Mac mirrored session")
        XCTAssertEqual(context?.updatedAt, Date(timeIntervalSince1970: 400))
    }

    func test_forwardContextSnapshot_withoutRuntimeID_isNil() async {
        let store = makeStore()
        let identity = AgentIdentity(
            id: "agent://vendor/custom",
            displayName: "Custom",
            glyph: "C",
            paletteHex: "112233",
            dispatchTransport: .macRelay(runtime: "custom")
        )

        let context = await store.forwardContextSnapshot(for: identity)

        XCTAssertNil(context)
    }

    // MARK: - forward

    func test_forward_nativeDestination_withDirectHandoff_stashesPromptAndOpensThread() async {
        let store = makeStore()
        let host = FakeBrandZoneMissionHost()
        AssistantPendingPrompt.shared.clear(.hermes)
        defer { AssistantPendingPrompt.shared.clear(.hermes) }

        let result = await store.forward(
            source: .builtIn(.codex),
            destination: .builtIn(.hermes),
            context: nil,
            note: "Take it from here.",
            missionHost: host,
            directThreadHandoffAvailable: true
        )

        XCTAssertEqual(result.resolution, .openRuntimeThread(.hermes))
        XCTAssertTrue(result.message.contains("opened a new thread"))
        // The prompt landed in the pending-prompt slot, not in a mission.
        let stashed = AssistantPendingPrompt.shared.consume(.hermes)
        XCTAssertNotNil(stashed)
        XCTAssertTrue(stashed?.contains("Operator note: Take it from here.") ?? false)
        XCTAssertTrue(host.dispatched.isEmpty)
    }

    func test_forward_nativeDestination_withoutDirectHandoff_dispatchesMission() async {
        let store = makeStore()
        let host = FakeBrandZoneMissionHost()
        host.outcome = .dispatched(missionID: "mission-42")
        AssistantPendingPrompt.shared.clear(.hermes)
        defer { AssistantPendingPrompt.shared.clear(.hermes) }

        let result = await store.forward(
            source: .builtIn(.codex),
            destination: .builtIn(.hermes),
            context: AgentForwardContextSnapshot(
                title: "Burn audit",
                preview: "How hot did we run?",
                sourceLabel: "mobile thread",
                updatedAt: Date(timeIntervalSince1970: 200)
            ),
            note: "",
            missionHost: host,
            directThreadHandoffAvailable: false
        )

        XCTAssertEqual(result.resolution, .openRuntimeList(.hermes))
        XCTAssertTrue(result.message.contains("mission-42"))
        XCTAssertNil(AssistantPendingPrompt.shared.consume(.hermes))
        XCTAssertEqual(host.dispatched.count, 1)
        let request = host.dispatched[0]
        XCTAssertEqual(request.runtimeID, "hermes")
        XCTAssertTrue(request.title.contains("Forward"))
        XCTAssertTrue(request.prompt.contains("Burn audit"))
        XCTAssertFalse(request.commandsAllowed)
        XCTAssertFalse(request.fileEditsAllowed)
    }

    func test_forward_failedDispatch_reportsFailureWithoutNavigation() async {
        let store = makeStore()
        let host = FakeBrandZoneMissionHost()
        host.outcome = .failed(message: "relay offline")

        let result = await store.forward(
            source: .builtIn(.claude),
            destination: .builtIn(.codex),
            context: nil,
            note: "",
            missionHost: host,
            directThreadHandoffAvailable: true
        )

        XCTAssertEqual(result.resolution, .none)
        XCTAssertEqual(result.message, "Forward failed: relay offline")
        XCTAssertEqual(host.dispatched.map(\.runtimeID), ["codex"])
    }

    func test_forward_unresolvableDestination_failsBeforeDispatch() async {
        let store = makeStore()
        let host = FakeBrandZoneMissionHost()
        let destination = AgentIdentity(
            id: "agent://vendor/native",
            displayName: "Native Agent",
            glyph: "N",
            paletteHex: "112233",
            dispatchTransport: .nativeRelay
        )

        let result = await store.forward(
            source: .builtIn(.claude),
            destination: destination,
            context: nil,
            note: "",
            missionHost: host,
            directThreadHandoffAvailable: true
        )

        XCTAssertEqual(result.resolution, .none)
        XCTAssertTrue(result.message.contains("Couldn't resolve a dispatch runtime"))
        XCTAssertTrue(host.dispatched.isEmpty)
    }

    // MARK: - Fixtures

    private func makeHistory() -> MobileChatHistoryStore {
        MobileChatHistoryStore(local: BrandZoneTestLocalStore(), cloud: nil)
    }

    private func makeStore(
        history: MobileChatHistoryStore? = nil,
        reader: CLIAgentChatReader? = nil
    ) -> AgentBrandZoneStore {
        AgentBrandZoneStore(
            historyStore: history ?? makeHistory(),
            cliReader: reader ?? CLIAgentChatReader(remote: StubCLISource(), observeAuthChanges: false),
            subscriptionTopics: AgentSubscriptionTopicStore(),
            pendingPrompt: .shared
        )
    }
}

// MARK: - Fakes

@MainActor
@Observable
private final class FakeBrandZoneMissionHost: MissionConsoleHost {
    var snapshot: MissionConsoleSnapshot = .empty
    var lastDispatchedMissionID: String?
    var isDispatching: Bool = false
    var inlineError: String?

    var dispatched: [MissionConsoleDispatchRequest] = []
    var outcome: MissionConsoleDispatchOutcome = .dispatched(missionID: "mission-1")

    func dispatch(_ request: MissionConsoleDispatchRequest) async -> MissionConsoleDispatchOutcome {
        dispatched.append(request)
        return outcome
    }

    func respond(to ask: MissionConsoleApprovalAsk, approve: Bool) async {}
    func clearInlineError() {}
    func refresh() async {}
}

private final class BrandZoneTestLocalStore: MobileChatLocalStoring {
    private var snapshot = MobileChatHistorySnapshot()

    func setActivePartition(_ key: String) {}

    func load() throws -> MobileChatHistorySnapshot {
        snapshot
    }

    func save(_ snapshot: MobileChatHistorySnapshot) throws {
        self.snapshot = snapshot
    }
}
