import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota

final class GoogleCloudQuotaRemainingTests: XCTestCase {
    override func tearDown() {
        GoogleQuotaStubURLProtocol.reset()
        super.tearDown()
    }

    func testAIStudioKeyIsRejectedAsRemainingCredential() async {
        let root = try! makeTemporaryDirectory("gcp-aiza")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await GoogleCloudQuotaCredentialResolver.resolve(
            context: makeContext(
                root: root,
                resolvedAPIKeys: [
                    "google_cloud_access_token": "AIzaSyNotRemaining1234567890",
                    "google_cloud_project": "burnbar-gemini"
                ]
            )
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected AI Studio keys to be rejected")
        }
        XCTAssertEqual(error, .aiStudioKeyRejected)
        XCTAssertTrue(error.statusMessage.localizedCaseInsensitiveContains("ai studio"))
        XCTAssertFalse(error.statusMessage.localizedCaseInsensitiveContains("firebase"))
    }

    func testMissingCredentialsStayHonestlyUnsupported() async {
        let root = try! makeTemporaryDirectory("gcp-missing")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await GoogleCloudQuotaCredentialResolver.resolve(context: makeContext(root: root))
        guard case .failure(let error) = result else {
            return XCTFail("Expected missing credentials")
        }
        XCTAssertEqual(error, .missing)
        XCTAssertTrue(error.statusMessage.localizedCaseInsensitiveContains("adc")
            || error.statusMessage.localizedCaseInsensitiveContains("service account"))
        XCTAssertTrue(error.statusMessage.localizedCaseInsensitiveContains("verizon"))
    }

    func testInjectedTokenRequiresARealProjectID() async {
        let root = try! makeTemporaryDirectory("gcp-noproject")
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await GoogleCloudQuotaCredentialResolver.resolve(
            context: makeContext(
                root: root,
                resolvedAPIKeys: ["google_cloud_access_token": "ya29.injected-access-token"]
            )
        )
        guard case .failure(let error) = result else {
            return XCTFail("Expected missing project")
        }
        XCTAssertEqual(error, .missingProject)
    }

    func testAuthorizedUserADCRefreshesWithFileClientID() async throws {
        let root = try makeTemporaryDirectory("gcp-adc")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeADC(
            at: root,
            json: """
            {
              "type":"authorized_user",
              "client_id":"gcloud-sdk-already-on-disk.apps.googleusercontent.com",
              "client_secret":"disk-secret",
              "refresh_token":"1//disk-refresh",
              "quota_project_id":"burnbar-gemini"
            }
            """
        )

        GoogleQuotaStubURLProtocol.stub { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let body = GoogleQuotaStubURLProtocol.bodyString(from: request)
                if !body.isEmpty {
                    XCTAssertTrue(body.contains("gcloud-sdk-already-on-disk"))
                    XCTAssertTrue(body.contains("refresh_token"))
                }
                return (200, #"{"access_token":"ya29.from-adc","token_type":"Bearer"}"#)
            }
            return (404, "{}")
        }

        let result = await GoogleCloudQuotaCredentialResolver.resolve(
            context: makeContext(root: root, session: GoogleQuotaStubURLProtocol.makeSession())
        )
        let identity = try result.get()
        XCTAssertEqual(identity.accessToken, "ya29.from-adc")
        XCTAssertEqual(identity.projectID, "burnbar-gemini")
        XCTAssertEqual(identity.source, .authorizedUserADC)
    }

    func testGeminiSettingsProjectIsAccepted() {
        let project = GoogleCloudQuotaCredentialResolver.projectID(fromGeminiSettings: [
            "selectedAuthType": "vertex-ai",
            "vertexai": ["project": "burnbar-gemini"]
        ])
        XCTAssertEqual(project, "burnbar-gemini")
    }

