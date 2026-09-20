import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OpenBurnBarKernel
@testable import OpenBurnBarQuota

final class XAIQuotaAdapterHonestyTests: XCTestCase {
    func testFetch_unknownPlanWithoutKey_namesLanesAndDoesNotPromiseLogin() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await XAIQuotaAdapter().fetch(context: makeContext(root: root, plan: .unknown))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.contains("Management Key"))
        XCTAssertTrue(message.contains("estimated"))
        XCTAssertTrue(message.contains("auth.json"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("SuperGrok login"))
    }

    func testFetch_grokBuildWithoutKey_asksForManagementKey() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await XAIQuotaAdapter().fetch(context: makeContext(root: root, plan: .grokBuild))

        XCTAssertEqual(snapshot.confidence, .unavailable)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.contains("Management Key"))
        XCTAssertTrue(message.contains("xai-mgmt-"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("SuperGrok login"))
    }

    func testFetch_superGrok_isEstimatedAndDoesNotOfferVendorLogin() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await XAIQuotaAdapter().fetch(context: makeContext(root: root, plan: .superGrok))

        XCTAssertEqual(snapshot.confidence, .estimated)
        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertTrue(snapshot.buckets[0].isEstimated)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.contains("estimated") || message.contains("remaining-quota API"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("connect"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("login"))
    }

    func testFetch_grokBuild_invalidManagementKey_isRejectedNotAuthenticated() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XAIHonestyURLProtocol.responder = { request in
            XAIHonestyURLProtocol.respond(
                status: 401,
                json: #"{ "error": { "message": "Invalid key" } }"#,
                for: request
            )
        }
        defer { XAIHonestyURLProtocol.responder = nil }

        let snapshot = try await XAIQuotaAdapter().fetch(
            context: makeContext(root: root, plan: .grokBuild, managementKey: "xai-mgmt-bad", useMockSession: true)
        )
        XCTAssertEqual(snapshot.confidence, .unavailable)
        XCTAssertTrue(snapshot.buckets.isEmpty)
        let message = try XCTUnwrap(snapshot.statusMessage)
        XCTAssertTrue(message.contains("rejected"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("authenticated"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("SuperGrok login"))
    }

    private func makeTempRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-xai-honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeContext(
        root: URL,
        plan: XAIQuotaPlanTier,
        managementKey: String? = nil,
        useMockSession: Bool = false
    ) -> ProviderQuotaAdapterContext {
        let configuration = URLSessionConfiguration.ephemeral
        if useMockSession {
            configuration.protocolClasses = [XAIHonestyURLProtocol.self]
        }
        var resolvedKeys: [String: String?] = [:]
        if let managementKey {
            resolvedKeys["xai_management_key"] = managementKey
        }
        return ProviderQuotaAdapterContext(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: root),
            fileManager: .default,
            session: URLSession(configuration: configuration),
            environment: [:],
            homeDirectoryURL: root,
            snapshotStore: XAIHonestySnapshotStore(),
            bridgeManager: XAIHonestyClaudeBridge(),
            miniMaxMode: .tokenPlan,
            factoryPlan: .unknown,
            xaiPlan: plan,
            mimoTokenPlanRegion: .sgp,
            mimoTokenPlanTier: nil,
            mimoTokenPlanBillingCycle: .monthly,
            codexRolloutScanCache: .empty,
            updateCodexRolloutScanCache: { _, _ in },
            claudeCredentialsReader: NoClaudeCredentialsReader(),
            resolvedAPIKeys: resolvedKeys
        )
    }
}

private final class XAIHonestyURLProtocol: URLProtocol {
    static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func respond(
        status: Int,
        json: String,
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.x.ai/v1/teams")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private struct XAIHonestySnapshotStore: ProviderQuotaSnapshotPersisting {
    func loadScratchString(forKey key: String) -> String? { nil }
    func saveScratchString(_ value: String, forKey key: String) {}
    func readJSONObject(from url: URL) throws -> [String: Any]? { nil }
}

private struct XAIHonestyClaudeBridge: ClaudeQuotaBridgeManaging {
    func installClaudeQuotaBridge() throws {}
    func refreshClaudeBridgeStatus() -> ClaudeQuotaBridgeStatus {
        ClaudeQuotaBridgeStatus(state: .notInstalled, wrapperPath: "", detailText: "", lastPayloadAt: nil)
    }
}
