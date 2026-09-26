import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel

/// Regression coverage for the Claude ≥8MB body tail-overwrite bug: when a
/// transcript at or above `incrementalScanThresholdBytes` grows between
/// passes, the second bodies pass resumes token accumulation from the
/// persisted byte offset but must still return the full conversation prefix.
/// A tail-only second pass loses the opening turns (marker, message count,
/// and inferred title all regress).
final class ClaudeCodeBodyResumeRegressionTests: XCTestCase {
    private static let resumeMarker = "RESUME_PREFIX_MARKER"
    private static let thresholdBytes: Int64 = 8 * 1024 * 1024

    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testLargeTranscriptBodyKeepsPrefixAcrossResumedPass() async throws {
        let root = try makeTemporaryDirectory(named: "claude-body-resume-large")
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let transcript = projectsRoot
            .appendingPathComponent("-Users-test-Project", isDirectory: true)
            .appendingPathComponent("session-resume.jsonl")

        var lines: [String] = []
        lines.reserveCapacity(4002)
        lines.append(userLine(text: "\(Self.resumeMarker) please review the parser resume behavior across incremental scans."))
        lines.append(assistantLine(text: "Acknowledged. Starting the review."))
        for turn in 1...2000 {
            lines.append(userLine(text: "Filler turn \(turn) " + String(repeating: "x", count: 4000)))
            lines.append(assistantLine(text: "Filler reply \(turn)."))
        }
        try write(lines.joined(separator: "\n") + "\n", to: transcript)

        let initialSize = try fileSize(of: transcript)
        XCTAssertGreaterThanOrEqual(
            initialSize,
            Self.thresholdBytes,
            "transcript must reach the incremental-scan threshold (saw \(initialSize) bytes)"
        )

        let parser = ClaudeCodeParser(
            fileManager: .default,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )
        let bodies = LogParseOptions(includeConversationBodies: true)

        let first = try await parser.parse(options: bodies)
        let firstConversation = try XCTUnwrap(first.conversations.first)
        XCTAssertEqual(first.conversations.count, 1)
        XCTAssertTrue(
            firstConversation.fullText.contains(Self.resumeMarker),
            "pass 1 must capture the opening marker"
        )
        // Exact: 1 opener pair + 2000 filler pairs.
        XCTAssertEqual(firstConversation.messageCount, 4002)
        let firstTitle = firstConversation.inferredTaskTitle

        var appended: [String] = []
        for turn in 1...5 {
            appended.append(userLine(text: "APPENDED_TAIL_TURN \(turn) verifying tail growth merges with the prefix."))
            appended.append(assistantLine(text: "Appended reply \(turn)."))
        }
        try append(appended.joined(separator: "\n") + "\n", to: transcript)

        let second = try await parser.parse(options: bodies)
        let secondConversation = try XCTUnwrap(second.conversations.first)
        XCTAssertEqual(second.conversations.count, 1)
        XCTAssertTrue(
            secondConversation.fullText.contains(Self.resumeMarker),
            "resumed pass 2 must retain the pass-1 prefix marker"
        )
        // Exact: pass-1 4002 + 5 appended pairs. An off-by-N drop fails here.
        XCTAssertEqual(
            secondConversation.messageCount,
            4012,
            "resumed pass 2 must keep every pass-1 message plus the tail"
        )
        XCTAssertEqual(
            secondConversation.inferredTaskTitle,
            firstTitle,
            "resumed pass 2 must keep the pass-1 inferred title"
        )
    }

