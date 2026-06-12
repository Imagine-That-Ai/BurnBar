import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class MiniMaxQuotaAdapterTests: XCTestCase {
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
        MiniMaxMockURLProtocol.responder = nil
        super.tearDown()
    }

    func testFetch_paygMode_returnsUnavailableMessage() async throws {
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-cp-test-key", mode: .payAsYouGo)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Pay-as-you-go"))
    }

    func testFetch_openPlatformKey_returnsGuidanceMessage() async throws {
        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-api-test-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.statusMessage.contains("Coding Plan key"))
    }

    func testFetch_codingPlanKey_usesCodingPlanEndpointFirst() async throws {
        let remainsJSON = """
        {"model_remains":[{"model_name":"MiniMax-M2.7","remains":900,"total":1000}]}
        """
        var requestedURLs: [String] = []
        MiniMaxMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            requestedURLs.append(url)
            if url.contains("coding_plan/remains") {
                let data = remainsJSON.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-cp-test-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
        XCTAssertTrue(requestedURLs.first?.contains("coding_plan/remains") ?? false)
    }

    func testFetch_tokenPlanEndpointUsedWhenCodingPlanFails() async throws {
        let remainsJSON = """
        {"model_remains":[{"model_name":"MiniMax-M2.7","remains":500,"total":1000}]}
        """
        MiniMaxMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("token_plan/remains") {
                let data = remainsJSON.data(using: .utf8)!
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let adapter = MiniMaxQuotaAdapter()
        let context = try makeContext(apiKey: "sk-other-token-plan-key")

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.confidence, .exact)
        XCTAssertFalse(snapshot.buckets.isEmpty)
    }

    private func makeContext(
        apiKey: String,
        mode: MiniMaxQuotaMode = .tokenPlan
    ) throws -> ProviderQuotaAdapterContext {
        let appPaths = OpenBurnBarAppPaths.live()
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let dbQueue = try DatabaseQueue()
        let dataStoreActor = try DataStoreActor(databaseQueue: dbQueue)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxMockURLProtocol.self]
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
            miniMaxModeProvider: { mode },
            factoryPlanProvider: { .unknown },
            xaiPlanProvider: { .unknown },
            mimoTokenPlanRegionProvider: { .sgp },
            mimoTokenPlanTierProvider: { nil },
            mimoTokenPlanBillingCycleProvider: { .monthly },
            claudeBridgeStatus: ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil),
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            refreshClaudeBridgeStatus: { ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil) },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: ["minimax": apiKey]
        )
    }
}

private final class MiniMaxMockURLProtocol: URLProtocol {
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
