import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class MissionGroupObserverTests: XCTestCase {

    func test_startLatestRestoresPersistedGroupAndChildren() throws {
        let dispatcher = FakeMissionGroupDispatcher()
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup(phase: .queued)

        observer.startLatest()
        XCTAssertEqual(dispatcher.latestObservationCount, 1)
        dispatcher.emitLatestGroup(group)
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-1", runtime: "codex"), id: "child-1")
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-2", runtime: "claude"), id: "child-2")

        XCTAssertEqual(observer.displayGroup?.id, group.id)
        XCTAssertEqual(observer.displayGroup?.title, group.title)
        XCTAssertEqual(observer.displayGroup?.phase, .awaitingMerge)
        XCTAssertEqual(observer.childTiles(fallbackActiveTiles: []).map(\.id), group.childMissionIDs)
    }

    func test_displayGroupWaitsForEveryChildBeforeShowingReadyToMerge() throws {
        let dispatcher = FakeMissionGroupDispatcher()
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup(phase: .queued)
        observer.start(groupID: group.id)
        dispatcher.emitGroup(group)

        dispatcher.emitChild(
            try Self.makeSnapshot(id: "child-1", runtime: "codex", status: "running"),
            id: "child-1"
        )
        XCTAssertEqual(observer.displayGroup?.phase, .fanningOut)

        dispatcher.emitChild(try Self.makeSnapshot(id: "child-1", runtime: "codex"), id: "child-1")
        XCTAssertEqual(observer.displayGroup?.phase, .fanningOut)

        dispatcher.emitChild(try Self.makeSnapshot(id: "child-2", runtime: "claude"), id: "child-2")
        XCTAssertEqual(observer.displayGroup?.phase, .awaitingMerge)
    }

    func test_childTilesKeepTerminalResultsAfterActiveMissionTilesDisappear() throws {
        let dispatcher = FakeMissionGroupDispatcher()
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup(phase: .queued)
        observer.start(groupID: group.id)
        dispatcher.emitGroup(group)
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-1", runtime: "codex"), id: "child-1")
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-2", runtime: "claude"), id: "child-2")

        let tiles = observer.childTiles(fallbackActiveTiles: [])

        XCTAssertEqual(tiles.map(\.phase), [.completed, .completed])
        XCTAssertEqual(tiles.map(\.lastEventSnippet), ["codex final answer.", "claude final answer."])
        XCTAssertEqual(tiles.map(\.runtimeDisplayLabel), ["Codex", "Claude"])
    }

    func test_applySynthesizeFetchesMissingChildSnapshotsBeforeDispatch() async throws {
        let dispatcher = FakeMissionGroupDispatcher()
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup()
        let childOne = try Self.makeSnapshot(id: "child-1", runtime: "codex")
        let childTwo = try Self.makeSnapshot(id: "child-2", runtime: "claude")
        dispatcher.fetchSnapshots["child-2"] = childTwo

        observer.start(groupID: group.id)
        dispatcher.emitGroup(group)
        dispatcher.emitChild(childOne, id: "child-1")

        await observer.applyMerge(.synthesize)

        XCTAssertEqual(dispatcher.fetchedIDs, ["child-2"])
        XCTAssertEqual(dispatcher.dispatchCalls.count, 1)
        XCTAssertEqual(Set(dispatcher.dispatchCalls[0].childSnapshots.keys), ["child-1", "child-2"])
        XCTAssertEqual(dispatcher.mergeWinnerIDs, ["synth-1"])
        XCTAssertNil(observer.inlineError)
    }

    func test_applySynthesizeIgnoresConcurrentDuplicateTap() async throws {
        let dispatcher = FakeMissionGroupDispatcher()
        dispatcher.dispatchDelayNanos = 50_000_000
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup()
        observer.start(groupID: group.id)
        dispatcher.emitGroup(group)
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-1", runtime: "codex"), id: "child-1")
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-2", runtime: "claude"), id: "child-2")

        let first = Task { @MainActor in await observer.applyMerge(.synthesize) }
        let second = Task { @MainActor in await observer.applyMerge(.synthesize) }
        await first.value
        await second.value

        XCTAssertEqual(dispatcher.dispatchCalls.count, 1)
        XCTAssertEqual(dispatcher.mergeWinnerIDs, ["synth-1"])
        XCTAssertNil(observer.inlineError)
    }

    func test_applySynthesizeRetryAfterMergeFailureReusesQueuedSynthesizer() async throws {
        let dispatcher = FakeMissionGroupDispatcher()
        dispatcher.mergeFailuresRemaining = 1
        let observer = MissionGroupObserver(dispatcher: dispatcher)
        let group = Self.makeGroup()
        observer.start(groupID: group.id)
        dispatcher.emitGroup(group)
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-1", runtime: "codex"), id: "child-1")
        dispatcher.emitChild(try Self.makeSnapshot(id: "child-2", runtime: "claude"), id: "child-2")

        await observer.applyMerge(.synthesize)
        XCTAssertEqual(dispatcher.dispatchCalls.count, 1)
        XCTAssertEqual(dispatcher.mergeWinnerIDs, ["synth-1"])
        XCTAssertEqual(observer.inlineError, "merge failed")

        await observer.applyMerge(.synthesize)

        XCTAssertEqual(dispatcher.dispatchCalls.count, 1)
        XCTAssertEqual(dispatcher.mergeWinnerIDs, ["synth-1", "synth-1"])
        XCTAssertNil(observer.inlineError)
    }

    private static func makeGroup(phase: MissionGroupPhase = .awaitingMerge) -> MissionGroupDocument {
        MissionGroupDocument(
            id: "grp-1",
            title: "Audit fan-out",
            prompt: "Audit every child before synthesis.",
            missionKind: "diligence",
            targetProject: "BurnBar",
            childMissionIDs: ["child-1", "child-2"],
            runtimeTokens: ["codex", "claude"],
            parallelismLimit: 2,
            mergeStrategy: .synthesize,
            phase: phase,
            createdAt: ISO8601DateFormatter().date(from: "2026-06-02T12:00:00Z")!,
            updatedAt: ISO8601DateFormatter().date(from: "2026-06-02T12:05:00Z")!
        )
    }

    private static func makeSnapshot(
        id: String,
        runtime: String,
        status: String = "completed"
    ) throws -> CLIAgentMissionSnapshot {
        try XCTUnwrap(
            CLIAgentMissionSnapshot(
                documentID: id,
                data: [
                    "id": id,
                    "title": "\(runtime) result",
                    "status": status,
                    "requestedRuntime": runtime,
                    "selectedRuntime": runtime,
                    "selectedRuntimeName": runtime.capitalized,
                    "targetProject": "BurnBar",
                    "resultPreview": "\(runtime) result preview.",
                    "createdAt": "2026-06-02T12:01:00Z",
                    "events": [
                        [
                            "sequence": 1,
                            "timestamp": "2026-06-02T12:02:00Z",
                            "kind": "final_answer",
                            "phase": "completed",
                            "title": "Completed",
                            "message": "\(runtime) final answer.",
                            "fullMessage": "\(runtime) complete final answer.",
                            "isError": false
                        ]
                    ]
                ]
            )
        )
    }
}