    func testSmallTranscriptBodyIsStableAcrossTwoPasses() async throws {
        let root = try makeTemporaryDirectory(named: "claude-body-resume-small")
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let transcript = projectsRoot
            .appendingPathComponent("-Users-test-Project", isDirectory: true)
            .appendingPathComponent("session-control.jsonl")

        // Trailing newline required: without it the later append fuses onto
        // the last line and the corrupt line is (correctly) skipped.
        try write(
            """
            \(userLine(text: "\(Self.resumeMarker) control transcript stays small."))
            \(assistantLine(text: "Control reply."))
            \(userLine(text: "Second control turn."))
            \(assistantLine(text: "Second control reply."))
            """ + "\n",
            to: transcript
        )
        XCTAssertLessThan(try fileSize(of: transcript), Self.thresholdBytes)

        let parser = ClaudeCodeParser(
            fileManager: .default,
            appPaths: OpenBurnBarAppPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true)
            ),
            projectsDirectoryOverride: projectsRoot
        )
        let bodies = LogParseOptions(includeConversationBodies: true)

        let first = try await parser.parse(options: bodies)
        let firstConversation = try XCTUnwrap(first.conversations.first)

        try append(
            userLine(text: "APPENDED_TAIL_TURN control growth.") + "\n"
                + assistantLine(text: "Appended control reply.") + "\n",
            to: transcript
        )

        let second = try await parser.parse(options: bodies)
        let secondConversation = try XCTUnwrap(second.conversations.first)

        XCTAssertTrue(secondConversation.fullText.contains(Self.resumeMarker))
        // Exact: 4 control turns + 1 appended pair.
        XCTAssertEqual(firstConversation.messageCount, 4)
        XCTAssertEqual(secondConversation.messageCount, 6)
        XCTAssertEqual(secondConversation.inferredTaskTitle, firstConversation.inferredTaskTitle)
    }

    func testUsagePassAfterBodiesPass_matchesFreshFullScan() async throws {
        // The bodies→usage interleave is the riskiest seam of usage-only
        // resume: the bodies pass persists full-file token state, and the
        // next usage-only pass resumes from it. Totals must equal a fresh
        // full scan — no double-count, no dropped tail.
        let root = try makeTemporaryDirectory(named: "claude-body-usage-interleave")
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let transcript = projectsRoot
            .appendingPathComponent("-Users-test-Project", isDirectory: true)
            .appendingPathComponent("session-interleave.jsonl")

        var lines: [String] = []
        lines.append(userLine(text: "\(Self.resumeMarker) interleave check."))
        lines.append(assistantLine(text: "Acknowledged."))
        for turn in 1...2000 {
            lines.append(userLine(text: "Filler turn \(turn) " + String(repeating: "x", count: 4000)))
            lines.append(assistantLine(text: "Filler reply \(turn)."))
        }
        try write(lines.joined(separator: "\n") + "\n", to: transcript)
        XCTAssertGreaterThanOrEqual(try fileSize(of: transcript), Self.thresholdBytes)

        func makeParser(supportName: String) -> ClaudeCodeParser {
            ClaudeCodeParser(
                fileManager: .default,
                appPaths: OpenBurnBarAppPaths(
                    applicationSupportRoot: root.appendingPathComponent(supportName, isDirectory: true)
                ),
                projectsDirectoryOverride: projectsRoot
            )
        }

        let parser = makeParser(supportName: "support-interleave")
        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))

        var appended: [String] = []
        for turn in 1...5 {
            appended.append(userLine(text: "APPENDED_TAIL_TURN \(turn)."))
            appended.append(assistantLine(text: "Appended reply \(turn)."))
        }
        try append(appended.joined(separator: "\n") + "\n", to: transcript)

        let resumed = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        let fresh = try await makeParser(supportName: "support-interleave-fresh")
            .parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(resumed.usages.count, 1)
        XCTAssertEqual(fresh.usages.count, 1)
        let resumedUsage = try XCTUnwrap(resumed.usages.first)
        let freshUsage = try XCTUnwrap(fresh.usages.first)
        // 2001 opener+filler assistant lines + 5 appended, 10 in / 5 out each.
        XCTAssertEqual(resumedUsage.inputTokens, 20_060)
        XCTAssertEqual(resumedUsage.outputTokens, 10_030)
        XCTAssertEqual(resumedUsage.inputTokens, freshUsage.inputTokens)
        XCTAssertEqual(resumedUsage.outputTokens, freshUsage.outputTokens)
        XCTAssertEqual(resumedUsage.startTime, freshUsage.startTime)
        XCTAssertEqual(resumedUsage.endTime, freshUsage.endTime)
    }

    private func userLine(text: String) -> String {
        #"{"type":"user","timestamp":"2026-05-04T08:00:00Z","message":{"role":"user","content":[{"type":"text","text":""# + text + #""}]}}"#
    }

    private func assistantLine(text: String) -> String {
        #"{"type":"assistant","timestamp":"2026-05-04T08:00:01Z","message":{"role":"assistant","model":"claude-sonnet-4","content":[{"type":"text","text":""# + text + #""}],"usage":{"input_tokens":10,"output_tokens":5}}}"#
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url, options: .atomic)
    }

    private func append(_ string: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
