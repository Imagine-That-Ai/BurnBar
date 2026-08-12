import Foundation
import XCTest
import OpenBurnBarCore

/// Live integration test: verifies the local Ollama daemon is reachable
/// and returns real model data via /api/tags.
@MainActor
final class OllamaIntegrationTests: XCTestCase {

    func test_localOllamaDaemon_returnsRealModels() throws {
        let baseURL = URL(string: "http://localhost:11434")!
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5

        let reachExp = XCTestExpectation(description: "tags")
        struct ResponseState: Sendable {
            var statusCode = 0
            var data: Data?
        }
        let responseState = Locked(ResponseState())

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { reachExp.fulfill() }
            guard let http = response as? HTTPURLResponse else { return }
            responseState.write(ResponseState(statusCode: http.statusCode, data: data))
        }.resume()
        wait(for: [reachExp], timeout: 10)

        let response = responseState.read()
        guard response.statusCode == 200 else {
            print("SKIP: Ollama daemon not reachable (HTTP \(response.statusCode))")
            return
        }

        let models = response.data
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["models"] as? [[String: Any]] } ?? []
        XCTAssertFalse(models.isEmpty, "Ollama must have at least one model pulled")
        let names = models.compactMap { $0["name"] as? String }
        print("✅ OLLAMA: \(models.count) models: \(names.joined(separator: ", "))")

        // Every model must have a name
        for model in models {
            XCTAssertNotNil(model["name"] as? String, "Every model must have a name")
        }
    }
}
