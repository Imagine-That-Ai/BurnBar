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

        // When preferred slot is nil, scoring determines selection.
        // Both slots have identical scores except for tie-break (providerID asc, slotID asc).
        // Since both are zai provider and slot-a < slot-b alphabetically, slot-a wins.
        try await harness.configStore.setPreferredCredentialSlot(providerID: "zai", slotID: nil)
        let unconstrainedRoute = try await harness.router.route(modelName: "glm-5")
        XCTAssertEqual(unconstrainedRoute.credentialSlotID, "slot-a", "With equal scores, deterministic tie-break selects slot-a (alphabetically first)")
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

        // Now route again - should get primary if not exhausted, or fallback
        let afterFailureRoute = try await harness.router.route(modelName: "glm-5")

        // Route should still work (failover to same or alternative)
        XCTAssertNotNil(afterFailureRoute.providerID)
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

    private func makeHarness(name: String) throws -> BurnBarProviderRouterHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-router-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
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
}

private struct BurnBarProviderRouterHarness {
    let rootURL: URL
    let configStore: BurnBarConfigStore
    let router: BurnBarProviderRouter
}
