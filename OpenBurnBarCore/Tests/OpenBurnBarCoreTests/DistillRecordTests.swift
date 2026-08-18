import XCTest
@testable import OpenBurnBarKernel

/// The distill log is what makes the Flame answerable after the fact, so these
/// pin that it keeps the losers, settles honestly, and stays bounded.
final class DistillRecordTests: XCTestCase {

    private let decidedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func body(_ id: String, online: Bool = true, runs: Int = 0) -> FleetBodySnapshot {
        FleetBodySnapshot(
            bodyID: id,
            displayName: id.uppercased(),
            isLocal: id == "mac-a",
            isOnline: online,
            wireReachable: true,
            capabilities: ["hermes_chat"],
            activeRunCount: runs
        )
    }

    private func decision(_ bodies: [FleetBodySnapshot]) -> RoutingDecision {
        FlameRouter.route(
            snapshot: FleetSnapshot(bodies: bodies),
            requiredCapabilities: ["hermes_chat"],
            decisionID: "d-1"
        )
    }

    // MARK: - Archiving

    func test_archivesTheDecisionWithItsRationaleAndCandidates() {
        let record = DistillRecord(
            decision: decision([body("mac-a"), body("mac-b", runs: 3)]),
            requiredCapabilities: ["hermes_chat"],
            decidedAt: decidedAt
        )
        XCTAssertEqual(record.id, "d-1")
        XCTAssertEqual(record.chosenBodyID, "mac-a")
        XCTAssertEqual(record.transport, .local)
        XCTAssertEqual(record.candidates.count, 2)
        XCTAssertEqual(record.requiredCapabilities, ["hermes_chat"])
        XCTAssertEqual(record.outcome, .pending)
    }

    /// "Why did it not pick the Mini?" is the question people actually ask, and
    /// it is unanswerable from the winner alone.
    func test_keepsThePassedOverMachinesAndWhy() {
        let record = DistillRecord(
            decision: decision([body("mac-a"), body("mac-b", runs: 3), body("mac-c", online: false)]),
            decidedAt: decidedAt
        )
        let passed = record.passedOver
        XCTAssertEqual(Set(passed.map(\.bodyID)), ["mac-b", "mac-c"])
        XCTAssertEqual(passed.first { $0.bodyID == "mac-b" }?.rejection, .outscored)
        XCTAssertEqual(passed.first { $0.bodyID == "mac-c" }?.rejection, .offline)
    }

    /// Nothing will ever act on a decision that routed nowhere, so it must not
    /// sit in the log looking pending forever.
    func test_aDecisionThatRoutedNowhereIsRecordedAsUnrouted() {
        let record = DistillRecord(
            decision: decision([body("mac-a", online: false)]),
            decidedAt: decidedAt
        )
        XCTAssertEqual(record.outcome, .unrouted)
        XCTAssertTrue(record.isSettled)
        XCTAssertNil(record.chosenBodyID)
    }

