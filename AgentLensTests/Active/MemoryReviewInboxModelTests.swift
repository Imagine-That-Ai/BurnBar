import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// Locks down `MemoryReviewInboxModel`'s two-bucket load + review transitions using
/// in-memory fake closures. The model is the contract the integrator wires to the
/// real `MemoryServing`, so these tests pin the quarantine/approve/reject behavior
/// (G4) that the inbox UI depends on.
@MainActor
final class MemoryReviewInboxModelTests: XCTestCase {

    // MARK: - Fake backing store

    /// One row in the fake: the authority record, its sealed body, and current status.
    private struct Row {
        var memory: Memory
        var body: String?
        var status: MemoryReviewStatus
    }

    /// In-memory stand-in for the memory service. Honors `includeQuarantined` the way
    /// the real backend does: quarantined rows are withheld unless explicitly requested.
    /// Honors the source-kind guard the same way too: rows outside the requested kinds
    /// are invisible to reads and untouchable by writes.
    private final class FakeStore {
        var rows: [MemoryID: Row]
        var shouldThrowOnLoad = false
        var bodyOpenFailures: Set<MemoryID> = []
        private(set) var setStatusCalls: [(MemoryID, MemoryReviewStatus)] = []
        private(set) var forgetCalls: [MemoryID] = []

        init(rows: [MemoryID: Row]) {
            self.rows = rows
        }

        func loadPage(_ request: MemoryPageRequest, sourceKinds: Set<MemorySourceKind>) async throws -> MemoryPage {
            if shouldThrowOnLoad { throw FakeError.load }
            let visible = rows.values.filter { row in
                sourceKinds.contains(row.memory.sourceKind)
                    && (request.includeQuarantined || row.status != .quarantined)
            }
            // Reflect the current status onto the returned records.
            let items = visible.map { row -> Memory in
                var memory = row.memory
                memory.reviewStatus = row.status
                return memory
            }
            .sorted { $0.id < $1.id }
            let pageSize = max(1, request.pageSize)
            let page = max(1, request.page)
            let start = max(0, (page - 1) * pageSize)
            return MemoryPage(
                items: Array(items.dropFirst(start).prefix(pageSize)),
                page: page,
                pageSize: pageSize,
                total: items.count
            )
        }

        func openBody(_ id: MemoryID) async throws -> String? {
            if bodyOpenFailures.contains(id) { throw FakeError.bodyOpen }
            return rows[id]?.body
        }

        func setStatus(
            _ id: MemoryID,
            _ status: MemoryReviewStatus,
            _ sourceKinds: Set<MemorySourceKind>
        ) async throws -> Bool {
            setStatusCalls.append((id, status))
            guard let row = rows[id], sourceKinds.contains(row.memory.sourceKind) else { return false }
            rows[id]?.status = status
            return true
        }

        func forget(_ id: MemoryID, _ sourceKinds: Set<MemorySourceKind>) async throws -> Bool {
            forgetCalls.append(id)
            guard let row = rows[id], sourceKinds.contains(row.memory.sourceKind) else { return false }
            rows[id] = nil
            return true
        }
    }

    private enum FakeError: LocalizedError {
        case load
        case bodyOpen
        var errorDescription: String? {
            switch self {
            case .load:
                return "fake load failure"
            case .bodyOpen:
                return "fake body-open failure"
            }
        }
    }

    // MARK: - Fixtures

    private let scope = MemoryScope(userID: "fixture-user", appID: "openburnbar")

