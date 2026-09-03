import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// The gate every memory-purpose request passes before it leaves the Mac,
/// in this order: Pro, master switch, provider consent, retention, budget.
final class BurnBarMemoryEgressEnforcerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeConfigStore() throws -> BurnBarConfigStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-egress-enforcer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BurnBarConfigStore(
            fileURL: root.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "memory-egress-enforcer-tests")
        )
    }

    private func writePolicy(_ policy: BurnBarMemoryEgressPolicy, to store: BurnBarConfigStore) async throws {
        var snapshot = try await store.snapshot()
        snapshot.memoryEgress = policy
        _ = try await store.replaceSnapshot(snapshot)
    }

    private func enforcer(
        store: BurnBarConfigStore,
        proActive: Bool = true,
        spentTodayUSD: Double = 0
    ) -> BurnBarMemoryEgressEnforcer {
        BurnBarMemoryEgressEnforcer(
            configStore: store,
            membership: FakeMembershipService(active: proActive, now: now),
            tokenStore: BurnBarGatewayScopedTokenStore(now: { self.now }),
            log: BurnBarMemoryEgressLogStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("memory-egress-\(UUID().uuidString).jsonl", isDirectory: false)),
            spentTodayUSD: { _ in spentTodayUSD },
            now: { self.now }
        )
    }

    private func expectDenial(_ code: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)")
        } catch let denial as BurnBarMemoryEgressDenial {
            XCTAssertEqual(denial.code, code)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_denialsFireInOrderThenAllow() async throws {
        let store = try makeConfigStore()
        try await writePolicy(BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter"], requireNoRetention: true, dailyCapUSD: 2), to: store)

        await expectDenial("PRO_REQUIRED") { try await self.enforcer(store: store, proActive: false).evaluate(purpose: .extract, providerID: "openrouter") }

        try await writePolicy(BurnBarMemoryEgressPolicy(enabled: false, consentedProviderIDs: ["openrouter"]), to: store)
        await expectDenial("CLOUD_CONSENT_REQUIRED") { try await self.enforcer(store: store).evaluate(purpose: .extract, providerID: "openrouter") }

        try await writePolicy(BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter"]), to: store)
        await expectDenial("PROVIDER_NOT_CONSENTED") { try await self.enforcer(store: store).evaluate(purpose: .extract, providerID: "anthropic") }

        try await writePolicy(BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["openrouter", "vercel-ai-gateway"], requireNoRetention: true), to: store)
        await expectDenial("EGRESS_BLOCKED_RETENTION") { try await self.enforcer(store: store).evaluate(purpose: .extract, providerID: "vercel-ai-gateway") }

        await expectDenial("BUDGET_EXCEEDED") { try await self.enforcer(store: store, spentTodayUSD: 2.5).evaluate(purpose: .extract, providerID: "openrouter") }

        try await enforcer(store: store, spentTodayUSD: 1.99).evaluate(purpose: .embed, providerID: "openrouter")
    }

    func test_vercelIsAllowedWhenRetentionRequirementIsOff() async throws {
        let store = try makeConfigStore()
        try await writePolicy(BurnBarMemoryEgressPolicy(enabled: true, consentedProviderIDs: ["vercel-ai-gateway"], requireNoRetention: false), to: store)
        try await enforcer(store: store).evaluate(purpose: .answer, providerID: "vercel-ai-gateway")
    }

    func test_scopedTokensValidateOnlyForMemoryPurposes() async throws {
        let store = try makeConfigStore()
        let subject = enforcer(store: store)
        let minted = await subject.tokenStore.mint(purposes: ["memory-extract"])
        let ok = await subject.validateToken(minted.token, purpose: .extract)
        let wrong = await subject.validateToken(minted.token, purpose: .answer)
        XCTAssertTrue(ok)
        XCTAssertFalse(wrong)
    }

    func test_recordAppendsOneContentFreeEntryPerRequest() async throws {
        let store = try makeConfigStore()
        let subject = enforcer(store: store)
        await subject.record(purpose: .extract, providerID: "openrouter", modelID: "anthropic/claude-opus-5", requestBytes: 10, responseBytes: 20, outcome: "allowed", code: nil, latencyMs: 5)
        await subject.record(purpose: .judge, providerID: "openrouter", modelID: "anthropic/claude-opus-5", requestBytes: 0, responseBytes: 0, outcome: "denied", code: "BUDGET_EXCEEDED", latencyMs: 0)
        let entries = try await subject.log.entries()
        XCTAssertEqual(entries.map(\.outcome), ["allowed", "denied"])
        XCTAssertEqual(entries[0].retention, "deny")
        let verification = try await subject.log.verify()
        XCTAssertTrue(verification.ok)
    }
}

struct FakeMembershipService: BurnBarMembershipServing {
    let active: Bool
    let now: Date

    func status() async -> BurnBarMembershipStatusResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return BurnBarMembershipStatusResponse(membership: BurnBarMembershipSnapshot(
            tier: active ? "pro" : "free",
            entitlementIds: active ? ["burnbar_pro"] : [],
            restoreAvailable: true,
            state: active ? .active : .offline,
            daemonCacheKey: "entitlements/test",
            source: "local_cache",
            updatedAt: formatter.string(from: now)
        ))
    }

    func checkoutURL(_ request: BurnBarMembershipCheckoutURLRequest) async throws -> BurnBarMembershipCheckoutURLResponse {
        throw BurnBarMembershipServiceError.unauthenticated
    }

    func portalURL(_ request: BurnBarMembershipPortalURLRequest) async throws -> BurnBarMembershipPortalURLResponse {
        throw BurnBarMembershipServiceError.unauthenticated
    }

    func restore() async -> BurnBarMembershipRestoreResponse {
        BurnBarMembershipRestoreResponse(ok: false, error: BurnBarMembershipErrorResult(code: .offline, message: "test"))
    }
}
