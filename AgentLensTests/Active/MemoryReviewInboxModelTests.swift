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
    private struct Row: Sendable {
        var memory: Memory
        var body: String?
        var status: MemoryReviewStatus
    }

    /// In-memory stand-in for the memory service. Honors `includeQuarantined` the way
    /// the real backend does: quarantined rows are withheld unless explicitly requested.
    private actor FakeStore {
        var rows: [MemoryID: Row]
        var shouldThrowOnLoad = false
        var bodyOpenFailures: Set<MemoryID> = []
        private(set) var setStatusCalls: [(MemoryID, MemoryReviewStatus)] = []

        init(rows: [MemoryID: Row]) {
            self.rows = rows
        }

        func loadPage(_ request: MemoryPageRequest) async throws -> MemoryPage {
            if shouldThrowOnLoad { throw FakeError.load }
            let visible = rows.values.filter { row in
                request.includeQuarantined || row.status != .quarantined
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

        func setStatus(_ id: MemoryID, _ status: MemoryReviewStatus) async throws -> Bool {
            setStatusCalls.append((id, status))
            guard rows[id] != nil else { return false }
            rows[id]?.status = status
            return true
        }

        func insertBodyOpenFailure(_ id: MemoryID) {
            bodyOpenFailures.insert(id)
        }

        func clearBody(for id: MemoryID) {
            rows[id]?.body = nil
        }

        func enableLoadFailure() {
            shouldThrowOnLoad = true
        }

        func statusCalls() -> [(MemoryID, MemoryReviewStatus)] {
            setStatusCalls
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

    private func makeModel(store: FakeStore) -> MemoryReviewInboxModel {
        MemoryReviewInboxModel(
            scope: scope,
            loadPage: { try await store.loadPage($0) },
            openBody: { try await store.openBody($0) },
            setStatus: { try await store.setStatus($0, $1) }
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
        await store.insertBodyOpenFailure("q1")
        let model = makeModel(store: store)

        await model.load()
        let unavailable = model.pending.first { $0.id == "q1" }
        XCTAssertEqual(unavailable?.body, "")
        XCTAssertEqual(unavailable?.bodyLoadState, .unavailable)
        XCTAssertFalse(unavailable?.canApprove ?? true)

        await model.approve("q1")

        let statusCallsAfterBodyFailure = await store.statusCalls()
        XCTAssertTrue(statusCallsAfterBodyFailure.isEmpty)
        XCTAssertEqual(model.errorMessage, "Memory contents are unavailable. Reject it or reload before approving.")
        XCTAssertTrue(model.pending.contains { $0.id == "q1" })
    }

    func testMissingBodyBlocksApproval() async {
        let store = makeStore()
        await store.clearBody(for: "q2")
        let model = makeModel(store: store)

        await model.load()
        let unavailable = model.pending.first { $0.id == "q2" }
        XCTAssertEqual(unavailable?.bodyLoadState, .unavailable)
        XCTAssertFalse(unavailable?.canApprove ?? true)

        await model.approve("q2")

        let statusCallsAfterMissingBody = await store.statusCalls()
        XCTAssertTrue(statusCallsAfterMissingBody.isEmpty)
        XCTAssertEqual(model.errorMessage, "Memory contents are unavailable. Reject it or reload before approving.")
    }

    func testApproveMovesItemFromPendingToApproved() async {
        let store = makeStore()
        let model = makeModel(store: store)
        await model.load()
        XCTAssertTrue(model.pending.contains { $0.id == "q1" })

        await model.approve("q1")

        let approvalCalls = await store.statusCalls()
        XCTAssertTrue(approvalCalls.contains { $0.0 == "q1" && $0.1 == .approved })
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

        let rejectionCalls = await store.statusCalls()
        XCTAssertTrue(rejectionCalls.contains { $0.0 == "q2" && $0.1 == .rejected })
        XCTAssertFalse(model.pending.contains { $0.id == "q2" })
        XCTAssertFalse(model.approved.contains { $0.id == "q2" })
    }

    func testThrowingLoadSetsErrorMessageAndClearsLoading() async {
        let store = makeStore()
        await store.enableLoadFailure()
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
}
