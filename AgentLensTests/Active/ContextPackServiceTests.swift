import XCTest
@testable import OpenBurnBar

// MARK: - Test Fixtures

private enum Fixtures {
    /// Fixed reference date for deterministic tests.
    static let referenceDate = Date(timeIntervalSince1970: 1_740_000_000)  // 2025-02-19

    /// Fixed calendar for date math.
    static let calendar = Calendar(identifier: .gregorian)

    /// Creates a date `days` before the reference date.
    static func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: referenceDate)!
    }

    /// Creates a minimal ConversationRecord for testing.
    ///
    /// All parameters with defaults are provided so call sites can pass
    /// arguments in any order using labeled arguments.
    static func makeConversation(
        id: String,
        sessionId: String,
        provider: AgentProvider = .claudeCode,
        projectName: String = "TestProject",
        daysOld: Int = 3,
        messageCount: Int = 10,
        keyFiles: [String] = [],
        keyCommands: [String] = [],
        keyTools: [String] = [],
        summary: String? = nil,
        summaryTitle: String? = nil,
        fullText: String = "Session body text.",
        startTime: Date? = nil,
        endTime: Date? = nil,
        indexedAt: Date? = nil
    ) -> ConversationRecord {
        let date = daysAgo(daysOld)
        return ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime ?? date.addingTimeInterval(0),
            endTime: endTime ?? date.addingTimeInterval(3600),
            messageCount: messageCount,
            userWordCount: 50,
            assistantWordCount: 200,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            keyTools: keyTools,
            inferredTaskTitle: summaryTitle ?? "Test Session",
            lastAssistantMessage: "Assistant response",
            fullText: fullText,
            indexedAt: indexedAt ?? date.addingTimeInterval(7200),
            fileModifiedAt: nil,
            summary: summary,
            summaryTitle: summaryTitle,
            sourceType: .providerLog
        )
    }
}

// MARK: - ContextPackServiceTests

@MainActor
final class ContextPackServiceTests: XCTestCase {

    // MARK: - VAL-CTXSRV-001: Ranking score ordering

    func test_rankingOrdersByScoreDescending() {
        let candidates = [
            Fixtures.makeConversation(
                id: "low-1", sessionId: "s-low-1",
                projectName: "Other", daysOld: 30
            ),
            Fixtures.makeConversation(
                id: "high-1", sessionId: "s-high-1",
                projectName: "AnchorProject", daysOld: 1,
                keyFiles: ["file1.swift"], summary: "Has summary"
            ),
            Fixtures.makeConversation(
                id: "mid-1", sessionId: "s-mid-1",
                projectName: "AnchorProject", daysOld: 5
            ),
        ]

        let params = ContextPackAssemblyParams(
            anchorProject: "AnchorProject",
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        XCTAssertEqual(pack.sessions.count, 3)
        // high-1 should be first (same project + recent + summary + signals)
        XCTAssertEqual(pack.sessions[0].id, "high-1")
        // mid-1 should be second (same project + recent)
        XCTAssertEqual(pack.sessions[1].id, "mid-1")
        // low-1 should be last (old, different project, no summary, no signals)
        XCTAssertEqual(pack.sessions[2].id, "low-1")

        // Scores should be descending
        let scores = pack.sessions.map(\.rankScore)
        for i in 0..<(scores.count - 1) {
            XCTAssertGreaterThanOrEqual(scores[i], scores[i + 1],
                "Score at index \(i) (\(scores[i])) should be >= score at \(i+1) (\(scores[i+1]))")
        }
    }

    // MARK: - VAL-CTXSRV-002: Deterministic tie-breaks

    func test_tieBreakDeterministicAcrossRuns() {
        // Two sessions with identical ranking factors but different times
        let candidates = [
            Fixtures.makeConversation(
                id: "tie-a", sessionId: "s-tie-a", daysOld: 3,
                startTime: Fixtures.daysAgo(3), endTime: Fixtures.daysAgo(3).addingTimeInterval(3600),
                indexedAt: Fixtures.daysAgo(3).addingTimeInterval(7200)
            ),
            Fixtures.makeConversation(
                id: "tie-b", sessionId: "s-tie-b", daysOld: 3,
                startTime: Fixtures.daysAgo(3).addingTimeInterval(100),
                endTime: Fixtures.daysAgo(3).addingTimeInterval(3700),
                indexedAt: Fixtures.daysAgo(3).addingTimeInterval(7300)
            ),
        ]

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)

        // Run 10 times and assert identical output
        var results: [[String]] = []
        for _ in 0..<10 {
            let pack = ContextPackService.assemble(candidates: candidates, params: params)
            results.append(pack.sessions.map(\.id))
        }

        let first = results[0]
        for (i, result) in results.enumerated() {
            XCTAssertEqual(result, first, "Run \(i) produced different ordering than run 0")
        }
    }

