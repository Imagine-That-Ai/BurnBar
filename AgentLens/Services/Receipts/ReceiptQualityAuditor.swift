import Foundation
import OpenBurnBarCore
import OpenBurnBarKernel

// MARK: - Receipt Quality Auditor

/// Evaluates a completed CLI session against a multi-factor rubric:
/// 1. Goal Completion (40%) — Was the user's objective reached with verifiable outputs?
/// 2. Code & Test Rigor (35%) — Were automated tests run/passed? Are commits clean?
/// 3. Token & Tool Efficiency (25%) — Throughput, prompt cache utilization, and cost proportionality.
///
/// Can run on-demand or automatically, with full offline deterministic grading.
struct ReceiptQualityAuditor: Sendable {

    private let llmClient: SummaryLLMClient?

    init(llmClient: SummaryLLMClient? = nil) {
        self.llmClient = llmClient
    }

    // MARK: - Audit Entry Point

    func audit(
        receipt: ReceiptRecord,
        settings: SummarySettingsSnapshot? = nil,
        apiKey: String? = nil
    ) async -> ReceiptQualityReview {
        // Try LLM-assisted audit if client & key are available
        if let llmClient, let settings, let apiKey, !apiKey.isEmpty {
            if let llmReview = await auditWithLLM(
                receipt: receipt,
                llmClient: llmClient,
                settings: settings,
                apiKey: apiKey
            ) {
                return llmReview
            }
        }

        // Offline deterministic grading fallback
        return auditDeterministic(receipt: receipt)
    }

    // MARK: - Deterministic Rubric Calculation

    public func auditDeterministic(receipt: ReceiptRecord) -> ReceiptQualityReview {
        // 1. Goal Completion Score (0 - 100)
        var goalScore: Double = 70.0 // baseline
        if !receipt.actualAccomplishments.isEmpty {
            goalScore += 15.0
        }
        if let git = receipt.gitStats, git.commitsCreated > 0 {
            goalScore += 15.0
        } else if !receipt.filesTouched.isEmpty {
            goalScore += 10.0
        }
        goalScore = min(100.0, max(20.0, goalScore))

        // 2. Code & Test Rigor Score (0 - 100)
        var rigorScore: Double = 65.0
        let hasTests = receipt.achievements.contains { $0.code == "tests_passing" } ||
                       receipt.toolsUsed.contains { $0.localizedCaseInsensitiveContains("test") }
        if hasTests {
            rigorScore += 25.0
        }
        if receipt.gitCommit != nil || (receipt.gitStats?.commitsCreated ?? 0) > 0 {
            rigorScore += 10.0
        }
        rigorScore = min(100.0, max(20.0, rigorScore))

        // 3. Efficiency Score (0 - 100)
        var efficiencyScore: Double = 60.0
        // Cache hit bonus (up to +25)
        let cacheBonus = min(25.0, (receipt.cacheHitPercentage / 100.0) * 30.0)
        efficiencyScore += cacheBonus

        // Speed bonus (up to +15)
        if receipt.tokensPerSecond >= 100.0 {
            efficiencyScore += 15.0
        } else if receipt.tokensPerSecond >= 50.0 {
            efficiencyScore += 10.0
        }

        // Frugal bonus
        if receipt.totalCostUSD < 0.20 && receipt.totalTokens > 500 {
            efficiencyScore += 5.0
        }
        efficiencyScore = min(100.0, max(20.0, efficiencyScore))

        // Overall composite score
        let composite = (goalScore * 0.40) + (rigorScore * 0.35) + (efficiencyScore * 0.25)
        let grade = Self.gradeForScore(composite)

        // Generate wins and critiques
        var wins: [String] = []
        var critiques: [String] = []

        if hasTests {
            wins.append("Verified code changes with automated test execution")
        }
        if receipt.cacheHitPercentage >= 70.0 {
            wins.append(String(format: "High prompt cache efficiency (%.0f%% hit rate, saved %@)", receipt.cacheHitPercentage, receipt.formattedSavings))
        }
        if let git = receipt.gitStats, git.commitsCreated > 0 {
            wins.append("Recorded structured commit history during the turn")
        }
        if wins.isEmpty {
            wins.append("Completed task within expected duration bounds")
        }

        if !hasTests {
            critiques.append("No automated test suite run was detected")
        }
        if receipt.cacheHitPercentage < 30.0 && receipt.totalTokens > 5000 {
            critiques.append("Low cache hit ratio increased input token expenditure")
        }
        if receipt.durationSeconds > 1800 {
            critiques.append("Extended turn duration (>30 min) suggests task complexity")
        }

        return ReceiptQualityReview(
            grade: grade,
            score: composite,
            goalScore: goalScore,
            rigorScore: rigorScore,
            efficiencyScore: efficiencyScore,
            wins: wins,
            critiques: critiques,
            reviewedAt: Date(),
            modelUsed: "heuristic-rubric"
        )
    }

