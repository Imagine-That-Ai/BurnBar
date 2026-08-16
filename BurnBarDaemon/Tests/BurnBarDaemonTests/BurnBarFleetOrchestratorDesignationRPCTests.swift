import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// M4 daemon-orchestrator-state: RPC-level tests for
/// `daemon.fleet.orchestrator.get/set` (VAL-RPC-008/009, VAL-ORCH-001..004,
/// 017, 018, 019, 020). The directive-record RPC tests live in
/// `BurnBarFleetOrchestratorDirectiveRPCTests`.
final class BurnBarFleetOrchestratorDesignationRPCTests: BurnBarFleetOrchestratorRPCTestCase {
    // MARK: - VAL-RPC-008 / fresh default over RPC

    func testOrchestratorGet_freshDaemon_defaultNone() async throws {
        let (server, configuration) = try await makeServer(name: "fresh-default")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let response: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "rpc-8", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(response.id, "rpc-8")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        let state = try XCTUnwrap(response.result?.state)
        XCTAssertEqual(state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertNil(state.setAt)
        XCTAssertEqual(state.pendingDirectives, 0)
    }

    // MARK: - VAL-ORCH-001 / burnBarManaged over RPC

    func testOrchestratorSet_getRoundTrip_burnBarManaged() async throws {
        let (server, configuration) = try await makeServer(name: "set-bbm")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let setResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-1",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .burnBarManaged)
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(setResponse.error)
        XCTAssertEqual(setResponse.result?.state.designation, .burnBarManaged)
        XCTAssertNotNil(setResponse.result?.state.setAt)

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-1-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, .burnBarManaged)
        XCTAssertEqual(getResponse.result?.state.setAt, setResponse.result?.state.setAt)
    }

    // MARK: - VAL-ORCH-002 / agent designation + sessionRef

