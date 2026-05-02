import Foundation

// MARK: - Ollama Usage Probe

/// Probes a local Ollama server for model availability and runtime status.
///
/// Ollama does not expose a billing/usage API. This probe reports model
/// discovery and currently-loaded models so OpenBurnBar can surface Ollama
/// in the provider list with live status. Token accounting comes from
/// daemon event routing, not from this probe.
final class OllamaUsageProbe: ProviderUsageAPI, Sendable {
    let providerName = "Ollama"
    let authMethod: ProviderAuthMethod = .apiKey

    private let baseURL: String
    private let apiKey: String?
    private let session: URLSession

    init(baseURL: String = "http://localhost:11434", apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    func validate() async throws -> Bool {
        let url = URL(string: "\(baseURL)/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let (_, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           http.statusCode == 200 {
            return true
        }
        return false
    }

    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord] {
        // Ollama does not expose a billing/usage API.
        // Token counts come from daemon event routing when models are used.
        return []
    }
}
