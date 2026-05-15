import XCTest
@testable import OpenBurnBarCore

/// Regression suite for the Intelligence Brief question path's
/// new contract:
///
///   1. User-owned route succeeded   → `source == .modelGateway`
///   2. User-owned route failed,      hosted picked up
///                                   → `source == .hostedFallback`,
///                                     `isFallback == false`
///   3. Selected model is hosted     → `source == .hostedFallback`
///   4. Hosted also failed           → local rules, `isFallback == true`
///   5. Privacy mode + no local      → local rules, never tries hosted
///   6. Successful user-owned route  → user-owned model display name
///                                     is preserved on the briefing.
///
/// The tests do NOT exercise OpenRouter or Firebase; they stub the
/// hosted adapter through the gateway protocol so the orchestrator
/// logic is verified in isolation. The wire-side hosted adapter is
/// covered by `BurnBarHostedInsightAdapter`'s own integration plan.
final class HostedFallbackTests: XCTestCase {

    // MARK: - Stubs

    /// Lightweight async invocation counter used by the
    /// gateway-invocation-count test. Built on a Swift actor so
    /// the counter is safe to share across the analysis Task.
    private actor InvocationCounter {
        private(set) var value = 0
        func tick() { value += 1 }
    }

    /// Stub `InsightModelGateway` that returns a canned analysis or
    /// throws. Used to mimic both a user-owned route AND the hosted
    /// fallback inside the orchestrator without any network.
    private struct StubGateway: InsightModelGateway {
        let providerKey: String
        let displayName: String
        let capabilities = InsightModelCapabilities(
            supportsStrictJSONSchema: false,
            supportsJSONObject: true,
            supportsThinking: false,
            supportsToolUse: false,
            supportsStreaming: false
        )
        let modelID: String
        let egressTier: InsightEgressTier
        let executiveSummary: String
        let throwingError: Error?
        /// Optional side-effect callback invoked at the top of
        /// every `analyze(...)`. Lets tests count invocations
        /// against the gateway without mocking URLSession.
        let onAnalyze: (@Sendable () async -> Void)?

        init(
            providerKey: String,
            displayName: String,
            modelID: String,
            egressTier: InsightEgressTier,
            executiveSummary: String,
            throwingError: Error?,
            onAnalyze: (@Sendable () async -> Void)? = nil
        ) {
            self.providerKey = providerKey
            self.displayName = displayName
            self.modelID = modelID
            self.egressTier = egressTier
            self.executiveSummary = executiveSummary
            self.throwingError = throwingError
            self.onAnalyze = onAnalyze
        }

        func availableModels() async throws -> [InsightCatalogModel] {
            [
                .init(
                    id: modelID,
                    displayName: displayName,
                    providerKey: providerKey,
                    egressTier: egressTier,
                    capabilities: capabilities
                )
            ]
        }

        func investigate(
            request: InsightInvestigateRequest,
            tools: InsightToolBroker?
        ) -> AsyncThrowingStream<InsightInvestigateEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func analyze(
            request: InsightAnalysisRequest,
            platform: InsightAnalysisPlatform,
            tools: InsightToolBroker?
        ) async throws -> InsightAnalysisResult {
            await onAnalyze?()
            if let throwingError {
                throw throwingError
            }
            let citation = InsightCitation(kind: .query(text: "stub"), label: "Stub evidence")
            return InsightAnalysisResult(
                requestID: request.id,
                platform: platform,
                timeWindow: request.currentCanvas?.filter.window ?? .last7d,
                executiveSummary: executiveSummary,
                modelTag: .init(
                    providerKey: providerKey,
                    modelID: modelID,
                    displayName: displayName,
                    egressTier: egressTier
                ),
                contextBudget: request.context.budgetReport,
                findings: [
                    .init(
                        title: "Stub finding",
                        whyItMatters: "Stub gateway answered.",
                        evidence: [citation],
                        confidence: .high,
                        severity: .info,
                        recommendedAction: "Verify the gateway wiring."
                    )
                ],
                citations: [citation]
            )
        }
    }

    // MARK: - Shared scaffolding

    private func makeRequest(
        prompt: String,
        selected: InsightModelTag
    ) throws -> InsightAnalysisRequest {
        let snapshot = InsightTestFixtures.twoWeeksOfUsage()
        let context = try InsightAggregator().buildContext(
            snapshot: snapshot,
            filter: InsightFilter(window: .last7d),
            includedDataSources: ["datastore_usage", "provider_summaries"]
        )
        return InsightAnalysisRequest(
            prompt: prompt,
            context: context,
            selectedModel: selected,
            instruction: .answerFollowUp,
            allowDeepTranscriptAnalysis: false,
            maxGeneratedWidgets: 4
        )
    }

