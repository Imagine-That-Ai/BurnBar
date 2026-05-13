import XCTest
@testable import OpenBurnBarCore

final class InsightLiveProviderSmokeTests: XCTestCase {

    func testLiveOllamaInsightAnalysisWhenEnabled() async throws {
        try XCTSkipUnless(Self.liveRunsEnabled, "Set OPENBURNBAR_RUN_LIVE_INSIGHTS=1 to run live provider smoke tests.")

        let session = Self.liveURLSession(timeout: 180)
        let adapter = OllamaInsightAdapter(urlSession: session, numPredict: 2_200)
        let models = try await adapter.availableModels()
        let modelID = Self.env("OPENBURNBAR_LIVE_OLLAMA_MODEL") ?? models.first?.id
        guard let modelID, !modelID.isEmpty else {
            throw XCTSkip("Ollama is reachable but did not advertise a model.")
        }

        let tag = InsightModelTag(
            providerKey: "ollama",
            modelID: modelID,
            displayName: modelID,
            egressTier: .localOnly
        )
        let result = try await adapter.analyze(
            request: Self.liveRequest(selectedModel: tag),
            platform: .macOS,
            tools: nil
        )

        Self.assertLiveResult(result, provider: "ollama")
    }

    func testLiveZAIInsightAnalysisWhenEnabled() async throws {
        try XCTSkipUnless(Self.liveRunsEnabled, "Set OPENBURNBAR_RUN_LIVE_INSIGHTS=1 to run live provider smoke tests.")
        try XCTSkipUnless(Self.env("OPENBURNBAR_RUN_LIVE_ZAI") == "1", "Set OPENBURNBAR_RUN_LIVE_ZAI=1 to spend Z.ai credits.")
        guard let apiKey = Self.env("ZAI_API_KEY") ?? Self.env("ZHIPUAI_API_KEY") else {
            throw XCTSkip("ZAI_API_KEY or ZHIPUAI_API_KEY is not set.")
        }

        let modelID = Self.env("OPENBURNBAR_LIVE_ZAI_MODEL") ?? "glm-4.6"
        let baseURL = URL(string: Self.env("INSIGHTS_ZAI_BASE_URL") ?? "https://open.bigmodel.cn")!
        let capabilities = InsightModelCapabilities(
            supportsStrictJSONSchema: false,
            supportsJSONObject: true,
            supportsThinking: false,
            supportsToolUse: false,
            supportsStreaming: true
        )
        let adapter = OpenAICompatibleInsightAdapter(
            providerKey: "zai",
            displayName: "Z.ai",
            apiKey: apiKey,
            baseURL: baseURL,
            modelCatalog: [
                .init(
                    id: modelID,
                    displayName: modelID,
                    providerKey: "zai",
                    egressTier: .userKey,
                    capabilities: capabilities,
                    symbolName: "brain.head.profile"
                )
            ],
            urlSession: Self.liveURLSession(timeout: 90),
            chatCompletionsPath: "/api/paas/v4/chat/completions",
            maxTokens: 900
        )
        let tag = InsightModelTag(
            providerKey: "zai",
            modelID: modelID,
            displayName: modelID,
            egressTier: .userKey
        )

        let result = try await adapter.analyze(
            request: Self.liveRequest(selectedModel: tag),
            platform: .macOS,
            tools: nil
        )

        Self.assertLiveResult(result, provider: "zai")
    }

    private static var liveRunsEnabled: Bool {
        env("OPENBURNBAR_RUN_LIVE_INSIGHTS") == "1"
    }

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func liveURLSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    private static func liveRequest(selectedModel: InsightModelTag) throws -> InsightAnalysisRequest {
        let now = Date()
        let start = now.addingTimeInterval(-7 * 24 * 3600)
        let usages = [
            InsightUsageRow(
                sessionID: "live-cost-baseline",
                provider: "Codex",
                model: "gpt-5.5",
                projectName: "/Users/me/app",
                deviceID: "device-A",
                deviceName: "Alberto's Mac",
                startTime: start.addingTimeInterval(3600),
                endTime: start.addingTimeInterval(4200),
                inputTokens: 8_000,
                outputTokens: 2_000,
                reasoningTokens: 500,
                cacheReadTokens: 1_000,
                cacheCreationTokens: 120,
                totalTokens: 11_620,
                costUSD: 0.18
            ),
            InsightUsageRow(
                sessionID: "live-cost-spike",
                provider: "Claude Code",
                model: "claude-sonnet-4-6",
                projectName: "/Users/me/app",
                deviceID: "device-A",
                deviceName: "Alberto's Mac",
                startTime: now.addingTimeInterval(-3600),
                endTime: now.addingTimeInterval(-3000),
                inputTokens: 42_000,
                outputTokens: 12_000,
                reasoningTokens: 3_000,
                cacheReadTokens: 0,
                cacheCreationTokens: 4_000,
                totalTokens: 61_000,
                costUSD: 2.80
            )
        ]
        let sessions = [
            InsightSessionRow(
                sessionID: "live-cost-baseline",
                provider: "Codex",
                projectName: "/Users/me/app",
                startTime: usages[0].startTime,
                endTime: usages[0].endTime,
                messageCount: 4,
                inferredTaskTitle: "Triage small bug",
                keyTools: ["read", "grep"],
                keyCommands: ["git diff"],
                keyFiles: []
            ),
            InsightSessionRow(
                sessionID: "live-cost-spike",
                provider: "Claude Code",
                projectName: "/Users/me/app",
                startTime: usages[1].startTime,
                endTime: usages[1].endTime,
                messageCount: 18,
                inferredTaskTitle: "Deep architecture analysis",
                keyTools: ["read", "grep", "test"],
                keyCommands: ["swift test"],
                keyFiles: []
            )
        ]
        let quota = InsightQuotaBucket(
            providerKey: "anthropic",
            providerDisplayName: "Claude Code",
            bucketName: "5h",
            used: 0.86,
            limit: 1.0,
            resetsAt: now.addingTimeInterval(45 * 60),
            sourceKind: "officialAPI",
            confidence: "high"
        )
        let snapshot = InsightDataSnapshot(
            window: DateInterval(start: start, end: now),
            generatedAt: now,
            usages: usages,
            sessions: sessions,
            quotaBuckets: [quota]
        )
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        return InsightAnalysisRequest(
            prompt: "Live provider smoke test. Identify the main cost change, why it matters, and one next action. Return compact JSON only.",
            context: context,
            selectedModel: selectedModel,
            instruction: .defaultBrief,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 2
        )
    }

    private static func assertLiveResult(
        _ result: InsightAnalysisResult,
        provider: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.modelTag.providerKey, provider, file: file, line: line)
        XCTAssertFalse(result.executiveSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file: file, line: line)
        XCTAssertFalse(result.resultHash.isEmpty, file: file, line: line)
        XCTAssertFalse(result.citations.isEmpty, file: file, line: line)
        XCTAssertTrue(
            !result.findings.isEmpty || !result.recommendations.isEmpty || !result.anomalies.isEmpty,
            "Live result should include at least one analytical object.",
            file: file,
            line: line
        )
        print("LIVE_INSIGHTS_OK provider=\(provider) model=\(result.modelTag.modelID) findings=\(result.findings.count) recommendations=\(result.recommendations.count) widgets=\(result.generatedWidgets.count) inputTokens=\(result.tokenUsage?.inputTokens ?? -1) outputTokens=\(result.tokenUsage?.outputTokens ?? -1)")
    }
}