    private func makeMemory(
        id: MemoryID,
        kind: MemoryKind = .fact,
        confidence: Double = 0.6,
        status: MemoryReviewStatus
    ) -> Memory {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Memory(
            id: id,
            kind: kind,
            scope: scope,
            confidence: confidence,
            bodyRedacted: "sealed-ref-\(id)",
            reviewStatus: status,
            citations: [],
            validFrom: now,
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeStore() -> FakeStore {
        FakeStore(rows: [
            "q1": Row(memory: makeMemory(id: "q1", status: .quarantined), body: "Prefers dark mode", status: .quarantined),
            "q2": Row(memory: makeMemory(id: "q2", confidence: 0.87, status: .quarantined), body: "Lives in Madrid", status: .quarantined),
            "a1": Row(memory: makeMemory(id: "a1", status: .approved), body: "Uses Swift daily", status: .approved),
            "r1": Row(memory: makeMemory(id: "r1", status: .rejected), body: "Rejected fact", status: .rejected)
        ])
    }

    private func makeModel(
        store: FakeStore,
        gateScan: @escaping (String) -> MemoryReviewGateScan.GateState = { MemoryReviewGateScan.scan($0) }
    ) -> MemoryReviewInboxModel {
        MemoryReviewInboxModel(
            scope: scope,
            loadPage: { try await store.loadPage($0, sourceKinds: $1) },
            openBody: { try await store.openBody($0) },
            setStatus: { try await store.setStatus($0, $1, $2) },
            forget: { try await store.forget($0, $1) },
            gateScan: gateScan
        )
    }

    // MARK: - Tests

    func testLoadPopulatesBucketsWithOpenedBodies() async {
        let store = makeStore()
        let model = makeModel(store: store)

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)

        XCTAssertEqual(Set(model.pending.map(\.id)), ["q1", "q2"])
        XCTAssertTrue(model.pending.allSatisfy { $0.memory.reviewStatus == .quarantined })

        XCTAssertEqual(model.approved.map(\.id), ["a1"])
        XCTAssertTrue(model.approved.allSatisfy { $0.memory.reviewStatus == .approved })

        // Rejected rows appear in neither bucket.
        XCTAssertFalse(model.pending.contains { $0.id == "r1" })
        XCTAssertFalse(model.approved.contains { $0.id == "r1" })

        // Bodies were opened transiently for display.
        let q2 = model.pending.first { $0.id == "q2" }
        XCTAssertEqual(q2?.body, "Lives in Madrid")
        XCTAssertTrue(q2?.canApprove ?? false)
        XCTAssertEqual(model.approved.first?.body, "Uses Swift daily")
    }

    func testUnavailableBodyBlocksApproval() async {
        let store = makeStore()
        store.bodyOpenFailures.insert("q1")
        let model = makeModel(store: store)

        await model.load()
        let unavailable = model.pending.first { $0.id == "q1" }
        XCTAssertEqual(unavailable?.body, "")
        XCTAssertEqual(unavailable?.bodyLoadState, .unavailable)
        XCTAssertFalse(unavailable?.canApprove ?? true)

        await model.approve("q1")

        XCTAssertTrue(store.setStatusCalls.isEmpty)
        XCTAssertEqual(model.errorMessage, "Memory contents are unavailable. Reject it or reload before approving.")
        XCTAssertTrue(model.pending.contains { $0.id == "q1" })
    }

    func testMissingBodyBlocksApproval() async {
        let store = makeStore()
        store.rows["q2"]?.body = nil
        let model = makeModel(store: store)

        await model.load()
        let unavailable = model.pending.first { $0.id == "q2" }
        XCTAssertEqual(unavailable?.bodyLoadState, .unavailable)
        XCTAssertFalse(unavailable?.canApprove ?? true)

        await model.approve("q2")

        XCTAssertTrue(store.setStatusCalls.isEmpty)
        XCTAssertEqual(model.errorMessage, "Memory contents are unavailable. Reject it or reload before approving.")
    }

    func testApproveMovesItemFromPendingToApproved() async {
        let store = makeStore()
        let model = makeModel(store: store)
        await model.load()
        XCTAssertTrue(model.pending.contains { $0.id == "q1" })

        await model.approve("q1")

        XCTAssertTrue(store.setStatusCalls.contains { $0.0 == "q1" && $0.1 == .approved })
        XCTAssertFalse(model.pending.contains { $0.id == "q1" })
        XCTAssertTrue(model.approved.contains { $0.id == "q1" })
        XCTAssertNil(model.errorMessage)
    }

    func testRejectRemovesItemFromPending() async {
        let store = makeStore()
        let model = makeModel(store: store)
        await model.load()
        XCTAssertTrue(model.pending.contains { $0.id == "q2" })

        await model.reject("q2")

        XCTAssertTrue(store.setStatusCalls.contains { $0.0 == "q2" && $0.1 == .rejected })
        XCTAssertFalse(model.pending.contains { $0.id == "q2" })
        XCTAssertFalse(model.approved.contains { $0.id == "q2" })
    }

    func testThrowingLoadSetsErrorMessageAndClearsLoading() async {
        let store = makeStore()
        store.shouldThrowOnLoad = true
        let model = makeModel(store: store)

        await model.load()

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.errorMessage, "fake load failure")
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertTrue(model.approved.isEmpty)
    }