    private func makeUserModelTag() -> InsightModelTag {
        .init(
            providerKey: "stub-userkey",
            modelID: "stub-userkey-v1",
            displayName: "Stub User Cloud",
            egressTier: .userKey
        )
    }

    private func makeHostedStub(
        throwing: Error? = nil
    ) -> StubGateway {
        StubGateway(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            egressTier: .hosted,
            executiveSummary: "Hosted MiniMax answered with grounded analysis.",
            throwingError: throwing
        )
    }

    // MARK: - Outcome 1: user-owned route answered

    func testUserOwnedGatewayAnswersWithModelGatewaySource() async throws {
        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "User-owned route answered.",
            throwingError: nil
        ))
        await catalog.register(makeHostedStub())

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "Why did cost spike?",
            selected: userTag
        )

        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .modelGateway,
                       "User-owned gateway answered — source must be modelGateway, not hostedFallback.")
        XCTAssertFalse(answer.isFallback,
                       "User-owned answer is not a fallback.")
        XCTAssertEqual(result.modelTag.providerKey, userTag.providerKey)
        XCTAssertEqual(result.modelTag.displayName, userTag.displayName)
    }

    // MARK: - Outcome 2: user-owned route failed → hosted picks up

    func testHostedFallbackTakesOverWhenUserGatewayFails() async throws {
        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        struct UserGatewayError: Error {}
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "(unreachable)",
            throwingError: UserGatewayError()
        ))
        await catalog.register(makeHostedStub())

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "Which provider is the biggest spend driver?",
            selected: userTag
        )

        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .hostedFallback,
                       "User-owned route failed — orchestrator must promote the hosted fallback.")
        XCTAssertFalse(answer.isFallback,
                       "Hosted fallback IS an LLM answer; the `isFallback` flag is reserved for the local-rules degrade.")
        XCTAssertEqual(answer.modelDisplayName, BurnBarHostedInsightAdapter.defaultModelDisplayName)
        XCTAssertEqual(result.modelTag.providerKey, BurnBarHostedInsightAdapter.providerKeyRaw,
                       "Audit must attribute the answer to BurnBar Hosted, not the user's selection.")
        XCTAssertEqual(result.modelTag.egressTier, .hosted)
    }

    // MARK: - Outcome 3: no user route registered → hosted picks up

    func testHostedFallbackUsedWhenNoUserGatewayRegistered() async throws {
        let catalog = InsightModelCatalog()
        await catalog.register(makeHostedStub())
        // Deliberately omit any user-owned gateway. The user's
        // selected model still points at a user-key tier so the
        // orchestrator has to discover the hosted fallback.
        let engine = OrchestratedInsightAnalysisEngine(
            platform: .iOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .iOS),
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "Recommend the next mission.",
            selected: makeUserModelTag()
        )
        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .hostedFallback)
        XCTAssertEqual(result.modelTag.providerKey, BurnBarHostedInsightAdapter.providerKeyRaw)
    }

    // MARK: - Outcome 4: hosted ALSO failed → local rules with disclosure

    func testLocalRulesFallbackWhenHostedAlsoFails() async throws {
        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        struct UserGatewayError: Error {}
        struct HostedError: Error {}
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "(unreachable)",
            throwingError: UserGatewayError()
        ))
        await catalog.register(makeHostedStub(throwing: HostedError()))

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "What changed this week?",
            selected: userTag
        )
        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .localRules,
                       "Both user gateway AND hosted failed — only local rules should answer.")
        XCTAssertTrue(answer.isFallback,
                      "Local-rules-after-LLM-failure must flag isFallback so the UI can show a recovery hint.")
        XCTAssertTrue(answer.modelDisplayName.contains("→ Local rules"),
                      "Display name must disclose the LLM route that was attempted before degrading.")
    }

    // MARK: - Premium gating

    /// When the hosted route refuses the call with the dedicated
    /// `InsightGatewayError.subscriptionRequired` signal (a
    /// free-tier user without BurnBar Pro), the orchestrator MUST
    /// degrade to local rules with the special
    /// `subscriptionRequiredDisplayName` marker so the UI swaps the
    /// generic "Connect your own model" CTA for "Upgrade to BurnBar
    /// Pro".
    func testHostedRouteSubscriptionRequiredLandsOnProUpgradeDisclosure() async throws {
        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        struct UserGatewayError: Error {}
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "(unreachable)",
            throwingError: UserGatewayError()
        ))
        await catalog.register(StubGateway(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            egressTier: .hosted,
            executiveSummary: "(paywalled)",
            throwingError: InsightGatewayError.subscriptionRequired(
                modelID: BurnBarHostedInsightAdapter.defaultModelID,
                productID: "com.openburnbar.hostedQuotaSync.cloud.monthly"
            )
        ))

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .iOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .iOS),
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "Why did cost spike?",
            selected: userTag
        )
        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .localRules,
                       "Subscription gate must degrade to local rules, not surface as hostedFallback.")
        XCTAssertTrue(answer.isFallback,
                      "Hosted route was attempted but blocked — the brief must mark this as a fallback so the UI shows a recovery affordance.")
        XCTAssertEqual(answer.modelDisplayName, InsightBriefingAnswer.subscriptionRequiredDisplayName,
                       "Display name must match the sentinel the UI keys off to swap the CTA to 'Upgrade to BurnBar Pro'.")
        XCTAssertTrue(answer.answer.localizedCaseInsensitiveContains("BurnBar Pro"),
                      "Answer body must disclose the upgrade path so users on screen-reader / accessibility surfaces hear the recovery action even without seeing the CTA button.")
    }

    // MARK: - Cache invariants

    /// When a hosted-fallback turn answers a request that originally
    /// targeted a user-owned model, the cache MUST NOT store that
    /// result under the user's selected-model cache key. Otherwise a
    /// future request — once the user's gateway is back up — would
    /// keep being served the cached hosted answer.
    func testHostedFallbackResultIsNotCachedUnderSelectedModelKey() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-fallback-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = InsightAnalysisCache(directoryURL: tempDir)

        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        struct UserGatewayError: Error {}
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "(unreachable)",
            throwingError: UserGatewayError()
        ))
        await catalog.register(makeHostedStub())

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            cache: cache,
            catalog: catalog
        )
        let request = try makeRequest(
            prompt: "Where did this week's spend go?",
            selected: userTag
        )
        _ = try await engine.analyze(request)

        let cacheKey = InsightAnalysisCache.key(
            prompt: request.prompt,
            digestContentHash: request.context.digest.contentHash,
            modelID: userTag.modelID,
            instruction: request.instruction
        )
        let cached = await cache.lookup(key: cacheKey)
        XCTAssertNil(cached,
                     "Hosted-fallback result must not be cached under the user's selected-model key; the user must get a fresh attempt next turn once their own route is back up.")
    }

    /// When the user explicitly picks `burnbar-hosted` as their
    /// model and isn't subscribed, the orchestrator must call the
    /// hosted gateway exactly ONCE — not bounce through
    /// `tryHostedFallback` for a second 403. Regression for the
    /// 2× server-rejection cost.
    func testExplicitHostedSelectionInvokesGatewayExactlyOnceOnPaywall() async throws {
        let catalog = InsightModelCatalog()
        let counter = InvocationCounter()
        let countingHostedStub = StubGateway(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            egressTier: .hosted,
            executiveSummary: "(paywalled)",
            throwingError: InsightGatewayError.subscriptionRequired(
                modelID: BurnBarHostedInsightAdapter.defaultModelID,
                productID: nil
            ),
            onAnalyze: { await counter.tick() }
        )
        await catalog.register(countingHostedStub)

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .iOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .iOS),
            catalog: catalog
        )
        let explicitHostedTag = InsightModelTag(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            egressTier: .hosted
        )
        let request = try makeRequest(prompt: "Free-tier user picks hosted", selected: explicitHostedTag)
        let result = try await engine.analyze(request)

        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.modelDisplayName, InsightBriefingAnswer.subscriptionRequiredDisplayName,
                       "Result must carry the Pro-upgrade marker even on explicit hosted selection.")
        let invocationCount = await counter.value
        XCTAssertEqual(invocationCount, 1,
                       "Hosted gateway must be invoked exactly once per turn — re-invoking on the same paywalled response is wasted server work.")
    }

    /// Pro is a *live* entitlement — caching a hosted answer would
    /// let a once-subscribed-now-cancelled caller keep getting
    /// hosted answers for the same prompt after they unsubscribe.
    /// The orchestrator must refuse to cache anything stamped by
    /// the BurnBar hosted gateway, even when the user explicitly
    /// picked `burnbar-hosted` as their model (so request and
    /// result match).
    func testHostedRouteResultIsNeverCachedEvenOnExplicitSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-explicit-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = InsightAnalysisCache(directoryURL: tempDir)

        let catalog = InsightModelCatalog()
        await catalog.register(makeHostedStub())

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            cache: cache,
            catalog: catalog
        )
        let explicitHostedTag = InsightModelTag(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            egressTier: .hosted
        )
        let request = try makeRequest(prompt: "Pick hosted directly", selected: explicitHostedTag)
        _ = try await engine.analyze(request)

        let cacheKey = InsightAnalysisCache.key(
            prompt: request.prompt,
            digestContentHash: request.context.digest.contentHash,
            modelID: explicitHostedTag.modelID,
            instruction: request.instruction
        )
        let cached = await cache.lookup(key: cacheKey)
        XCTAssertNil(cached,
                     "Hosted-route results must never be cached. Pro entitlement is live; a cached hosted answer would let a cancelled subscriber keep getting hosted replies for the same prompt indefinitely.")
    }

    /// When a result is stored in the cache (e.g. by a successful
    /// user-owned gateway), and the cache returns it without a
    /// `briefingAnswer`, the orchestrator's synthesizer must
    /// attribute the answer to the right source — `.hostedFallback`
    /// for results stamped by the hosted gateway, `.modelGateway`
    /// otherwise.
    func testCachedHostedResultSurfacesAsHostedFallbackOnLookup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosted-fallback-cache-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cache = InsightAnalysisCache(directoryURL: tempDir)

        let userTag = makeUserModelTag()
        let request = try makeRequest(prompt: "Replay the brief", selected: userTag)

        // Manually seed the cache with a result whose modelTag points
        // at the hosted route and whose briefingAnswer is nil — the
        // exact shape an older client run could have written.
        let hostedModelTag = InsightModelTag(
            providerKey: BurnBarHostedInsightAdapter.providerKeyRaw,
            modelID: BurnBarHostedInsightAdapter.defaultModelID,
            displayName: BurnBarHostedInsightAdapter.defaultModelDisplayName,
            egressTier: .hosted
        )
        let seeded = InsightAnalysisResult(
            requestID: request.id,
            platform: .macOS,
            timeWindow: .last7d,
            executiveSummary: "Hosted route had previously answered.",
            modelTag: hostedModelTag,
            contextBudget: request.context.budgetReport,
            findings: [
                .init(
                    title: "Cached finding",
                    whyItMatters: "Body",
                    evidence: [],
                    confidence: .medium,
                    severity: .info,
                    recommendedAction: "Re-run if needed"
                )
            ],
            citations: [],
            briefingAnswer: nil
        )
        let cacheKey = InsightAnalysisCache.key(
            prompt: request.prompt,
            digestContentHash: request.context.digest.contentHash,
            modelID: userTag.modelID,
            instruction: request.instruction
        )
        try await cache.store(.init(key: cacheKey, result: seeded))

        let catalog = InsightModelCatalog()
        await catalog.register(makeHostedStub())
        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            cache: cache,
            catalog: catalog
        )
        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .hostedFallback,
                       "Cached result whose modelTag.providerKey is 'burnbar-hosted' must surface as a hostedFallback briefing, not a generic modelGateway answer.")
    }

    // MARK: - Outcome 5: privacy mode never tries hosted

    func testPrivacyModeBlocksHostedAndLandsOnLocalRules() async throws {
        let catalog = InsightModelCatalog()
        let userTag = makeUserModelTag()
        struct UserGatewayError: Error {}
        await catalog.register(StubGateway(
            providerKey: userTag.providerKey,
            displayName: userTag.displayName,
            modelID: userTag.modelID,
            egressTier: .userKey,
            executiveSummary: "(unreachable)",
            throwingError: UserGatewayError()
        ))
        await catalog.register(makeHostedStub())

        let engine = OrchestratedInsightAnalysisEngine(
            platform: .macOS,
            fallback: RuleBasedInsightAnalysisEngine(platform: .macOS),
            catalog: catalog,
            configuration: .init(privacyModeRestrictsToLocal: true)
        )
        // Build a local-only model tag — privacy mode would block any
        // non-local egress regardless of the gateway availability.
        let localTag = InsightModelTag(
            providerKey: "local-rules",
            modelID: "local-rules-v1",
            displayName: "Local rules",
            egressTier: .localOnly
        )
        let request = try makeRequest(
            prompt: "Audit anything that touched non-local egress.",
            selected: localTag
        )
        let result = try await engine.analyze(request)
        let answer = try XCTUnwrap(result.briefingAnswer)
        XCTAssertEqual(answer.source, .localRules,
                       "Privacy mode must never escalate to hosted; local rules answers.")
        XCTAssertFalse(answer.isFallback,
                       "Direct local-rules selection isn't a fallback.")
    }
}
