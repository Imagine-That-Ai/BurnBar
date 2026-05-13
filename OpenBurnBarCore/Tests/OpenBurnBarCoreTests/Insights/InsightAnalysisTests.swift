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
        XCTAssertFalse(result.generatedWidgets.isEmpty)
        XCTAssertFalse(result.followUpQuestions.isEmpty)
        XCTAssertFalse(result.resultHash.isEmpty)
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
        XCTAssertEqual(result.resultHash, "selected-gateway-result")
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
