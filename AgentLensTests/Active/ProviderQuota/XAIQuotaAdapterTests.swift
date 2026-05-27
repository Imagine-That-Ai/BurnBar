import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

final class XAIQuotaAdapterTests: XCTestCase {
    var tempDirectoryURL: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    override func tearDown() {
        try? fileManager.removeItem(at: tempDirectoryURL)
        XAIMockURLProtocol.responder = nil
        super.tearDown()
    }

    // MARK: - Branch 3: missing key + unknown plan

    func testFetch_unknownPlanWithoutKey_returnsUnavailable() async throws {
        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .unknown, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)

        XCTAssertEqual(snapshot.provider, .xAI)
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        XCTAssertTrue(snapshot.statusMessage.contains("Pick a Grok plan"))
    }

    // MARK: - Branch 1: GrokBuild credit balance

    func testFetch_grokBuildPlan_parsesPrepaidBalanceFromManagementAPI() async throws {
        // 1234 USD cents of unspent credit → xAI returns total.val = "-1234".
        let teamsJSON = #"{ "teams": [ { "id": "team_42", "name": "Acme" } ] }"#
        let balanceJSON = #"{ "total": { "val": "-1234" } }"#
        let usageJSON = #"""
        {
          "timeSeries": [
            {
              "dataPoints": [
                { "timestamp": "\#(iso8601(Date().addingTimeInterval(-60)))", "values": [ { "name": "usd", "value": 0.5 } ] },
                { "timestamp": "\#(iso8601(Date().addingTimeInterval(-2 * 24 * 60 * 60)))", "values": [ { "name": "usd", "value": 2.0 } ] }
              ]
            }
          ]
        }
        """#

        XAIMockURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case "https://api.x.ai/v1/teams":
                return Self.respond(json: teamsJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/prepaid/balance":
                return Self.respond(json: balanceJSON, for: request)
            case "https://api.x.ai/v1/billing/teams/team_42/usage":
                return Self.respond(json: usageJSON, for: request)
            default:
                return Self.respond(status: 404, json: "{}", for: request)
            }
        }

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .grokBuild, mgmtKey: "xai-mgmt-test")

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, .xAI)
        XCTAssertEqual(snapshot.confidence, .exact)

        guard let balanceBucket = snapshot.buckets.first(where: { $0.key == "xai-prepaid-credit-balance" }) else {
            XCTFail("Missing prepaid credit balance bucket"); return
        }
        XCTAssertEqual(balanceBucket.unit, .currency)
        XCTAssertEqual(balanceBucket.remainingValue ?? -1, 12.34, accuracy: 0.001)

        guard let bucket24h = snapshot.buckets.first(where: { $0.key == "xai-usage-24h" }) else {
            XCTFail("Missing 24h usage bucket"); return
        }
        XCTAssertEqual(bucket24h.usedValue ?? -1, 0.5, accuracy: 0.001)

        guard let bucket7d = snapshot.buckets.first(where: { $0.key == "xai-usage-7d" }) else {
            XCTFail("Missing 7d usage bucket"); return
        }
        XCTAssertEqual(bucket7d.usedValue ?? -1, 2.5, accuracy: 0.001)
    }

    // MARK: - Branch 2: SuperGrok pacing

    func testFetch_superGrokPlan_withPopulatedLog_reportsRollingWindowUsage() async throws {
        let now = Date()
        try writeSuperGrokLog(events: [
            // In-window events.
            now.addingTimeInterval(-30 * 60),
            now.addingTimeInterval(-60 * 60),
            now.addingTimeInterval(-90 * 60),
            // Out of window — must NOT count.
            now.addingTimeInterval(-3 * 60 * 60),
        ])

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .superGrok, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, .xAI)
        XCTAssertEqual(snapshot.confidence, .estimated)

        guard let bucket = snapshot.buckets.first(where: { $0.key == "xai-supergrok-2h-rolling" }) else {
            XCTFail("Missing rolling 2h bucket"); return
        }
        XCTAssertEqual(bucket.usedValue ?? -1, 3, accuracy: 0.0001)
        XCTAssertEqual(bucket.limitValue ?? -1, 100, accuracy: 0.0001)
        XCTAssertEqual(bucket.remainingValue ?? -1, 97, accuracy: 0.0001)
        XCTAssertTrue(bucket.isEstimated)
    }

    func testFetch_superGrokPlan_withEmptyLog_reportsZeroUsedAndFullHeadroom() async throws {
        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .superGrokHeavy, mgmtKey: nil)

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, .xAI)
        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.buckets.count, 1)
        let bucket = snapshot.buckets[0]
        XCTAssertEqual(bucket.usedValue, 0)
        XCTAssertEqual(bucket.limitValue ?? -1, 400, accuracy: 0.0001)
        XCTAssertEqual(bucket.remainingValue ?? -1, 400, accuracy: 0.0001)
    }

    // MARK: - Branch 1: HTTP error → unavailable

    func testFetch_grokBuildPlan_returnsUnavailableWhenTeamsEndpointRejects() async throws {
        XAIMockURLProtocol.responder = { request in
            Self.respond(status: 401, json: #"{ "error": { "message": "Invalid key" } }"#, for: request)
        }

        let adapter = XAIQuotaAdapter()
        let context = try makeContext(plan: .grokBuild, mgmtKey: "xai-mgmt-bad")

        let snapshot = try await adapter.fetch(context: context)
        XCTAssertEqual(snapshot.provider, .xAI)
        XCTAssertEqual(snapshot.confidence, .unavailable)
    }

    // MARK: - Helpers

    private func makeContext(
        plan: XAIQuotaPlanTier,
        mgmtKey: String?
    ) throws -> ProviderQuotaAdapterContext {
        // Use a temp-scoped app-support root so the resolved-team-id scratch
        // cache is isolated per test and never short-circuits the mocked
        // `/v1/teams` resolution with a value left over from a prior run.
        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: tempDirectoryURL)
        let snapshotStore = ProviderQuotaSnapshotStore(appPaths: appPaths, fileManager: fileManager)
        let dbQueue = try DatabaseQueue()
        let dataStoreActor = try DataStoreActor(databaseQueue: dbQueue)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [XAIMockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        var resolvedKeys: [String: String?] = [:]
        if let mgmtKey {
            resolvedKeys["xai_management_key"] = mgmtKey
        }

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
            xaiPlanProvider: { plan },
            mimoTokenPlanRegionProvider: { .sgp },
            mimoTokenPlanTierProvider: { nil },
            mimoTokenPlanBillingCycleProvider: { .monthly },
            claudeBridgeStatus: ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil),
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            refreshClaudeBridgeStatus: { ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "Not installed", lastPayloadAt: nil) },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: resolvedKeys
        )
    }

    /// Write a populated SuperGrok event log to the temp home directory
    /// so the pacing branch has something to read.
    private func writeSuperGrokLog(events: [Date]) throws {
        let url = XAIQuotaAdapter.superGrokLogURL(homeDirectoryURL: tempDirectoryURL)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let lines = events.map { date -> String in
            let ms = Int(date.timeIntervalSince1970 * 1000)
            return "{\"plan\":\"superGrok\",\"timestamp\":\(ms)}"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func respond(
        status: Int = 200,
        json: String,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, json.data(using: .utf8) ?? Data())
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private final class XAIMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotLoadFromNetwork))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