@MainActor
private final class FakeMissionGroupDispatcher: MissionGroupDispatching {
    struct DispatchCall {
        let group: MissionGroupDocument
        let childSnapshots: [String: CLIAgentMissionSnapshot]
    }

    var fetchSnapshots: [String: CLIAgentMissionSnapshot] = [:]
    var fetchedIDs: [String] = []
    var dispatchCalls: [DispatchCall] = []
    var dispatchDelayNanos: UInt64 = 0
    var mergeWinnerIDs: [String] = []
    var mergeFailuresRemaining = 0
    var latestObservationCount = 0

    private var groupUpdate: (@MainActor (MissionGroupDocument) -> Void)?
    private var latestGroupUpdate: (@MainActor (MissionGroupDocument) -> Void)?
    private var childUpdates: [String: (@MainActor (CLIAgentMissionSnapshot) -> Void)] = [:]

    func observeLatestMissionGroup(
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        latestObservationCount += 1
        latestGroupUpdate = onUpdate
        return CLIAgentMissionObservation(registrations: [])
    }

    func observeMissionGroup(
        groupID: String,
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        groupUpdate = onUpdate
        return CLIAgentMissionObservation(registrations: [])
    }

    func observe(
        requestID: String,
        onUpdate: @escaping @MainActor (CLIAgentMissionSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        childUpdates[requestID] = onUpdate
        return CLIAgentMissionObservation(registrations: [])
    }

    func fetchMissionSnapshot(requestID: String) async throws -> CLIAgentMissionSnapshot {
        fetchedIDs.append(requestID)
        guard let snapshot = fetchSnapshots[requestID] else {
            throw FakeMissionGroupDispatcherError.missingSnapshot(requestID)
        }
        return snapshot
    }

    func dispatchMissionGroupSynthesis(
        group: MissionGroupDocument,
        childSnapshots: [String: CLIAgentMissionSnapshot]
    ) async throws -> String {
        if dispatchDelayNanos > 0 {
            try await Task.sleep(nanoseconds: dispatchDelayNanos)
        }
        dispatchCalls.append(DispatchCall(group: group, childSnapshots: childSnapshots))
        return "synth-\(dispatchCalls.count)"
    }

    func mergeMissionGroup(
        groupID: String,
        winnerMissionID: String?,
        synthesisSummary: String?
    ) async throws {
        mergeWinnerIDs.append(winnerMissionID ?? "<nil>")
        if mergeFailuresRemaining > 0 {
            mergeFailuresRemaining -= 1
            throw FakeMissionGroupDispatcherError.mergeFailed
        }
    }

    func emitGroup(_ group: MissionGroupDocument) {
        groupUpdate?(group)
    }

    func emitLatestGroup(_ group: MissionGroupDocument) {
        latestGroupUpdate?(group)
    }

    func emitChild(_ snapshot: CLIAgentMissionSnapshot, id: String) {
        childUpdates[id]?(snapshot)
    }
}

private enum FakeMissionGroupDispatcherError: LocalizedError {
    case missingSnapshot(String)
    case mergeFailed

    var errorDescription: String? {
        switch self {
        case let .missingSnapshot(id):
            return "missing snapshot \(id)"
        case .mergeFailed:
            return "merge failed"
        }
    }
}
