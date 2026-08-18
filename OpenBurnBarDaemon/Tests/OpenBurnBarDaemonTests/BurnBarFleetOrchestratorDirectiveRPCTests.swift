import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// M4 daemon-orchestrator-state: RPC-level tests for
/// `daemon.fleet.directive.record` (VAL-RPC-015, VAL-ORCH-015/029/038/039)
/// and read purity of snapshot/get reads (VAL-CROSS-009). Designation tests
/// live in `BurnBarFleetOrchestratorDesignationRPCTests`.
final class BurnBarFleetOrchestratorDirectiveRPCTests: BurnBarFleetOrchestratorRPCTestCase {
    // MARK: - VAL-RPC-015 / directive record envelope + store agreement

    func testDirectiveRecord_valid_successEnvelope_storeRowMatches() async throws {
        let (server, configuration) = try await makeServer(name: "record")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let directive = makeDirective(id: "dir-rpc-1")
        let response: BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rpc-15",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: directive)
            ),
            socketPath: socketPath
        )
        XCTAssertEqual(response.id, "rpc-15")
        XCTAssertEqual(response.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertNil(response.error)
        let recorded = try XCTUnwrap(response.result?.directive)
        XCTAssertEqual(recorded, directive)

        // Read-only sqlite3 inspection: the row matches the RPC result exactly.
        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 1)
        XCTAssertEqual(rows.directives[0], recorded)
    }

    func testDirectiveRecord_retrySameID_idempotent_singleRow() async throws {
        let (server, configuration) = try await makeServer(name: "record-retry")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let first = makeDirective(id: "dir-retry", state: .approved)
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rpc-15a",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: first)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>

        // Retry with the same id and a terminal state: the documented
        // idempotency rule updates the record in place — never a duplicate.
        let retry = makeDirective(
            id: "dir-retry",
            state: .delivered,
            decidedAt: Date(timeIntervalSince1970: 1_752_000_200)
        )
        let retryResponse: BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rpc-15b",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: retry)
            ),
            socketPath: socketPath
        )
        XCTAssertNil(retryResponse.error)
        XCTAssertEqual(retryResponse.result?.directive, retry)

        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 1, "retry must never duplicate")
        XCTAssertEqual(rows.directives[0], retry)
    }

    func testDirectiveRecord_reconciliationDoesNotDowngradeTerminalRecord() async throws {
        let (server, configuration) = try await makeServer(name: "record-reconcile")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let delivered = makeDirective(
            id: "dir-reconcile",
            state: .delivered,
            decidedAt: Date(timeIntervalSince1970: 1_752_000_200)
        )
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "reconcile-terminal",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: delivered)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>

        let recoveryCandidate = makeDirective(
            id: "dir-reconcile",
            state: .approved,
            decidedAt: delivered.decidedAt
        )
        let response: BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "reconcile-approved",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: recoveryCandidate)
            ),
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.directive, delivered)
        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 1)
        XCTAssertEqual(rows.directives.first?.state, .delivered)
    }

    // MARK: - VAL-ORCH-029 / directive.record validation over RPC

    func testDirectiveRecord_unknownKind_rejectedTyped_noRecord() async throws {
        let (server, configuration) = try await makeServer(name: "record-invalid-kind")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let raw = try rawRequest(
            #"{"id":"orch-29a","method":"daemon.fleet.directive.record","params":{"directive":"#
                + #"{"id":"bad-1","kind":"banana","payload":"x","state":{"kind":"approved"},"#
                + #""createdAt":"2026-08-12T01:01:05.000Z"}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertNil(envelope.result)
        XCTAssertNotNil(envelope.error, "unknown directive kind must fail closed")

        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 0, "no record may be created")
    }

    func testDirectiveRecord_emptyPayload_rejectedTyped_noRecord() async throws {
        let (server, configuration) = try await makeServer(name: "record-empty-payload")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let raw = try rawRequest(
            #"{"id":"orch-29b","method":"daemon.fleet.directive.record","params":{"directive":"#
                + #"{"id":"bad-2","kind":"summarize","payload":"   ","state":{"kind":"approved"},"#
                + #""createdAt":"2026-08-12T01:01:05.000Z"}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "orch-29b")
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603, "empty payload is a typed validation error")
        XCTAssertEqual(envelope.error?.message.contains("payload"), true)

        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 0)
    }

    func testDirectiveRecord_nonRosterTargetAgent_rejectedTyped_noRecord() async throws {
        let (server, configuration) = try await makeServer(name: "record-invalid-target")
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        let raw = try rawRequest(
            #"{"id":"orch-29c","method":"daemon.fleet.directive.record","params":{"directive":"#
                + #"{"id":"bad-3","kind":"summarize","targetAgent":"aider","payload":"x","#
                + #""state":{"kind":"approved"},"createdAt":"2026-08-12T01:01:05.000Z"}}}"#,
            socketPath: socketPath
        )
        let envelope = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
            from: Data(raw.utf8)
        )
        XCTAssertEqual(envelope.id, "orch-29c")
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, -32603)
        XCTAssertEqual(envelope.error?.message.contains("aider"), true)

        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 0)
    }

    // MARK: - VAL-ORCH-015 / directive history survives restart

    func testDirectiveHistory_survivesDaemonRestart() async throws {
        let (server, configuration) = try await makeServer(name: "history-restart")
        let socketPath = configuration.socketPath

        let approved = makeDirective(id: "approved-1", state: .approved)
        let dismissed = makeDirective(
            id: "dismissed-1",
            state: .dismissed,
            decidedAt: Date(timeIntervalSince1970: 1_752_000_150)
        )
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "h1",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: approved)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "h2",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: dismissed)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>

        let before = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(before.directives.count, 2)
        await server.stop()

        // Restart against the same support dir.
        let restartedServer = BurnBarDaemonServer(configuration: configuration)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }

        let after = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(after.directives.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: after.directives.map { ($0.id, $0) })
        XCTAssertEqual(byID["approved-1"]?.state, .approved)
        XCTAssertEqual(byID["dismissed-1"]?.state, .dismissed)
        XCTAssertEqual(byID["dismissed-1"]?.decidedAt, dismissed.decidedAt)

        // pendingDirectives survives restart and counts only non-terminal.
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "h-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.pendingDirectives, 1, "approved-1 pending, dismissed-1 not")
    }

    // MARK: - VAL-ORCH-039 / terminal outcomes survive restart, no redelivery

    func testTerminalOutcomes_surviveRestart_noRedelivery() async throws {
        let (server, configuration) = try await makeServer(name: "terminal-restart")
        let socketPath = configuration.socketPath

        let delivered = makeDirective(
            id: "delivered-1",
            state: .delivered,
            decidedAt: Date(timeIntervalSince1970: 1_752_000_180),
            deliveryChannel: "hermes"
        )
        let failed = makeDirective(
            id: "failed-1",
            state: .failed(reason: "gateway unreachable"),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_190),
            deliveryChannel: "hermes"
        )
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "t1",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: delivered)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "t2",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: failed)
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>
        await server.stop()

        let restartedServer = BurnBarDaemonServer(configuration: configuration)
        try await restartedServer.start()
        defer { Task { await restartedServer.stop() } }

        let after = try readStoreRows(databasePath: configuration.fleetStorePath)
        let byID = Dictionary(uniqueKeysWithValues: after.directives.map { ($0.id, $0) })
        XCTAssertEqual(byID["delivered-1"]?.state, .delivered)
        XCTAssertEqual(byID["delivered-1"]?.deliveryChannel, "hermes")
        XCTAssertEqual(byID["failed-1"]?.state, .failed(reason: "gateway unreachable"))
        XCTAssertEqual(byID["failed-1"]?.deliveryChannel, "hermes")
        XCTAssertEqual(byID["failed-1"]?.decidedAt, failed.decidedAt)

        // Terminal records never count as pending after restart, and a
        // restart never replays delivery: the records still carry their
        // terminal outcomes (no record reverted to proposed/approved).
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "t-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.pendingDirectives, 0)
    }

    // MARK: - VAL-ORCH-038 / coherence: store, RPC get, snapshot, file

    func testRecordState_coherentAcrossStoreGetSnapshotAndFile() async throws {
        let (server, configuration) = try await makeServer(name: "coherence", cadenceSeconds: 1)
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "c1",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(
                    directive: makeDirective(id: "c-proposed", state: .proposed)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "c2",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(
                    directive: makeDirective(id: "c-approved", state: .approved)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "c3",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(
                    directive: makeDirective(id: "c-delivered", state: .delivered)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>

        // Wait for a tick so the snapshot + well-known file embed the state.
        let deadline = Date().addingTimeInterval(15)
        var snapshot: BurnBarFleetSnapshot?
        while Date() < deadline {
            let attempt: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
                BurnBarRPCRequestEnvelope(id: "c-snap", method: .fleetSnapshot),
                socketPath: socketPath
            )
            if let current = attempt.result?.snapshot,
               current.orchestrator.pendingDirectives == 2,
               FileManager.default.fileExists(atPath: configuration.fleetSnapshotFilePath) {
                snapshot = current
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let served = try XCTUnwrap(snapshot, "snapshot never carried pendingDirectives=2")
        XCTAssertEqual(served.orchestrator.pendingDirectives, 2, "proposed + approved pending, delivered not")

        // orchestrator.get agrees with the snapshot.
        let getResponse: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "c-get", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        XCTAssertEqual(getResponse.result?.state.pendingDirectives, 2)

        // The well-known file is the exact snapshot payload → same count.
        let fileData = try Data(contentsOf: URL(fileURLWithPath: configuration.fleetSnapshotFilePath))
        let fileSnapshot = try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: fileData)
        XCTAssertEqual(fileSnapshot.orchestrator.pendingDirectives, 2)

        // The store rows agree (3 records, exact states).
        let rows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(rows.directives.count, 3)
        let byID = Dictionary(uniqueKeysWithValues: rows.directives.map { ($0.id, $0) })
        XCTAssertEqual(byID["c-proposed"]?.state, .proposed)
        XCTAssertEqual(byID["c-approved"]?.state, .approved)
        XCTAssertEqual(byID["c-delivered"]?.state, .delivered)
    }

    // MARK: - VAL-CROSS-009 / read purity: snapshot + get never mutate

    func testReadStorm_neverMutatesControlState() async throws {
        let (server, configuration) = try await makeServer(name: "read-purity", cadenceSeconds: 1)
        let socketPath = configuration.socketPath
        defer { Task { await server.stop() } }

        // Post-write baseline: designation + one approved directive.
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rp-1",
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: .burnBarManaged)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse>
        _ = try sendEnvelope(
            BurnBarRPCRequestEnvelopeWithParams(
                id: "rp-2",
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(
                    directive: makeDirective(id: "rp-approved", state: .approved)
                )
            ),
            socketPath: socketPath
        ) as BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse>

        // Wait for one completed tick so the snapshot is ready.
        let readyDeadline = Date().addingTimeInterval(15)
        var snapshotReady = false
        while Date() < readyDeadline {
            let attempt: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse> = try sendEnvelope(
                BurnBarRPCRequestEnvelope(id: "rp-ready", method: .fleetSnapshot),
                socketPath: socketPath
            )
            if attempt.result?.snapshot != nil {
                snapshotReady = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(snapshotReady, "snapshot never became ready")

        let baselineGet: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "rp-before", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        let baselineState = try XCTUnwrap(baselineGet.result?.state)
        let baselineRows = try readStoreRows(databasePath: configuration.fleetStorePath)

        // Read storm: 20 snapshot + get reads from 2 concurrent clients.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "read-storm", attributes: .concurrent)
        let lock = NSLock()
        var failures: [String] = []
        for index in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let method = index % 2 == 0 ? "daemon.fleet.snapshot" : "daemon.fleet.orchestrator.get"
                    let raw = try self.rawRequest(
                        "{\"id\":\"rs-\(index)\",\"method\":\"\(method)\"}",
                        socketPath: socketPath
                    )
                    let object = try XCTUnwrap(
                        try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                    )
                    if object["error"] != nil {
                        lock.lock()
                        failures.append("rs-\(index): \(object["error"] ?? "error")")
                        lock.unlock()
                    }
                } catch {
                    lock.lock()
                    failures.append("rs-\(index): \(error)")
                    lock.unlock()
                }
            }
        }
        let waitResult = group.wait(timeout: .now() + 20)
        XCTAssertEqual(waitResult, .success)
        XCTAssertTrue(failures.isEmpty, "read-storm failures: \(failures)")

        // Post-storm: designation, directive states, and pendingDirectives are
        // identical to their post-write values.
        let afterGet: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try sendEnvelope(
            BurnBarRPCRequestEnvelope(id: "rp-after", method: .fleetOrchestratorGet),
            socketPath: socketPath
        )
        let afterState = try XCTUnwrap(afterGet.result?.state)
        XCTAssertEqual(afterState.designation, baselineState.designation)
        XCTAssertEqual(afterState.setAt, baselineState.setAt)
        XCTAssertEqual(afterState.pendingDirectives, baselineState.pendingDirectives)

        let afterRows = try readStoreRows(databasePath: configuration.fleetStorePath)
        XCTAssertEqual(afterRows.directives, baselineRows.directives)
        XCTAssertEqual(afterRows.state, baselineRows.state)
    }
}
