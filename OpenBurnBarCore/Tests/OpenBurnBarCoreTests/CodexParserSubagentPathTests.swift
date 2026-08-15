import XCTest
@testable import OpenBurnBarLogParsers

final class CodexParserSubagentPathTests: XCTestCase {
    func test_rolloutPathLooksLikeSubagent_usesPathMarkersOnly() {
        XCTAssertTrue(
            CodexParser.rolloutPathLooksLikeSubagent(
                "/Users/me/.codex/sessions/2026/08/12/subagents/rollout.jsonl"
            )
        )
        XCTAssertTrue(
            CodexParser.rolloutPathLooksLikeSubagent(
                "/Users/me/.codex/sessions/2026/08/12/rollout-subagent-abc.jsonl"
            )
        )
        XCTAssertFalse(
            CodexParser.rolloutPathLooksLikeSubagent(
                "/Users/me/.codex/sessions/2026/08/12/rollout-2026-08-12.jsonl"
            )
        )
    }
}
