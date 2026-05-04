import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - CacheHitRateTests

@MainActor
final class CacheHitRateTests: XCTestCase {

    // MARK: - CacheEfficiency primitive

    func test_cacheEfficiency_noPromptData_hasNoSignal() {
        let efficiency = CacheEfficiency.zero
        XCTAssertFalse(efficiency.hasSignal)
        XCTAssertNil(efficiency.hitRate)
        XCTAssertEqual(efficiency.formattedHitRate, "—")
        XCTAssertEqual(CacheHitRateTier(efficiency), .noSignal)
    }

    func test_cacheEfficiency_hitRate_isReadOverPromptBasis() {
        let efficiency = CacheEfficiency(inputTokens: 1_000, cacheCreationTokens: 1_000, cacheReadTokens: 8_000)
        XCTAssertEqual(efficiency.promptBasis, 10_000)
        XCTAssertEqual(efficiency.hitRate ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(efficiency.formattedHitRate, "80%")
        XCTAssertEqual(CacheHitRateTier(efficiency), .strong)
    }

    func test_cacheEfficiency_aggregate_sumsAllRows() {
        let usages: [TokenUsage] = [
            usage(provider: .factory, model: "factory-m", input: 100, cacheCreate: 50, cacheRead: 200),
            usage(provider: .factory, model: "factory-m", input: 200, cacheCreate: 0, cacheRead: 100)
        ]
        let efficiency = CacheEfficiency.aggregate(usages)
        XCTAssertEqual(efficiency.inputTokens, 300)
        XCTAssertEqual(efficiency.cacheCreationTokens, 50)
        XCTAssertEqual(efficiency.cacheReadTokens, 300)
        XCTAssertEqual(efficiency.promptBasis, 650)
        XCTAssertEqual(efficiency.hitRate ?? -1, 300.0 / 650.0, accuracy: 0.0001)
    }

    func test_cacheEfficiency_outputAndReasoningTokensIgnoredInBasis() {
        // Output and reasoning tokens should not pollute the prompt-side denominator.
        let row = usage(
            provider: .codex,
            model: "gpt-5",
            input: 1_000,
            output: 5_000,
            reasoning: 4_000,
            cacheCreate: 0,
            cacheRead: 1_000
        )
        let efficiency = row.cacheEfficiency
        XCTAssertEqual(efficiency.promptBasis, 2_000)
        XCTAssertEqual(efficiency.hitRate ?? -1, 0.5, accuracy: 0.0001)
    }

    // MARK: - Provider summary

    func test_providerSummary_includesCacheEfficiency() {
        let usages: [TokenUsage] = [
            usage(provider: .claudeCode, model: "claude-sonnet-4", input: 500, cacheRead: 1_500),
            usage(provider: .claudeCode, model: "claude-sonnet-4", input: 500, cacheRead: 500),
            usage(provider: .factory, model: "claude-sonnet-4", input: 1_000, cacheRead: 0)
        ]
        let summaries = DashboardUsageViewModel.makeProviderSummaries(from: usages)
        let claude = summaries.first(where: { $0.provider == .claudeCode })
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.cacheEfficiency.cacheReadTokens, 2_000)
        XCTAssertEqual(claude?.cacheEfficiency.promptBasis, 3_000)
        XCTAssertEqual(claude?.cacheEfficiency.hitRate ?? -1, 2_000.0 / 3_000.0, accuracy: 0.0001)

        let factory = summaries.first(where: { $0.provider == .factory })
        XCTAssertEqual(factory?.cacheEfficiency.hitRate ?? -1, 0.0, accuracy: 0.0001)
    }

