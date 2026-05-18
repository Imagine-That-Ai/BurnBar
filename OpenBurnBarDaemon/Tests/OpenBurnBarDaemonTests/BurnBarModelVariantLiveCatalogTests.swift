import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarModelVariantLiveCatalogTests: XCTestCase {

    func testLiveCatalogEmitsVariantRowsForRegisteredVariants() async throws {
        let harness = try makeHarness(name: "live-variants")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")

        for level in [BurnBarThinkingLevel.high, .xhigh, .max] {
            _ = try await harness.configStore.upsertModelVariant(
                providerID: "anthropic",
                variant: BurnBarModelVariant(
                    variantID: BurnBarModelVariant.defaultVariantID(baseModelID: "claude-opus-4-7", level: level),
                    label: BurnBarModelVariant.defaultLabel(for: level),
                    baseModelID: "claude-opus-4-7",
                    thinkingLevel: level
                )
            )
        }

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()
        let advertisedIDs = Set(snapshot.models.map(\.id))

        XCTAssertTrue(advertisedIDs.contains("claude-opus-4-7"), "Base row must be present")
        XCTAssertTrue(advertisedIDs.contains("claude-opus-4-7-high"))
        XCTAssertTrue(advertisedIDs.contains("claude-opus-4-7-xhigh"))
        XCTAssertTrue(advertisedIDs.contains("claude-opus-4-7-max"))

        let variantRow = snapshot.models.first { $0.id == "claude-opus-4-7-xhigh" }
        XCTAssertEqual(variantRow?.baseModelID, "claude-opus-4-7")
        XCTAssertEqual(variantRow?.thinkingLevel, "xhigh")
        XCTAssertEqual(variantRow?.sourceKind, "thinking_level_variant")
        XCTAssertTrue(
            variantRow?.displayName.contains("(XHigh)") ?? false,
            "Variant displayName should disambiguate level for the picker."
        )
    }

    func testLiveCatalogDropsVariantRowsAfterRemoval() async throws {
        let harness = try makeHarness(name: "live-variants-removed")

        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://api.anthropic.com/v1",
                preferredModelIDs: ["claude-opus-4-7"]
            )
        )
        try await harness.configStore.setSecret("test-anthropic-key", for: "anthropic")
        _ = try await harness.configStore.upsertModelVariant(
            providerID: "anthropic",
            variant: BurnBarModelVariant(
                variantID: "claude-opus-4-7-high",
                label: "High",
                baseModelID: "claude-opus-4-7",
                thinkingLevel: .high
            )
        )

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: nonNetworkSession(),
            refreshTimeoutSeconds: 0.05
        )
        var snapshot = try await liveCatalog.snapshot()
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7-high" })

        try await harness.configStore.removeModelVariant(providerID: "anthropic", variantID: "claude-opus-4-7-high")
        snapshot = try await liveCatalog.snapshot()
        XCTAssertFalse(snapshot.models.contains { $0.id == "claude-opus-4-7-high" })
        XCTAssertTrue(snapshot.models.contains { $0.id == "claude-opus-4-7" }, "Base row must remain after variant removal.")
    }

    private struct VariantHarness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> VariantHarness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-live-catalog-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let secretStore = BurnBarInMemorySecretStore()
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: secretStore,
            logger: BurnBarDaemonLogger(category: "live-catalog-variant-tests")
        )
        return VariantHarness(rootURL: rootURL, configStore: configStore)
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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
