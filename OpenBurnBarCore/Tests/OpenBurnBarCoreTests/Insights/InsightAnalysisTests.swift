import XCTest
@testable import OpenBurnBarCore

final class InsightAnalysisTests: XCTestCase {

    func testAggregatorBuildsBudgetAndEvidenceIndex() throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )

        XCTAssertGreaterThan(context.budgetReport.encodedBytes, 0)
        XCTAssertGreaterThan(context.budgetReport.estimatedPromptTokens, 0)
        XCTAssertLessThanOrEqual(context.budgetReport.encodedBytes, InsightDigest.maxEncodedBytes)
        XCTAssertTrue(context.evidenceIndex.contains { $0.source == "provider_summaries" })
        XCTAssertTrue(context.evidenceIndex.contains { $0.source == "quota_snapshots" })
    }

    func testRuleBasedAnalysisReturnsStructuredFindingsAndWidgets() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        let request = InsightAnalysisRequest(
            prompt: "Why did cost spike this week?",
            context: context,
            selectedModel: .init(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            instruction: .answerFollowUp
        )

        let result = try await RuleBasedInsightAnalysisEngine(platform: .macOS).analyze(request)

        XCTAssertEqual(result.requestID, request.id)
        XCTAssertFalse(result.executiveSummary.isEmpty)
        XCTAssertFalse(result.findings.isEmpty)
        XCTAssertFalse(result.findings.flatMap(\.evidence).isEmpty)
        XCTAssertFalse(result.missionCandidates.isEmpty)
        XCTAssertTrue(result.missionCandidates.contains { $0.lens == .accretion })
        XCTAssertTrue(result.missionCandidates.contains { $0.lens == .diligence || $0.lens == .techDebt })
        XCTAssertTrue(result.missionCandidates.allSatisfy { !$0.acceptanceCriteria.isEmpty && !$0.evidence.isEmpty })
        XCTAssertFalse(result.generatedWidgets.isEmpty)
        XCTAssertFalse(result.followUpQuestions.isEmpty)
        XCTAssertFalse(result.resultHash.isEmpty)
    }

    /// Regression: an `.answerFollowUp` request must produce a
    /// non-nil `briefingAnswer` with the user's question echoed back,
    /// a non-empty data-grounded body, and at least one chip. Without
    /// this, the Q&A card above the brief stays empty and the user
    /// sees a follow-up tap as a no-op.
    func testRuleBasedAnalysisProducesBriefingAnswerForFollowUp() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        let model = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let engine = RuleBasedInsightAnalysisEngine(platform: .iOS)
        let prompt = "Why did cost spike this week?"
        let result = try await engine.analyze(
            .init(prompt: prompt, context: context, selectedModel: model, instruction: .answerFollowUp)
        )
        let answer = try XCTUnwrap(result.briefingAnswer,
                                   "Engine must surface a briefingAnswer for .answerFollowUp prompts so the UI Q&A card has content.")
        XCTAssertEqual(answer.question, prompt)
        XCTAssertFalse(answer.answer.isEmpty,
                       "Reply body must not be empty — the card needs visible answer text.")
        XCTAssertFalse(answer.bullets.isEmpty,
                       "Reply must surface data-grounded points to prove it's computed from the digest.")
        XCTAssertEqual(answer.source, .localRules,
                       "Local-rules path must declare its provenance honestly so the UI can label it.")
        // The local rules engine flags the "no LLM configured" case in the
        // display name so the UI can avoid claiming an LLM "answered" the
        // question. See `RuleBasedInsightAnalysisEngine.analyze` honesty
        // check.
        XCTAssertEqual(answer.modelDisplayName, "Local rules · no LLM configured")
        XCTAssertTrue(answer.answer.localizedCaseInsensitiveContains("local rules") ||
                      answer.answer.localizedCaseInsensitiveContains("connect a model"),
                      "Local-rules reply body should make clear it isn't an LLM answer.")
        XCTAssertFalse(answer.isFallback,
                       "Direct local-rules answer is not a fallback; only gateway failures get isFallback=true.")
    }

    /// Regression: the default brief (instruction == .defaultBrief)
    /// must NOT carry a `briefingAnswer`, so the Q&A card is hidden
    /// when there's no user question to reply to (first launch).
    func testRuleBasedAnalysisDefaultBriefOmitsBriefingAnswer() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries"]
        )
        let model = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let result = try await RuleBasedInsightAnalysisEngine(platform: .iOS).analyze(
            .init(prompt: "Default brief.", context: context, selectedModel: model, instruction: .defaultBrief)
        )
        XCTAssertNil(result.briefingAnswer,
                     "Default brief must not carry a Q&A reply card — it isn't answering a question.")
    }

    /// Regression: each canonical follow-up prompt must produce a
    /// distinct executive summary so tapping different questions
    /// doesn't render identical briefs. Catches the bug where the
    /// engine ignored `request.prompt` and the only thing that
    /// changed was the audit ID + result hash.
    func testRuleBasedAnalysisExecutiveSummaryRespondsToPrompt() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        let model = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let engine = RuleBasedInsightAnalysisEngine(platform: .iOS)
        let prompts = [
            "Why did cost spike this week?",
            "Which project or workflow wasted the most money?",
            "Which model should I route routine work to instead?",
            "Which benchmarked model is cheapest at similar performance?",
            "Which model should handle UI and design tasks?",
            "Find quota risks in the next 24 hours."
        ]
        var summaries: [String] = []
        for prompt in prompts {
            let result = try await engine.analyze(
                .init(prompt: prompt, context: context, selectedModel: model, instruction: .answerFollowUp)
            )
            summaries.append(result.executiveSummary)
        }
        let uniqueSummaries = Set(summaries)
        XCTAssertEqual(uniqueSummaries.count, prompts.count,
                       "Expected one distinct executive summary per prompt; got \(uniqueSummaries.count) unique out of \(prompts.count). Summaries: \(summaries)")
    }

    /// Regression test: every generated widget surfaced by the
    /// rule-based engine must carry a non-`nil` `data` payload so the
    /// Editorial Observatory brief paints real charts on first render
    /// (no empty chrome waiting for a canvas refresh).
    func testRuleBasedAnalysisGeneratedWidgetsCarryDataForRendering() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        let request = InsightAnalysisRequest(
            prompt: "Default brief, please.",
            context: context,
            selectedModel: .init(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            instruction: .defaultBrief
        )
        let result = try await RuleBasedInsightAnalysisEngine(platform: .macOS).analyze(request)

        XCTAssertFalse(result.generatedWidgets.isEmpty)
        for generated in result.generatedWidgets {
            XCTAssertNotNil(
                generated.widget.data,
                "Generated widget '\(generated.widget.title)' (\(generated.widget.kind)) must include synthesized data so the brief renders content, not just chrome."
            )
        }

        // The fixture includes provider, daily-cost and quota signal so
        // we expect at least one ranking, one time series, and a quota
        // pulse to be present and populated.
        let kinds = Set(result.generatedWidgets.map(\.widget.kind))
        XCTAssertTrue(kinds.contains(.barRanking) || kinds.contains(.timeSeriesLine) || kinds.contains(.quotaPulse),
                      "Brief should include at least one chart-bearing widget for this fixture.")

        for generated in result.generatedWidgets {
            switch generated.widget.data {
            case .ranking(let ranking):
                XCTAssertFalse(ranking.rows.isEmpty, "Ranking widgets must have rows.")
            case .timeSeries(let series):
                XCTAssertFalse(series.series.isEmpty, "Time series widgets must have at least one series.")
                XCTAssertGreaterThanOrEqual(series.series.first?.points.count ?? 0, 2,
                                            "Time series widgets need ≥2 points to plot a line.")
            case .quota(let quota):
                XCTAssertFalse(quota.buckets.isEmpty, "Quota pulse widgets must have buckets.")
            default:
                break
            }
        }
    }

    func testRuleBasedAnalysisUsesBenchmarkEvidenceForModelRecommendations() async throws {
        var snapshot = InsightTestFixtures.twoWeeksOfUsage()
        snapshot.modelBenchmarks = [
            .init(
                id: "aa-gpt-55-coding",
                source: "artificial_analysis",
                sourceURL: "https://artificialanalysis.ai/",
                attribution: "Artificial Analysis",
                fetchedAt: snapshot.generatedAt,
                modelID: "gpt-5.5",
                providerID: "openai",
                taskCategory: "coding",
                score: 0.91,
                rank: 1,
                costSignal: 0.28,
                confidence: 0.82,
                freshness: "fresh",
                blendedCostPerMtoken: 8.50
            ),
            .init(
                id: "da-ui-model-design",
                source: "design_arena",
                sourceURL: "https://www.designarena.ai/",
                attribution: "Design Arena",
                fetchedAt: snapshot.generatedAt,
                modelID: "ui-fast-model",
                providerID: "openai",
                taskCategory: "design",
                score: 0.88,
                rank: 2,
                costSignal: 0.74,
                confidence: 0.78,
                freshness: "fresh",
                blendedCostPerMtoken: 1.25
            )
        ]
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries", "model_benchmarks"]
        )
        let request = InsightAnalysisRequest(
            prompt: "Which model should I use?",
            context: context,
            selectedModel: .init(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            instruction: .defaultBrief
        )

        let result = try await RuleBasedInsightAnalysisEngine(platform: .iOS).analyze(request)

        XCTAssertTrue(result.contextBudget.includedDataSources.contains("model_benchmarks"))
        XCTAssertTrue(result.citations.contains { citation in
            if case .benchmark = citation.kind { return true }
            return false
        })
        XCTAssertTrue(result.findings.contains { $0.title.contains("UI/design") })
        XCTAssertTrue(result.recommendations.contains { $0.title.contains("cheaper") || $0.rationale.contains("cost signal") })
        XCTAssertTrue(result.generatedWidgets.contains { $0.widget.title == "Benchmark-aware model board" })
    }

    func testOrchestratedEngineWritesAuditAndCachesResult() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries"]
        )
        let model = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let request = InsightAnalysisRequest(
            prompt: "Default brief, please.",
            context: context,
            selectedModel: model,
            instruction: .defaultBrief
        )

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ob-analysis-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let audit = InsightAnalysisAuditLog(fileURL: tempDir.appendingPathComponent("audit.jsonl"))
        let cache = InsightAnalysisCache(directoryURL: tempDir.appendingPathComponent("cache", isDirectory: true))

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .iOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .iOS),
            auditLog: audit,
            cache: cache
        )

        let firstResult = try await engine.analyze(request)
        XCTAssertEqual(firstResult.requestID, request.id)
        XCTAssertNotNil(firstResult.auditID, "Orchestrator should stamp the audit id on the result.")
        XCTAssertFalse(firstResult.resultHash.isEmpty)

        let auditRows = try await audit.readAll(limit: 10)
        XCTAssertEqual(auditRows.count, 1, "Only one audit row per requestID.")
        XCTAssertEqual(auditRows.first?.status, .succeeded)
        XCTAssertEqual(auditRows.first?.resultHash, firstResult.resultHash)
        XCTAssertEqual(auditRows.first?.platform, .iOS)
        XCTAssertFalse(auditRows.first?.promptHash.isEmpty ?? true)

        let cacheKey = InsightAnalysisCache.key(
            prompt: request.prompt,
            digestContentHash: request.context.digest.contentHash,
            modelID: model.modelID,
            instruction: request.instruction
        )
        let cached = await cache.lookup(key: cacheKey)
        XCTAssertEqual(cached?.result.id, firstResult.id, "Second call should hit cache.")

        let secondResult = try await engine.analyze(request)
        XCTAssertEqual(secondResult.id, firstResult.id, "Cache hit returns the same result instance.")
        let auditRowsAfter = try await audit.readAll(limit: 10)
        XCTAssertEqual(auditRowsAfter.count, 1, "Cache hits should not write a new audit row.")
    }

    func testOrchestratedEngineDispatchesSelectedGateway() async throws {
        struct SelectedGatewayStub: InsightModelGateway {
            let providerKey = "selected-stub"
            let displayName = "Selected Stub"
            let capabilities = InsightModelCapabilities(supportsStrictJSONSchema: true)

            func availableModels() async throws -> [InsightCatalogModel] {
                [
                    .init(
                        id: "selected-stub-model",
                        displayName: "Selected Stub Model",
                        providerKey: providerKey,
                        egressTier: .userKey,
                        capabilities: capabilities
                    )
                ]
            }

            func investigate(
                request: InsightInvestigateRequest,
                tools: InsightToolBroker?
            ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.finish()
                }
            }

            func analyze(
                request: InsightAnalysisRequest,
                platform: InsightAnalysisPlatform,
                tools: InsightToolBroker?
            ) async throws -> InsightAnalysisResult {
                let now = Date()
                return InsightAnalysisResult(
                    requestID: request.id,
                    platform: platform,
                    timeWindow: .last7d,
                    executiveSummary: "Selected gateway produced this analysis.",
                    modelTag: request.selectedModel,
                    contextBudget: request.context.budgetReport,
                    citations: request.context.evidenceIndex.map(\.citation),
                    tokenUsage: .init(
                        providerKey: providerKey,
                        modelID: request.selectedModel.modelID,
                        inputTokens: 11,
                        outputTokens: 7,
                        startedAt: now,
                        completedAt: now
                    ),
                    resultHash: "selected-gateway-result"
                )
            }
        }

        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries"]
        )
        let selectedModel = InsightModelTag(
            providerKey: "selected-stub",
            modelID: "selected-stub-model",
            displayName: "Selected Stub Model",
            egressTier: .userKey
        )
        let request = InsightAnalysisRequest(
            prompt: "Use the selected model.",
            context: context,
            selectedModel: selectedModel,
            instruction: .answerFollowUp
        )

        let catalog = InsightModelCatalog()
        await catalog.register(SelectedGatewayStub())
        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            catalog: catalog,
            configuration: .init(privacyModeRestrictsToLocal: false)
        )

        let result = try await engine.analyze(request)

        XCTAssertEqual(result.modelTag.providerKey, "selected-stub")
        XCTAssertEqual(result.executiveSummary, "Selected gateway produced this analysis.")
        XCTAssertEqual(result.tokenUsage?.inputTokens, 11)
        XCTAssertFalse(result.missionCandidates.isEmpty)
        XCTAssertNotEqual(result.resultHash, "selected-gateway-result")
    }

    func testCacheKeyIsStableAcrossEquivalentInputs() {
        let a = InsightAnalysisCache.key(
            prompt: "What changed this week?",
            digestContentHash: "abc123",
            modelID: "claude-sonnet-4-6",
            instruction: .defaultBrief
        )
        let b = InsightAnalysisCache.key(
            prompt: "What changed this week?",
            digestContentHash: "abc123",
            modelID: "claude-sonnet-4-6",
            instruction: .defaultBrief
        )
        let c = InsightAnalysisCache.key(
            prompt: "What changed this week?",
            digestContentHash: "abc123",
            modelID: "claude-sonnet-4-6",
            instruction: .answerFollowUp
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testProviderFamilyCatalogGroupsAndSortsByFamily() {
        let strict = InsightModelCapabilities(
            supportsStrictJSONSchema: true,
            supportsJSONObject: true,
            supportsThinking: true,
            supportsToolUse: true,
            supportsStreaming: true
        )
        let basic = InsightModelCapabilities(
            supportsStrictJSONSchema: false,
            supportsJSONObject: true,
            supportsThinking: false,
            supportsToolUse: false,
            supportsStreaming: true
        )
        let claude = InsightCatalogModel(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            providerKey: "anthropic",
            egressTier: .userKey,
            capabilities: strict
        )
        let ollama = InsightCatalogModel(
            id: "llama3",
            displayName: "Llama 3",
            providerKey: "ollama",
            egressTier: .localOnly,
            capabilities: basic
        )
        let kimi = InsightCatalogModel(
            id: "kimi-k2",
            displayName: "Kimi K2",
            providerKey: "moonshot",
            egressTier: .userKey,
            capabilities: basic
        )
        let unknown = InsightCatalogModel(
            id: "mystery-model",
            displayName: "Mystery",
            providerKey: "custom",
            egressTier: .userKey,
            capabilities: basic
        )

        let entries = InsightProviderFamilyCatalog.entries(
            from: [claude, ollama, kimi, unknown],
            automaticDefault: (providerKey: "anthropic", modelID: "claude-sonnet-4-6")
        )

        XCTAssertEqual(entries.first?.family, .ollama, "Local-only families sort first.")
        XCTAssertTrue(entries.contains { $0.family == .claude && $0.isAutomaticDefault })
        XCTAssertTrue(entries.contains { $0.family == .kimi })
        XCTAssertTrue(entries.contains { $0.family == .other }, "Unknown provider falls through to .other.")

        let grouped = InsightProviderFamilyCatalog.grouped(entries)
        XCTAssertEqual(grouped.map { $0.family }, [.ollama, .claude, .kimi, .other])
    }

    func testProviderFamilyMatcherToleratesPunctuation() {
        XCTAssertEqual(
            InsightProviderFamilyCatalog.family(forProviderKey: "Claude-Code", modelID: "claude-sonnet-4-6"),
            .claude
        )
        XCTAssertEqual(
            InsightProviderFamilyCatalog.family(forProviderKey: "z.ai", modelID: "glm-4.5"),
            .zai
        )
        XCTAssertEqual(
            InsightProviderFamilyCatalog.family(forProviderKey: "open_ai", modelID: "gpt-5"),
            .openai
        )
        XCTAssertEqual(
            InsightProviderFamilyCatalog.family(forProviderKey: "ollama", modelID: "phi-3"),
            .ollama
        )
        XCTAssertEqual(
            InsightProviderFamilyCatalog.family(forProviderKey: "unknown", modelID: "llama-3"),
            .ollama,
            "Model id sniffing should win when provider key is unknown."
        )
    }

    func testIntelligenceBriefFormattingProducesStableLabels() {
        XCTAssertEqual(IntelligenceBriefFormatting.windowLabel(.last7d), "Last 7 days")
        XCTAssertEqual(IntelligenceBriefFormatting.windowLabel(.today), "Today")

        let budget = InsightContextBudgetReport(
            encodedBytes: 5_120,
            estimatedPromptTokens: 1_280,
            includedDataSources: ["firestore_rollups"],
            truncatedDataSources: ["provider_summaries"],
            truncationSummary: "trimmed"
        )
        let budgetLabel = IntelligenceBriefFormatting.budgetLabel(budget)
        XCTAssertTrue(budgetLabel.contains("~5 KB"), "Expected '\(budgetLabel)' to include byte estimate.")
        XCTAssertTrue(budgetLabel.contains("trimmed"))

        let usage = InsightTokenUsage(
            providerKey: "anthropic",
            modelID: "claude-sonnet-4-6",
            inputTokens: 1_200,
            outputTokens: 400,
            reasoningTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            estimatedCostUSD: 0.0234,
            startedAt: Date(timeIntervalSince1970: 0),
            completedAt: Date(timeIntervalSince1970: 2)
        )
        let usageLabel = IntelligenceBriefFormatting.tokenUsageLabel(usage, cost: 0.0234)
        XCTAssertTrue(usageLabel.contains("1600 tokens"))
        XCTAssertTrue(usageLabel.contains("$0.0234"))
    }

    func testModelPreferenceDefaultsAreSafe() {
        let pref = InsightModelPreference.default
        XCTAssertEqual(pref.mode, .automatic)
        XCTAssertFalse(pref.deepTranscriptOptIn)
        XCTAssertFalse(pref.restrictToLocalOnly)
        XCTAssertNil(pref.explicitModel)
    }

    func testAuditEntryRoundTripsThroughJSON() throws {
        let entry = InsightAnalysisAuditEntry(
            requestID: UUID(),
            platform: .android,
            selectedModel: .init(
                providerKey: "ollama",
                modelID: "llama3",
                displayName: "Llama 3",
                egressTier: .localOnly
            ),
            egressTier: .localOnly,
            timeWindow: .last7d,
            contextBudget: InsightContextBudgetReport(
                encodedBytes: 1024,
                estimatedPromptTokens: 256,
                includedDataSources: ["firestore_rollups"],
                truncatedDataSources: [],
                truncationSummary: "No truncation."
            ),
            includedDataSources: ["firestore_rollups"],
            truncationSummary: "No truncation.",
            promptHash: "deadbeef",
            resultHash: "cafebabe",
            status: .succeeded
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(InsightAnalysisAuditEntry.self, from: data)

        XCTAssertEqual(restored.id, entry.id)
        XCTAssertEqual(restored.requestID, entry.requestID)
        XCTAssertEqual(restored.status, .succeeded)
        XCTAssertEqual(restored.includedDataSources, entry.includedDataSources)
    }

    func testAnalysisResultRoundTripsAndMaterializesCanvas() async throws {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "quota_snapshots", "provider_summaries"]
        )
        let request = InsightAnalysisRequest(
            prompt: "Generate a report for this month.",
            context: context,
            selectedModel: .init(
                providerKey: "local-rules",
                modelID: "local-rules-v1",
                displayName: "Local rules",
                egressTier: .localOnly
            ),
            instruction: .generateReport
        )
        let result = try await RuleBasedInsightAnalysisEngine(platform: .iPadOS).analyze(request)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(InsightAnalysisResult.self, from: data)
        let canvas = RuleBasedInsightAnalysisEngine.materializeCanvas(from: restored, prompt: request.prompt)

        XCTAssertEqual(restored.id, result.id)
        XCTAssertEqual(canvas.widgets.count, restored.generatedWidgets.count)
        XCTAssertEqual(canvas.modelTag, restored.modelTag)
        XCTAssertEqual(canvas.origin, .composed(prompt: request.prompt))
    }
}
