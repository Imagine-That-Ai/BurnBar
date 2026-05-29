import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Coverage for the opt-in cross-vendor degrade safety net (Part B3).
final class BurnBarCrossVendorDegradeTests: XCTestCase {
    // MARK: - Policy

    func testPolicyDisabledByDefaultFromEmptyEnvironment() {
        let policy = BurnBarCrossVendorDegradePolicy.fromEnvironment([:])
        XCTAssertFalse(policy.isEnabled)
    }

    func testPolicyEnabledViaEnvironmentFlag() {
        for value in ["1", "true", "yes", "on", "ON", "True"] {
            let policy = BurnBarCrossVendorDegradePolicy.fromEnvironment([
                "OPENBURNBAR_CROSS_VENDOR_DEGRADE": value
            ])
            XCTAssertTrue(policy.isEnabled, "expected \(value) to enable degrade")
            XCTAssertEqual(policy.allowedVendorIDs, BurnBarCrossVendorDegradePolicy.defaultVendorIDs)
        }
    }

    func testPolicyIgnoresUnrecognizedFlagValue() {
        let policy = BurnBarCrossVendorDegradePolicy.fromEnvironment([
            "OPENBURNBAR_CROSS_VENDOR_DEGRADE": "maybe"
        ])
        XCTAssertFalse(policy.isEnabled)
    }

    func testPolicyNarrowsVendorAllowlistFromEnvironment() {
        let policy = BurnBarCrossVendorDegradePolicy.fromEnvironment([
            "OPENBURNBAR_CROSS_VENDOR_DEGRADE": "1",
            "OPENBURNBAR_CROSS_VENDOR_DEGRADE_VENDORS": " DeepSeek , ZAI "
        ])
        XCTAssertTrue(policy.isEnabled)
        XCTAssertEqual(policy.allowedVendorIDs, ["deepseek", "zai"])
        XCTAssertTrue(policy.allows(providerID: "DeepSeek"))
        XCTAssertFalse(policy.allows(providerID: "moonshot"))
    }

    // MARK: - Router degrade routes

    func testDegradeRoutesEmptyWhenPolicyDisabled() async throws {
        let harness = try makeHarness(name: "degrade-disabled")
        try await configureDeepSeek(harness)

        let routes = try await harness.router.crossVendorDegradeRoutes(policy: .disabled)
        XCTAssertTrue(routes.isEmpty)
    }

    func testDegradeRoutesReturnsAllowlistedVendorsWhenEnabled() async throws {
        let harness = try makeHarness(name: "degrade-enabled")
        try await configureDeepSeek(harness)
        try await configureZAI(harness)

        let policy = BurnBarCrossVendorDegradePolicy(
            isEnabled: true,
            allowedVendorIDs: ["deepseek", "zai"],
            preferredModelByVendorID: ["deepseek": "deepseek-chat", "zai": "glm-5-turbo"]
        )
        let routes = try await harness.router.crossVendorDegradeRoutes(policy: policy)

        let providerIDs = Set(routes.map { $0.route.providerID })
        XCTAssertTrue(providerIDs.contains("deepseek"))
        XCTAssertTrue(providerIDs.contains("zai"))
        XCTAssertTrue(routes.allSatisfy { $0.route.formatFamily == .openaiCompat })
        XCTAssertTrue(routes.contains { $0.route.resolvedModelID == "deepseek-chat" })
        XCTAssertTrue(routes.contains { $0.route.resolvedModelID == "glm-5-turbo" })
    }

    func testDegradeRoutesRespectVendorAllowlist() async throws {
        let harness = try makeHarness(name: "degrade-allowlist")
        try await configureDeepSeek(harness)
        try await configureZAI(harness)

        let policy = BurnBarCrossVendorDegradePolicy(
            isEnabled: true,
            allowedVendorIDs: ["deepseek"],
            preferredModelByVendorID: ["deepseek": "deepseek-chat"]
        )
        let routes = try await harness.router.crossVendorDegradeRoutes(policy: policy)

        XCTAssertFalse(routes.isEmpty)
        XCTAssertTrue(routes.allSatisfy { $0.route.providerID == "deepseek" })
    }

    func testDegradeRoutesHonorExcludedRouteKeys() async throws {
        let harness = try makeHarness(name: "degrade-excluded")
        try await configureDeepSeek(harness)

        let policy = BurnBarCrossVendorDegradePolicy(
            isEnabled: true,
            allowedVendorIDs: ["deepseek"],
            preferredModelByVendorID: ["deepseek": "deepseek-chat"]
        )
        let excludedKey = await harness.router.routeKey(providerID: "deepseek", slotID: "default")
        let routes = try await harness.router.crossVendorDegradeRoutes(
            policy: policy,
            excludedRouteKeys: [excludedKey]
        )

        XCTAssertTrue(routes.isEmpty)
    }

    func testDegradeRoutesSkipDisabledVendors() async throws {
        let harness = try makeHarness(name: "degrade-disabled-vendor")
        try await configureDeepSeek(harness, enabled: false)

        let policy = BurnBarCrossVendorDegradePolicy(
            isEnabled: true,
            allowedVendorIDs: ["deepseek"],
            preferredModelByVendorID: ["deepseek": "deepseek-chat"]
        )
        let routes = try await harness.router.crossVendorDegradeRoutes(policy: policy)
        XCTAssertTrue(routes.isEmpty)
    }

    // MARK: - Helpers

    private func configureDeepSeek(
        _ harness: BurnBarCrossVendorDegradeHarness,
        enabled: Bool = true
    ) async throws {
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
        if !enabled {
            // Disable after the slot exists (slot upserts re-enable the
            // provider) while preserving the live credential slot, so the test
            // exercises the `settings.isEnabled` filter rather than missing
            // credentials.
            var settings = try await harness.configStore.resolvedConfiguration(for: "deepseek").settings
            settings.isEnabled = false
            _ = try await harness.configStore.upsertProvider(settings)
        }
    }

    private func configureZAI(_ harness: BurnBarCrossVendorDegradeHarness) async throws {
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://api.z.ai/api/coding/paas/v4",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "default"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "default",
            label: "Z.ai API",
            apiKey: "zai-key"
        )
    }

    private func makeHarness(name: String) throws -> BurnBarCrossVendorDegradeHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-degrade-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "degrade-tests")
        )
        return BurnBarCrossVendorDegradeHarness(
            configStore: configStore,
            router: BurnBarProviderRouter(
                configStore: configStore,
                logger: BurnBarDaemonLogger(category: "degrade-tests")
            )
        )
    }
}

private struct BurnBarCrossVendorDegradeHarness {
    let configStore: BurnBarConfigStore
    let router: BurnBarProviderRouter
}