    func test_providerSummary_modelBreakdown_exposesPerModelCacheHitRate() {
        let usages: [TokenUsage] = [
            usage(provider: .claudeCode, model: "claude-sonnet-4", input: 1_000, cacheRead: 1_000),
            usage(provider: .claudeCode, model: "claude-haiku-4", input: 1_000, cacheRead: 0)
        ]
        let summaries = DashboardUsageViewModel.makeProviderSummaries(from: usages)
        guard let claude = summaries.first(where: { $0.provider == .claudeCode }) else {
            return XCTFail("missing claude summary")
        }
        let sonnet = claude.modelBreakdown.first(where: { $0.modelName == "claude-sonnet-4" })
        let haiku = claude.modelBreakdown.first(where: { $0.modelName == "claude-haiku-4" })
        XCTAssertEqual(sonnet?.cacheEfficiency.hitRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(haiku?.cacheEfficiency.hitRate ?? -1, 0.0, accuracy: 0.0001)
    }

    // MARK: - Model summary

    func test_modelSummary_includesCacheEfficiency_andPerProviderBreakdown() {
        let usages: [TokenUsage] = [
            usage(provider: .factory, model: "claude-sonnet-4", input: 500, cacheRead: 1_500),
            usage(provider: .claudeCode, model: "claude-sonnet-4", input: 500, cacheRead: 500),
            usage(provider: .cursor, model: "claude-sonnet-4", input: 1_000, cacheRead: 0)
        ]
        let summaries = DashboardUsageViewModel.makeModelSummaries(from: usages)
        guard let model = summaries.first(where: { $0.modelName.contains("sonnet") }) else {
            return XCTFail("missing model summary")
        }
        XCTAssertEqual(model.cacheEfficiency.cacheReadTokens, 2_000)
        XCTAssertEqual(model.cacheEfficiency.promptBasis, 4_000)
        XCTAssertEqual(model.cacheEfficiency.hitRate ?? -1, 0.5, accuracy: 0.0001)

        let factorySlice = model.providerBreakdown.first(where: { $0.provider == .factory })
        XCTAssertEqual(factorySlice?.cacheEfficiency.hitRate ?? -1, 0.75, accuracy: 0.0001)

        let cursorSlice = model.providerBreakdown.first(where: { $0.provider == .cursor })
        XCTAssertEqual(cursorSlice?.cacheEfficiency.hitRate ?? -1, 0.0, accuracy: 0.0001)
    }

    // MARK: - View model passthrough

    func test_viewModel_cacheEfficiencyForRange_aggregatesFilteredUsages() {
        let vm = DashboardUsageViewModel()
        let now = Date()
        let inWindow = usage(provider: .factory, model: "m", input: 1_000, cacheRead: 1_000,
                             startTime: now.addingTimeInterval(-3600))
        let outOfWindow = usage(provider: .factory, model: "m", input: 1_000, cacheRead: 0,
                                startTime: now.addingTimeInterval(-86_400 * 30))
        vm.replaceUsages([inWindow, outOfWindow])

        let range = now.addingTimeInterval(-86_400)...now.addingTimeInterval(3600)
        let efficiency = vm.cacheEfficiency(in: range)
        XCTAssertEqual(efficiency.cacheReadTokens, 1_000)
        XCTAssertEqual(efficiency.hitRate ?? -1, 0.5, accuracy: 0.0001)

        let allTime = vm.cacheEfficiency(in: nil)
        XCTAssertEqual(allTime.cacheReadTokens, 1_000)
        XCTAssertEqual(allTime.promptBasis, 3_000)
        XCTAssertEqual(allTime.hitRate ?? -1, 1_000.0 / 3_000.0, accuracy: 0.0001)
    }

    func test_viewModel_cacheEfficiency_emptyUsages_isNoSignal() {
        let vm = DashboardUsageViewModel()
        let efficiency = vm.cacheEfficiency(in: nil)
        XCTAssertFalse(efficiency.hasSignal)
        XCTAssertNil(efficiency.hitRate)
    }

    // MARK: - Tier classification

    func test_cacheHitRateTier_bandsByPercentile() {
        XCTAssertEqual(CacheHitRateTier(makeEfficiency(rate: 0.65)), .strong)
        XCTAssertEqual(CacheHitRateTier(makeEfficiency(rate: 0.40)), .healthy)
        XCTAssertEqual(CacheHitRateTier(makeEfficiency(rate: 0.10)), .warming)
        XCTAssertEqual(CacheHitRateTier(makeEfficiency(rate: 0.02)), .cold)
        XCTAssertEqual(CacheHitRateTier(.zero), .noSignal)
    }

    // MARK: - Format helpers

    func test_formatAsPercent_handlesEdges() {
        XCTAssertEqual(0.5.formatAsPercent(), "50%")
        XCTAssertEqual(0.075.formatAsPercent(), "7.5%")
        XCTAssertEqual(0.0005.formatAsPercent(), "0.05%")
        XCTAssertEqual(Double.infinity.formatAsPercent(), "—")
    }

    // MARK: - Helpers

    private func makeEfficiency(rate: Double) -> CacheEfficiency {
        // Pick a 1000-token basis and produce a clean cache-read share.
        let basis = 1_000
        let read = Int(Double(basis) * rate)
        return CacheEfficiency(
            inputTokens: basis - read,
            cacheCreationTokens: 0,
            cacheReadTokens: read
        )
    }

    private func usage(
        provider: AgentProvider,
        model: String,
        input: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        cacheCreate: Int = 0,
        cacheRead: Int = 0,
        startTime: Date = Date()
    ) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: UUID().uuidString,
            projectName: "test",
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            startTime: startTime,
            endTime: startTime.addingTimeInterval(60)
        )
    }
}
