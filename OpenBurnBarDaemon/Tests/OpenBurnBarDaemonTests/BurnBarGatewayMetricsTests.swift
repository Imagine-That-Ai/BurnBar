import OpenBurnBarEngine
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarGatewayMetricsTests: XCTestCase {
    func testFactoryCatalogCacheReprojectsCredentialHealthForModelsAndRouteKeys() async throws {
        let droidRunner = CountingGatewayFactoryDroidRunner()
        let harness = try GatewayHarness(
            modelCatalogDroidProcessRunner: droidRunner,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureFactoryProviderForGateway()

        let requestedModel = BurnBarHTTPGatewayServer.GatewayRequestedModel(
            originalID: "factory/gpt-5.5",
            modelID: "gpt-5.5",
            providerID: "factory",
            accountID: "max"
        )
        let readyKeys = try await harness.advertisedRouteKeysByFamily(for: requestedModel)
        XCTAssertEqual(readyKeys[.openaiCompat], ["factory#max"])

        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "factory",
            slotID: "max",
            status: .coolingDown,
            cooldownUntil: Date().addingTimeInterval(60),
            message: "retry later"
        )
        let coolingKeys = try await harness.advertisedRouteKeysByFamily(for: requestedModel)
        XCTAssertNil(coolingKeys[.openaiCompat])

        let modelsBody = await harness.handleModelsBody(includeUnadvertised: true)
        let modelsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: modelsBody) as? [String: Any]
        )
        let rows = try XCTUnwrap(modelsObject["data"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first {
            ($0["provider_id"] as? String) == "factory"
                && ($0["account_id"] as? String) == "max"
                && ($0["id"] as? String) == "factory/gpt-5.5"
        })
        XCTAssertEqual(row["quota_state"] as? String, "cooling_down")
        XCTAssertEqual(row["route_eligible"] as? Bool, false)
        XCTAssertEqual(row["advertised"] as? Bool, false)
        XCTAssertEqual(droidRunner.count, 1, "gateway consumers must share cached discovery")
    }

    func testGatewayRateLimitClientKeysAreEphemeralKeyedPseudonyms() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-gateway-rate-limit-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: tempDirectory) }

        let configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
        let configuration = BurnBarGatewayConfiguration(
            isEnabled: false,
            host: "127.0.0.1",
            port: 8317,
            authToken: nil
        )
        let firstServer = BurnBarHTTPGatewayServer(
            configuration: configuration,
            configStore: configStore
        )
        let secondServer = BurnBarHTTPGatewayServer(
            configuration: configuration,
            configStore: configStore
        )
        let primaryToken = "sensitive-primary-api-key"
        let primaryRequest = BurnBarHTTPGatewayServer.HTTPRequest(
            method: "GET",
            path: "/health",
            headers: ["authorization": "Bearer \(primaryToken)"],
            body: nil
        )
        let secondaryRequest = BurnBarHTTPGatewayServer.HTTPRequest(
            method: "GET",
            path: "/health",
            headers: ["x-api-key": "sensitive-secondary-api-key"],
            body: nil
        )

        let firstPrimary = await firstServer.rateLimitClientKey(for: primaryRequest)
        let repeatedPrimary = await firstServer.rateLimitClientKey(for: primaryRequest)
        let firstSecondary = await firstServer.rateLimitClientKey(for: secondaryRequest)
        let restartedPrimary = await secondServer.rateLimitClientKey(for: primaryRequest)

        XCTAssertEqual(firstPrimary, repeatedPrimary)
        XCTAssertNotEqual(firstPrimary, firstSecondary)
        XCTAssertNotEqual(firstPrimary, restartedPrimary)
        XCTAssertFalse(firstPrimary.contains(primaryToken))
        XCTAssertNotNil(firstPrimary.range(of: #"^token:[0-9a-f]{24}$"#, options: .regularExpression))
    }

    func test_liveSnapshotIncludesGatewayCounters() {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: true)

        XCTAssertTrue(snapshot.gatewayEnabled)
        XCTAssertGreaterThanOrEqual(snapshot.uptimeSeconds, 0)
        XCTAssertEqual(snapshot.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertEqual(snapshot.counters["gateway_enabled"], 1)
        XCTAssertEqual(snapshot.counters["heartbeat_stale"], snapshot.heartbeatStale ? 1 : 0)
    }

    func test_liveSnapshotEncodesToJSON() throws {
        let snapshot = BurnBarGatewayMetricsSnapshot.live(gatewayEnabled: false)
        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["gatewayEnabled"] as? Bool, false)
        XCTAssertNotNil(json?["generatedAt"])
        XCTAssertNotNil(json?["counters"])
    }
}
