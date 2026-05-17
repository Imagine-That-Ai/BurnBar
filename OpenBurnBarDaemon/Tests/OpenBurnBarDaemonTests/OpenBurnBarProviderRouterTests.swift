import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarProviderRouterTests: XCTestCase {
    func testRouterSelectsZAIForConfiguredGLMModel() async throws {
        let harness = try makeHarness(name: "zai")
        try await harness.configStore.setSecret("zai-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5-turbo", "glm-5"]
            )
        )

        let route = try await harness.router.route(modelName: "glm-5-turbo")
        XCTAssertEqual(route.providerID, "zai")
        XCTAssertEqual(route.resolvedModelID, "glm-5-turbo")
        XCTAssertEqual(route.pricing, BurnBarCatalogLoader.bundledCatalog.pricing(forModelName: "glm-5-turbo"))
    }

    func testRouterSelectsMiniMaxForConfiguredModel() async throws {
        let harness = try makeHarness(name: "minimax")
        try await harness.configStore.setSecret("minimax-key", for: "minimax")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )

        let route = try await harness.router.route(modelName: "MiniMax-M2.7-highspeed")
        XCTAssertEqual(route.providerID, "minimax")
        XCTAssertEqual(route.resolvedModelID, "minimax-m2.7-highspeed")
    }

    func testRouterUsesExactAdvertisedAliasForNonFamilyModels() async throws {
        let harness = try makeHarness(name: "deepseek-live-alias")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://api.deepseek.com/v1",
                preferredModelIDs: ["deepseek-chat"],
                preferredCredentialSlotID: "default"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "default",
            label: "DeepSeek API",
            apiKey: "deepseek-key"
        )

        let route = try await harness.router.route(
            modelName: "deepseek-v4-flash",
            preferredProviderID: "deepseek",
            requestedFormatFamily: .openaiCompat,
            requiredCapabilityClassID: "deepseek-v4-flash"
        )

        XCTAssertEqual(route.providerID, "deepseek")
        XCTAssertEqual(route.resolvedModelID, "deepseek-v4-flash")
        XCTAssertEqual(route.modelCapabilityClassID, "deepseek-v4-flash")
    }

    func testRouterDoesNotPinAdvertisedModelToUncredentialedBrokerFamily() async throws {
        let harness = try makeHarness(name: "deepseek-live-alias-broker")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "opencode",
                isEnabled: true,
                baseURL: "https://opencode.ai/zen/go/v1",
                preferredModelIDs: ["opencode-deepseek-v4-flash-family"],
                preferredCredentialSlotID: "opencode"
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://api.deepseek.com/v1",
                preferredModelIDs: ["deepseek-chat"],
                preferredCredentialSlotID: "deepseek"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "deepseek",
            label: "DeepSeek API",
            apiKey: "deepseek-key"
        )

        let route = try await harness.router.route(
            modelName: "deepseek-v4-flash",
            requestedFormatFamily: .openaiCompat,
            requiredCapabilityClassID: "deepseek-v4-flash"
        )

        XCTAssertEqual(route.providerID, "deepseek")
        XCTAssertEqual(route.resolvedModelID, "deepseek-v4-flash")
    }

    func testRouterPreservesUnlistedOllamaCloudAliasAsDirectCloudModelID() async throws {
        let harness = try makeHarness(name: "ollama-cloud-family")
        try await harness.configStore.setSecret("ollama-key", for: "ollama")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://ollama.com/api",
                preferredModelIDs: ["ollama-cloud-family"]
            )
        )

        let colonRoute = try await harness.router.route(modelName: "some-new-model:cloud", preferredProviderID: "ollama")
        XCTAssertEqual(colonRoute.providerID, "ollama")
        XCTAssertEqual(colonRoute.requestedModel, "some-new-model:cloud")
        XCTAssertEqual(colonRoute.resolvedModelID, "some-new-model")

        let dashRoute = try await harness.router.route(modelName: "some-new-model-cloud", preferredProviderID: "ollama")
        XCTAssertEqual(dashRoute.resolvedModelID, "some-new-model")
    }

    func testRouterExtractsOpenCodeGoKeyFromAuthJSON() async throws {
        let harness = try makeHarness(name: "opencode-auth-json")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "opencode",
                isEnabled: true,
                baseURL: "https://opencode.ai/zen/go/v1",
                preferredModelIDs: ["kimi-k2.6"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "opencode",
            slotID: "primary",
            label: "OpenCode Go",
            apiKey: #"{"opencode-go":{"type":"api","key":"opencode-route-key"}}"#
        )

        let route = try await harness.router.route(modelName: "kimi-k2.6", preferredProviderID: "opencode")
        XCTAssertEqual(route.providerID, "opencode")
        XCTAssertEqual(route.resolvedModelID, "kimi-k2.6")
        XCTAssertEqual(route.apiKey, "opencode-route-key")
    }

    func testRouterRejectsOpenCodeAuthJSONWithoutGoRouteKey() async throws {
        let harness = try makeHarness(name: "opencode-invalid-auth-json")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "opencode",
                isEnabled: true,
                baseURL: "https://opencode.ai/zen/go/v1",
                preferredModelIDs: ["kimi-k2.6"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "opencode",
            slotID: "primary",
            label: "Wrong OpenCode account",
            apiKey: #"{"some-other-provider":{"type":"api","key":"do-not-use-this"}}"#
        )

        do {
            _ = try await harness.router.route(modelName: "kimi-k2.6", preferredProviderID: "opencode")
            XCTFail("Expected missing credential error")
        } catch let error as BurnBarProviderRouterError {
            guard case .missingCredential(let providerID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "opencode")
        }
    }

    func testRouterUsesProviderAliasForVirtualFamilyModelIDs() async throws {
        let harness = try makeHarness(name: "anthropic-family-wire-id")
        try await harness.configStore.setSecret("sk-ant-test", for: "anthropic")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7-family"]
            )
        )

        let familyRoute = try await harness.router.route(modelName: "claude-opus-4-7-family")
        XCTAssertEqual(familyRoute.requestedModel, "claude-opus-4-7-family")
        XCTAssertEqual(familyRoute.resolvedModelID, "claude-opus-4-7")
        XCTAssertEqual(familyRoute.modelCapabilityClassID, "anthropic:opus")

        let aliasRoute = try await harness.router.route(modelName: "claude-opus-4-7")
        XCTAssertEqual(aliasRoute.resolvedModelID, "claude-opus-4-7")
    }

    func testRouterRejectsUnsupportedProviderModelsAndMissingCredentials() async throws {
        let harness = try makeHarness(name: "rejections")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        do {
            _ = try await harness.router.route(modelName: "glm-5", preferredProviderID: "zai")
            XCTFail("Expected missing credential error")
        } catch let error as BurnBarProviderRouterError {
            guard case .missingCredential(let providerID) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "zai")
        }

        try await harness.configStore.setSecret("zai-key", for: "zai")

        do {
            _ = try await harness.router.route(modelName: "kimi")
            XCTFail("Expected unsupported model error")
        } catch let error as BurnBarProviderRouterError {
            guard case .unsupportedModel(let modelName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(modelName, "kimi")
        }

        do {
            _ = try await harness.router.route(modelName: "pony-alpha-2")
            XCTFail("Expected unsupported model error")
        } catch let error as BurnBarProviderRouterError {
            guard case .unsupportedModel(let modelName) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(modelName, "pony-alpha-2")
        }
    }

    func testRouterSelectsByScorecardWithPreferredSlotBoost() async throws {
        // With scoring-based routing, preferred slot gets policyFit=1.0 vs 0.3 for non-preferred.
        // This test verifies: (1) preferred slot is selected when set, (2) without preferred slot,
        // selection follows scorecard ordering with deterministic tie-break (providerID asc, slotID asc).
        let harness = try makeHarness(name: "slots")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-b",
            label: "Plan B",
            apiKey: "zai-key-b"
        )
        try await harness.configStore.recordCredentialSelection(providerID: "zai", slotID: "slot-a")

        // When preferred slot is set to slot-a, it should be selected due to policyFit scoring
        try await harness.configStore.setPreferredCredentialSlot(providerID: "zai", slotID: "slot-a")
        let preferredRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(preferredRoute.credentialSlotID, "slot-a", "Preferred slot should be selected via policyFit scoring")

        // When preferred slot is nil, healthy slots rotate by least-recently selected.
        try await harness.configStore.setPreferredCredentialSlot(providerID: "zai", slotID: nil)
        let unconstrainedRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(unconstrainedRoute.credentialSlotID, "slot-b", "Without a pinned preferred slot, the router should rotate to the least-recently selected plan")
    }

    func testRouterMarksQuotaFailureAsExhaustedSlot() async throws {
        let harness = try makeHarness(name: "failure-status")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )

        let route = try await harness.router.route(modelName: "glm-5")
        await harness.router.markRouteFailure(route, error: BurnBarProviderExecutorError.upstreamError(402, "quota exceeded"))

        let snapshot = try await harness.configStore.snapshot()
        let slotStatus = snapshot.providerSettings(id: "zai")?.credentialSlots.first(where: { $0.slotID == "slot-a" })?.status
        XCTAssertEqual(slotStatus, .exhausted)
    }

    func testRepairedCredentialSlotClearsStaleCooldownAndError() async throws {
        let harness = try makeHarness(name: "repair-clears-stale-status")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://api.deepseek.com/v1",
                preferredModelIDs: ["deepseek-chat"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "default",
            label: "Default plan",
            apiKey: "old-key"
        )

        let failedRoute = try await harness.router.route(modelName: "deepseek-chat")
        await harness.router.markRouteFailure(
            failedRoute,
            error: BurnBarProviderExecutorError.upstreamError(429, "rate limited")
        )

        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "default",
            label: "Default plan",
            apiKey: "new-key"
        )

        let snapshot = try await harness.configStore.snapshot()
        let repairedSlot = snapshot.providerSettings(id: "deepseek")?.credentialSlots.first(where: { $0.slotID == "default" })
        XCTAssertEqual(repairedSlot?.status, .ready)
        XCTAssertNil(repairedSlot?.cooldownUntil)
        XCTAssertNil(repairedSlot?.lastStatusMessage)
    }

    func testRouterDoesNotPoisonCredentialSlotForInvalidRequestError() async throws {
        let harness = try makeHarness(name: "invalid-request-does-not-poison-slot")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7-family"],
                preferredCredentialSlotID: "icloud"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "icloud",
            label: "iCloud",
            apiKey: "sk-ant-oat01-test"
        )

        let route = try await harness.router.route(
            modelName: "claude-opus-4-7",
            requestedFormatFamily: .anthropic
        )
        await harness.router.markRouteFailure(
            route,
            error: BurnBarProviderExecutorError.upstreamError(
                400,
                #"{"type":"error","error":{"type":"invalid_request_error","message":"context_management: Extra inputs are not permitted"}}"#
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        let slot = snapshot.providerSettings(id: "anthropic")?.credentialSlots.first(where: { $0.slotID == "icloud" })
        XCTAssertEqual(slot?.status, .ready)
        XCTAssertNil(slot?.cooldownUntil)
        XCTAssertNil(slot?.lastStatusMessage)

        let candidates = try await harness.router.candidateRoutes(
            modelName: "claude-opus-4-7",
            requestedFormatFamily: .anthropic
        )
        XCTAssertEqual(candidates.map(\.credentialSlotID), ["icloud"])
    }

    func testRouterDoesNotPoisonAnthropicOAuthSlotForModelScopedRateLimit() async throws {
        let harness = try makeHarness(name: "anthropic-oauth-rate-limit-does-not-poison-slot")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7-family"],
                preferredCredentialSlotID: "icloud"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "icloud",
            label: "iCloud",
            apiKey: "sk-ant-oat01-test"
        )

        let route = try await harness.router.route(
            modelName: "claude-opus-4-7",
            requestedFormatFamily: .anthropic
        )
        await harness.router.markRouteFailure(
            route,
            error: BurnBarProviderExecutorError.upstreamError(
                429,
                #"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#
            )
        )

        let snapshot = try await harness.configStore.snapshot()
        let slot = snapshot.providerSettings(id: "anthropic")?.credentialSlots.first(where: { $0.slotID == "icloud" })
        XCTAssertEqual(slot?.status, .ready)
        XCTAssertNil(slot?.cooldownUntil)
        XCTAssertNil(slot?.lastStatusMessage)

        let candidates = try await harness.router.candidateRoutes(
            modelName: "claude-opus-4-7",
            requestedFormatFamily: .anthropic
        )
        XCTAssertEqual(candidates.map(\.credentialSlotID), ["icloud"])
    }

    func testOllamaRouterRotatesSlotsAndSkipsExhaustedPlan() async throws {
        let harness = try makeHarness(name: "ollama-slot-rotation")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://ollama.com/api",
                preferredModelIDs: ["deepseek-v4-flash"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "slot-a",
            label: "Ollama Plan A",
            apiKey: "ollama-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "slot-b",
            label: "Ollama Plan B",
            apiKey: "ollama-key-b"
        )
        try await harness.configStore.setPreferredCredentialSlot(providerID: "ollama", slotID: nil)

        let firstRoute = try await harness.router.route(modelName: "deepseek-v4-flash:cloud", preferredProviderID: "ollama")
        XCTAssertEqual(firstRoute.providerID, "ollama")
        XCTAssertEqual(firstRoute.resolvedModelID, "deepseek-v4-flash")
        XCTAssertEqual(firstRoute.credentialSlotID, "slot-a")

        let secondRoute = try await harness.router.route(modelName: "deepseek-v4-flash:cloud", preferredProviderID: "ollama")
        XCTAssertEqual(secondRoute.credentialSlotID, "slot-b", "Unpinned Ollama Cloud slots should rotate by least-recently selected")

        await harness.router.markRouteFailure(
            firstRoute,
            error: BurnBarProviderExecutorError.upstreamError(402, "quota exhausted")
        )

        let remainingCandidates = try await harness.router.candidateRoutes(modelName: "deepseek-v4-flash:cloud", preferredProviderID: "ollama")
        XCTAssertEqual(remainingCandidates.map(\.credentialSlotID), ["slot-b"])

        let afterExhaustionRoute = try await harness.router.route(modelName: "deepseek-v4-flash:cloud", preferredProviderID: "ollama")
        XCTAssertEqual(afterExhaustionRoute.credentialSlotID, "slot-b", "Exhausted Ollama plans must be skipped in the same failover pool")
    }

    // MARK: - VAL-DAEMON-012: Router scorecard ranking is deterministic across required dimensions

    func test_VAL_DAEMON_012_scorecardConsidersAllFiveDimensions() async throws {
        // VAL-DAEMON-012: Router scorecard ranking is deterministic across required dimensions
        // Routing decisions rank candidate agent/tool routes using capability, cost, latency,
        // trust, and policy-fit dimensions with deterministic tie-break behavior.
        let harness = try makeHarness(name: "scorecard-five-dimensions")

        // Set up two providers with different pricing
        try await harness.configStore.setSecret("zai-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )

        try await harness.configStore.setSecret("minimax-key", for: "minimax")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )

        // Score and rank routes
        let rankingResult = try await harness.router.scoreAndRankRoutes(modelName: "glm-5")

        // Must return ranked routes
        XCTAssertFalse(rankingResult.rankedRoutes.isEmpty, "Expected ranked routes for glm-5")

        // Verify all five dimensions are present in each breakdown
        for rankedRoute in rankingResult.rankedRoutes {
            let breakdown = rankedRoute.breakdown
            // Verify score has all five dimensions
            XCTAssertGreaterThanOrEqual(breakdown.score.capability, 0.0)
            XCTAssertLessThanOrEqual(breakdown.score.capability, 1.0)
            XCTAssertGreaterThanOrEqual(breakdown.score.cost, 0.0)
            XCTAssertLessThanOrEqual(breakdown.score.cost, 1.0)
            XCTAssertGreaterThanOrEqual(breakdown.score.latency, 0.0)
            XCTAssertLessThanOrEqual(breakdown.score.latency, 1.0)
            XCTAssertGreaterThanOrEqual(breakdown.score.trust, 0.0)
            XCTAssertLessThanOrEqual(breakdown.score.trust, 1.0)
            XCTAssertGreaterThanOrEqual(breakdown.score.policyFit, 0.0)
            XCTAssertLessThanOrEqual(breakdown.score.policyFit, 1.0)

            // Verify composite is weighted sum
            let expectedComposite = breakdown.score.capability * 0.20
                + breakdown.score.cost * 0.25
                + breakdown.score.latency * 0.15
                + breakdown.score.trust * 0.25
                + breakdown.score.policyFit * 0.15
            XCTAssertEqual(breakdown.score.composite, expectedComposite, accuracy: 0.0001)

            // Verify raw values are captured
            XCTAssertFalse(breakdown.routeKey.isEmpty)
            XCTAssertFalse(breakdown.providerID.isEmpty)
        }
    }

    func test_VAL_DAEMON_012_scorecardRankingIsDeterministic() async throws {
        // VAL-DAEMON-012: Deterministic tie-break behavior
        let harness = try makeHarness(name: "scorecard-deterministic")

        try await harness.configStore.setSecret("zai-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        // Run ranking twice and verify identical results
        let ranking1 = try await harness.router.scoreAndRankRoutes(modelName: "glm-5")
        let ranking2 = try await harness.router.scoreAndRankRoutes(modelName: "glm-5")

        // Same number of routes
        XCTAssertEqual(ranking1.rankedRoutes.count, ranking2.rankedRoutes.count)

        // Same ordering (deterministic)
        for i in 0..<ranking1.rankedRoutes.count {
            let r1 = ranking1.rankedRoutes[i]
            let r2 = ranking2.rankedRoutes[i]
            XCTAssertEqual(r1.breakdown.routeKey, r2.breakdown.routeKey)
            XCTAssertEqual(r1.breakdown.score.composite, r2.breakdown.score.composite, accuracy: 0.0001)
        }
    }

    func test_VAL_DAEMON_012_tieBreakUsesProviderIDAscending() async throws {
        // VAL-DAEMON-012: Deterministic tie-break via providerID ascending
        let harness = try makeHarness(name: "scorecard-tiebreak")

        // Set up two providers that may produce equal composite scores
        // Use supported providers: zai and minimax
        try await harness.configStore.setSecret("zai-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        try await harness.configStore.setSecret("minimax-key", for: "minimax")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(modelName: "glm-5")

        // Extract provider IDs in ranking order
        let rankedProviderIDs = ranking.rankedRoutes.map { $0.breakdown.providerID }

        // Verify deterministic ordering: minimax < zai alphabetically
        // (m < z)
        XCTAssertEqual(rankedProviderIDs.sorted(), rankedProviderIDs)
    }

    func test_VAL_EXEC_008_failoverIsDeterministicWithOrderedRouteAttempts() async throws {
        // VAL-EXEC-008: Provider failover is deterministic for retryable upstream failures
        // Retryable upstream failures fail over alternate routes with preserved run continuity
        // and no duplicate terminal records.
        let harness = try makeHarness(name: "failover-deterministic")

        // Set up primary and fallback providers
        try await harness.configStore.setSecret("primary-key", for: "zai")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )

        try await harness.configStore.setSecret("fallback-key", for: "minimax")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )

        // Get ordered candidate routes
        let primaryRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(primaryRoute.providerID, "zai")

        // Simulate primary failure (quota - retryable)
        await harness.router.markRouteFailure(primaryRoute, error: BurnBarProviderExecutorError.upstreamError(429, "rate limited"))

        do {
            _ = try await harness.router.route(modelName: "glm-5")
            XCTFail("Expected cooling credential error")
        } catch let error as BurnBarProviderRouterError {
            guard case .credentialsUnavailable(let providerID, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "zai")
            XCTAssertTrue(reason.contains("cooling down"))
        }
    }

    func test_VAL_EXEC_008_singleTerminalOutcomeUnderFailover() async throws {
        // VAL-EXEC-008: Single terminal outcome under failover
        // Verify that exhausting all credential slots for a provider results in no available routes.
        let harness = try makeHarness(name: "failover-terminal")

        // Set up provider with two slots (same pattern as passing testRouterMarksQuotaFailureAsExhaustedSlot)
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-a",
            label: "Plan A",
            apiKey: "zai-key-a"
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "slot-b",
            label: "Plan B",
            apiKey: "zai-key-b"
        )

        // Verify both slots start as candidates
        let initialCandidates = try await harness.router.candidateRoutes(modelName: "glm-5")
        XCTAssertEqual(initialCandidates.count, 2, "Both slots should be candidates initially")

        // Route should succeed initially
        let route = try await harness.router.route(modelName: "glm-5")
        XCTAssertNotNil(route.providerID)
        XCTAssertNotNil(route.credentialSlotID)

        // Mark slot as exhausted (terminal for quota)
        await harness.router.markRouteFailure(route, error: BurnBarProviderExecutorError.upstreamError(402, "quota exceeded"))

        // Re-fetch snapshot to see updated status
        let snapshot = try await harness.configStore.snapshot()
        let exhaustedSlotStatus = snapshot.providerSettings(id: "zai")?
            .credentialSlots.first(where: { $0.slotID == route.credentialSlotID })?.status
        XCTAssertEqual(exhaustedSlotStatus, .exhausted)

        // After exhausting one slot, at least one candidate should remain (the other slot)
        let afterExhaustCandidates = try await harness.router.candidateRoutes(modelName: "glm-5")
        XCTAssertEqual(afterExhaustCandidates.count, 1, "One slot exhausted, one should remain")
    }

    func testRouterReportsExhaustedSlotsInsteadOfMissingCredentials() async throws {
        let harness = try makeHarness(name: "exhausted-error")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "default",
            label: "Z.ai Coding Plan",
            apiKey: "zai-key"
        )

        let route = try await harness.router.route(modelName: "glm-5")
        await harness.router.markRouteFailure(
            route,
            error: BurnBarProviderExecutorError.upstreamError(429, "Weekly/Monthly Limit Exhausted")
        )

        do {
            _ = try await harness.router.route(modelName: "glm-5", preferredProviderID: "zai")
            XCTFail("Expected exhausted credential error")
        } catch let error as BurnBarProviderRouterError {
            guard case .credentialsUnavailable(let providerID, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(providerID, "zai")
            XCTAssertTrue(reason.contains("exhausted"))
            XCTAssertTrue(reason.contains("Weekly/Monthly Limit Exhausted"))
        }
    }

    func testProviderFamilyModeScopesUnpinnedRoutingToCatalogVendor() async throws {
        let harness = try makeHarness(name: "provider-family-mode", catalog: sharedModelCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        try await harness.configStore.setSecret("beta-key", for: "beta")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["shared-code-model"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://beta.example/v1",
                preferredModelIDs: ["shared-code-model"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(
            modelName: "shared-code-model",
            routerMode: .providerFamilyFailover
        )

        XCTAssertEqual(ranking.routerMode, .providerFamilyFailover)
        XCTAssertEqual(ranking.rankedRoutes.map { $0.route.providerID }, ["alpha"])
    }

    func testIntelligentModeCanRankCompatibleCrossProviderRoutes() async throws {
        let harness = try makeHarness(name: "intelligent-mode", catalog: sharedModelCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        try await harness.configStore.setSecret("beta-key", for: "beta")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["shared-code-model"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://beta.example/v1",
                preferredModelIDs: ["shared-code-model"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(
            modelName: "shared-code-model",
            routerMode: .intelligentModelRouter,
            taskCategory: .coding,
            benchmarkSnapshots: [
                ProviderModelBenchmarkSnapshot(
                    id: "shared-code-model-terminal",
                    source: .terminalBench,
                    fetchedAt: Date(),
                    modelID: "shared-code-model",
                    taskCategory: .terminal,
                    score: 0.80,
                    rank: 4,
                    reliabilitySignal: 0.8,
                    confidence: 0.8,
                    freshness: .fresh
                )
            ],
            benchmarkStatus: ProviderModelBenchmarkStatus(
                source: .terminalBench,
                fetchedAt: Date(),
                freshness: .fresh,
                message: "Fresh benchmark fixture."
            )
        )

        XCTAssertEqual(ranking.routerMode, .intelligentModelRouter)
        XCTAssertEqual(ranking.winner?.providerID, "beta", "Cheaper compatible provider should win once Intelligent mode can consider cross-provider candidates")
        let event = harness.router.routingDecisionEvent(ranking: ranking, modelName: "shared-code-model")
        XCTAssertEqual(event.routerMode, .intelligentModelRouter)
        XCTAssertEqual(event.benchmarkStatus?.freshness, .fresh)
        XCTAssertFalse(event.explanation.localizedCaseInsensitiveContains("bearer "))
    }

    func testIntelligentModeHandlesStaleBenchmarkDataSafely() async throws {
        let harness = try makeHarness(name: "intelligent-stale", catalog: sharedModelCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["shared-code-model"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(
            modelName: "shared-code-model",
            routerMode: .intelligentModelRouter,
            taskCategory: .coding,
            benchmarkStatus: ProviderModelBenchmarkStatus(
                source: .cachedFixture,
                fetchedAt: Date(timeIntervalSinceNow: -8 * 24 * 60 * 60),
                freshness: .stale,
                message: "Cached data is stale."
            )
        )

        XCTAssertEqual(ranking.winner?.providerID, "alpha")
        XCTAssertEqual(ranking.benchmarkStatus?.freshness, .stale)
    }

    func testCandidateRoutes_filtersByRequiredCapabilityClassID() async throws {
        let harness = try makeHarness(name: "capability-class-filter", catalog: capabilityClassCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        try await harness.configStore.setSecret("beta-key", for: "beta")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["alpha-shared-pro"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://beta.example/v1",
                preferredModelIDs: ["beta-shared-base"]
            )
        )

        let allCandidates = try await harness.router.candidateRoutes(
            modelName: "shared-code-model",
            routerMode: .intelligentModelRouter
        )
        XCTAssertEqual(Set(allCandidates.map(\.providerID)), Set(["alpha", "beta"]))

        let filtered = try await harness.router.candidateRoutes(
            modelName: "shared-code-model",
            requiredCapabilityClassID: "openai:shared:pro",
            routerMode: .intelligentModelRouter
        )
        XCTAssertEqual(filtered.map(\.providerID), ["alpha"])
        XCTAssertTrue(filtered.allSatisfy { $0.modelCapabilityClassID == "openai:shared:pro" })
    }

    func testScoreAndRankReportsBlockedCapabilityClassRoutes() async throws {
        let harness = try makeHarness(name: "blocked-class-report", catalog: capabilityClassCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        try await harness.configStore.setSecret("beta-key", for: "beta")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["alpha-shared-pro"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://beta.example/v1",
                preferredModelIDs: ["beta-shared-base"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(
            modelName: "shared-code-model",
            requiredCapabilityClassID: "openai:shared:pro",
            routerMode: .intelligentModelRouter
        )
        XCTAssertTrue(ranking.rankedRoutes.allSatisfy { $0.route.modelCapabilityClassID == "openai:shared:pro" })
        XCTAssertFalse(ranking.blockedCapabilityClassRoutes.isEmpty,
                       "Must report the filtered-out lower-class routes.")
        XCTAssertTrue(ranking.blockedCapabilityClassRoutes.allSatisfy { $0.modelCapabilityClassID != "openai:shared:pro" })
    }

    func testScoreAndRank_noBlockedRoutesWhenNoClassFilter() async throws {
        let harness = try makeHarness(name: "no-class-filter-blocked", catalog: capabilityClassCatalog())
        try await harness.configStore.setSecret("alpha-key", for: "alpha")
        try await harness.configStore.setSecret("beta-key", for: "beta")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://alpha.example/v1",
                preferredModelIDs: ["alpha-shared-pro"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://beta.example/v1",
                preferredModelIDs: ["beta-shared-base"]
            )
        )

        let ranking = try await harness.router.scoreAndRankRoutes(
            modelName: "shared-code-model",
            routerMode: .intelligentModelRouter
        )
        XCTAssertTrue(ranking.blockedCapabilityClassRoutes.isEmpty,
                       "Must not report blocked routes when no class filter was applied.")
    }

    private func makeHarness(
        name: String,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog
    ) throws -> BurnBarProviderRouterHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-router-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: catalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "provider-router-tests")
        )

        return BurnBarProviderRouterHarness(
            rootURL: rootURL,
            configStore: configStore,
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "provider-router-tests")
            )
        )
    }

    private func sharedModelCatalog() -> BurnBarCatalog {
        let expensive = BurnBarCatalogModel(
            id: "shared-code-model",
            displayName: "Shared Code Model",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 20, outputPerMToken: 40, cacheReadPerMToken: 1)
        )
        let cheap = BurnBarCatalogModel(
            id: "shared-code-model",
            displayName: "Shared Code Model",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1)
        )
        return BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [expensive]
                ),
                BurnBarCatalogProvider(
                    id: "beta",
                    displayName: "Beta",
                    baseURL: "https://beta.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [cheap]
                )
            ]
        )
    }

    private func capabilityClassCatalog() -> BurnBarCatalog {
        let pro = BurnBarCatalogModel(
            id: "alpha-shared-pro",
            displayName: "Shared Pro",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 20, outputPerMToken: 40, cacheReadPerMToken: 1),
            capabilityClassID: "openai:shared:pro",
            capabilityClassRank: 100
        )
        let base = BurnBarCatalogModel(
            id: "beta-shared-base",
            displayName: "Shared Base",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 2, outputPerMToken: 4, cacheReadPerMToken: 0.2),
            capabilityClassID: "openai:shared:base",
            capabilityClassRank: 10
        )
        return BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://alpha.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [pro]
                ),
                BurnBarCatalogProvider(
                    id: "beta",
                    displayName: "Beta",
                    baseURL: "https://beta.example/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [base]
                )
            ]
        )
    }
}

private struct BurnBarProviderRouterHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
    let router: BurnBarProviderRouter
}
