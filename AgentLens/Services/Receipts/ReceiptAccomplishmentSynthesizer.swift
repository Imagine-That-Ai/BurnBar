import Foundation
import OpenBurnBarKernel

// MARK: - Receipt Accomplishment Synthesizer

/// Combines filesystem/git proof with LLM analysis to produce a concrete,
/// verified punchlist of what was ACTUALLY accomplished during a CLI session,
/// accompanied by achievement badges and git statistics.
struct ReceiptAccomplishmentSynthesizer: Sendable {

    struct SynthesisContext: Sendable {
        let projectName: String
        let projectPath: String?
        let promptSummary: String
        let filesTouched: [String]
        let toolsUsed: [String]
        let durationSeconds: Double
        let tokensPerSecond: Double
        let cacheHitPercentage: Double
        let totalCostUSD: Double
        let lastAssistantMessage: String?

        init(
            projectName: String,
            projectPath: String? = nil,
            promptSummary: String = "",
            filesTouched: [String] = [],
            toolsUsed: [String] = [],
            durationSeconds: Double = 0,
            tokensPerSecond: Double = 0,
            cacheHitPercentage: Double = 0,
            totalCostUSD: Double = 0,
            lastAssistantMessage: String? = nil
        ) {
            self.projectName = projectName
            self.projectPath = projectPath
            self.promptSummary = promptSummary
            self.filesTouched = filesTouched
            self.toolsUsed = toolsUsed
            self.durationSeconds = durationSeconds
            self.tokensPerSecond = tokensPerSecond
            self.cacheHitPercentage = cacheHitPercentage
            self.totalCostUSD = totalCostUSD
            self.lastAssistantMessage = lastAssistantMessage
        }
    }

    struct SynthesisResult: Sendable {
        let accomplishments: [String]
        let gitStats: ReceiptGitStats?
        let achievements: [ReceiptAchievement]
    }

    private let llmClient: SummaryLLMClient?

    init(llmClient: SummaryLLMClient? = nil) {
        self.llmClient = llmClient
    }

    // MARK: - Main Synthesis

    func synthesize(
        context: SynthesisContext,
        settings: SummarySettingsSnapshot? = nil,
        apiKey: String? = nil
    ) async -> SynthesisResult {
        // 1. Gather Git proof from filesystem if path available
        let gitStats = gatherGitStats(at: context.projectPath)

        // 2. Compute dynamic achievements
        let achievements = deriveAchievements(context: context, gitStats: gitStats)

        // 3. Generate accomplishments: Try LLM first if available, else deterministic
        if let llmClient, let settings, let apiKey, !apiKey.isEmpty {
            if let llmAccomplishments = await synthesizeWithLLM(
                context: context,
                gitStats: gitStats,
                llmClient: llmClient,
                settings: settings,
                apiKey: apiKey
            ), !llmAccomplishments.isEmpty {
                return SynthesisResult(
                    accomplishments: llmAccomplishments,
                    gitStats: gitStats,
                    achievements: achievements
                )
            }
        }

        // 4. Deterministic fallback
        let deterministicAccomplishments = synthesizeDeterministic(
            context: context,
            gitStats: gitStats
        )

        return SynthesisResult(
            accomplishments: deterministicAccomplishments,
            gitStats: gitStats,
            achievements: achievements
        )
    }

    // MARK: - Git Proof Extraction

