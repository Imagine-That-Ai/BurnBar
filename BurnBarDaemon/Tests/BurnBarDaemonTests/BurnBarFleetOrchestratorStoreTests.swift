import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import GRDB
import XCTest

/// M4 daemon-orchestrator-state: unit tests for `BurnBarFleetControlStore`
/// (designation lifecycle, validation, directive upsert idempotency,
/// pendingDirectives definition, restart persistence).
final class BurnBarFleetOrchestratorStoreTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-orchestrator-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    private var storeURL: URL {
        fixtureRoot.appendingPathComponent("fleet.sqlite")
    }

    private func makeStore() throws -> BurnBarFleetStore {
        let store = BurnBarFleetStore(databasePath: storeURL.path)
        _ = try store.open()
        return store
    }

    private func makeControlStore(store: BurnBarFleetStore? = nil) -> BurnBarFleetControlStore {
        BurnBarFleetControlStore(store: store)
    }

    /// A valid directive for record tests.
    private func makeDirective(
        id: String = "dir-1",
        kind: BurnBarFleetDirectiveKind = .summarize,
        targetAgent: BurnBarFleetAgentID? = .claudeCode,
        payload: String = "Summarize current work",
        state: BurnBarFleetDirectiveState = .approved,
        createdAt: Date = Date(timeIntervalSince1970: 1_752_000_000),
        decidedAt: Date? = Date(timeIntervalSince1970: 1_752_000_100),
        deliveryChannel: String? = nil
    ) -> BurnBarFleetDirective {
        BurnBarFleetDirective(
            id: id,
            kind: kind,
            targetAgent: targetAgent,
            payload: payload,
            state: state,
            createdAt: createdAt,
            decidedAt: decidedAt,
            deliveryChannel: deliveryChannel
        )
    }

    // MARK: - VAL-RPC-008 / fresh default

    func testFreshDefault_designationNone_setAtNil_pendingZero() async {
        let control = makeControlStore()
        let state = await control.currentState()
        XCTAssertEqual(state.designation, .none)
        XCTAssertNil(state.setAt)
        XCTAssertEqual(state.pendingDirectives, 0)
    }

    // MARK: - ORCH-001 / burnBarManaged round-trip

    func testSetBurnBarManaged_persistsAndRoundTrips() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let updated = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .burnBarManaged)
        )
        XCTAssertEqual(updated.designation, .burnBarManaged)
        XCTAssertNotNil(updated.setAt)

        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .burnBarManaged)
        XCTAssertEqual(readBack.setAt, updated.setAt)

        // Exactly one state row in the store (ORCH-017 single-row rule).
        XCTAssertEqual(try store.orchestratorStateRowCount(), 1)
    }

    // MARK: - ORCH-002 / agent designation with sessionRef

    func testSetAgent_withSessionRef_preserved() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let updated = try await control.setOrchestratorState(
            BurnBarOrchestratorState(
                designation: .agent(id: .claudeCode, sessionRef: .present("session-abc"))
            )
        )
        XCTAssertEqual(updated.designation, .agent(id: .claudeCode, sessionRef: .present("session-abc")))
        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .agent(id: .claudeCode, sessionRef: .present("session-abc")))
    }

    // MARK: - ORCH-003 / clear

    func testClear_afterDesignation_returnsNone() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        _ = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .agent(id: .hermes, sessionRef: .absent))
        )
        let cleared = try await control.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        XCTAssertEqual(cleared.designation, .none)
        XCTAssertNotNil(cleared.setAt, "a real clear stamps setAt with the clear time (documented)")

        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .none)
        XCTAssertEqual(readBack.setAt, cleared.setAt)
    }

    // MARK: - ORCH-018 / clearing when none is idempotent

    func testClearWhenNone_idempotent_noPhantomSetAt_noRow() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let result = try await control.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        XCTAssertEqual(result.designation, .none)
        XCTAssertNil(result.setAt, "none-on-none must not fabricate a phantom setAt")

        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .none)
        XCTAssertNil(readBack.setAt)

        // No state row is created by the no-op (store unchanged).
        XCTAssertEqual(try store.orchestratorStateRowCount(), 0)
    }

    // MARK: - ORCH-017 / overwrite semantics

    func testOverwrite_setWhileSet_advancesSetAt_singleRow() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let first = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .agent(id: .claudeCode, sessionRef: .absent))
        )
        // Ensure the second setAt is strictly later (dates may collide at
        // nanosecond resolution on fast machines).
        try await Task.sleep(nanoseconds: 2_000_000)
        let second = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .burnBarManaged)
        )
        XCTAssertEqual(second.designation, .burnBarManaged)
        let firstSetAt = try XCTUnwrap(first.setAt)
        let secondSetAt = try XCTUnwrap(second.setAt)
        XCTAssertGreaterThan(secondSetAt, firstSetAt, "set-while-set must advance setAt")

        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .burnBarManaged)
        XCTAssertEqual(readBack.setAt, secondSetAt)
        XCTAssertEqual(try store.orchestratorStateRowCount(), 1, "exactly one state row after overwrite")
    }

    // MARK: - VAL-RPC-009 / invalid designation payloads

    func testSetAgent_unknownID_rejectedTyped_stateUnchanged() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        do {
            _ = try await control.setOrchestratorState(
                BurnBarOrchestratorState(designation: .agent(id: .unknown("aider"), sessionRef: .absent))
            )
            XCTFail("non-roster agent id must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .invalidDesignationAgent("aider"))
        }
        let state = await control.currentState()
        XCTAssertEqual(state.designation, .none)
        XCTAssertEqual(try store.orchestratorStateRowCount(), 0, "rejected set must not persist")
    }

    // MARK: - ORCH-019 / declared non-running agent accepted (outcome A)

    func testSetAgent_declaredNonRunningAgent_accepted() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        // pi is a declared roster agent; designation does not require running.
        let updated = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .agent(id: .pi, sessionRef: .absent))
        )
        XCTAssertEqual(updated.designation, .agent(id: .pi, sessionRef: .absent))
        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, .agent(id: .pi, sessionRef: .absent))
    }

    // MARK: - VAL-RPC-015 / directive record + idempotent retry

    func testRecordDirective_valid_persistedVerbatim() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let directive = makeDirective()
        let recorded = try await control.recordDirective(directive)
        XCTAssertEqual(recorded, directive)

        // The store row round-trips the exact record.
        let records = try store.directiveRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0], directive)
        XCTAssertEqual(try store.directiveRowCount(), 1)
    }

    func testRecordDirective_retrySameID_upsertNoDuplicate() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        let first = makeDirective(id: "dir-1", state: .approved)
        _ = try await control.recordDirective(first)
        let retry = makeDirective(id: "dir-1", state: .delivered, decidedAt: Date(timeIntervalSince1970: 1_752_000_200))
        let recorded = try await control.recordDirective(retry)

        // Documented idempotency rule: re-recording an existing id updates the
        // record in place — the response describes the single persisted record.
        XCTAssertEqual(recorded, retry)
        XCTAssertEqual(try store.directiveRowCount(), 1, "retry must never duplicate")
        let records = try store.directiveRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0], retry)
    }

    // MARK: - ORCH-029 / directive.record payload validation

    func testRecordDirective_emptyPayload_rejected_noRecordCreated() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        do {
            _ = try await control.recordDirective(makeDirective(payload: "   "))
            XCTFail("empty payload must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .emptyDirectivePayload)
        }
        XCTAssertEqual(try store.directiveRowCount(), 0, "rejected record must not persist")
    }

    func testRecordDirective_emptyID_rejected() async throws {
        let control = makeControlStore()
        do {
            _ = try await control.recordDirective(makeDirective(id: "  "))
            XCTFail("empty directive id must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .emptyDirectiveID)
        }
    }

    func testRecordDirective_unknownTargetAgent_rejected() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        do {
            _ = try await control.recordDirective(makeDirective(targetAgent: .unknown("aider")))
            XCTFail("non-roster targetAgent must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .invalidDirectiveTargetAgent("aider"))
        }
        XCTAssertEqual(try store.directiveRowCount(), 0)
    }

    func testRecordDirective_nilTargetAgent_accepted() async throws {
        let control = makeControlStore()
        let recorded = try await control.recordDirective(makeDirective(targetAgent: nil))
        XCTAssertEqual(recorded.targetAgent, nil)
    }

    // MARK: - ORCH-038 / pendingDirectives definition (proposed + approved)

    func testPendingDirectives_countsProposedAndApprovedOnly() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        _ = try await control.recordDirective(makeDirective(id: "p1", state: .proposed))
        _ = try await control.recordDirective(makeDirective(id: "p2", state: .approved))
        _ = try await control.recordDirective(makeDirective(id: "d1", state: .dismissed))
        _ = try await control.recordDirective(makeDirective(id: "d2", state: .delivered))
        _ = try await control.recordDirective(
            makeDirective(id: "f1", state: .failed(reason: "gateway unreachable"))
        )

        let state = await control.currentState()
        XCTAssertEqual(state.pendingDirectives, 2, "pending = proposed + approved only")

        // Terminal transition removes from pending.
        _ = try await control.recordDirective(makeDirective(id: "p2", state: .delivered))
        let after = await control.currentState()
        XCTAssertEqual(after.pendingDirectives, 1)
    }

    // MARK: - ORCH-004 / ORCH-015 / ORCH-039 / restart persistence

    func testDesignationAndDirectives_surviveReopen() async throws {
        // Write with one control store over the store file...
        let store = try makeStore()
        let control = makeControlStore(store: store)
        _ = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .agent(id: .grokBot, sessionRef: .present("ref-1")))
        )
        _ = try await control.recordDirective(makeDirective(id: "delivered-1", state: .delivered))
        _ = try await control.recordDirective(
            makeDirective(id: "failed-1", state: .failed(reason: "gateway unreachable"), deliveryChannel: "hermes")
        )

        // ...then reload with a fresh control store over the same file
        // (simulates a daemon restart: same support dir, new instance).
        let reopenedStore = BurnBarFleetStore(databasePath: storeURL.path)
        _ = try reopenedStore.open()
        let reopened = makeControlStore(store: reopenedStore)
        await reopened.loadPersistedState()

        let state = await reopened.currentState()
        XCTAssertEqual(state.designation, .agent(id: .grokBot, sessionRef: .present("ref-1")))
        let originalState = await control.currentState()
        // The persisted payload encodes setAt as ISO-8601 with millisecond
        // precision, so the reopened value equals the original within 1ms.
        XCTAssertEqual(
            state.setAt?.timeIntervalSince1970 ?? -1,
            originalState.setAt?.timeIntervalSince1970 ?? -2,
            accuracy: 0.001
        )

        let records = try reopenedStore.directiveRecords()
        XCTAssertEqual(Set(records.map(\.id)), ["delivered-1", "failed-1"])
        let delivered = try XCTUnwrap(records.first { $0.id == "delivered-1" })
        XCTAssertEqual(delivered.state, .delivered)
        let failed = try XCTUnwrap(records.first { $0.id == "failed-1" })
        XCTAssertEqual(failed.state, .failed(reason: "gateway unreachable"))
        XCTAssertEqual(failed.deliveryChannel, "hermes")
        // Terminal records never count as pending after restart.
        XCTAssertEqual(state.pendingDirectives, 0)
    }

    func testRecordAfterRestart_keepsTerminalOutcomes_noRedeliveryReplay() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        _ = try await control.recordDirective(makeDirective(id: "delivered-1", state: .delivered))

        // Restart: reload; a re-record of the delivered id keeps one row and
        // the terminal state is the latest recorded state — a restart never
        // replays delivery (the record already carries the terminal outcome).
        let reopenedStore = BurnBarFleetStore(databasePath: storeURL.path)
        _ = try reopenedStore.open()
        let reopened = makeControlStore(store: reopenedStore)
        await reopened.loadPersistedState()
        _ = try await reopened.recordDirective(makeDirective(id: "delivered-1", state: .delivered))
        XCTAssertEqual(try reopenedStore.directiveRowCount(), 1)
        let records = try reopenedStore.directiveRecords()
        XCTAssertEqual(records[0].state, .delivered)
    }
}
