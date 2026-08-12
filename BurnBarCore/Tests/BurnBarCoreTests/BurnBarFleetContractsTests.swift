@testable import BurnBarCore
import XCTest

final class BurnBarFleetContractsTests: XCTestCase {
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

    // MARK: - VAL-CONTRACT-001: full snapshot round-trip

    func test_snapshotRoundTrip_preservesEveryField() throws {
        let original = makeSnapshot(persistenceHealth: .ok)
        let decoded: BurnBarFleetSnapshot = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    func test_snapshotRoundTrip_preservesDegradedPersistenceHealth() throws {
        let original = makeSnapshot(persistenceHealth: .degraded(reason: "fleet.sqlite rebuild in progress"))
        let decoded: BurnBarFleetSnapshot = try roundTrip(original)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.persistenceHealth, .degraded(reason: "fleet.sqlite rebuild in progress"))
    }

    func test_snapshotRoundTrip_preservesFailedProbeHealth() throws {
        let base = makeSnapshot()
        let original = BurnBarFleetSnapshot(
            schemaVersion: base.schemaVersion,
            generatedAt: base.generatedAt,
            cadenceSeconds: base.cadenceSeconds,
            machine: base.machine,
            agents: base.agents,
            repos: base.repos,
            runningCount: base.runningCount,
            countsByAgent: base.countsByAgent,
            orchestrator: base.orchestrator,
            probeHealth: [
                BurnBarFleetProbeHealth(
                    agent: .claudeCode,
                    state: .failed(reason: "permission denied"),
                    rootPath: "/Users/albertonunez/.claude",
                    checkedAt: base.generatedAt
                ),
                base.probeHealth[1],
                base.probeHealth[2]
            ],
            persistenceHealth: base.persistenceHealth
        )
        let decoded: BurnBarFleetSnapshot = try roundTrip(original)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - VAL-CONTRACT-002: confidence ordering + wire strings

    func test_confidenceWireStrings_exactFive() throws {
        let expected: [(BurnBarFleetConfidence, String)] = [
            (.exactProcess, "exactProcess"),
            (.activeSessionFile, "activeSessionFile"),
            (.logHeartbeat, "logHeartbeat"),
            (.estimated, "estimated"),
            (.unsupported, "unsupported")
        ]
        for (confidence, wire) in expected {
            let data = try JSONEncoder().encode(confidence)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(wire)\"", "wire mismatch for \(confidence)")
            let decoded = try JSONDecoder().decode(BurnBarFleetConfidence.self, from: data)
            XCTAssertEqual(decoded, confidence)
        }
    }

    func test_confidenceOrdering_adjacentPairs() {
        let order: [BurnBarFleetConfidence] = [
            .exactProcess, .activeSessionFile, .logHeartbeat, .estimated, .unsupported
        ]
        for index in 0..<(order.count - 1) {
            XCTAssertGreaterThan(order[index], order[index + 1], "\(order[index]) should be > \(order[index + 1])")
            XCTAssertLessThan(order[index + 1], order[index], "\(order[index + 1]) should be < \(order[index])")
        }
    }

    func test_confidenceOrdering_shuffledSortYieldsCanonicalOrder() {
        let shuffled: [BurnBarFleetConfidence] = [
            .unsupported, .exactProcess, .estimated, .logHeartbeat, .activeSessionFile
        ]
        XCTAssertEqual(shuffled.sorted(), [.unsupported, .estimated, .logHeartbeat, .activeSessionFile, .exactProcess])
    }

    // MARK: - VAL-CONTRACT-003: status + identity wire values