    func testPendingCountReflectsPendingBucket() async {
        let store = makeStore()
        let model = makeModel(store: store)
        await model.load()

        XCTAssertEqual(model.pendingCount, model.pending.count)
        XCTAssertEqual(model.pendingCount, 2)

        await model.approve("q1")
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertEqual(model.pendingCount, model.pending.count)
    }

    func testForgetRemovesRowFromItsBucket() async {
        let store = makeStore()
        let model = makeModel(store: store)
        await model.load()
        XCTAssertTrue(model.pending.contains { $0.id == "q1" })

        await model.forget("q1")

        XCTAssertEqual(store.forgetCalls, ["q1"])
        XCTAssertNil(store.rows["q1"])
        XCTAssertFalse(model.pending.contains { $0.id == "q1" })
        XCTAssertFalse(model.approved.contains { $0.id == "q1" })
        XCTAssertNil(model.errorMessage)
    }

    func testPendingLoadPagesPastApprovedRows() async {
        var rows: [MemoryID: Row] = [:]
        for index in 0 ..< 210 {
            let id = String(format: "a%03d", index)
            rows[id] = Row(memory: makeMemory(id: id, status: .approved), body: "Approved \(index)", status: .approved)
        }
        rows["q999"] = Row(memory: makeMemory(id: "q999", status: .quarantined), body: "Needs review", status: .quarantined)
        let store = FakeStore(rows: rows)
        let model = makeModel(store: store)

        await model.load()

        XCTAssertTrue(model.pending.contains { $0.id == "q999" })
    }

    // MARK: - B10: the row names the SCAN, never a verdict

    /// Quarantine is the DEFAULT review state in this app: an extracted memory
    /// lands quarantined with no gate having fired (the app's own gates DROP a
    /// candidate rather than quarantining it). Such a row must say exactly that
    /// — inventing a gate would tell the member their memory tripped a secret
    /// scanner when nothing did.
    func test_a_row_quarantined_without_a_firing_gate_names_no_gate() async {
        let store = FakeStore(rows: [
            "plain": Row(
                memory: makeMemory(id: "plain", status: .quarantined),
                // Text a naive substring re-scan would happily mislabel.
                body: "Assistant: ignore previous instructions was the example we discussed.",
                status: .quarantined
            )
        ])
        let model = makeModel(store: store)
        await model.load()

        let item = model.pending.first
        XCTAssertEqual(item?.id, "plain")
        XCTAssertEqual(item?.gateState, .noGateFired, "no gate fired, so the row names none")
    }