    // MARK: - VAL-CTXSRV-003: Same-project boost

    func test_sameProjectSessionsAreBoosted() {
        let sameProject = Fixtures.makeConversation(
            id: "same-proj", sessionId: "s-same",
            projectName: "AnchorProject", daysOld: 3
        )
        let otherProject = Fixtures.makeConversation(
            id: "other-proj", sessionId: "s-other",
            projectName: "OtherProject", daysOld: 3
        )

        // Control: same age, same signals, same summary status
        let params = ContextPackAssemblyParams(
            anchorProject: "AnchorProject",
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: [otherProject, sameProject], params: params)

        XCTAssertEqual(pack.sessions.count, 2)
        XCTAssertEqual(pack.sessions[0].id, "same-proj",
            "Same-project session should rank higher")
        XCTAssertGreaterThan(pack.sessions[0].rankScore, pack.sessions[1].rankScore,
            "Same-project session should have strictly higher rank score")
    }

    // MARK: - VAL-CTXSRV-004: Recency weighting and decay

    func test_recentSessionsWeightedOverOlder() {
        let recent = Fixtures.makeConversation(
            id: "recent", sessionId: "s-recent",
            projectName: "SameProject", daysOld: 2
        )
        let older = Fixtures.makeConversation(
            id: "older", sessionId: "s-older",
            projectName: "SameProject", daysOld: 14
        )

        // Same project, no summary, no signals — only recency differs
        let params = ContextPackAssemblyParams(
            anchorProject: "SameProject",
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: [older, recent], params: params)

        XCTAssertEqual(pack.sessions.count, 2)
        XCTAssertEqual(pack.sessions[0].id, "recent",
            "Recent session (2d ago) should rank higher than older (14d ago)")
        XCTAssertGreaterThan(pack.sessions[0].rankScore, pack.sessions[1].rankScore)
    }

    // MARK: - VAL-CTXSRV-005: Summary-presence rank contribution

    func test_summaryPresenceBoostAffectsRanking() {
        let withSummary = Fixtures.makeConversation(
            id: "with-summary", sessionId: "s-with-sum",
            daysOld: 3, summary: "This session did important work"
        )
        let withoutSummary = Fixtures.makeConversation(
            id: "without-summary", sessionId: "s-no-sum",
            daysOld: 3
        )

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        let pack = ContextPackService.assemble(candidates: [withoutSummary, withSummary], params: params)

        XCTAssertEqual(pack.sessions.count, 2)
        XCTAssertEqual(pack.sessions[0].id, "with-summary",
            "Session with summary should rank higher")
        XCTAssertGreaterThan(pack.sessions[0].rankScore, pack.sessions[1].rankScore)
    }

    // MARK: - VAL-CTXSRV-006: Signal-size rank contribution

