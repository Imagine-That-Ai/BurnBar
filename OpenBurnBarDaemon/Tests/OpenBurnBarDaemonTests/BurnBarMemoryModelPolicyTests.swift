import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// `daemon.memory.model_policy` tells the Python memory engine what it may
/// use: Pro state, consented providers with their retention class and the
/// models per purpose, CLI consent, and a scoped gateway token.
final class BurnBarMemoryModelPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let catalogSupport = BurnBarProviderCatalogSupport(catalog: BurnBarCatalogLoader.bundledCatalog)

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func membership(active: Bool = true, ageDays: Double = 0) -> BurnBarMembershipSnapshot {
        BurnBarMembershipSnapshot(
            tier: active ? "pro" : "free",
            entitlementIds: active ? ["burnbar_pro"] : [],
            restoreAvailable: true,
            state: active ? .active : .offline,
            daemonCacheKey: "entitlements/test",
            source: "local_cache",
            updatedAt: iso(now.addingTimeInterval(-ageDays * 86_400))
        )
    }

    private func snapshot(
        enabled: Bool = true,
        providers: [String] = ["openrouter"],
        clis: [String] = ["claude_cli"],
        allowed: [String: [String]] = [:]
    ) -> BurnBarProviderConfigurationSnapshot {
        var snapshot = BurnBarProviderConfigurationSnapshot(providers: [])
        snapshot.memoryEgress = BurnBarMemoryEgressPolicy(
            enabled: enabled,
            consentedProviderIDs: providers,
            consentedCLIProviderIDs: clis,
            allowedModelIDsByPurpose: allowed,
            requireNoRetention: true,
            dailyCapUSD: 2.0,
            updatedAt: now
        )
        return snapshot
    }

    func test_usablePolicyListsConsentedProvidersWithDefaultsAndMintsAToken() async {
        let store = BurnBarGatewayScopedTokenStore(now: { self.now }, ttl: 900)
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot(),
            membership: membership(),
            catalogSupport: catalogSupport,
            tokenStore: store,
            gatewayURL: "http://127.0.0.1:8317",
            now: now
        )
        XCTAssertTrue(response.proActive)
        XCTAssertTrue(response.enabled)
        XCTAssertNil(response.code)
        XCTAssertEqual(response.gatewayURL, "http://127.0.0.1:8317")
        XCTAssertEqual(response.gatewayToken?.count, 64)
        XCTAssertNotNil(response.tokenExpiresAt)
        XCTAssertEqual(response.cli, ["claude_cli": true, "codex_cli": false])
        XCTAssertEqual(response.providers.map(\.id), ["openrouter"])
        let openrouter = response.providers[0]
        XCTAssertTrue(openrouter.consented)
        XCTAssertEqual(openrouter.retention, "deny")
        XCTAssertEqual(openrouter.purposes["memory-extract"], ["anthropic/claude-opus-5", "anthropic/claude-haiku-4-5", "openai/gpt-5.5"])
        XCTAssertEqual(openrouter.purposes["memory-embed"], ["openai/text-embedding-3-small"])
        XCTAssertEqual(openrouter.purposes["memory-rerank"], ["anthropic/claude-haiku-4-5"])
        XCTAssertEqual(openrouter.purposes["memory-answer"], openrouter.purposes["memory-extract"])
        let token = try? XCTUnwrap(response.gatewayToken)
        if let token {
            let valid = await store.validate(token: token, purpose: "memory-answer", now: now)
            let notForModels = await store.validate(token: token, purpose: "models", now: now)
            XCTAssertTrue(valid)
            XCTAssertFalse(notForModels)
        }
    }

    func test_staleMembershipIsProRequiredWithoutAToken() async {
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot(),
            membership: membership(ageDays: 8),
            catalogSupport: catalogSupport,
            tokenStore: BurnBarGatewayScopedTokenStore(now: { self.now }),
            gatewayURL: "http://127.0.0.1:8317",
            now: now
        )
        XCTAssertFalse(response.proActive)
        XCTAssertEqual(response.code, "PRO_REQUIRED")
        XCTAssertNil(response.gatewayToken)
        XCTAssertEqual(response.providers.map(\.id), ["openrouter"], "consent state is still reported so the UI can explain")
    }

    func test_disabledPolicyIsConsentRequiredWithoutAToken() async {
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot(enabled: false),
            membership: membership(),
            catalogSupport: catalogSupport,
            tokenStore: BurnBarGatewayScopedTokenStore(now: { self.now }),
            gatewayURL: "http://127.0.0.1:8317",
            now: now
        )
        XCTAssertTrue(response.proActive)
        XCTAssertFalse(response.enabled)
        XCTAssertEqual(response.code, "CLOUD_CONSENT_REQUIRED")
        XCTAssertNil(response.gatewayToken)
    }

    func test_unknownProvidersAreDroppedAndOverridesReplaceDefaults() async {
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot(providers: ["openrouter", "not-a-provider", "vercel-ai-gateway"], clis: ["codex_cli", "bogus_cli"],
                               allowed: ["memory-extract": ["openai/gpt-5.5"]]),
            membership: membership(),
            catalogSupport: catalogSupport,
            tokenStore: BurnBarGatewayScopedTokenStore(now: { self.now }),
            gatewayURL: "http://127.0.0.1:8317",
            now: now
        )
        XCTAssertEqual(response.providers.map(\.id), ["openrouter", "vercel-ai-gateway"])
        XCTAssertEqual(response.providers[0].purposes["memory-extract"], ["openai/gpt-5.5"])
        XCTAssertEqual(response.providers[1].retention, "provider-policy")
        XCTAssertEqual(response.cli, ["claude_cli": false, "codex_cli": true])
    }

    func test_noGatewayMeansNoTokenButCLIsStillWork() async {
        let response = await BurnBarMemoryModelPolicy.assemble(
            snapshot: snapshot(providers: [], clis: ["claude_cli"]),
            membership: membership(),
            catalogSupport: catalogSupport,
            tokenStore: nil,
            gatewayURL: nil,
            now: now
        )
        XCTAssertNil(response.gatewayURL)
        XCTAssertNil(response.gatewayToken)
        XCTAssertNil(response.code)
        XCTAssertTrue(response.cli["claude_cli"] ?? false)
    }
}