    func test_recordMintsTheFlameOriginatorForTheRunItStarts() {
        let record = DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt)
        XCTAssertEqual(record.originator.kind, .flame)
        XCTAssertEqual(record.originator.decisionID, "d-1")
    }

    func test_roundTripsThroughCodable() throws {
        let record = DistillRecord(decision: decision([body("mac-a"), body("mac-b")]), decidedAt: decidedAt)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(DistillRecord.self, from: data), record)
    }

    // MARK: - Settling

    func test_settlingStampsOutcomeRunAndDwell() {
        var log = DistillLog()
        log.record(DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt))
        XCTAssertTrue(log.settle(
            id: "d-1", outcome: .succeeded, runID: "run-7", at: decidedAt.addingTimeInterval(42)
        ))

        let record = log.record(id: "d-1")
        XCTAssertEqual(record?.outcome, .succeeded)
        XCTAssertEqual(record?.runID, "run-7")
        XCTAssertEqual(record?.dwell, 42)
        XCTAssertTrue(record?.isSettled ?? false)
    }

    func test_settlingAnUnknownDecisionReportsFailureRatherThanInventingARecord() {
        var log = DistillLog()
        XCTAssertFalse(log.settle(id: "nope", outcome: .succeeded, at: decidedAt))
        XCTAssertTrue(log.records.isEmpty)
    }

    /// Settlement is terminal: a late RPC cannot flip a settled verdict, so
    /// the audit history and the success rate stay trustworthy.
    func test_aSettledVerdictCannotBeRewritten() {
        var log = DistillLog()
        log.record(DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt))
        XCTAssertTrue(log.settle(id: "d-1", outcome: .succeeded, runID: "run-7", at: decidedAt.addingTimeInterval(1)))

        XCTAssertFalse(log.settle(id: "d-1", outcome: .failed, at: decidedAt.addingTimeInterval(9)))
        let record = log.record(id: "d-1")
        XCTAssertEqual(record?.outcome, .succeeded)
        XCTAssertEqual(record?.dwell, 1, "the losing rewrite must not move the settlement time either")
        XCTAssertEqual(log.successRate, 1.0)
    }

    /// An identical retry is a duplicate delivery, not a conflict — it reports
    /// success and leaves the record untouched.
    func test_settlingTwiceWithTheSameOutcomeIsIdempotent() {
        var log = DistillLog()
        log.record(DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt))
        XCTAssertTrue(log.settle(id: "d-1", outcome: .failed, runID: "run-7", at: decidedAt.addingTimeInterval(2)))

        XCTAssertTrue(log.settle(id: "d-1", outcome: .failed, at: decidedAt.addingTimeInterval(30)))
        XCTAssertEqual(log.record(id: "d-1")?.dwell, 2)
    }

    /// An unrouted decision settled at creation stays unrouted — a stray
    /// success for a decision that dispatched nothing is a lie.
    func test_anUnroutedDecisionCannotBeSettledIntoASuccess() {
        var log = DistillLog()
        log.record(DistillRecord(decision: decision([]), decidedAt: decidedAt))
        XCTAssertFalse(log.settle(id: "d-1", outcome: .succeeded, at: decidedAt.addingTimeInterval(5)))
        XCTAssertEqual(log.record(id: "d-1")?.outcome, .unrouted)
    }

    func test_dwellIsNilUntilSettled() {
        let record = DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt)
        XCTAssertNil(record.dwell)
        XCTAssertFalse(record.isSettled)
    }

    func test_pendingAndDispatchedAreNotSettled() {
        var record = DistillRecord(decision: decision([body("mac-a")]), decidedAt: decidedAt)
        record.outcome = .dispatched
        XCTAssertFalse(record.isSettled)
        for settled in [DistillRecord.Outcome.succeeded, .failed, .abandoned, .unrouted] {
            record.outcome = settled
            XCTAssertTrue(record.isSettled, "\(settled) should read as settled")
        }
    }

    // MARK: - The log

    func test_newestDecisionComesFirst() {
        var log = DistillLog()
        for index in 0..<3 {
            log.record(DistillRecord(
                id: "d-\(index)", decidedAt: decidedAt, chosenBodyID: "mac-a",
                transport: .local, rationale: "", candidates: []
            ))
        }
        XCTAssertEqual(log.records.map(\.id), ["d-2", "d-1", "d-0"])
    }

    /// Re-recording the same decision must not leave two copies in the log.
    func test_reRecordingADecisionReplacesIt() {
        var log = DistillLog()
        let record = DistillRecord(
            id: "d-1", decidedAt: decidedAt, chosenBodyID: "mac-a",
            transport: .local, rationale: "first", candidates: []
        )
        log.record(record)
        var updated = record
        updated.rationale = "second"
        log.record(updated)

        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.records.first?.rationale, "second")
    }

    /// This runs in a long-lived daemon; an unbounded history is a slow leak.
    func test_logIsBoundedAndDropsTheOldest() {
        var log = DistillLog(capacity: 3)
        for index in 0..<5 {
            log.record(DistillRecord(
                id: "d-\(index)", decidedAt: decidedAt, chosenBodyID: nil,
                transport: nil, rationale: "", candidates: []
            ))
        }
        XCTAssertEqual(log.records.count, 3)
        XCTAssertEqual(log.records.map(\.id), ["d-4", "d-3", "d-2"])
    }

    func test_capacityIsAtLeastOne() {
        var log = DistillLog(capacity: 0)
        log.record(DistillRecord(
            id: "d-1", decidedAt: decidedAt, chosenBodyID: nil, transport: nil,
            rationale: "", candidates: []
        ))
        XCTAssertEqual(log.records.count, 1)
    }

    func test_recentClampsToWhatExists() {
        var log = DistillLog()
        log.record(DistillRecord(
            id: "d-1", decidedAt: decidedAt, chosenBodyID: nil, transport: nil,
            rationale: "", candidates: []
        ))
        XCTAssertEqual(log.recent(10).count, 1)
        XCTAssertTrue(log.recent(0).isEmpty)
        XCTAssertTrue(log.recent(-5).isEmpty)
    }

    // MARK: - Judging the Flame

    /// Nil until there is something to judge, so the UI shows "no reading yet"
    /// instead of a confident zero.
    func test_successRateIsNilWithNothingJudgeable() {
        var log = DistillLog()
        XCTAssertNil(log.successRate)
        log.record(DistillRecord(
            id: "d-1", decidedAt: decidedAt, chosenBodyID: "mac-a",
            transport: .local, rationale: "", candidates: []
        ))
        XCTAssertNil(log.successRate, "a pending decision is not evidence either way")
    }

    func test_successRateCountsOnlySucceededAndFailed() throws {
        var log = DistillLog()
        let outcomes: [DistillRecord.Outcome] = [.succeeded, .succeeded, .failed, .abandoned, .unrouted]
        for (index, outcome) in outcomes.enumerated() {
            log.record(DistillRecord(
                id: "d-\(index)", decidedAt: decidedAt, chosenBodyID: "mac-a",
                transport: .local, rationale: "", candidates: [], outcome: outcome
            ))
        }
        let rate = try XCTUnwrap(log.successRate)
        XCTAssertEqual(rate, 2.0 / 3.0, accuracy: 0.0001)
    }
}
