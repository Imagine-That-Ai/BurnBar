import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

/// Verifies the local, credential-less Ollama provider (`ollama-local`)
/// auto-discovers and advertises the machine's installed models through the
/// gateway live catalog — without any API key — and goes quiet when the local
/// server is unreachable.
final class BurnBarLocalOllamaLiveCatalogTests: XCTestCase {

    private static let modelsJSON = Data("""
    {
      "models": [
        {"name": "qwen2.5:3b", "model": "qwen2.5:3b", "details": {"parameter_size": "3.1B"}},
        {"name": "llama3.2:latest", "model": "llama3.2:latest", "details": {"parameter_size": "3.2B"}},
        {"name": "gpt-oss:120b-cloud", "model": "gpt-oss:120b-cloud", "details": {}}
      ]
    }
    """.utf8)

    func testLocalOllamaAdvertisesDiscoveredModelsWithoutCredential() async throws {
        let harness = try makeHarness(name: "ollama-local-up")
        StubURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("11434") ?? false,
                          "Only the local Ollama endpoint should be queried (no credentials configured).")
            XCTAssertEqual(request.url?.path, "/api/tags",
                           "Local discovery should use Ollama's canonical /api/tags endpoint.")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Self.modelsJSON)
        }
        defer { StubURLProtocol.handler = nil }

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: stubSession(),
            refreshTimeoutSeconds: 1.0
        )
        let snapshot = try await liveCatalog.snapshot()

        let localRows = snapshot.models.filter { $0.providerID == "ollama-local" }
        XCTAssertEqual(Set(localRows.map(\.id)), ["qwen2.5:3b", "llama3.2:latest"],
                       "Local models are discovered from /api/tags; :cloud models are filtered out and left to the Ollama Cloud provider.")
        XCTAssertFalse(localRows.contains { $0.id.contains("cloud") },
                       "Cloud-suffixed models must not be advertised by the local provider.")
        XCTAssertTrue(localRows.allSatisfy { $0.routeEligible },
                      "Local models route without an API key.")
        XCTAssertTrue(localRows.allSatisfy { $0.sourceKind == "local_ollama_models_endpoint" })

        let account = snapshot.accounts.first { $0.providerID == "ollama-local" }
        XCTAssertNotNil(account, "A local Ollama account descriptor should be present.")
        XCTAssertFalse(account?.hasCredential == false && (account?.quotaState == .missingCredential),
                       "Local provider must not be reported as missing a credential.")
    }

    func testLocalOllamaAdvertisesNothingWhenServerUnreachable() async throws {
        let harness = try makeHarness(name: "ollama-local-down")
        StubURLProtocol.handler = nil // every request fails

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: stubSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()

        let localRows = snapshot.models.filter { $0.providerID == "ollama-local" }
        XCTAssertTrue(localRows.isEmpty,
                      "No local models are advertised when the Ollama server is down.")
    }

    /// Live smoke test: runs the real discovery path against a running local
    /// Ollama daemon. Auto-skips when Ollama isn't reachable (e.g. in CI).
    func testLiveLocalOllamaDiscovery_realServer() async throws {
        let probe = URL(string: "http://localhost:11434/api/tags")!
        var reachable = false
        do {
            let (_, response) = try await URLSession.shared.data(from: probe)
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            reachable = false
        }
        try XCTSkipUnless(reachable, "Local Ollama not running; skipping live discovery smoke test.")

        let harness = try makeHarness(name: "ollama-local-live")
        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: .shared,
            refreshTimeoutSeconds: 5.0
        )
        let snapshot = try await liveCatalog.snapshot()

        let localRows = snapshot.models.filter { $0.providerID == "ollama-local" }
        XCTAssertFalse(localRows.isEmpty,
                       "A running Ollama with installed models should advertise at least one local model.")
        XCTAssertTrue(localRows.allSatisfy { $0.routeEligible },
                      "Live local models must be route-eligible without a credential.")
        XCTAssertFalse(localRows.contains { $0.id.hasSuffix(":cloud") || $0.id.hasSuffix("-cloud") },
                       "Cloud-suffixed models must be filtered from local advertising.")
    }

    // MARK: - Harness

    private struct Harness {
        let rootURL: URL
        let configStore: BurnBarConfigStore
    }

    private func makeHarness(name: String) throws -> Harness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-ollama-local-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let configStore = BurnBarConfigStore(
            fileURL: rootURL.appendingPathComponent("provider-config.json", isDirectory: false),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "ollama-local-tests")
        )
        return Harness(rootURL: rootURL, configStore: configStore)
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 1.0
        configuration.timeoutIntervalForResource = 1.0
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
