@testable import BurnBarCore
import XCTest

final class BurnBarFleetContractsPolicyTests: XCTestCase {
    // MARK: - Fixtures

    private func makeAgent(
        id: BurnBarFleetAgentID = .claudeCode,
        status: BurnBarFleetAgentStatus = .running,
        confidence: BurnBarFleetConfidence = .exactProcess,
        currentTask: String? = nil,
        projectName: String? = nil,
        model: String? = nil,
        lastActivityAt: Date? = nil,
        process: BurnBarFleetProcessInfo? = nil,
        signals: [BurnBarFleetSignalSource] = [],
        note: String? = nil
    ) -> BurnBarFleetAgent {
        BurnBarFleetAgent(
            id: id,
            displayName: id.wireValue,
            status: status,
            confidence: confidence,
            currentTask: currentTask,
            projectName: projectName,
            model: model,
            lastActivityAt: lastActivityAt,
            process: process,
            signals: signals,
            note: note
        )
    }

    private func makeMachine(
        thermal: BurnBarSensorState = .unavailable(reason: "pmset thermlog empty"),
        power: BurnBarSensorState = .unavailable(reason: "no cheap power API")
    ) -> BurnBarMachineStatus {
        BurnBarMachineStatus(
            cpuPercent: 12.5,
            memoryUsedBytes: 8_000_000_000,
            memoryTotalBytes: 48_000_000_000,
            loadAverage: [1.2, 1.0, 0.8],
            diskFreeBytes: 500_000_000_000,
            thermal: thermal,
            power: power
        )
    }