    func test_keyFilesAndCommandsSignalAffectsRanking() {
        let highSignal = Fixtures.makeConversation(
            id: "high-signal", sessionId: "s-hi-sig",
            daysOld: 3,
            keyFiles: ["file1.swift", "file2.swift", "file3.swift"],
            keyCommands: ["build", "test"]
        )
        let lowSignal = Fixtures.makeConversation(
            id: "low-signal", sessionId: "s-lo-sig",
            daysOld: 3
        )

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        let pack = ContextPackService.assemble(candidates: [lowSignal, highSignal], params: params)

        XCTAssertEqual(pack.sessions.count, 2)
        XCTAssertEqual(pack.sessions[0].id, "high-signal",
            "Session with more key files/commands should rank higher")
        XCTAssertGreaterThan(pack.sessions[0].rankScore, pack.sessions[1].rankScore)
    }

    // MARK: - VAL-CTXSRV-007: Session cap maximum five

    func test_sessionCapMaximumFive() {
        // Create 8 eligible sessions
        var candidates: [ConversationRecord] = []
        for i in 0..<8 {
            candidates.append(Fixtures.makeConversation(
                id: "session-\(i)", sessionId: "s-cap-\(i)", daysOld: i + 1
            ))
        }

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        XCTAssertLessThanOrEqual(pack.sessions.count, 5,
            "Pack should contain at most 5 sessions")
        XCTAssertEqual(pack.sessions.count, 5,
            "With 8 eligible sessions, pack should contain exactly 5")
    }

    // MARK: - VAL-CTXSRV-007B: Under-cap retention

    func test_underCapRetainsAllEligibleSessions() {
        // 0 sessions
        let pack0 = ContextPackService.assemble(
            candidates: [],
            params: ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        )
        XCTAssertEqual(pack0.sessions.count, 0)

        // 1 session
        let one = [Fixtures.makeConversation(id: "s1", sessionId: "s1", daysOld: 1)]
        let pack1 = ContextPackService.assemble(
            candidates: one,
            params: ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        )
        XCTAssertEqual(pack1.sessions.count, 1)

        // Exactly 5 sessions
        var five: [ConversationRecord] = []
        for i in 0..<5 {
            five.append(Fixtures.makeConversation(id: "f\(i)", sessionId: "f\(i)", daysOld: i + 1))
        }
        let pack5 = ContextPackService.assemble(
            candidates: five,
            params: ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        )
        XCTAssertEqual(pack5.sessions.count, 5)

        // 3 sessions under cap with small body
        var three: [ConversationRecord] = []
        for i in 0..<3 {
            three.append(Fixtures.makeConversation(
                id: "t\(i)", sessionId: "t\(i)", daysOld: i + 1, fullText: "short"
            ))
        }
        let pack3 = ContextPackService.assemble(
            candidates: three,
            params: ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        )
        XCTAssertEqual(pack3.sessions.count, 3)
    }

    // MARK: - VAL-CTXSRV-008: Character cap boundary

