import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// End-to-end coverage for user-declared custom models: a model id the bundled
/// catalog does not know about must still advertise through the live catalog and
/// be route-eligible on its provider, so the proxy's `/v1/models` surfaces it
/// once the provider has a usable credential.
final class BurnBarCustomModelLiveCatalogTests: XCTestCase {

    func testLiveCatalogAdvertisesCustomModelAsRouteEligibleRow() async throws {
        let harness = try makeHarness(name: "custom-advertise")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")

        _ = try await harness.configStore.upsertCustomModel(
            providerID: "anthropic",
            customModel: BurnBarCustomModel(modelID: "claude-net-new", displayName: "Claude Net New")
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()

        let customRow = try XCTUnwrap(snapshot.models.first { $0.id == "claude-net-new" })
        XCTAssertEqual(customRow.displayName, "Claude Net New")
        XCTAssertEqual(customRow.providerID, "anthropic")
        XCTAssertTrue(customRow.routeEligible, "A custom model on an enabled, credentialed provider must be route-eligible.")
        // The original catalog model is still advertised alongside the custom one.
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7" })

        // The catalog confirms an eligible route exists for the custom id.
        let routes = try await liveCatalog.hasEligibleRoute(for: "claude-net-new", formatFamily: .anthropic)
        XCTAssertTrue(routes)
    }

    func testCustomModelIsNotRouteEligibleWithoutCredential() async throws {
        let harness = try makeHarness(name: "custom-no-cred")

        // Enabled, but no secret set → missing credential.
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://api.minimax.io/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )
        _ = try await harness.configStore.upsertCustomModel(
            providerID: "minimax",
            customModel: BurnBarCustomModel(modelID: "minimax-m3")
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()
        let customRow = try XCTUnwrap(snapshot.models.first { $0.id == "minimax-m3" })
        // The row exists (so the management UI can show it), but it is not
        // route-eligible until the provider gets a working credential — the
        // same gating its seeded models obey.
        XCTAssertFalse(customRow.routeEligible)
        XCTAssertEqual(customRow.quotaState, .missingCredential)
    }

    func testRemovingCustomModelDropsItFromCatalog() async throws {
        let harness = try makeHarness(name: "custom-removed")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")
        _ = try await harness.configStore.upsertCustomModel(
            providerID: "anthropic",
            customModel: BurnBarCustomModel(modelID: "claude-net-new")
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        var snapshot = try await liveCatalog.snapshot()
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-net-new" })

        try await harness.configStore.removeCustomModel(providerID: "anthropic", modelID: "claude-net-new")
        snapshot = try await liveCatalog.snapshot()
        XCTAssertFalse(snapshot.models.contains { $0.id == "claude-net-new" })
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7" })
    }

    func testInvalidCustomModelIDIsRejected() async throws {
        let harness = try makeHarness(name: "custom-invalid")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        do {
            _ = try await harness.configStore.upsertCustomModel(
                providerID: "anthropic",
                customModel: BurnBarCustomModel(modelID: "has space")
            )
            XCTFail("Expected an invalid-custom-model-id error.")
        } catch let error as BurnBarConfigStoreError {
            guard case .invalidCustomModelID = error else {
                return XCTFail("Expected .invalidCustomModelID, got \(error).")
            }
        }
    }

    private struct CustomHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> CustomHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-live-custom-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "live-custom-catalog-tests")
        )
        return CustomHarness(rootURL: rootURL, configStore: configStore)
    }

    private func nonNetworkSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingCustomURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.05
        configuration.timeoutIntervalForResource = 0.05
        return URLSession(configuration: configuration)
    }
}

private final class BlockingCustomURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
