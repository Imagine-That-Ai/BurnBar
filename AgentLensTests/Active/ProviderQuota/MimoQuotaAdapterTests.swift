import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class MimoQuotaAdapterTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectoryURL)
        MimoMockURLProtocol.responder = nil
        super.tearDown()
    }

    func testFetch_paygKey_returnsUnavailableBalanceMessage() async throws {
        let adapter = MimoQuotaAdapter()
        let context = try makeContext(apiKey: "sk-test-payg-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("pay-as-you-go"))
    }

    func testFetch_tokenPlanRemains_parsesExactBuckets() async throws {
        let remainsJSON = """
        {"data":{"remains":[{"name":"credits","used":100,"limit":1000,"remaining":900}]}}
        """
        MimoMockURLProtocol.responder = { request in
            let url = request.url ?? URL(string: "https://example.com")!
            guard url.absoluteString.contains("token_plan/remains") else {
                let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let data = remainsJSON.data(using: .utf8)!
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let adapter = MimoQuotaAdapter()
        let context = try makeContext(apiKey: "tp-test-token-plan")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    func testFetch_tokenPlanRemainsMissing_usesTierEstimate() async throws {
        MimoMockURLProtocol.responder = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data("{}".utf8))
        }

        let adapter = MimoQuotaAdapter()
        let context = try makeContext(
            apiKey: "tp-test-token-plan",
            tier: .standard,
            billingCycle: .monthly
        )

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .mimo)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.buckets.first?.limitValue, MimoTokenPlanTier.standard.monthlyCreditLimit)
    }

    private func makeContext(
        apiKey: String,
        region: ProviderEndpointRegion = .sgp,
        tier: MimoTokenPlanTier? = nil,
        billingCycle: MimoTokenPlanBillingCycle = .monthly
    ) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths.live()
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let dbQueue = try DatabaseQueue()
        let dataStoreActor = try DataStoreActor(databaseQueue: dbQueue)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MimoMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: [:],
            homeDirectoryURL: tempDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: snapshotStore,
            bridgeManager: ClaudeQuotaBridgeManager(
                appPaths: appPaths,
                homeDirectoryURL: tempDirectoryURL,
                fileManager: fileManager,
                snapshotStore: snapshotStore
            ),
            miniMaxModeProvider: { .tokenPlan },
            factoryPlanProvider: { .unknown },
            xaiPlanProvider: { .unknown },
            mimoTokenPlanRegionProvider: { region },
            mimoTokenPlanTierProvider: { tier },
            mimoTokenPlanBillingCycleProvider: { billingCycle },
            claudeBridgeStatus: ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil),
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            refreshClaudeBridgeStatus: { ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil) },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: ["mimo": apiKey]
        )
    }
}

private final class MimoMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (URLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