    func testServiceUsageAndMonitoringJoinToRemaining() throws {
        let serviceUsage = """
        {
          "metrics": [
            {
              "metric": "generativelanguage.googleapis.com/generate_content_free_tier_requests",
              "displayName": "Generate Content requests per day per project per base model",
              "consumerQuotaLimits": [{
                "unit": "1/d/{project}/{base_model}",
                "quotaBuckets": [{ "effectiveLimit": "1500", "dimensions": {} }]
              }]
            },
            {
              "metric": "compute.googleapis.com/cpus",
              "displayName": "CPUs",
              "consumerQuotaLimits": [{
                "unit": "1/{project}",
                "quotaBuckets": [{ "effectiveLimit": "24" }]
              }]
            }
          ]
        }
        """
        let monitoring = """
        {
          "timeSeries": [{
            "metric": {
              "type": "serviceruntime.googleapis.com/quota/allocation/usage",
              "labels": { "quota_metric": "generativelanguage.googleapis.com/generate_content_free_tier_requests" }
            },
            "resource": {
              "type": "consumer_quota",
              "labels": { "service": "generativelanguage.googleapis.com", "project_id": "burnbar-gemini" }
            },
            "points": [{ "value": { "int64Value": "34" } }]
          }]
        }
        """

        let limits = try GoogleCloudQuotaClient.parseConsumerQuotaMetrics(
            data: Data(serviceUsage.utf8),
            service: GoogleCloudQuotaCredentialResolver.generativeLanguageService
        ).limits
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits[0].window, .daily)
        XCTAssertEqual(limits[0].kind, .requests)
        XCTAssertFalse(GoogleCloudQuotaClient.isGeminiRelevant(
            metric: "compute.googleapis.com/cpus",
            displayName: "CPUs",
            service: "compute.googleapis.com"
        ))

