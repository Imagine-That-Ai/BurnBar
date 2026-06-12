import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarModelAliasLiveCatalogTests: XCTestCase {

    func testLiveCatalogEmitsAliasRowsForRegisteredAliases() async throws {
        let harness = try makeHarness(name: "live-aliases")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")

        _ = try await harness.configStore.upsertModelAlias(
            providerID: "anthropic",
            alias: BurnBarModelAlias(
                aliasID: "my-opus",
                baseModelID: "claude-opus-4-7",
                displayName: "My Opus"
            )
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()
        let aliasRow = snapshot.models.first { $0.id == "my-opus" }
        XCTAssertNotNil(aliasRow)
        XCTAssertEqual(aliasRow?.baseModelID, "claude-opus-4-7")
        XCTAssertEqual(aliasRow?.sourceKind, "user_model_alias")
        XCTAssertEqual(aliasRow?.displayName, "My Opus")
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7" })
    }

    func testLiveCatalogPropagatesHideBaseFlagOnAliasRows() async throws {
        let harness = try makeHarness(name: "live-aliases-hide-base")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")

        _ = try await harness.configStore.upsertModelAlias(
            providerID: "anthropic",
            alias: BurnBarModelAlias(
                aliasID: "my-opus",
                baseModelID: "claude-opus-4-7",
                displayName: "My Opus",
                hidesBaseModel: true
            )
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()
        let aliasRow = try XCTUnwrap(snapshot.models.first { $0.id == "my-opus" })
        XCTAssertTrue(aliasRow.hidesBaseModel ?? false)
    }

    func testLiveCatalogDeprioritizesXAIWhenSlotQuotaBelowTwentyPercent() async throws {
        let harness = try makeHarness(name: "xai-quota-pressure")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "xai",
                isEnabled: true,
                baseURL: "https://api.x.ai/v1",
                preferredModelIDs: ["grok-build-0.1"]
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "xai",
            slotID: "grok-default",
            label: "Grok Build",
            apiKey: "xai-test-key"
        )
        try await harness.configStore.updateCredentialSlotQuota(
            providerID: "xai",
            slotID: "grok-default",
            remainingPercent: 15,
            resetsAt: nil,
            message: "SuperGrok pacing pressure"
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()
        let row = try XCTUnwrap(snapshot.models.first { $0.id == "grok-build-0.1" })
        XCTAssertEqual(row.quotaState, .coolingDown)
        XCTAssertFalse(row.routeEligible)
    }

    func testLiveCatalogDropsAliasRowsAfterRemoval() async throws {
        let harness = try makeHarness(name: "live-aliases-removed")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")
        _ = try await harness.configStore.upsertModelAlias(
            providerID: "anthropic",
            alias: BurnBarModelAlias(
                aliasID: "my-opus",
                baseModelID: "claude-opus-4-7",
                displayName: "My Opus"
            )
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        var snapshot = try await liveCatalog.snapshot()
        XCTAssertTrue(snapshot.models.contains { $0.id == "my-opus" })

        try await harness.configStore.removeModelAlias(providerID: "anthropic", aliasID: "my-opus")
        snapshot = try await liveCatalog.snapshot()
        XCTAssertFalse(snapshot.models.contains { $0.id == "my-opus" })
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7" })
    }

    private struct AliasHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> AliasHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-live-alias-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "live-alias-catalog-tests")
        )
        return AliasHarness(rootURL: rootURL, configStore: configStore)
    }

    private func nonNetworkSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.05
        configuration.timeoutIntervalForResource = 0.05
        return URLSession(configuration: configuration)
    }
}

private final class BlockingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