    private func makeSnapshot(
        persistenceHealth: BurnBarFleetPersistenceHealth = .ok,
        generatedAt: Date = Date(timeIntervalSince1970: 1_752_000_000)
    ) -> BurnBarFleetSnapshot {
        let agents = [
            makeAgent(
                id: .claudeCode,
                currentTask: "Refactor probe layer",
                projectName: "/Users/albertonunez/Developer/AgentLens",
                model: "claude-sonnet-4-5",
                lastActivityAt: generatedAt,
                process: BurnBarFleetProcessInfo(
                    pid: 19_457,
                    cpuPercent: 3.2,
                    memoryBytes: 1_024_000_000,
                    startedAt: generatedAt
                ),
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "session-registry",
                        path: "/Users/albertonunez/.claude/sessions/19457.json",
                        detail: "updatedAt fresh"
                    )
                ]
            ),
            makeAgent(
                id: .grokBot,
                status: .idle,
                confidence: .exactProcess,
                signals: [
                    BurnBarFleetSignalSource(
                        kind: "process-list",
                        path: "/Users/albertonunez/.grokbot/local-exec-daemon.json",
                        detail: "inflightCount 0"
                    )
                ]
            ),
            makeAgent(
                id: .kimi,
                status: .unknown,
                confidence: .unsupported,
                note: "no live signal defined"
            )
        ]
        return BurnBarFleetSnapshot(
            schemaVersion: 1,
            generatedAt: generatedAt,
            cadenceSeconds: 15,
            machine: makeMachine(),
            agents: agents,
            repos: [
                BurnBarFleetRepoGroup(
                    projectName: "/Users/albertonunez/Developer/AgentLens",
                    agents: [.claudeCode]
                )
            ],
            runningCount: 1,
            countsByAgent: ["claude-code": 1, "grok-bot": 0, "kimi": 0],
            orchestrator: BurnBarOrchestratorState(
                designation: .burnBarManaged,
                setAt: generatedAt,
                pendingDirectives: 2
            ),
            probeHealth: [
                BurnBarFleetProbeHealth(
                    agent: .claudeCode,
                    state: .ok,
                    rootPath: "/Users/albertonunez/.claude",
                    checkedAt: generatedAt
                ),
                BurnBarFleetProbeHealth(
                    agent: .grokBot,
                    state: .ok,
                    rootPath: "/Users/albertonunez/.grokbot",
                    checkedAt: generatedAt
                ),
                BurnBarFleetProbeHealth(
                    agent: .kimi,
                    state: .degraded(reason: "root stale since Jul 19"),
                    rootPath: "/Users/albertonunez/.kimi",
                    checkedAt: generatedAt
                )
            ],
            persistenceHealth: persistenceHealth
        )
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    // MARK: - VAL-CONTRACT-014: sensor-state available round-trip

    func test_sensorState_availableRoundTripsValue() throws {
        let machine = makeMachine(
            thermal: .available(value: 68.5),
            power: .available(value: 12.0)
        )
        let decoded: BurnBarMachineStatus = try roundTrip(machine)
        XCTAssertEqual(decoded.thermal, .available(value: 68.5))
        XCTAssertEqual(decoded.power, .available(value: 12.0))
    }

    func test_sensorState_availableWireShape() throws {
        let data = try JSONEncoder().encode(BurnBarSensorState.available(value: 68.5))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"available\""), "unexpected wire: \(json)")
        XCTAssertTrue(json.contains("\"value\":68.5"), "unexpected wire: \(json)")
    }

    // MARK: - VAL-CONTRACT-011: unknown agent id lossless round-trip

    func test_unknownAgentID_roundTripsLosslessly() throws {
        let original = makeAgent(id: .unknown("aider"), status: .idle, confidence: .estimated)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"id\":\"aider\""), "unknown id must encode to its original string: \(json)")

        let decoded: BurnBarFleetAgent = try roundTrip(original)
        XCTAssertEqual(decoded.id, .unknown("aider"))
        XCTAssertEqual(decoded, original)

        // Re-encode the decoded value: same wire string.
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(String(data: reencoded, encoding: .utf8), json)
    }

    func test_unknownAgentID_snapshotRowSurvivesWithCounts() throws {
        let base = makeSnapshot()
        let snapshot = BurnBarFleetSnapshot(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            cadenceSeconds: base.cadenceSeconds,
            machine: base.machine,
            agents: base.agents + [makeAgent(id: .unknown("aider"), status: .idle, confidence: .estimated)],
            repos: base.repos,
            runningCount: base.runningCount,
            countsByAgent: base.countsByAgent.merging(["aider": 0]) { _, new in new },
            orchestrator: base.orchestrator,
            probeHealth: base.probeHealth,
            persistenceHealth: base.persistenceHealth
        )
        let decoded: BurnBarFleetSnapshot = try roundTrip(snapshot)
        XCTAssertEqual(decoded.agents.count, snapshot.agents.count, "unknown-id row must not be dropped")
        XCTAssertEqual(decoded.agents.last?.id, .unknown("aider"))
        XCTAssertEqual(decoded.countsByAgent["aider"], 0)
        XCTAssertEqual(decoded, snapshot)
    }

    // MARK: - VAL-CONTRACT-012: Unicode / extreme-length strings

    func test_unicodeAndExtremeLengthStrings_roundTripExactly() throws {
        let hostileTask = "日本語のタスク 🧑💻 مرحبا بالعالم こんにちは e\u{0301}tude — combining: a\u{0308}b\u{0301}c"
        let longTask = String(repeating: "x", count: 10_000)
        let projectName = "/Users/测试/My Cool Project/with spaces/emoji 🚀/café"

        let original = makeAgent(
            id: .claudeCode,
            currentTask: hostileTask,
            projectName: projectName,
            model: "claude-sonnet-4-5"
        )
        let decoded: BurnBarFleetAgent = try roundTrip(original)
        XCTAssertEqual(decoded.currentTask, hostileTask, "hostile unicode must survive exactly")
        XCTAssertEqual(decoded.projectName, projectName)

        let longOriginal = makeAgent(id: .codex, currentTask: longTask, projectName: projectName)
        let longDecoded: BurnBarFleetAgent = try roundTrip(longOriginal)
        XCTAssertEqual(longDecoded.currentTask?.count, 10_000, "10,000-char task must not truncate")
        XCTAssertEqual(longDecoded.currentTask, longTask)

        // JSON stays valid UTF-8.
        let data = try JSONEncoder().encode(longOriginal)
        XCTAssertNotNil(String(data: data, encoding: .utf8), "encoded JSON must be valid UTF-8")
    }

    // MARK: - VAL-CONTRACT-013: orchestrator + directive wire values

    func test_orchestratorDesignation_wireKinds() throws {
        let none = BurnBarOrchestratorDesignation.none
        let noneData = try JSONEncoder().encode(none)
        XCTAssertEqual(String(data: noneData, encoding: .utf8), #"{"kind":"none"}"#)

        let managed = BurnBarOrchestratorDesignation.burnBarManaged
        let managedData = try JSONEncoder().encode(managed)
        XCTAssertEqual(String(data: managedData, encoding: .utf8), #"{"kind":"burnBarManaged"}"#)

        let agent = BurnBarOrchestratorDesignation.agent(id: .hermes, sessionRef: .present("sess-1"))
        let agentData = try JSONEncoder().encode(agent)
        let agentJSON = try XCTUnwrap(String(data: agentData, encoding: .utf8))
        XCTAssertTrue(agentJSON.contains("\"kind\":\"agent\""), "unexpected wire: \(agentJSON)")
        XCTAssertTrue(agentJSON.contains("\"id\":\"hermes\""), "unexpected wire: \(agentJSON)")
        XCTAssertTrue(agentJSON.contains("\"sessionRef\":\"sess-1\""), "unexpected wire: \(agentJSON)")
    }

    func test_orchestratorState_setAtIsISOUtcString() throws {
        let date = Date(timeIntervalSince1970: 1_752_000_000)
        let state = BurnBarOrchestratorState(designation: .burnBarManaged, setAt: date, pendingDirectives: 1)
        let data = try JSONEncoder().encode(state)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // ISO-8601 UTC: YYYY-MM-DDTHH:MM:SS(.sss)Z
        XCTAssertTrue(json.contains("\"setAt\":\"2025-07-08T18:40:00.000Z\""), "setAt must be ISO-8601 UTC: \(json)")

        let decoded = try JSONDecoder().decode(BurnBarOrchestratorState.self, from: data)
        XCTAssertEqual(decoded.setAt, date, "ISO-8601 UTC date must round-trip exactly")
    }

    func test_orchestratorState_setAtAbsentAndNull() throws {
        let absent = BurnBarOrchestratorState(designation: .none, setAt: nil, pendingDirectives: 0)
        let absentData = try JSONEncoder().encode(absent)
        let absentJSON = try XCTUnwrap(String(data: absentData, encoding: .utf8))
        XCTAssertFalse(absentJSON.contains("setAt"), "nil setAt must be omitted: \(absentJSON)")
        let decodedAbsent = try JSONDecoder().decode(BurnBarOrchestratorState.self, from: absentData)
        XCTAssertNil(decodedAbsent.setAt)

        // Explicit null in the payload decodes to nil too.
        let nullJSON = #"{"designation":{"kind":"none"},"setAt":null,"pendingDirectives":0}"#
        let decodedNull = try JSONDecoder().decode(BurnBarOrchestratorState.self, from: Data(nullJSON.utf8))
        XCTAssertNil(decodedNull.setAt)
    }

    func test_directiveKind_wireStrings() throws {
        let expected: [(BurnBarFleetDirectiveKind, String)] = [
            (.summarize, "summarize"),
            (.focusRepo, "focusRepo"),
            (.askStatus, "askStatus"),
            (.suggestAssignee, "suggestAssignee"),
            (.custom, "custom")
        ]
        for (kind, wire) in expected {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(wire)\"", "wire mismatch for \(kind)")
            let decoded = try JSONDecoder().decode(BurnBarFleetDirectiveKind.self, from: data)
            XCTAssertEqual(decoded, kind)
        }
    }

    func test_directiveState_taggedObjectShapes() throws {
        let cases: [(BurnBarFleetDirectiveState, String)] = [
            (.proposed, #"{"kind":"proposed"}"#),
            (.approved, #"{"kind":"approved"}"#),
            (.dismissed, #"{"kind":"dismissed"}"#),
            (.delivered, #"{"kind":"delivered"}"#)
        ]
        for (state, expectedJSON) in cases {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(String(data: data, encoding: .utf8), expectedJSON, "wire mismatch for \(state)")
            let decoded = try JSONDecoder().decode(BurnBarFleetDirectiveState.self, from: data)
            XCTAssertEqual(decoded, state)
        }

        let failed = BurnBarFleetDirectiveState.failed(reason: "gateway unreachable")
        let failedData = try JSONEncoder().encode(failed)
        let failedJSON = try XCTUnwrap(String(data: failedData, encoding: .utf8))
        XCTAssertTrue(failedJSON.contains("\"kind\":\"failed\""), "unexpected wire: \(failedJSON)")
        XCTAssertTrue(failedJSON.contains("\"reason\":\"gateway unreachable\""), "unexpected wire: \(failedJSON)")
        let decodedFailed = try JSONDecoder().decode(BurnBarFleetDirectiveState.self, from: failedData)
        XCTAssertEqual(decodedFailed, .failed(reason: "gateway unreachable"))
    }

    func test_directiveState_failedEmptyReasonFailsTyped() {
        let json = #"{"kind":"failed","reason":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetDirectiveState.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? BurnBarFleetContractError, .emptyReason(field: "directive.state.reason"))
        }
    }

    func test_directive_sessionRefOptionalityMatrix() throws {
        let date = Date(timeIntervalSince1970: 1_752_000_000)
        let absent = BurnBarFleetDirective(
            id: "d1", kind: .askStatus, targetAgent: .hermes, payload: "status?",
            state: .proposed, createdAt: date
        )
        let absentData = try JSONEncoder().encode(absent)
        let absentJSON = try XCTUnwrap(String(data: absentData, encoding: .utf8))
        XCTAssertFalse(absentJSON.contains("decidedAt"), "absent decidedAt must be omitted: \(absentJSON)")
        let decodedAbsent = try JSONDecoder().decode(BurnBarFleetDirective.self, from: absentData)
        XCTAssertNil(decodedAbsent.decidedAt)
        XCTAssertEqual(decodedAbsent, absent)

        let nullJSON = """
        {"id":"d2","kind":"askStatus","targetAgent":"hermes","payload":"status?",
         "state":{"kind":"approved"},"createdAt":"2026-08-12T00:00:00.000Z","decidedAt":null}
        """
        let decodedNull = try JSONDecoder().decode(BurnBarFleetDirective.self, from: Data(nullJSON.utf8))
        XCTAssertNil(decodedNull.decidedAt)

        let present = BurnBarFleetDirective(
            id: "d3", kind: .askStatus, targetAgent: .hermes, payload: "status?",
            state: .approved, createdAt: date, decidedAt: date, deliveryChannel: "hermes-gateway"
        )
        let presentData = try JSONEncoder().encode(present)
        let presentJSON = try XCTUnwrap(String(data: presentData, encoding: .utf8))
        XCTAssertTrue(presentJSON.contains("\"decidedAt\":\"2025-07-08T18:40:00.000Z\""), "unexpected wire: \(presentJSON)")
        let decodedPresent = try JSONDecoder().decode(BurnBarFleetDirective.self, from: presentData)
        XCTAssertEqual(decodedPresent.decidedAt, date)
        XCTAssertEqual(decodedPresent, present)
    }

    func test_directiveDeliveryAttemptID_roundTripsAsDurableHandoff() throws {
        let directive = BurnBarFleetDirective(
            id: "handoff-1",
            kind: .askStatus,
            targetAgent: .hermes,
            payload: "status?",
            state: .approved,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_100),
            deliveryChannel: "hermes",
            deliveryAttemptID: "attempt-1"
        )

        let data = try JSONEncoder().encode(directive)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"deliveryAttemptID\":\"attempt-1\""))
        let decoded = try JSONDecoder().decode(BurnBarFleetDirective.self, from: data)
        XCTAssertEqual(decoded, directive)
    }

    func test_orchestratorDesignation_sessionRefOptionalityMatrix() throws {
        // Absent: no sessionRef key.
        let absent = BurnBarOrchestratorDesignation.agent(id: .hermes, sessionRef: .absent)
        let absentData = try JSONEncoder().encode(absent)
        let absentJSON = try XCTUnwrap(String(data: absentData, encoding: .utf8))
        XCTAssertFalse(absentJSON.contains("sessionRef"), "absent sessionRef must be omitted: \(absentJSON)")
        let decodedAbsent = try JSONDecoder().decode(BurnBarOrchestratorDesignation.self, from: absentData)
        XCTAssertEqual(decodedAbsent, absent)
        XCTAssertNil(decodedAbsent.sessionRef)

        // Explicit null: sessionRef key present with null.
        let nullJSON = #"{"kind":"agent","id":"hermes","sessionRef":null}"#
        let decodedNull = try JSONDecoder().decode(BurnBarOrchestratorDesignation.self, from: Data(nullJSON.utf8))
        XCTAssertEqual(decodedNull, .agent(id: .hermes, sessionRef: .null))
        XCTAssertNil(decodedNull.sessionRef)

        // Present: sessionRef key with a string.
        let present = BurnBarOrchestratorDesignation.agent(id: .hermes, sessionRef: .present("sess-9"))
        let presentData = try JSONEncoder().encode(present)
        let presentJSON = try XCTUnwrap(String(data: presentData, encoding: .utf8))
        XCTAssertTrue(presentJSON.contains("\"sessionRef\":\"sess-9\""), "unexpected wire: \(presentJSON)")
        let decodedPresent = try JSONDecoder().decode(BurnBarOrchestratorDesignation.self, from: presentData)
        XCTAssertEqual(decodedPresent, present)
        XCTAssertEqual(decodedPresent.sessionRef, "sess-9")
    }

    // MARK: - VAL-CONTRACT-015: schemaVersion policy

    func test_schemaVersion2_failsTyped() throws {
        var json = try makeSnapshotJSON()
        json["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)) { error in
            XCTAssertEqual(
                error as? BurnBarFleetContractError,
                .incompatibleSchemaVersion(found: 2, supported: [1]),
                "expected typed incompatible-version error, got \(error)"
            )
        }
    }

    func test_schemaVersion1_withAdditiveUnknownKeys_decodes() throws {
        var json = try makeSnapshotJSON()
        json["futureField"] = ["nested": ["value": 42]]
        json["anotherFutureKey"] = "ignored"
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.agents.count, 3)
        XCTAssertEqual(decoded.runningCount, 1)
    }

    func test_schemaVersion0_failsTyped() throws {
        var json = try makeSnapshotJSON()
        json["schemaVersion"] = 0
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)) { error in
            XCTAssertEqual(error as? BurnBarFleetContractError, .incompatibleSchemaVersion(found: 0, supported: [1]))
        }
    }

    // MARK: - VAL-CONTRACT-016: status/confidence consistency rule

    func test_consistencyRule_runningNeverUnsupportedOrEstimated() {
        XCTAssertThrowsError(try makeAgent(status: .running, confidence: .unsupported).validateConsistency()) { error in
            XCTAssertEqual(
                error as? BurnBarFleetContractError,
                .inconsistentStatusConfidence(status: .running, confidence: .unsupported)
            )
        }
        XCTAssertThrowsError(try makeAgent(status: .running, confidence: .estimated).validateConsistency()) { error in
            XCTAssertEqual(
                error as? BurnBarFleetContractError,
                .inconsistentStatusConfidence(status: .running, confidence: .estimated)
            )
        }
    }

    func test_consistencyRule_unknownNeverExactProcess() {
        XCTAssertThrowsError(try makeAgent(status: .unknown, confidence: .exactProcess).validateConsistency()) { error in
            XCTAssertEqual(
                error as? BurnBarFleetContractError,
                .inconsistentStatusConfidence(status: .unknown, confidence: .exactProcess)
            )
        }
    }

    func test_consistencyRule_validCombinationsPass() throws {
        // running with exactProcess/activeSessionFile/logHeartbeat is valid.
        _ = try makeAgent(status: .running, confidence: .exactProcess).validateConsistency()
        _ = try makeAgent(status: .running, confidence: .activeSessionFile).validateConsistency()
        _ = try makeAgent(status: .running, confidence: .logHeartbeat).validateConsistency()
        // idle/stale with any confidence is valid.
        _ = try makeAgent(status: .idle, confidence: .unsupported).validateConsistency()
        _ = try makeAgent(status: .stale, confidence: .logHeartbeat).validateConsistency()
        // unknown with non-exactProcess is valid.
        _ = try makeAgent(status: .unknown, confidence: .unsupported).validateConsistency()
        _ = try makeAgent(status: .unknown, confidence: .estimated).validateConsistency()
    }

    func test_consistencyRule_snapshotLevelGuard() throws {
        let valid = makeSnapshot()
        XCTAssertNoThrow(try valid.validateConsistency())

        let base = makeSnapshot()
        let invalid = BurnBarFleetSnapshot(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            cadenceSeconds: base.cadenceSeconds,
            machine: base.machine,
            agents: [makeAgent(status: .running, confidence: .unsupported)] + base.agents.dropFirst(),
            repos: base.repos,
            runningCount: base.runningCount,
            countsByAgent: base.countsByAgent,
            orchestrator: base.orchestrator,
            probeHealth: base.probeHealth,
            persistenceHealth: base.persistenceHealth
        )
        XCTAssertThrowsError(try invalid.validateConsistency()) { error in
            XCTAssertEqual(
                error as? BurnBarFleetContractError,
                .inconsistentStatusConfidence(status: .running, confidence: .unsupported)
            )
        }
    }

    // MARK: - Helpers

    private func makeSnapshotJSON() throws -> [String: Any] {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "BurnBarFleetContractsPolicyTests", code: 1)
        }
        return dictionary
    }
}