    func gatherGitStats(at path: String?) -> ReceiptGitStats? {
        guard let path, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let diffStat = runGitCommand(["diff", "--shortstat"], at: path)
        let (insertions, deletions, filesChanged) = parseGitShortstat(diffStat)

        let commitsCountStr = runGitCommand(["rev-list", "--count", "HEAD@{15.minutes.ago}..HEAD"], at: path)
        let commits = Int(commitsCountStr.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        if insertions > 0 || deletions > 0 || filesChanged > 0 || commits > 0 {
            return ReceiptGitStats(
                insertions: insertions,
                deletions: deletions,
                filesChanged: filesChanged,
                commitsCreated: max(0, commits)
            )
        }
        return nil
    }

    private func parseGitShortstat(_ text: String) -> (insertions: Int, deletions: Int, filesChanged: Int) {
        // e.g. " 3 files changed, 45 insertions(+), 12 deletions(-)"
        var files = 0
        var ins = 0
        var del = 0

        let parts = text.components(separatedBy: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.components(separatedBy: " ")
            guard let count = tokens.first.flatMap(Int.init) else { continue }

            if trimmed.contains("file") {
                files = count
            } else if trimmed.contains("insertion") {
                ins = count
            } else if trimmed.contains("deletion") {
                del = count
            }
        }
        return (ins, del, files)
    }

    private func runGitCommand(_ args: [String], at path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "-C", path
        ] + args

        var environment = ProcessInfo.processInfo.environment.filter { entry in
            !entry.key.hasPrefix("GIT_")
        }
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let deadline = Date().addingTimeInterval(3.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                process.terminate()
                return ""
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Achievement Derivation

    func deriveAchievements(context: SynthesisContext, gitStats: ReceiptGitStats?) -> [ReceiptAchievement] {
        var badges: [ReceiptAchievement] = []

        // Speed Demon: >150 tok/s
        if context.tokensPerSecond >= 150 {
            badges.append(.speedDemon)
        }

        // Cache Beast: >80% prompt cache hit
        if context.cacheHitPercentage >= 80 {
            badges.append(.cacheBeast)
        }

        // Tests Passing: detected test command in tools or output
        let ranTests = context.toolsUsed.contains { tool in
            let lower = tool.lowercased()
            return lower.contains("test") || lower.contains("xcodebuild") || lower.contains("pytest") || lower.contains("cargo test")
        } || (context.lastAssistantMessage?.localizedCaseInsensitiveContains("test passed") ?? false)
          || (context.lastAssistantMessage?.localizedCaseInsensitiveContains("tests passed") ?? false)

        if ranTests {
            badges.append(.testsPassing)
        }

        // Clean Commit: Git commits recorded
        if let gitStats, gitStats.commitsCreated > 0 {
            badges.append(.cleanCommit)
        }

        // Frugal: total cost under $0.05
        if context.totalCostUSD > 0 && context.totalCostUSD < 0.05 {
            badges.append(.frugal)
        }

        // Marathon: session ran longer than 25 minutes
        if context.durationSeconds >= 25 * 60 {
            badges.append(.marathon)
        }

        return badges
    }

    // MARK: - Deterministic Fallback

    func synthesizeDeterministic(context: SynthesisContext, gitStats: ReceiptGitStats?) -> [String] {
        var items: [String] = []

        if let gitStats {
            if gitStats.commitsCreated > 0 {
                items.append("Committed \(gitStats.commitsCreated) change\(gitStats.commitsCreated == 1 ? "" : "s") to repository")
            }
            if gitStats.filesChanged > 0 {
                items.append("Modified \(gitStats.filesChanged) file\(gitStats.filesChanged == 1 ? "" : "s") (+\(gitStats.insertions)/-\(gitStats.deletions) lines)")
            }
        } else if !context.filesTouched.isEmpty {
            let count = context.filesTouched.count
            let preview = context.filesTouched.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            items.append("Updated \(count) file\(count == 1 ? "" : "s"): \(preview)\(count > 3 ? "…" : "")")
        }

        // Parse test execution from tools
        let testTools = context.toolsUsed.filter { $0.localizedCaseInsensitiveContains("test") }
        if !testTools.isEmpty {
            items.append("Executed automated test verification suites")
        }

        // Extract key sentence from last assistant message or prompt summary
        if let lastMsg = context.lastAssistantMessage, !lastMsg.isEmpty {
            let lines = lastMsg.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("```") }
            if let firstMeaningful = lines.first(where: { $0.count > 15 && !$0.contains("http") }) {
                items.append(firstMeaningful)
            }
        } else if !context.promptSummary.isEmpty {
            items.append("Objective: \(context.promptSummary)")
        }

        if items.isEmpty {
            items.append("Session completed successfully")
        }

        return items
    }

    // MARK: - LLM-Assisted Accomplishment Extraction

    private func extractAccomplishmentsWithLLM(
        context: SynthesisContext,
        llmClient: SummaryLLMClient,
        settings: SummarySettingsSnapshot,
        apiKey: String
    ) async -> [String]? {
        var prompt = """
        You are an expert engineering reviewer inspecting an AI agent CLI session transcript.
        Extract a concise punchlist of 2 to 4 bullet points stating what was ACTUALLY accomplished.
        Focus on concrete technical deliverables (e.g. tests written, bugs fixed, models migrated, APIs called).
        Do NOT include conversational fluff or pleasantries.

        Session details:
        - Project: \(context.projectName)
        - Files modified: \(context.filesTouched.prefix(15).joined(separator: ", "))
        - Tools used: \(context.toolsUsed.prefix(15).joined(separator: ", "))
        - Prompt / Goal: \(context.promptSummary)
        """

        if let lastMsg = context.lastAssistantMessage, !lastMsg.isEmpty {
            let truncated = String(lastMsg.prefix(800))
            prompt += "\n- Agent final summary: \(truncated)"
        }

        prompt += """
        \n\nReturn strict JSON with this schema:
        {
          "accomplishments": [
            "Concise accomplishment bullet 1",
            "Concise accomplishment bullet 2"
          ]
        }
        """

        let rawResponse = await llmClient.callOpenAICompatibleCompletion(
            baseURL: settings.localBaseURL.isEmpty ? "https://openrouter.ai/api/v1" : settings.localBaseURL,
            apiKey: apiKey,
            model: settings.openRouterPrimaryModel.isEmpty ? "anthropic/claude-3.5-haiku" : settings.openRouterPrimaryModel,
            prompt: prompt,
            timeout: 8.0,
            maxOutputTokens: 250,
            includeOpenRouterHeaders: true
        )

        guard let rawResponse else { return nil }

        let jsonText = Self.cleanJSONResponse(rawResponse)
        guard let data = jsonText.data(using: .utf8) else { return nil }

        struct Output: Decodable {
            let accomplishments: [String]
        }

        if let parsed = try? JSONDecoder().decode(Output.self, from: data), !parsed.accomplishments.isEmpty { // try?-ok(malformed LLM output falls back to deterministic extraction)
            return parsed.accomplishments
        }
        return nil
    }

    static func cleanJSONResponse(_ rawResponse: String) -> String {
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
