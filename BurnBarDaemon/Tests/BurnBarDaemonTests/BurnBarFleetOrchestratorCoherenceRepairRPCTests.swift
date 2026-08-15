import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

/// M4 REPAIR (scrutiny round 1, daemon-orchestrator-state): RPC-level
/// regression tests over the socket for the idempotent-clear coherence fix
/// and the store-independent directive-state validation.
///
/// - Repeated `set(.none)` after a real clear returns the retained clear
///   timestamp in the set response, and the immediately following get agrees
///   (fresh daemon AND after restart with a persisted `none` row).
/// - `directive.record` with `failed(reason: "")` is rejected typed `-32603`
///   and no record is created.
final class BurnBarFleetOrchestratorCoherenceRepairRPCTests: BurnBarFleetOrchestratorRPCTestCase {
    // MARK: - Repeated clear after an existing none (set/get coherence)

    func testOrchestratorSet_repeatedClear_afterRealClear_returnsRetainedSetAt() async throws {
        let (server, configuration) = try await makeServer(name: "clear-coherence")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // Real designation → real clear stamps the clear timestamp.
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-1a",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .burnBarManaged)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>
        let clearResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-1b",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        let clearSetAt = try XCTUnwrap(clearResponse.result?.state.setAt)

        // Repeated set(.none): the idempotent no-op returns the UNCHANGED
        // current state — including the retained clear timestamp — so the set
        // response and the immediately following get always agree.
        let repeatedResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-1c",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        XCTAssertNil(repeatedResponse.error, "none-on-none must remain a typed success")
        let repeatedSetAt = try XCTUnwrap(repeatedResponse.result?.state.setAt)
        XCTAssertEqual(repeatedSetAt, clearSetAt, "repeated clear must preserve the prior clear timestamp")

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "coh-1-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertEqual(getResponse.result?.state.setAt, repeatedSetAt, "set response and get must agree")

        // Storage untouched by the no-op: still exactly the real clear's row.
        XCTAssertEqual(try orchestratorStateRowCount(databasePath: configuration.fleetStorePath), 1)
    }

    func testOrchestratorSet_repeatedClear_afterRestartWithPersistedNone_returnsRetainedSetAt() async throws {
        // Phase 1: set → clear, capture the clear timestamp, stop.
        let (server, configuration) = try await makeServer(name: "clear-restart-coherence")
        let socketPath = configuration.socketPath

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-2a",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .agent(id: .codex, sessionRef: .absent))
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>
        let clearResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-2b",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        let clearSetAt = try XCTUnwrap(clearResponse.result?.state.setAt)
        await server.stop()

        // Phase 2: restart with the SAME support dir — the persisted none row
        // (with its clear timestamp) is loaded.
        let restartedServer = BurnBarDaemonServer(configuration: configuration)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }

        // Repeated set(.none) after restart: returns the retained clear
        // timestamp (wire ISO-8601 millisecond precision), and the
        // immediately following get agrees.
        let repeatedResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "coh-2c",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(state: BurnBarOrchestratorState(designation: .none))
            ),
            socketPath: socketPath
        )
        XCTAssertNil(repeatedResponse.error)
        let repeatedSetAt = try XCTUnwrap(repeatedResponse.result?.state.setAt)
        XCTAssertEqual(
            repeatedSetAt.timeIntervalSince1970,
            clearSetAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the persisted clear timestamp must survive restart and be returned by the no-op"
        )

        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "coh-2-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertEqual(getResponse.result?.state.setAt, repeatedSetAt, "set response and get must agree")
        XCTAssertEqual(try orchestratorStateRowCount(databasePath: configuration.fleetStorePath), 1)
    }

    // MARK: - directive.record: failed(reason: "") rejected typed, no record

    func testDirectiveRecord_failedEmptyReason_rejectedTyped_noRecord() async throws {
        let (server, configuration) = try await makeServer(name: "record-empty-reason")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // A directly constructed failed(reason: "") state violates the
        // contract invariant (failed reasons are non-empty); the state
        // invariants are validated BEFORE the persistence path, so the wired
        // RPC rejects it typed and no record is created.
        let raw = try rawRequest(
            #"{"id":"orch-29d","method":"daemon.fleet.directive.record","params":{"directive":"#
                + #"{"id":"bad-4","kind":"summarize","payload":"x","state":{"kind":"failed","reason":""},"#
                + #""createdAt":"2026-08-12T01:01:05.000Z"}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "orch-29d")
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603, "empty failed reason is a typed validation error")
        XCTAssertTrue(envelope.error?.message.contains("reason") == true)

        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 0)
    }
}
