import OpenBurnBarEngine
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

    private static let cloudCatalogHTML = Data("""
    <html>
      <body>
        <a href="/library/kimi-k2.7-code">Kimi K2.7 Code</a>
        <a href="/library/kimi-k3">Kimi K3</a>
        <a href="/library/glm-5.2%3Acloud">GLM-5.2</a>
        <a href="/library/qwen3-coder%3A480b">Qwen3 Coder 480B</a>
        <a href="/library/deepseek-v4-flash%2Fshadow">Injected slash</a>
        <a href="/library/qwen%0Aevil">Injected newline</a>
        <a href="/library/minimax-m2.7%3Ftoken%3D1">Injected query</a>
      </body>
    </html>
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
        var hasInstalledLocalModel = false
        do {
            let (data, response) = try await URLSession.shared.data(from: probe)
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            if reachable,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = object["models"] as? [[String: Any]] {
                hasInstalledLocalModel = models.contains { row in
                    let model = ((row["model"] as? String) ?? (row["name"] as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    return !model.isEmpty
                        && !model.hasSuffix(":cloud")
                        && !model.hasSuffix("-cloud")
                }
            }
        } catch {
            reachable = false
        }
        try XCTSkipUnless(reachable, "Local Ollama not running; skipping live discovery smoke test.")
        try XCTSkipUnless(
            hasInstalledLocalModel,
            "Local Ollama has no installed non-cloud model; skipping live discovery smoke test."
        )

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

    func testOllamaCloudAdvertisesKimi27AndGLM52CloudModelsWithCredential() async throws {
        let harness = try makeHarness(name: "ollama-cloud")
        let configSnapshot = try await harness.configStore.snapshot()
        var ollama = try XCTUnwrap(configSnapshot.providers.first { $0.providerID == "ollama" })
        ollama.isEnabled = true
        ollama.preferredModelIDs = ["kimi-k2.7-code", "kimi-k3", "glm-5.2", "qwen3-coder:480b"]
        _ = try await harness.configStore.upsertProvider(ollama)
        try await harness.configStore.setSecret("ollama-cloud-token", for: "ollama")

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": request.url?.host == "ollama.com" ? "text/html" : "application/json"
                ]
            )!
            if request.url?.path == "/api/tags" {
                XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/tags")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (response, Data(#"{"models":[]}"#.utf8))
            }

            XCTAssertEqual(request.url?.absoluteString, "https://ollama.com/search?c=cloud")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (response, Self.cloudCatalogHTML)
        }
        defer { StubURLProtocol.handler = nil }

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: stubSession(),
            refreshTimeoutSeconds: 1.0
        )
        let snapshot = try await liveCatalog.snapshot()

        let cloudRows = snapshot.models.filter { $0.providerID == "ollama" }
        let cloudIDs = Set(cloudRows.map(\.id))
        XCTAssertTrue(cloudIDs.contains("kimi-k2.7-code:cloud"))
        XCTAssertTrue(cloudIDs.contains("kimi-k3:cloud"))
        XCTAssertTrue(cloudIDs.contains("glm-5.2:cloud"))
        XCTAssertTrue(cloudIDs.contains("qwen3-coder:480b:cloud"))
        XCTAssertFalse(cloudIDs.contains { $0.contains("/") })
        XCTAssertFalse(cloudIDs.contains { $0.contains("\n") })
        XCTAssertFalse(cloudIDs.contains { $0.contains("?") })
        XCTAssertEqual(cloudRows.first { $0.id == "kimi-k2.7-code:cloud" }?.routeEligible, true)
        XCTAssertEqual(cloudRows.first { $0.id == "kimi-k3:cloud" }?.routeEligible, true)
        XCTAssertEqual(cloudRows.first { $0.id == "glm-5.2:cloud" }?.routeEligible, true)
        XCTAssertEqual(cloudRows.first { $0.id == "qwen3-coder:480b:cloud" }?.routeEligible, true)
        XCTAssertEqual(cloudRows.first { $0.id == "kimi-k2.7-code:cloud" }?.modelCapabilities?.supportsImageInput, true)
        XCTAssertEqual(cloudRows.first { $0.id == "kimi-k3:cloud" }?.modelCapabilities?.supportsImageInput, true)
        XCTAssertEqual(
            cloudRows.first { $0.id == "kimi-k3:cloud" }?.modelCapabilities?.contextWindowTokens,
            1_048_576
        )
        XCTAssertEqual(
            cloudRows.first { $0.id == "glm-5.2:cloud" }?.modelCapabilities?.contextWindowTokens,
            976_000
        )
    }

    func testCodexStaticCatalogAdvertisesAliasesInsteadOfFamilyIDs() async throws {
        let harness = try makeHarness(name: "codex-static")

        let liveCatalog = BurnBarLiveModelCatalog(
            configStore: harness.configStore,
            session: stubSession(),
            refreshTimeoutSeconds: 0.05
        )
        let snapshot = try await liveCatalog.snapshot()

        let codexRows = snapshot.models.filter { $0.providerID == "codex" }
        let codexIDs = Set(codexRows.map(\.id))
        XCTAssertTrue(codexIDs.contains("gpt-5.5"))
        XCTAssertTrue(codexIDs.contains("gpt-5.5-codex"))
        XCTAssertTrue(codexIDs.contains("gpt-5.4"))
        XCTAssertFalse(codexIDs.contains("codex-gpt-5.5-family"))
        XCTAssertEqual(codexRows.first { $0.id == "gpt-5.5" }?.routeEligible, true)
        XCTAssertEqual(codexRows.first { $0.id == "gpt-5.5-codex" }?.routeEligible, true)
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