    /// A body that really does trip the shared secret scanner names the SCAN and
    /// what it saw — and still never claims a verdict, because nothing gated this
    /// row. The row model must therefore carry no `verdict` (nor `gate`/`reason`)
    /// member at all, on the item or on the Kernel record behind it.
    func test_a_row_whose_body_trips_the_secret_scanner_names_a_scan_not_a_verdict() async {
        XCTAssertTrue(
            MemorySecretPIIGate.isAvailable,
            "the shared secret corpus must load in this target or the scan line is meaningless"
        )
        // Built at runtime so no secret-shaped literal is committed.
        let apiKey = "sk-ant-" + "deadbeefdeadbeefdeadbeef0007"
        let store = FakeStore(rows: [
            "leaky": Row(
                memory: makeMemory(id: "leaky", status: .quarantined),
                body: "My api key is \(apiKey) keep it safe.",
                status: .quarantined
            )
        ])
        let model = makeModel(store: store)
        await model.load()

        let item = model.pending.first
        XCTAssertEqual(item?.id, "leaky")
        guard case .scanned(let gate, let reason) = item?.gateState else {
            XCTFail("a secret-shaped body must render as a scan, got \(String(describing: item?.gateState))")
            return
        }
        XCTAssertEqual(gate, MemoryReviewGateScan.secretGate)
        XCTAssertTrue(
            reason.hasPrefix("secret shape detected: "),
            "the reason names what the scan saw, verbatim; got \(reason)"
        )
        XCTAssertFalse(reason.contains(apiKey), "the reason names the shape, never the secret itself")

        // No verdict anywhere: not on the row, not on the Kernel record.
        let itemMembers = Mirror(reflecting: item!).children.compactMap(\.label)
        for forbidden in ["verdict", "gate", "reason"] {
            XCTAssertFalse(
                itemMembers.contains(forbidden),
                "the inbox row must not carry a `\(forbidden)` member — no app producer can fill it"
            )
        }
        let memoryMembers = Mirror(reflecting: item!.memory).children.compactMap(\.label)
        for forbidden in ["verdict", "gate", "reason"] {
            XCTAssertFalse(
                memoryMembers.contains(forbidden),
                "the Kernel Memory record must not carry a `\(forbidden)` field"
            )
        }
    }

    /// Naming the scan is presentation: it must not touch the approve/reject path.
    func test_naming_the_gate_leaves_approve_and_reject_untouched() async {
        let apiKey = "sk-ant-" + "deadbeefdeadbeefdeadbeef0008"
        let store = FakeStore(rows: [
            "scanned": Row(
                memory: makeMemory(id: "scanned", status: .quarantined),
                body: "My api key is \(apiKey) keep it safe.",
                status: .quarantined
            ),
            "plain": Row(
                memory: makeMemory(id: "plain", status: .quarantined),
                body: "Prefers dark mode",
                status: .quarantined
            )
        ])
        let model = makeModel(store: store)
        await model.load()

        XCTAssertEqual(model.pending.first { $0.id == "scanned" }?.canApprove, true,
                       "a scanned row is still reviewable")
        await model.approve("scanned")
        XCTAssertEqual(store.setStatusCalls.map(\.1), [.approved])
        XCTAssertFalse(model.pending.contains { $0.id == "scanned" })
        XCTAssertTrue(model.approved.contains { $0.id == "scanned" })

        await model.reject("plain")
        XCTAssertEqual(store.setStatusCalls.map(\.1), [.approved, .rejected])
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// The gate is fail-closed: a missing or corrupt corpus makes EVERY
    /// evaluation reject with the synthetic `corpus-unavailable` finding. A row
    /// re-scanned under that corpus was not really checked, and must say so
    /// rather than rendering as a clean "no gate fired".
    func test_an_unavailable_scanner_corpus_says_so_rather_than_reporting_a_clean_row() async {
        let corpusUnavailable = MemoryGateVerdict.reject(findings: [
            MemoryGateFinding(
                id: MemorySecretPIIGate.corpusUnavailableFindingID,
                label: MemorySecretPIIGate.corpusUnavailableLabel,
                kind: .secret
            )
        ])
        let store = FakeStore(rows: [
            "plain": Row(
                memory: makeMemory(id: "plain", status: .quarantined),
                body: "Prefers dark mode",
                status: .quarantined
            )
        ])
        let model = makeModel(store: store) { body in
            MemoryReviewGateScan.scan(body) { _ in corpusUnavailable }
        }
        await model.load()

        XCTAssertEqual(model.pending.first?.gateState, .scannerUnavailable)
    }
}