    func test_characterCapBoundaryAndOverflow() {
        // Create sessions where total body is exactly 12000 chars
        let bodySize = 4000
        let body = String(repeating: "x", count: bodySize)
        let candidates = [
            Fixtures.makeConversation(id: "exact-1", sessionId: "s-e1", daysOld: 1, fullText: body),
            Fixtures.makeConversation(id: "exact-2", sessionId: "s-e2", daysOld: 2, fullText: body),
            Fixtures.makeConversation(id: "exact-3", sessionId: "s-e3", daysOld: 3, fullText: body),
        ]

        let params = ContextPackAssemblyParams(
            maxCharBudget: 12_000,
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        // The body includes header text (## title, provider line, etc.) so the raw fullText alone
        // doesn't equal the bodyText. Verify the char budget is respected.
        let totalChars = pack.sessions.reduce(0) { $0 + $1.bodyText.count }
        XCTAssertLessThanOrEqual(totalChars, 12_001,
            "At boundary, total chars should be <= budget or just one session over")

        // Now test with explicit overflow: make bodies large enough to exceed budget
        let largeBody = String(repeating: "y", count: 5000)
        let largeCandidates = [
            Fixtures.makeConversation(id: "over-1", sessionId: "s-o1", daysOld: 1, fullText: largeBody),
            Fixtures.makeConversation(id: "over-2", sessionId: "s-o2", daysOld: 2, fullText: largeBody),
            Fixtures.makeConversation(id: "over-3", sessionId: "s-o3", daysOld: 3, fullText: largeBody),
        ]

        let packOver = ContextPackService.assemble(
            candidates: largeCandidates,
            params: ContextPackAssemblyParams(maxCharBudget: 12_000, referenceDate: Fixtures.referenceDate)
        )

        let totalCharsOver = packOver.sessions.reduce(0) { $0 + $1.bodyText.count }
        XCTAssertLessThanOrEqual(totalCharsOver, 12_001,
            "Over budget should be trimmed to <= budget (allowing single session truncation)")
    }

    // MARK: - VAL-CTXSRV-009: Overflow trims oldest included first

    func test_overflowTrimsOldestIncludedFirst() {
        // Create sessions with large bodies; sessions are already ranked by recency
        // The oldest (lowest rank) should be trimmed first
        let largeBody = String(repeating: "z", count: 6000)

        let recent = Fixtures.makeConversation(id: "recent-1", sessionId: "s-recent", daysOld: 1, fullText: largeBody)
        let mid = Fixtures.makeConversation(id: "mid-1", sessionId: "s-mid", daysOld: 3, fullText: largeBody)
        let older = Fixtures.makeConversation(id: "older-1", sessionId: "s-older", daysOld: 5, fullText: largeBody)

        // With budget of 12000, the oldest should be trimmed since recent + mid likely exceed budget
        let params = ContextPackAssemblyParams(
            maxCharBudget: 12_000,
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: [older, mid, recent], params: params)

        // The oldest session should be trimmed
        XCTAssertTrue(pack.sessions.contains(where: { $0.id == "recent-1" }),
            "Most recent session should be retained")
        XCTAssertFalse(pack.sessions.contains(where: { $0.id == "older-1" }),
            "Oldest session should be trimmed when over char budget")

        // Verify deterministic removal order: older sessions removed before newer ones
        let totalChars = pack.sessions.reduce(0) { $0 + $1.bodyText.count }
        XCTAssertLessThanOrEqual(totalChars, 12_001,
            "After trimming oldest, total should be within budget")
    }

    // MARK: - VAL-CTXSRV-010: Key file dedup and commands collection

    func test_keyFilesDedupAndCommandsCollection() {
        let candidates = [
            Fixtures.makeConversation(
                id: "s1", sessionId: "s1", daysOld: 1,
                keyFiles: ["file1.swift", "file2.swift", "file3.swift"],
                keyCommands: ["npm test", "npm build"]
            ),
            Fixtures.makeConversation(
                id: "s2", sessionId: "s2", daysOld: 2,
                keyFiles: ["file2.swift", "file3.swift", "file4.swift"],
                keyCommands: ["npm build", "swift test"]
            ),
        ]

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        // Key files should be deduped, preserving order of first occurrence
        XCTAssertEqual(pack.keyFiles, ["file1.swift", "file2.swift", "file3.swift", "file4.swift"])

        // Key commands should be deduped, preserving order of first occurrence
        XCTAssertEqual(pack.keyCommands, ["npm test", "npm build", "swift test"])
    }

    // MARK: - VAL-CTXSRV-011: Reason labels and usage summary

    func test_reasonLabelsAndUsageSummaryFormatting() {
        let candidates = [
            Fixtures.makeConversation(
                id: "r1", sessionId: "s-r1",
                projectName: "MyProject", daysOld: 1,
                keyFiles: ["a.swift"],
                summary: "Fixed a bug"
            ),
        ]

        let params = ContextPackAssemblyParams(
            anchorProject: "MyProject",
            referenceDate: Fixtures.referenceDate
        )
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        // Reason label should be non-empty and human-readable
        XCTAssertFalse(pack.sessions[0].reasonLabel.isEmpty,
            "Reason label should not be empty")
        XCTAssertTrue(pack.sessions[0].reasonLabel.contains("same project"),
            "Reason should mention same project boost")

        // Usage summary should contain session count
        XCTAssertTrue(pack.usageSummary.contains("1 session"),
            "Usage summary should mention session count")
    }

    // MARK: - VAL-CTXSRV-012: Permutation-invariant ranking

    func test_rankingPermutationInvariance() {
        let candidates = [
            Fixtures.makeConversation(id: "p-a", sessionId: "s-pa", projectName: "Proj", daysOld: 1),
            Fixtures.makeConversation(id: "p-b", sessionId: "s-pb", projectName: "Proj", daysOld: 3),
            Fixtures.makeConversation(id: "p-c", sessionId: "s-pc", projectName: "Proj", daysOld: 7),
            Fixtures.makeConversation(id: "p-d", sessionId: "s-pd", projectName: "Proj", daysOld: 10),
        ]

        let params = ContextPackAssemblyParams(
            anchorProject: "Proj",
            referenceDate: Fixtures.referenceDate
        )

        // Test multiple permutations produce identical output
        let expected = ContextPackService.assemble(candidates: candidates, params: params)
            .sessions.map(\.id)

        let permutations: [[ConversationRecord]] = [
            [candidates[3], candidates[1], candidates[0], candidates[2]],
            [candidates[2], candidates[0], candidates[3], candidates[1]],
            [candidates[1], candidates[3], candidates[2], candidates[0]],
            Array(candidates.reversed()),
        ]

        for (i, perm) in permutations.enumerated() {
            let result = ContextPackService.assemble(candidates: perm, params: params)
                .sessions.map(\.id)
            XCTAssertEqual(result, expected,
                "Permutation \(i) produced different ordering than original")
        }
    }

    // MARK: - VAL-CTXSRV-013: Session-identity dedupe before ranking and caps

    func test_sessionIdentityDedupeBeforeRankingAndCaps() {
        // Create duplicate sessions with same provider+sessionId but different ids
        let dupA = Fixtures.makeConversation(
            id: "dup-a", sessionId: "s-dup", daysOld: 1
        )
        let dupB = Fixtures.makeConversation(
            id: "dup-b", sessionId: "s-dup", daysOld: 1,
            indexedAt: Fixtures.daysAgo(1).addingTimeInterval(100)  // more recent indexedAt
        )
        let unique = Fixtures.makeConversation(
            id: "unique-1", sessionId: "s-unique", daysOld: 1
        )

        let params = ContextPackAssemblyParams(referenceDate: Fixtures.referenceDate)
        let pack = ContextPackService.assemble(candidates: [dupA, dupB, unique], params: params)

        // Should have exactly 2 unique sessions (dupA/B deduped to one)
        XCTAssertEqual(pack.sessions.count, 2,
            "Duplicate sessions should be deduped before ranking")

        // All session IDs should be unique
        let sessionIds = pack.sessions.map { $0.id }
        XCTAssertEqual(Set(sessionIds).count, sessionIds.count,
            "Included sessions should have unique IDs")
    }

    // MARK: - VAL-CTXSRV-014: Oversize single-session cap safety

    func test_oversizeSingleSessionCapHandling() {
        // One session with a body exceeding 12k chars
        let hugeBody = String(repeating: "a", count: 50_000)
        let candidates = [
            Fixtures.makeConversation(id: "huge-1", sessionId: "s-huge", daysOld: 1, fullText: hugeBody),
        ]

        let params = ContextPackAssemblyParams(
            maxCharBudget: 12_000,
            referenceDate: Fixtures.referenceDate
        )

        // This should complete without crash, infinite loop, or malformed state
        let pack = ContextPackService.assemble(candidates: candidates, params: params)

        // Should return exactly 1 session
        XCTAssertEqual(pack.sessions.count, 1)

        // Body should be bounded (truncated to fit within budget)
        XCTAssertLessThanOrEqual(pack.sessions[0].bodyText.count, 12_000,
            "Oversize single session body should be truncated to fit budget")

        // Pack should be well-formed
        XCTAssertFalse(pack.isEmpty)
        XCTAssertGreaterThanOrEqual(pack.charEstimate, 0)
        XCTAssertLessThanOrEqual(pack.charEstimate, 12_000)
    }
}