    func test_statusWireStrings_exactFour() throws {
        let expected: [(BurnBarFleetAgentStatus, String)] = [
            (.running, "running"),
            (.idle, "idle"),
            (.stale, "stale"),
            (.unknown, "unknown")
        ]
        for (status, wire) in expected {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(wire)\"", "wire mismatch for \(status)")
            let decoded = try JSONDecoder().decode(BurnBarFleetAgentStatus.self, from: data)
            XCTAssertEqual(decoded, status)
        }
    }

    func test_agentIDWireStrings_exactTenCaseSet() throws {
        let expected: [(BurnBarFleetAgentID, String)] = [
            (.claudeCode, "claude-code"),
            (.factoryDroid, "factory-droid"),
            (.codex, "codex"),
            (.hermes, "hermes"),
            (.grokBot, "grok-bot"),
            (.grokCLI, "grok-cli"),
            (.pi, "pi"),
            (.cursor, "cursor"),
            (.kimi, "kimi"),
            (.geminiCLI, "gemini-cli")
        ]
        for (id, wire) in expected {
            let data = try JSONEncoder().encode(id)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(wire)\"", "wire mismatch for \(id)")
            let decoded = try JSONDecoder().decode(BurnBarFleetAgentID.self, from: data)
            XCTAssertEqual(decoded, id)
        }
    }

    func test_agentIDRoster_isExactlyTen() {
        XCTAssertEqual(BurnBarFleetAgentID.declaredRoster.count, 10)
        XCTAssertEqual(BurnBarFleetAgentID.allCases.count, 10)
        let wires = BurnBarFleetAgentID.declaredRoster.map(\.wireValue)
        XCTAssertEqual(Set(wires).count, 10, "roster contains duplicate wire values")
        let expected = [
            "claude-code", "factory-droid", "codex", "hermes", "grok-bot",
            "grok-cli", "pi", "cursor", "kimi", "gemini-cli"
        ]
        XCTAssertEqual(Set(wires), Set(expected))
    }

    func test_agentID_unknownIsNotPartOfDeclaredRoster() {
        XCTAssertFalse(BurnBarFleetAgentID.declaredRoster.contains(.unknown("aider")))
        XCTAssertNil(BurnBarFleetAgentID(wireValue: "aider"))
    }

    // MARK: - VAL-CONTRACT-004: malformed payloads fail typed

    func test_malformedPayload_truncatedJSONThrowsTyped() {
        let data = Data("{\"schemaVersion\":1,\"generatedAt\":".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    func test_malformedPayload_missingRequiredFieldThrowsTyped() {
        let data = Data("{\"schemaVersion\":1,\"generatedAt\":\"2026-08-12T00:00:00.000Z\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    func test_malformedPayload_unknownConfidenceThrowsTyped() {
        let json = """
        {"id":"claude-code","displayName":"Claude Code","status":"running","confidence":"definitely","signals":[]}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetAgent.self, from: data)) { error in
            XCTAssertEqual(error as? BurnBarFleetContractError, .unknownConfidence("definitely"))
        }
    }

    func test_malformedPayload_unknownStatusThrowsTyped() {
        let json = """
        {"id":"claude-code","displayName":"Claude Code","status":"flying","confidence":"exactProcess","signals":[]}
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetAgent.self, from: data)) { error in
            XCTAssertEqual(error as? BurnBarFleetContractError, .unknownStatus("flying"))
        }
    }

    func test_malformedPayload_neverFabricatesRunningRow() {
        // A row with an unknown status must throw; it must never decode to a
        // live-looking "running" row.
        let json = """
        {"id":"claude-code","displayName":"Claude Code","status":"flying","confidence":"exactProcess","signals":[]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetAgent.self, from: Data(json.utf8)))
    }

    // MARK: - VAL-CONTRACT-005: sensor-state honesty (unavailable)

    func test_sensorState_unavailableRoundTripsWithReason() throws {
        let machine = makeMachine(
            thermal: .unavailable(reason: "pmset thermlog empty"),
            power: .unavailable(reason: "no cheap power API")
        )
        let decoded: BurnBarMachineStatus = try roundTrip(machine)
        XCTAssertEqual(decoded.thermal, .unavailable(reason: "pmset thermlog empty"))
        XCTAssertEqual(decoded.power, .unavailable(reason: "no cheap power API"))
    }

    func test_sensorState_unavailableWireShape() throws {
        let data = try JSONEncoder().encode(BurnBarSensorState.unavailable(reason: "pmset thermlog empty"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"kind\":\"unavailable\""), "unexpected wire: \(json)")
        XCTAssertTrue(json.contains("\"reason\":\"pmset thermlog empty\""), "unexpected wire: \(json)")
        XCTAssertFalse(json.contains("\"value\""), "unavailable must not carry a value: \(json)")
    }

    func test_sensorState_unavailableEmptyReasonFailsTyped() {
        let json = #"{"kind":"unavailable","reason":"  "}"#
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarSensorState.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? BurnBarFleetContractError, .emptyReason(field: "sensor.reason"))
        }
    }

    // MARK: - VAL-CONTRACT-006: RPC method cases

    func test_fleetRPCMethodWireStrings_exactFour() {
        let expected: [(BurnBarRPCMethod, String)] = [
            (.fleetSnapshot, "daemon.fleet.snapshot"),
            (.fleetOrchestratorGet, "daemon.fleet.orchestrator.get"),
            (.fleetOrchestratorSet, "daemon.fleet.orchestrator.set"),
            (.fleetDirectiveRecord, "daemon.fleet.directive.record")
        ]
        for (method, wire) in expected {
            XCTAssertEqual(method.rawValue, wire, "rawValue mismatch for \(method)")
            XCTAssertEqual(BurnBarRPCMethod(rawValue: wire), method, "rawValue lookup failed for \(wire)")
        }
    }

    // MARK: - VAL-CONTRACT-007: RPC envelope pattern

    func test_fleetRPCEnvelopes_followEnvelopePattern() throws {
        let snapshotRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "fleet-1",
            method: .fleetSnapshot,
            params: BurnBarFleetSnapshotRequest()
        )
        let requestData = try JSONEncoder().encode(snapshotRequest)
        let requestJSON = try XCTUnwrap(String(data: requestData, encoding: .utf8))
        XCTAssertTrue(requestJSON.contains("\"id\":\"fleet-1\""), "missing id: \(requestJSON)")
        XCTAssertTrue(requestJSON.contains("\"method\":\"daemon.fleet.snapshot\""), "missing method: \(requestJSON)")
        XCTAssertTrue(requestJSON.contains("\"params\""), "missing params: \(requestJSON)")
        let decodedRequest = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetSnapshotRequest>.self,
            from: requestData
        )
        XCTAssertEqual(decodedRequest.id, "fleet-1")
        XCTAssertEqual(decodedRequest.method, .fleetSnapshot)

        let response = BurnBarRPCResponseEnvelope(
            id: "fleet-1",
            protocolVersion: BurnBarProtocolVersion.current,
            result: BurnBarFleetSnapshotResponse(snapshot: makeSnapshot())
        )
        let responseData = try JSONEncoder().encode(response)
        let responseJSON = try XCTUnwrap(String(data: responseData, encoding: .utf8))
        XCTAssertTrue(responseJSON.contains("\"protocolVersion\":1"), "protocolVersion must be 1: \(responseJSON)")
        XCTAssertTrue(responseJSON.contains("\"result\""), "missing result: \(responseJSON)")
        let decodedResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>.self,
            from: responseData
        )
        XCTAssertEqual(decodedResponse.id, "fleet-1")
        XCTAssertEqual(decodedResponse.protocolVersion, 1)
        XCTAssertNil(decodedResponse.error)
        XCTAssertEqual(decodedResponse.result?.snapshot, makeSnapshot())
    }

    func test_fleetRPCEnvelopes_orchestratorAndDirectiveRoundTrip() throws {
        let getRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "orch-1",
            method: .fleetOrchestratorGet,
            params: BurnBarFleetOrchestratorGetRequest()
        )
        let getData = try JSONEncoder().encode(getRequest)
        let decodedGet = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorGetRequest>.self,
            from: getData
        )
        XCTAssertEqual(decodedGet.method, .fleetOrchestratorGet)

        let setRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "orch-2",
            method: .fleetOrchestratorSet,
            params: BurnBarFleetOrchestratorSetRequest(
                state: BurnBarOrchestratorState(designation: .none, setAt: nil, pendingDirectives: 0)
            )
        )
        let setData = try JSONEncoder().encode(setRequest)
        let decodedSet = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetOrchestratorSetRequest>.self,
            from: setData
        )
        XCTAssertEqual(decodedSet.method, .fleetOrchestratorSet)
        XCTAssertEqual(decodedSet.params.state.designation, .none)

        let directive = BurnBarFleetDirective(
            id: "dir-1",
            kind: .summarize,
            targetAgent: .hermes,
            payload: "Summarize the fleet",
            state: .proposed,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let recordRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: "dir-1",
            method: .fleetDirectiveRecord,
            params: BurnBarFleetDirectiveRecordRequest(directive: directive)
        )
        let recordData = try JSONEncoder().encode(recordRequest)
        let decodedRecord = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarFleetDirectiveRecordRequest>.self,
            from: recordData
        )
        XCTAssertEqual(decodedRecord.method, .fleetDirectiveRecord)
        XCTAssertEqual(decodedRecord.params.directive, directive)
    }

    func test_protocolVersion_currentRemainsOne() {
        XCTAssertEqual(BurnBarProtocolVersion.current, 1)
        XCTAssertEqual(BurnBarProtocolVersion.supported, [1])
    }
}
