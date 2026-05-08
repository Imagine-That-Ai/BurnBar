import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

final class ChartStudioPromptEngineTests: XCTestCase {

    private func makeDigest() -> TrendDataDigest {
        let providers = [
            RollupProviderSummary(provider: "claudecode", providerID: ProviderID(rawValue: "claudecode"), totalRequests: 100, totalTokens: 600_000, totalCost: 60),
            RollupProviderSummary(provider: "codex",      providerID: ProviderID(rawValue: "codex"),      totalRequests: 100, totalTokens: 400_000, totalCost: 40)
        ]
        let models = [
            RollupModelSummary(model: "claude-sonnet-4.5", provider: "claudecode", requests: 50, tokens: 300_000, cost: 30),
            RollupModelSummary(model: "gpt-5.4-codex",     provider: "codex",      requests: 50, tokens: 200_000, cost: 20)
        ]
        return TrendDataDigest.build(
            windowTotals: [.today: RollupTotals(requests: 10, tokens: 50_000, costUsd: 5.0)],
            providerSummaries: providers,
            modelSummaries: models,
            deviceSummaries: [],
            dailyPoints: [],
            recentUsages: [],
            displayMode: .currency
        )
    }

    func testSystemPromptContainsRequiredSchemaSections() {
        let engine = ChartStudioPromptEngine(digest: makeDigest())
        let prompt = engine.systemPrompt()

        // Critical instructions
        XCTAssertTrue(prompt.contains("STRICT OUTPUT FORMAT"))
        XCTAssertTrue(prompt.contains("\"kind\""))
        XCTAssertTrue(prompt.contains("swift_chart"))
        XCTAssertTrue(prompt.contains("mermaid"))
        XCTAssertTrue(prompt.contains("insight"))
        XCTAssertTrue(prompt.contains("ascii"))
        XCTAssertTrue(prompt.contains("composed"))

        // Skill awareness
        XCTAssertTrue(prompt.contains("HERMES SKILLS"))
        XCTAssertTrue(prompt.contains("ascii-art"))
        XCTAssertTrue(prompt.contains("architecture-diagram"))

        // Examples
        XCTAssertTrue(prompt.contains("EXAMPLES"))
        XCTAssertTrue(prompt.contains("sequenceDiagram"))

        // ASCII rules teach the model the legal character families.
        XCTAssertTrue(prompt.contains("box-drawing"))
        XCTAssertTrue(prompt.contains("half-blocks"))
        XCTAssertTrue(prompt.contains("▉") || prompt.contains("▇"))

        // Data digest is appended
        XCTAssertTrue(prompt.contains("DIGEST"))
        XCTAssertTrue(prompt.contains("claudecode"))
    }

    func testSuggestedPromptsMentionTopProviderAndModel() {
        let engine = ChartStudioPromptEngine(digest: makeDigest())
        let prompts = engine.suggestedPrompts()

        XCTAssertGreaterThanOrEqual(prompts.count, 6)
        XCTAssertTrue(prompts.contains { $0.contains("Claude Code") || $0.contains("claudecode") })
        XCTAssertTrue(prompts.contains { $0.contains("claude-sonnet-4.5") || $0.contains("Mermaid") })
    }
}