        let usage = try GoogleCloudQuotaClient.parseTimeSeries(data: Data(monitoring.utf8))
        let buckets = GoogleCloudQuotaClient.selectBuckets(limits: limits, usage: usage)
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.usedValue, 34)
        XCTAssertEqual(bucket.limitValue, 1500)
        XCTAssertEqual(bucket.remainingValue, 1466)
        XCTAssertEqual(bucket.unit, .requests)
        XCTAssertFalse(bucket.isUsedOnlyMeter)
        XCTAssertNotNil(bucket.displayRemainingFraction)
        XCTAssertTrue(bucket.label.localizedCaseInsensitiveContains("remaining today"))
        XCTAssertFalse(bucket.label.localizedCaseInsensitiveContains("verizon"))
    }

    func testUnusedAllocationTreatsUsedAsZero() {
        let limits = [
            GoogleCloudQuotaLimit(
                service: GoogleCloudQuotaCredentialResolver.generativeLanguageService,
                metric: "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                displayName: "Generate content requests per day",
                unit: "1/d/{project}",
                effectiveLimit: 500,
                dimensions: [:],
                window: .daily,
                kind: .requests
            )
        ]
        let buckets = GoogleCloudQuotaClient.selectBuckets(limits: limits, usage: [])
        XCTAssertEqual(buckets.first?.usedValue, 0)
        XCTAssertEqual(buckets.first?.remainingValue, 500)
    }

    func testZeroEffectiveLimitsAreNotShownAsFakeBatteries() {
        let limits = [
            GoogleCloudQuotaLimit(
                service: GoogleCloudQuotaCredentialResolver.generativeLanguageService,
                metric: "generativelanguage.googleapis.com/generate_content_requests",
                displayName: "Generate content requests per minute",
                unit: "1/min/{project}",
                effectiveLimit: 0,
                dimensions: ["region": "asia-east1"],
                window: .minute,
                kind: .requests
            )
        ]
        XCTAssertTrue(GoogleCloudQuotaClient.selectBuckets(limits: limits, usage: []).isEmpty)
    }

    func testStressSelectsASmallHonestSetFromARegionalFlood() {
        var limits: [GoogleCloudQuotaLimit] = []
        let regions = (0..<40).map { "us-region-\($0)" }
        for region in regions {
            limits.append(
                GoogleCloudQuotaLimit(
                    service: GoogleCloudQuotaCredentialResolver.generativeLanguageService,
                    metric: "generativelanguage.googleapis.com/generate_content_requests",
                    displayName: "Generate Content requests per minute per project per region",
                    unit: "1/min/{project}/{region}",
                    effectiveLimit: 15,
                    dimensions: ["region": region],
                    window: .minute,
                    kind: .requests
                )
            )
            limits.append(
                GoogleCloudQuotaLimit(
                    service: GoogleCloudQuotaCredentialResolver.generativeLanguageService,
                    metric: "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                    displayName: "Generate Content requests per day per project",
                    unit: "1/d/{project}/{region}",
                    effectiveLimit: 1500,
                    dimensions: ["region": region],
                    window: .daily,
                    kind: .requests
                )
            )
            limits.append(
                GoogleCloudQuotaLimit(
                    service: GoogleCloudQuotaCredentialResolver.vertexService,
                    metric: "aiplatform.googleapis.com/online_prediction_tokens_per_minute",
                    displayName: "Online prediction tokens per minute",
                    unit: "1/min/{project}/{region}",
                    effectiveLimit: 200_000,
                    dimensions: ["region": region],
                    window: .minute,
                    kind: .tokens
                )
            )
            limits.append(
                GoogleCloudQuotaLimit(
                    service: "compute.googleapis.com",
                    metric: "compute.googleapis.com/cpus",
                    displayName: "CPUs",
                    unit: "1/{project}",
                    effectiveLimit: 24,
                    dimensions: ["region": region],
                    window: .other,
                    kind: .other
                )
            )
        }

        let usage = [
            GoogleCloudQuotaUsage(
                service: GoogleCloudQuotaCredentialResolver.generativeLanguageService,
                metric: "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                location: "us-region-3",
                used: 400
            )
        ]
        let buckets = GoogleCloudQuotaClient.selectBuckets(limits: limits, usage: usage)
        XCTAssertLessThanOrEqual(buckets.count, GoogleCloudQuotaClient.maxSelectedBuckets)
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.contains { $0.label.localizedCaseInsensitiveContains("remaining today") })
        XCTAssertFalse(buckets.contains { $0.label.localizedCaseInsensitiveContains("cpu") })
        XCTAssertFalse(buckets.contains { $0.isUsedOnlyMeter })
        XCTAssertTrue(buckets.allSatisfy { ($0.limitValue ?? 0) > 0 })
        XCTAssertTrue(buckets.allSatisfy { $0.remainingValue != nil })
    }

    func testMalformedServiceUsageIsRejected() {
        XCTAssertThrowsError(
            try GoogleCloudQuotaClient.parseConsumerQuotaMetrics(
                data: Data("not-json".utf8),
                service: GoogleCloudQuotaCredentialResolver.generativeLanguageService
            )
        )
    }

    func testHTTP403DoesNotInventRemainingBuckets() async {
        GoogleQuotaStubURLProtocol.stub { request in
            if request.url?.path.contains("consumerQuotaMetrics") == true {
                return (403, #"{"error":{"message":"PERMISSION_DENIED"}}"#)
            }
            if request.url?.path.contains("timeSeries") == true {
                return (403, #"{"error":{"message":"PERMISSION_DENIED"}}"#)
            }
            return (404, "{}")
        }

        let result = await GoogleCloudQuotaClient.fetchRemaining(
            identity: GoogleCloudQuotaIdentity(
                accessToken: "ya29.test",
                projectID: "burnbar-gemini",
                source: .injected
            ),
            session: GoogleQuotaStubURLProtocol.makeSession()
        )
        XCTAssertTrue(result.buckets.isEmpty)
        XCTAssertTrue(result.hadAPIError)
        XCTAssertTrue(result.statusMessage.localizedCaseInsensitiveContains("denied")
            || result.statusMessage.localizedCaseInsensitiveContains("403"))
        XCTAssertFalse(result.statusMessage.localizedCaseInsensitiveContains("verizon %"))
    }

    func testAdapterComposesUsedOnlyWithCloudRemaining() async throws {
        let root = try makeTemporaryDirectory("gcp-compose")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(at: root, sessionID: "live", timestamp: Date(), inputTokens: 20, outputTokens: 5)

        GoogleQuotaStubURLProtocol.stub { request in
            if request.url?.path.contains("consumerQuotaMetrics") == true {
                if request.url?.path.contains("generativelanguage") == true {
                    return (200, """
                    {"metrics":[{
                      "metric":"generativelanguage.googleapis.com/generate_content_free_tier_requests",
                      "displayName":"Generate Content requests per day",
                      "consumerQuotaLimits":[{"unit":"1/d/{project}","quotaBuckets":[{"effectiveLimit":"200"}]}]
                    }]}
                    """)
                }
                return (200, #"{"metrics":[]}"#)
            }
            if request.url?.path.contains("timeSeries") == true {
                return (200, """
                {"timeSeries":[{
                  "metric":{"labels":{"quota_metric":"generativelanguage.googleapis.com/generate_content_free_tier_requests"}},
                  "resource":{"labels":{"service":"generativelanguage.googleapis.com"}},
                  "points":[{"value":{"int64Value":"40"}}]
                }]}
                """)
            }
            return (404, "{}")
        }

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(
            context: makeContext(
                root: root,
                session: GoogleQuotaStubURLProtocol.makeSession(),
                resolvedAPIKeys: [
                    "google_cloud_access_token": "ya29.compose",
                    "google_cloud_project": "burnbar-gemini"
                ]
            )
        )
        XCTAssertEqual(snapshot.sourceKind, .officialAPI)
        let used = try XCTUnwrap(snapshot.buckets.first { $0.key == "tokens-24h" })
        XCTAssertEqual(used.usedValue, 25)
        XCTAssertTrue(used.isUsedOnlyMeter)
        XCTAssertNil(used.displayRemainingFraction)
        let remaining = try XCTUnwrap(snapshot.buckets.first { $0.label.localizedCaseInsensitiveContains("remaining today") })
        XCTAssertEqual(remaining.usedValue, 40)
        XCTAssertEqual(remaining.remainingValue, 160)
        XCTAssertFalse(remaining.isUsedOnlyMeter)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("service usage"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("firebase"))
    }

    func testUsedOnlySurvivesCloudAuthFailure() async throws {
        let root = try makeTemporaryDirectory("gcp-used-survives")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(at: root, sessionID: "live", timestamp: Date(), inputTokens: 9, outputTokens: 1)

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(
            context: makeContext(
                root: root,
                resolvedAPIKeys: [
                    "google_cloud_access_token": "AIzaSyShouldNotUnlockRemaining",
                    "google_cloud_project": "burnbar-gemini"
                ]
            )
        )
        XCTAssertEqual(snapshot.sourceKind, .localSession)
        XCTAssertEqual(snapshot.buckets.count, 2)
        XCTAssertTrue(snapshot.buckets.allSatisfy(\.isUsedOnlyMeter))
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("ai studio"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("verizon"))
    }

    func testConsumerOAuthStillRefusesVerizonRemainingWhenCloudIsAbsent() async throws {
        let root = try makeTemporaryDirectory("gcp-verizon")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".gemini", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"""
        {"selectedAuthType":"oauth-personal"}
        """#.write(to: root.appendingPathComponent(".gemini/settings.json"), atomically: true, encoding: .utf8)

        let snapshot = try await GeminiCLIQuotaAdapter().fetch(context: makeContext(root: root))
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("verizon"))
        XCTAssertFalse(snapshot.buckets.contains { $0.displayRemainingFraction != nil })
    }

    private func writeADC(at root: URL, json: String) throws {
        let directory = root.appendingPathComponent(".config/gcloud", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json.write(
            to: directory.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeSession(
        at root: URL,
        sessionID: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int
    ) throws {
        let chats = root.appendingPathComponent(".gemini/tmp/project-hash-1/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        try """
        {"role":"user","content":"hello","timestamp":"\(iso.string(from: timestamp))"}
        {"role":"model","content":"done","timestamp":"\(iso.string(from: timestamp))","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}
        """.write(
            to: chats.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContext(
        root: URL,
        session: URLSession = URLSession(configuration: .ephemeral),
        resolvedAPIKeys: [String: String?] = [:]
    ) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            fileManager: .default,
            session: session,
            environment: [:],
            homeDirectoryURL: root,
            snapshotStore: GoogleQuotaTestSnapshotStore(),
            bridgeManager: GoogleQuotaTestClaudeBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .pro,
            xaiPlan: .unknown,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: resolvedAPIKeys
        )
    }
}

final class GoogleQuotaStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> (Int, String))?

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    static func stub(_ next: @escaping (URLRequest) -> (Int, String)) {
        lock.lock()
        handler = next
        lock.unlock()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleQuotaStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        let (status, body) = handler?(request) ?? (404, "{}")
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) {
            return text
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}

private struct GoogleQuotaTestSnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct GoogleQuotaTestClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