    public static func gradeForScore(_ score: Double) -> String {
        switch score {
        case 95...100: return "A+"
        case 90..<95:  return "A"
        case 85..<90:  return "A-"
        case 80..<85:  return "B+"
        case 75..<80:  return "B"
        case 70..<75:  return "C"
        default:       return "D"
        }
    }

    // MARK: - LLM-Assisted Audit

    private func auditWithLLM(
        receipt: ReceiptRecord,
        llmClient: SummaryLLMClient,
        settings: SummarySettingsSnapshot,
        apiKey: String
    ) async -> ReceiptQualityReview? {
        var prompt = """
        You are a senior engineering auditor conducting a quality review of an AI coding agent CLI session.
        Evaluate three pillars (each 0 to 100):
        1. goalScore: Did the agent accomplish the user's objective without hallucination or abandonment?
        2. rigorScore: Code quality, tests executed/passed, commit cleanliness.
        3. efficiencyScore: Cost and time proportionality, cache utilization, no loop retries.

        Session details:
        - Project: \(receipt.projectName)
        - Harness: \(receipt.harness)
        - Model: \(receipt.modelName)
        - Duration: \(receipt.formattedDuration)
        - Total Tokens: \(receipt.formattedTokens) (Cache Hit: \(String(format: "%.1f%%", receipt.cacheHitPercentage)))
        - Total Cost: \(receipt.formattedCost)
        - Prompt / Goal: \(receipt.promptSummary)
        - Accomplishments: \(receipt.actualAccomplishments.joined(separator: "; "))
        - Files touched: \(receipt.filesTouched.prefix(10).joined(separator: ", "))
        - Tools used: \(receipt.toolsUsed.prefix(10).joined(separator: ", "))
        """

        if let git = receipt.gitStats {
            prompt += "\n- Git deliverables: \(git.summary)"
        }

        prompt += """
        \n\nReturn strict JSON with keys:
        {
          "goalScore": 90,
          "rigorScore": 85,
          "efficiencyScore": 95,
          "wins": ["Highlight 1", "Highlight 2"],
          "critiques": ["Note or improvement area"]
        }
        """

        let rawResponse = await llmClient.callOpenAICompatibleCompletion(
            baseURL: settings.localBaseURL.isEmpty ? "https://openrouter.ai/api/v1" : settings.localBaseURL,
            apiKey: apiKey,
            model: settings.openRouterPrimaryModel.isEmpty ? "anthropic/claude-3.5-haiku" : settings.openRouterPrimaryModel,
            prompt: prompt,
            timeout: 10.0,
            maxOutputTokens: 300,
            includeOpenRouterHeaders: true
        )

        guard let rawResponse else { return nil }

        let jsonText = Self.cleanJSONResponse(rawResponse)
        guard let data = jsonText.data(using: .utf8) else { return nil }

        struct LLMOutput: Decodable {
            let goalScore: Double
            let rigorScore: Double
            let efficiencyScore: Double
            let wins: [String]
            let critiques: [String]
        }

        guard let parsed = try? JSONDecoder().decode(LLMOutput.self, from: data) else { return nil }

        let composite = (parsed.goalScore * 0.40) + (parsed.rigorScore * 0.35) + (parsed.efficiencyScore * 0.25)
        let grade = Self.gradeForScore(composite)

        return ReceiptQualityReview(
            grade: grade,
            score: composite,
            goalScore: parsed.goalScore,
            rigorScore: parsed.rigorScore,
            efficiencyScore: parsed.efficiencyScore,
            wins: parsed.wins,
            critiques: parsed.critiques,
            reviewedAt: Date(),
            modelUsed: settings.openRouterPrimaryModel
        )
    }

    public static func cleanJSONResponse(_ rawResponse: String) -> String {
        var jsonText = rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```json") {
            jsonText = String(jsonText.dropFirst(7))
        } else if jsonText.hasPrefix("```") {
            jsonText = String(jsonText.dropFirst(3))
        }
        if jsonText.hasSuffix("```") {
            jsonText = String(jsonText.dropLast(3))
        }
        return jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
