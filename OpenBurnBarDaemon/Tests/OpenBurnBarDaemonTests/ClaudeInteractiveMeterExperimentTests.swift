import XCTest
@testable import OpenBurnBarDaemon

final class ClaudeInteractiveMeterExperimentTests: XCTestCase {

    // MARK: - Verdict logic

    func test_verdict_turnDidNotComplete_whenNoTokenDelta() {
        let (verdict, _) = ClaudeInteractiveMeterExperiment.evaluate(
            tokenDelta: 0,
            windowsBefore: nil,
            windowsAfter: nil,
            haveToken: false
        )
        XCTAssertEqual(verdict, .turnDidNotComplete)
    }

    func test_verdict_inconclusive_whenNoOAuthToken() {
        let (verdict, _) = ClaudeInteractiveMeterExperiment.evaluate(
            tokenDelta: 1200,
            windowsBefore: nil,
            windowsAfter: nil,
            haveToken: false
        )
        XCTAssertEqual(verdict, .inconclusiveNoSubscriptionSignal)
    }

    func test_verdict_drewFromSubscription_when5hWindowMovesUp() {
        let before = ClaudeInteractiveMeterExperiment.SubscriptionWindows(fiveHourUsed: 10, sevenDayUsed: 5)
        let after = ClaudeInteractiveMeterExperiment.SubscriptionWindows(fiveHourUsed: 12, sevenDayUsed: 5)
        let (verdict, _) = ClaudeInteractiveMeterExperiment.evaluate(
            tokenDelta: 800,
            windowsBefore: before,
            windowsAfter: after,
            haveToken: true
        )
        XCTAssertEqual(verdict, .drewFromSubscription)
    }

    func test_verdict_didNotDraw_whenWindowsFlatButTokensGrew() {
        let before = ClaudeInteractiveMeterExperiment.SubscriptionWindows(fiveHourUsed: 10, sevenDayUsed: 5)
        let after = ClaudeInteractiveMeterExperiment.SubscriptionWindows(fiveHourUsed: 10, sevenDayUsed: 5)
        let (verdict, _) = ClaudeInteractiveMeterExperiment.evaluate(
            tokenDelta: 800,
            windowsBefore: before,
            windowsAfter: after,
            haveToken: true
        )
        XCTAssertEqual(verdict, .didNotDrawFromSubscription)
    }

    // MARK: - JSONL probe

    func test_jsonlProbe_sumsUsageAcrossRecentSessions() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-jsonl-probe-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("project-a", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessionURL = projectDir.appendingPathComponent("session-1.jsonl")
        let lines = [
            #"{"message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10}}}"#,
            #"{"message":{"usage":{"input_tokens":5,"output_tokens":5}}}"#,
            #"{"type":"summary"}"#
        ]
        try lines.joined(separator: "\n").write(to: sessionURL, atomically: true, encoding: .utf8)

        let probe = ClaudeCodeJSONLUsageProbe(projectsDirectory: root, recencyCutoff: 60 * 60)
        let snapshot = probe.snapshot()
        XCTAssertEqual(snapshot.totalTokens, 100 + 50 + 10 + 5 + 5)
    }

    func test_jsonlProbe_changedSessions_detectsGrowth() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("obb-jsonl-changed-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("project-b", isDirectory: true)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sessionURL = projectDir.appendingPathComponent("turn.jsonl")
        try #"{"message":{"usage":{"input_tokens":10,"output_tokens":10}}}"#
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let probe = ClaudeCodeJSONLUsageProbe(projectsDirectory: root, recencyCutoff: 60 * 60)
        let before = probe.snapshot()

        let appended = [
            #"{"message":{"usage":{"input_tokens":10,"output_tokens":10}}}"#,
            #"{"message":{"usage":{"input_tokens":40,"output_tokens":40}}}"#
        ].joined(separator: "\n")
        try appended.write(to: sessionURL, atomically: true, encoding: .utf8)
        let after = probe.snapshot()

        XCTAssertEqual(after.totalTokens - before.totalTokens, 80)
        XCTAssertEqual(ClaudeCodeJSONLUsageProbe.changedSessions(before: before, after: after), ["turn.jsonl"])
    }

    // MARK: - ANSI stripping

    func test_stripANSI_removesColorAndCursorSequences() {
        let input = "\u{1B}[1;32mPONG\u{1B}[0m\u{1B}[2K done"
        XCTAssertEqual(PTYInteractiveSession.stripANSI(input), "PONG done")
    }

    func test_stripANSI_removesOSCAndCarriageReturns() {
        let input = "\u{1B}]0;title\u{07}line1\rline2"
        XCTAssertEqual(PTYInteractiveSession.stripANSI(input), "line1line2")
    }

    func test_stripANSI_keepsPlainText() {
        XCTAssertEqual(PTYInteractiveSession.stripANSI("hello world"), "hello world")
    }
}
