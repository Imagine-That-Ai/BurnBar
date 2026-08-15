import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import GRDB
import XCTest

/// M4 REPAIR (scrutiny round 1, daemon-orchestrator-state): store-level
/// regression tests for the idempotent-clear coherence fix and the
/// store-independent directive-state validation.
///
/// - Repeated `set(.none)` after an existing clear returns the UNCHANGED
///   current state (including its prior `setAt`) so the set response and the
///   subsequent get always agree — for a fresh store that cleared once, and
///   after restart with a persisted `none` row (ORCH-018 set/get coherence).
/// - A `failed(reason: "")` directive state is rejected typed BEFORE the
///   persistence path is chosen — validation must not depend on the backing
///   store (store-less/in-memory mode rejects exactly like wired mode).
final class BurnBarFleetOrchestratorCoherenceRepairTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-fleet-coherence-repair-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - ORCH-018 / repeated clear after an existing none (fresh store)

    func testRepeatedClear_afterRealClear_returnsPriorSetAt_setAndGetAgree() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)

        // Real designation → real clear stamps the clear timestamp.
        _ = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .agent(id: .hermes, sessionRef: .absent))
        )
        let cleared = try await control.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        let clearSetAt = try XCTUnwrap(cleared.setAt)

        // Repeated set(.none): the idempotent no-op returns the UNCHANGED
        // current state — including the retained clear timestamp — so the
        // set response and the subsequent get always agree.
        let repeated = try await control.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        XCTAssertEqual(repeated.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertEqual(
            repeated.setAt, clearSetAt,
            "repeated clear must preserve the prior clear timestamp"
        )
        XCTAssertEqual(repeated.pendingDirectives, cleared.pendingDirectives)

        let readBack = await control.currentState()
        XCTAssertEqual(readBack.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertEqual(readBack.setAt, repeated.setAt, "set response and subsequent get must agree")

        // Storage untouched by the no-op: still exactly the real clear's row.
        XCTAssertEqual(try store.orchestratorStateRowCount(), 1)
    }

    // MARK: - ORCH-018 / repeated clear after restart with a persisted none row

    func testRepeatedClear_afterRestartWithPersistedNone_returnsPriorSetAt() async throws {
        // Phase 1: real designation → real clear, persisted.
        let store = try makeStore()
        let control = makeControlStore(store: store)
        _ = try await control.setOrchestratorState(
            BurnBarOrchestratorState(designation: .burnBarManaged)
        )
        let cleared = try await control.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        let clearSetAt = try XCTUnwrap(cleared.setAt)

        // Phase 2: restart — a fresh control store over the same file loads
        // the persisted none row with its clear timestamp.
        let reopenedStore = BurnBarFleetStore(databasePath: storeURL.path)
        _ = try reopenedStore.open()
        let reopened = makeControlStore(store: reopenedStore)
        await reopened.loadPersistedState()

        // Repeated set(.none) after restart: returns the retained clear
        // timestamp (ISO-8601 millisecond precision on the wire), and the
        // immediately following get agrees exactly.
        let repeated = try await reopened.setOrchestratorState(BurnBarOrchestratorState(designation: .none))
        XCTAssertEqual(repeated.designation, BurnBarOrchestratorDesignation.none)
        let repeatedSetAt = try XCTUnwrap(repeated.setAt)
        XCTAssertEqual(
            repeatedSetAt.timeIntervalSince1970,
            clearSetAt.timeIntervalSince1970,
            accuracy: 0.001,
            "the persisted clear timestamp must survive restart and be returned by the no-op"
        )

        let readBack = await reopened.currentState()
        XCTAssertEqual(readBack.designation, BurnBarOrchestratorDesignation.none)
        XCTAssertEqual(readBack.setAt, repeatedSetAt, "set response and subsequent get must agree")

        // Storage untouched by the no-op: still one state row.
        XCTAssertEqual(try reopenedStore.orchestratorStateRowCount(), 1)
    }

    // MARK: - ORCH-029 / directive state invariants validated before the
    // persistence path (store-independent validation)

    func testRecordDirective_failedEmptyReason_rejected_storeLessMode() async throws {
        // Store-less mode: state invariants are validated BEFORE the
        // persistence path is chosen, so an invalid state (failed with an
        // empty reason) is rejected typed even without a wired store — the
        // validation must not depend on the backing store.
        let control = makeControlStore()
        do {
            _ = try await control.recordDirective(makeDirective(state: .failed(reason: "  ")))
            XCTFail("failed(reason: \"\") must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .emptyDirectiveStateReason)
        }
    }

    func testRecordDirective_failedEmptyReason_rejected_storeMode_noRecord() async throws {
        let store = try makeStore()
        let control = makeControlStore(store: store)
        do {
            _ = try await control.recordDirective(makeDirective(state: .failed(reason: "")))
            XCTFail("failed(reason: \"\") must be rejected")
        } catch let error as BurnBarFleetControlError {
            XCTAssertEqual(error, .emptyDirectiveStateReason)
        }
        XCTAssertEqual(try store.directiveRowCount(), 0, "rejected record must not persist")
    }
}
