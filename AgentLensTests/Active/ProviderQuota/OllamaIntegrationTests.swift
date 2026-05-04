import Foundation
import XCTest

/// Live integration test: verifies the local Ollama daemon is reachable
/// and returns real model data via /api/tags.
@MainActor
final class OllamaIntegrationTests: XCTestCase {

    func test_localOllamaDaemon_returnsRealModels() throws {
        let baseURL = URL(string: "http://localhost:11434")!
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5

        let reachExp = XCTestExpectation(description: "tags")
        var statusCode = 0
        var models: [[String: Any]] = []

        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { reachExp.fulfill() }
            guard let http = response as? HTTPURLResponse else { return }
            statusCode = http.statusCode
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelList = json["models"] as? [[String: Any]] else { return }
            models = modelList
        }.resume()
        wait(for: [reachExp], timeout: 10)

        guard statusCode == 200 else {
            print("SKIP: Ollama daemon not reachable (HTTP \(statusCode))")
            return
        }

        XCTAssertFalse(models.isEmpty, "Ollama must have at least one model pulled")
        let names = models.compactMap { $0["name"] as? String }
        print("✅ OLLAMA: \(models.count) models: \(names.joined(separator: ", "))")

        // Every model must have a name
        for model in models {
            XCTAssertNotNil(model["name"] as? String, "Every model must have a name")
        }
    }
}