    func testOrchestratorSet_getRoundTrip_agentWithSessionRef() async throws {
        let (server, configuration) = try await makeServer(name: "set-agent")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let setResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-2",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(
                        designation: .agent(id: .claudeCode, sessionRef: .present("session-xyz"))
                    )
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(setResponse.error)
        XCTAssertEqual(
            setResponse.result?.state.designation,
            .agent(id: .claudeCode, sessionRef: .present("session-xyz"))
        )

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-2-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(
            getResponse.result?.state.designation,
            .agent(id: .claudeCode, sessionRef: .present("session-xyz"))
        )
    }

    // MARK: - Minimal set payload accepted (validator wire shape)

    func testOrchestratorSet_minimalPayloadWithoutPendingFields_accepted() async throws {
        let (server, configuration) = try await makeServer(name: "minimal-set")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // Validators send `{"state":{"designation":{...}}}` without setAt or
        // pendingDirectives; the server consumes only `designation`.
        let raw = try rawRequest(
            #"{"id":"min-1","method":"daemon.fleet.orchestrator.set","params":{"state":{"designation":{"kind":"agent","id":"codex"}}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "min-1")
        XCTAssertNil(envelope.error)
        XCTAssertEqual(envelope.result?.state.designation, .agent(id: .codex, sessionRef: .absent))
        XCTAssertNotNil(envelope.result?.state.setAt)
    }

    // MARK: - VAL-ORCH-003 / clear over RPC + store

    func testOrchestratorSet_clear_none() async throws {
        let (server, configuration) = try await makeServer(name: "clear")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-3a",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .burnBarManaged)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>

        let clearResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-3b",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        XCTAssertNil(clearResponse.error)
        XCTAssertEqual(clearResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertNotNil(clearResponse.result?.state.setAt)

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-3-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)

        // Daemon-state inspection: the stored row holds the cleared state.
        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        let storedState = try JSONDecoder().decode(
            BurnBarOrchestratorState.self,
            from: Data(try XCTUnwrap(rows.state).utf8)
        )
        XCTAssertEqual(storedState.designation, BurnBarOrchestratorDesignation.none)
    }

    // MARK: - VAL-ORCH-017 / overwrite + single row

    func testOrchestratorSet_overwrite_advancesSetAt_singleRow() async throws {
        let (server, configuration) = try await makeServer(name: "overwrite")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let first: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-17a",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .agent(id: .claudeCode, sessionRef: .absent))
                )
            ),
            socketPath: socketPath
        )
        try await Task.sleep(nanoseconds: 2_000_000)
        let second: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-17b",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .burnBarManaged))
            ),
            socketPath: socketPath
        )
        XCTAssertNil(second.error)
        XCTAssertEqual(second.result?.state.designation, .burnBarManaged)
        let firstSetAt = try XCTUnwrap(first.result?.state.setAt)
        let secondSetAt = try XCTUnwrap(second.result?.state.setAt)
        XCTAssertGreaterThan(secondSetAt, firstSetAt)

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-17-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, .burnBarManaged)
        XCTAssertEqual(getResponse.result?.state.setAt, secondSetAt)

        // Exactly one state row (SELECT COUNT(*) FROM orchestrator_state).
        XCTAssertEqual(try orchestratorStateRowCount(databasePath: configuration.fleetStorePath), 1)
    }

    // MARK: - VAL-ORCH-018 / idempotent clear when none

    func testOrchestratorSet_clearWhenNone_idempotent() async throws {
        let (server, configuration) = try await makeServer(name: "clear-none")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let response: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-18",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        XCTAssertNil(response.error, "none-on-none must be a typed success")
        XCTAssertEqual(response.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertNil(response.result?.state.setAt, "idempotent clear must not fabricate a phantom setAt")

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-18-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertNil(getResponse.result?.state.setAt)

        // Store unchanged: no state row was created by the no-op.
        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertNil(rows.state)
    }

    // MARK: - VAL-RPC-009 / invalid set rejected typed, state unchanged

    func testOrchestratorSet_unknownDesignationKind_rejectedTyped() async throws {
        let (server, configuration) = try await makeServer(name: "invalid-kind")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let raw = try rawRequest(
            #"{"id":"rpc-9a","method":"daemon.fleet.orchestrator.set","params":{"state":{"designation":{"kind":"banana"},"pendingDirectives":0}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "rpc-9a")
        XCTAssertNil(envelope.result)
        // The unknown designation kind is a semantic decode failure that
        // propagates typed as the daemon's -32603 internalError (only a
        // wrong-typed `params` value yields -32602, per the error matrix).
        XCTAssertEqual(envelope.error?.code, -32603, "unknown designation kind is a typed validation error")
        XCTAssertFalse(envelope.error?.details.isEmpty == true)

        // State unchanged: get still returns the fresh none default.
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "rpc-9a-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
    }

    func testOrchestratorSet_nonRosterAgentID_rejectedTyped_stateUnchanged() async throws {
        let (server, configuration) = try await makeServer(name: "invalid-agent")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // First establish a real designation so "state unchanged" is observable.
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rpc-9b-set",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .burnBarManaged)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>

        // agent("aider") is outside the declared ten-ID roster → typed rejection.
        let raw = try rawRequest(
            #"{"id":"rpc-9b","method":"daemon.fleet.orchestrator.set","params":{"state":{"designation":{"kind":"agent","id":"aider"},"pendingDirectives":0}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "rpc-9b")
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603, "non-roster agent id is a typed validation error")
        XCTAssertTrue(envelope.error?.message.contains("aider") == true)

        // Stored state unchanged: still burnBarManaged.
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "rpc-9b-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, .burnBarManaged)
    }

    // MARK: - VAL-ORCH-019 / declared non-running agent — documented outcome A

    func testOrchestratorSet_declaredNonRunningAgent_accepted_documentedOutcomeA() async throws {
        let (server, configuration) = try await makeServer(name: "non-running", cadenceSeconds: 1)
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // pi is a declared roster agent (present as a fixed row in every
        // snapshot) but is not running in this hermetic fixture. Outcome A
        // (documented): the designation is ACCEPTED — designation is
        // control-plane intent, not a liveness claim.
        let setResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-19",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .agent(id: .pi, sessionRef: .absent))
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(setResponse.error, "declared non-running agent designation must be accepted (outcome A)")
        XCTAssertEqual(setResponse.result?.state.designation, .agent(id: .pi, sessionRef: .absent))

        // The fixed pi row remains present in the snapshot with its real
        // (non-running) status — designation never fabricates liveness.
        // Poll until a tick embeds the new designation into the snapshot.
        let deadline = Date().addingTimeInterval(10)
        var snapshot: BurnBarFleetSnapshot?
        while Date() < deadline {
            let attempt: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
                BurnBarRPCRequestEnvelope(id: "orch-19-snap", method: .fleetSnapshot),
                socketPath: socketPath
            )
            if let current = attempt.result?.snapshot,
               current.orchestrator.designation == .agent(id: .pi, sessionRef: .absent) {
                snapshot = current
                break
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        let served = try XCTUnwrap(snapshot, "snapshot never embedded the pi designation")
        let pi = try XCTUnwrap(served.agents.first { $0.id == .pi })
        XCTAssertNotEqual(pi.status, .running)
        XCTAssertEqual(served.orchestrator.designation, .agent(id: .pi, sessionRef: .absent))
    }

    // MARK: - VAL-ORCH-004 / designation survives restart

    func testDesignation_survivesDaemonRestart_sameSupportDir() async throws {
        // Phase 1: set a designation, capture it, stop the daemon.
        let (server, configuration) = try await makeServer(name: "restart")
        let socketPath = configuration.socketPath
        let setResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "orch-4a",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .agent(id: .hermes, sessionRef: .present("gw-1")))
                )
            ),
            socketPath: socketPath
        )
        XCTAssertNil(setResponse.error)
        let before = try XCTUnwrap(setResponse.result?.state)
        await server.stop()

        // Phase 2: relaunch with the SAME support dir (same store path).
        let restartedServer = BurnBarDaemonServer(configuration: configuration)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "orch-4b", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        let after = try XCTUnwrap(getResponse.result?.state)
        XCTAssertEqual(after.designation, before.designation)
        XCTAssertEqual(after.designation, .agent(id: .hermes, sessionRef: .present("gw-1")))
        let beforeSetAt = try XCTUnwrap(before.setAt)
        let afterSetAt = try XCTUnwrap(after.setAt)
        XCTAssertEqual(afterSetAt.timeIntervalSince1970, beforeSetAt.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - VAL-ORCH-020 / serialized single-state integrity (concurrent sets)

    func testConcurrentSets_serializedSingleState() async throws {
        let (server, configuration) = try await makeServer(name: "concurrent-sets")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "concurrent-sets", attributes: .concurrent)
        let lock = NSLock()
        var failures: [String] = []
        var successCount = 0

        let payloads: [(String, BurnBarOrchestratorDesignation)] = [
            ("cs-1", .burnBarManaged),
            ("cs-2", .agent(id: .claudeCode, sessionRef: .absent)),
            ("cs-3", .agent(id: .grokBot, sessionRef: .present("g-1"))),
            ("cs-4", .none)
        ]
        for (id, designation) in payloads {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let envelope = BurnBarRPCRequestEnvelopeWithParams(
                        id: id,
                        method: .fleetOrchestratorSet,
                        params: BurnBarFleetOrchestratorSetRequest(
                            state: BurnBarOrchestratorState(designation: designation)
                        )
                    )
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(envelope) + Data([0x0A])
                    let fileDescriptor = try self.connectSocket(socketPath: socketPath)
                    defer { close(fileDescriptor) }
                    try writeFleetSocketData(data, to: fileDescriptor)
                    let response = try self.readResponse(from: fileDescriptor)
                    let decoded = try JSONDecoder().decode(
                        BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>.self,
                        from: response
                    )
                    if decoded.error != nil {
                        lock.lock()
                        failures.append("\(id): \(decoded.error?.message ?? "unknown error")")
                        lock.unlock()
                    } else {
                        lock.lock()
                        successCount += 1
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failures.append("\(id): \(error)")
                    lock.unlock()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 15)
        XCTAssertEqual(waitResult, .success, "concurrent sets must all complete")
        XCTAssertTrue(failures.isEmpty, "concurrent failures: \(failures)")
        XCTAssertEqual(successCount, 4, "all four accepted payloads must return typed success")

        // The final state equals exactly one of the accepted payloads —
        // never torn or merged.
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "cs-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        let finalState = try XCTUnwrap(getResponse.result?.state)
        let acceptedDesignations: [BurnBarOrchestratorDesignation] = payloads.map(\.1)
        XCTAssertTrue(
            acceptedDesignations.contains(finalState.designation),
            "final designation must equal exactly one accepted payload, got \(finalState.designation)"
        )

        // Exactly one state row exists.
        XCTAssertEqual(try orchestratorStateRowCount(databasePath: configuration.fleetStorePath), 1)

        // The single state survives restart.
        await server.stop()
        let restartedServer = BurnBarDaemonServer(configuration: configuration)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }
        let afterGet: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "cs-get-2", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(afterGet.result?.state.designation, finalState.designation)
    }
}
