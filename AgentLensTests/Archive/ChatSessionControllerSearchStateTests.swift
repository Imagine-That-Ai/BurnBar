// Quarantined tests extracted from: ChatSessionControllerSearchStateTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

final class ChatSessionControllerSearchStateTests: XCTestCase {

    // MARK: - Quarantined Tests

    func test_send_hermesProviderRankingQuery_returnsTopProviderAndAlignedTargets() async throws {
        try XCTSkipIf(true, "Stale contract — provider ranking heuristics changed; rebuild harness fixtures.")
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-hermes-provider-ranking")
        defer { harness.cleanup() }

        let claudeConversationA = harness.makeConversationFixture(
            id: "conv-rank-claude-a",
            provider: .claudeCode,
            fullText: "fuck this build. shit keeps failing."
        )
        let claudeConversationB = harness.makeConversationFixture(
            id: "conv-rank-claude-b",
            provider: .claudeCode,
            fullText: "damn, this refactor is cursed. fuck."
        )
        let hermesConversation = harness.makeConversationFixture(
            id: "conv-rank-hermes",
            provider: .hermes,
            fullText: "shit, this prompt is odd."
        )

        for conversation in [claudeConversationA, claudeConversationB, hermesConversation] {
            try harness.dataStore.upsertConversation(conversation)
            try harness.dataStore.enqueueConversationProjectionJob(
                conversationID: conversation.id,
                jobType: .project,
                now: harness.clock.now()
            )
        }
        _ = try await harness.runProjectionSweep(maxJobs: 20)

        let searchService = harness.makeSearchService(semanticEnabled: false)
        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: searchService
        )
        controller.startNewChatThread()
        controller.chatBackend = .hermes
        controller.hermesAvailable = true
        controller.inputText = "which agent do i curse at most often"

        await controller.send()

        XCTAssertFalse(controller.isStreaming)
        XCTAssertFalse(controller.conversationJumpTargets.isEmpty)
        XCTAssertTrue(controller.conversationJumpTargets.allSatisfy { $0.conversation.provider == .claudeCode })
        let response = controller.messages.last?.content ?? ""
        XCTAssertTrue(response.localizedCaseInsensitiveContains("Claude Code"))
        XCTAssertTrue(response.localizedCaseInsensitiveContains("Hermes"))
        XCTAssertTrue(response.localizedCaseInsensitiveContains("strong-language"))
    }


}
