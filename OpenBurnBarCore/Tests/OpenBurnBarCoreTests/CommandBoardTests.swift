import XCTest
@testable import OpenBurnBarKernel

/// Face C's contract: one grid, honest attribution, and exactly one answer to
/// "where is the money going".
final class CommandBoardTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func run(
        _ id: String,
        body: String? = "mac-a",
        bodyName: String = "Studio",
        originator: BurnBarOriginator = BurnBarOriginator(kind: .userLocal, confidence: .exact),
        status: CommandBoardRun.Status = .succeeded,
        startedOffset: TimeInterval = 0,
        endedOffset: TimeInterval? = 60,
        cost: Double = 0,
        tokens: Int = 0
    ) -> CommandBoardRun {
        CommandBoardRun(
            id: id,
            bodyID: body,
            bodyDisplayName: bodyName,
            title: "run \(id)",
            originator: originator,
            status: status,
            startedAt: epoch.addingTimeInterval(startedOffset),
            endedAt: endedOffset.map { epoch.addingTimeInterval($0) },
            costUSD: cost,
            tokens: tokens
        )
    }

    private var flame: BurnBarOriginator {
        BurnBarOriginator(kind: .flame, decisionID: "d-a3f2c9ff", confidence: .exact)
    }

    // MARK: - Ordering

    /// The board answers "what is happening right now" before "what happened".
    func test_runningWorkSortsAboveFinishedWork() {
        let board = CommandBoard.summarize(runs: [
            run("old", status: .succeeded, startedOffset: 900, endedOffset: 950),
            run("live", status: .running, startedOffset: 10, endedOffset: nil)
        ])
        XCTAssertEqual(board.runs.map(\.id), ["live", "old"])
    }

    func test_newestFirstWithinEachHalf() {
        let board = CommandBoard.summarize(runs: [
            run("a", startedOffset: 100),
            run("c", startedOffset: 300),
            run("b", startedOffset: 200)
        ])
        XCTAssertEqual(board.runs.map(\.id), ["c", "b", "a"])
    }

    func test_identicalStartTimesBreakTiesStably() {
        let board = CommandBoard.summarize(runs: [run("b"), run("a")])
        XCTAssertEqual(board.runs.map(\.id), ["a", "b"])
    }

    // MARK: - Rollups

    func test_costRollsUpPerMachine() throws {
        let board = CommandBoard.summarize(runs: [
            run("1", body: "mac-a", bodyName: "Studio", cost: 1.50, tokens: 100),
            run("2", body: "mac-a", bodyName: "Studio", cost: 2.25, tokens: 200),
            run("3", body: "mac-b", bodyName: "Mini", cost: 0.75, tokens: 50)
        ])
        let studio = try XCTUnwrap(board.byMachine.first { $0.id == "mac-a" })
        XCTAssertEqual(studio.label, "Studio")
        XCTAssertEqual(studio.runCount, 2)
        XCTAssertEqual(studio.costUSD, 3.75, accuracy: 0.0001)
        XCTAssertEqual(studio.tokens, 300)
        XCTAssertEqual(board.totalCostUSD, 4.50, accuracy: 0.0001)
        XCTAssertEqual(board.totalTokens, 350)
    }

    /// The question that brings someone to a cost column is "where is the money
    /// going", so the biggest spender leads.
    func test_rollupsSortBySpend() {
        let board = CommandBoard.summarize(runs: [
            run("1", body: "mac-a", bodyName: "Studio", cost: 0.10),
            run("2", body: "mac-b", bodyName: "Mini", cost: 9.00),
            run("3", body: "mac-c", bodyName: "Air", cost: 1.00)
        ])
        XCTAssertEqual(board.byMachine.map(\.label), ["Mini", "Air", "Studio"])
    }

    func test_startedByRollsUpByKind() throws {
        let board = CommandBoard.summarize(runs: [
            run("1", originator: flame, cost: 3.00),
            run("2", originator: BurnBarOriginator(kind: .flame, decisionID: "d-77b1", confidence: .exact), cost: 1.00),
            run("3", originator: BurnBarOriginator(kind: .userLocal, confidence: .exact), cost: 0.50)
        ])
        let flameRollup = try XCTUnwrap(board.byOriginator.first { $0.id == "flame" })
        XCTAssertEqual(flameRollup.runCount, 2)
        XCTAssertEqual(flameRollup.costUSD, 4.00, accuracy: 0.0001)
        // Rolling two decisions up under the first one's id would read as a lie.
        XCTAssertEqual(flameRollup.label, "Flame")
    }

    func test_runsWithoutAMachineRollUpTogether() throws {
        let board = CommandBoard.summarize(runs: [
            run("1", body: nil, bodyName: "This Mac", cost: 1.00),
            run("2", body: nil, bodyName: "This Mac", cost: 2.00)
        ])
        XCTAssertEqual(board.byMachine.count, 1)
        XCTAssertEqual(try XCTUnwrap(board.byMachine.first).runCount, 2)
    }

    /// Two different machines that both lack an id must not have their spend
    /// summed under whichever name happened to sort first.
    func test_unidentifiedMachinesStaySeparateByName() throws {
        let board = CommandBoard.summarize(runs: [
            run("1", body: nil, bodyName: "This Mac", cost: 1.00),
            run("2", body: nil, bodyName: "Another Mac", cost: 5.00)
        ])
        XCTAssertEqual(board.byMachine.count, 2)
        XCTAssertEqual(try XCTUnwrap(board.byMachine.first).label, "Another Mac")
        XCTAssertEqual(try XCTUnwrap(board.byMachine.first).costUSD, 5.00, accuracy: 0.0001)
    }

    /// A source that infers "finished" from silence has an outcome-free status
    /// to report, so it never has to claim a success it did not observe.
    func test_endedIsDistinctFromSucceeded() {
        let board = CommandBoard.summarize(runs: [run("1", status: .ended, cost: 1.0)])
        XCTAssertEqual(board.runs.first?.status, .ended)
        XCTAssertTrue(try XCTUnwrap(board.runs.first).isFinished)
        XCTAssertEqual(board.runningCount, 0)
    }

    func test_runningCountsAreTrackedPerMachineAndOverall() throws {
        let board = CommandBoard.summarize(runs: [
            run("1", body: "mac-a", status: .running, endedOffset: nil),
            run("2", body: "mac-a", status: .succeeded),
            run("3", body: "mac-b", bodyName: "Mini", status: .running, endedOffset: nil)
        ])
        XCTAssertEqual(board.runningCount, 2)
        XCTAssertEqual(try XCTUnwrap(board.byMachine.first { $0.id == "mac-a" }).runningCount, 1)
    }

    /// The moment the board stops being a list and starts being a fleet view.
    func test_theBoardKnowsWhenMoreThanOneMachineIsWorking() {
        let single = CommandBoard.summarize(runs: [
            run("1", body: "mac-a", status: .running, endedOffset: nil),
            run("2", body: "mac-b", status: .succeeded)
        ])
        XCTAssertFalse(single.isFleetActive)

        let fleet = CommandBoard.summarize(runs: [
            run("1", body: "mac-a", status: .running, endedOffset: nil),
            run("2", body: "mac-b", bodyName: "Mini", status: .running, endedOffset: nil)
        ])
        XCTAssertTrue(fleet.isFleetActive)
    }

    // MARK: - Duration

    func test_aFinishedRunMeasuresToItsEnd() {
        let finished = run("1", startedOffset: 0, endedOffset: 120)
        XCTAssertEqual(finished.duration(now: epoch.addingTimeInterval(9_999)), 120, accuracy: 0.001)
    }

    func test_aRunningRunMeasuresToNow() {
        let live = run("1", status: .running, startedOffset: 0, endedOffset: nil)
        XCTAssertEqual(live.duration(now: epoch.addingTimeInterval(45)), 45, accuracy: 0.001)
    }

    /// Clock skew between two Macs must not render a negative duration.
    func test_durationNeverGoesNegative() {
        let live = run("1", status: .running, startedOffset: 100, endedOffset: nil)
        XCTAssertEqual(live.duration(now: epoch), 0, accuracy: 0.001)
    }

    func test_anEmptyBoardIsEmpty() {
        let board = CommandBoard.summarize(runs: [])
        XCTAssertTrue(board.isEmpty)
        XCTAssertEqual(board.totalCostUSD, 0, accuracy: 0.0001)
        XCTAssertTrue(board.byMachine.isEmpty)
        XCTAssertFalse(board.isFleetActive)
    }
}
