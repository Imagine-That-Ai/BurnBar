import Foundation

// MARK: - Session Summary Payload

/// JSON payload returned by LLM summary endpoints.
struct SessionSummaryPayload: Decodable {
    let title: String
    let summary: String
}

// MARK: - Summary LLM Client

/// Stateless, `Sendable` client for calling Ollama and OpenAI-compatible
/// completion endpoints to produce session summaries.
///
/// All mutable cooldown / progress state stays in `AutoSummaryEngine`;
/// this type is pure request/response I/O so it can be safely called
/// from concurrent `TaskGroup` workers.
struct SummaryLLMClient: Sendable {

    // MARK: - OpenAI-Compatible Completion

    /// Calls an OpenAI-compatible `/chat/completions` endpoint and returns
    /// the assistant's reply text, or `nil` on any failure.
    func callOpenAICompatibleCompletion(
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        timeout: Double,
        maxOutputTokens: Int,
        includeOpenRouterHeaders: Bool
    ) async -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/chat/completions") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if includeOpenRouterHeaders {
            request.setValue("OpenBurnBar", forHTTPHeaderField: "X-Title")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Return strict JSON with keys title and summary."],
                ["role": "user", "content": prompt],
            ],
            "temperature": 0.1,
            "max_tokens": maxOutputTokens,
        ]
        if model.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains("gpt-5.5") {
            body["reasoning_effort"] = "high"
        }

        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = requestBody

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            return nil
        }

        if let content = message["content"] as? String {
            return content
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    // MARK: - Ollama

    /// Calls a local Ollama `/api/generate` endpoint and returns a parsed
    /// `SessionSummaryPayload`, or `nil` on failure.
    ///
    /// Returns `(payload, shouldCooldown)` so the caller can apply cooldown
    /// logic without the client needing mutable state.
    func callOllama(
        baseURL: String,
        model: String,
        prompt: String,
        timeout: Double,
        maxOutputTokens: Int
    ) async -> (payload: SessionSummaryPayload?, shouldCooldown: Bool) {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: base)?.appendingPathComponent("api/generate"),
              !model.isEmpty
        else {
            return (nil, false)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": maxOutputTokens,
            ],
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return (nil, false)
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let nsError = error as NSError
            let cooldown = nsError.domain == NSURLErrorDomain
            return (nil, cooldown)
        }

        guard let http = response as? HTTPURLResponse else { return (nil, false) }
        guard (200 ..< 300).contains(http.statusCode) else {
            let cooldown = http.statusCode == 404 || http.statusCode == 408
                || http.statusCode == 429 || http.statusCode >= 500
            return (nil, cooldown)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String
        else {
            return (nil, false)
        }

        return (parseSummaryPayload(from: text), false)
    }

    // MARK: - Payload Parsing

    /// Attempts to decode a `SessionSummaryPayload` from raw LLM output text.
    /// Handles both clean JSON and text with embedded JSON.
    func parseSummaryPayload(from text: String) -> SessionSummaryPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SessionSummaryPayload.self, from: data) {
            return decoded
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}")
        else {
            return nil
        }
        let candidate = String(trimmed[start ... end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionSummaryPayload.self, from: data)
    }

    /// Validates and cleans a summary payload, applying title/summary length limits
    /// and substituting the fallback title when the LLM returns an empty one.
    func sanitizeSummaryPayload(
        _ payload: SessionSummaryPayload,
        fallbackTitle: String
    ) -> SessionSummaryPayload? {
        let cleanedSummary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty else { return nil }

        let cleanedTitleRaw = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = cleanedTitleRaw.isEmpty ? fallbackTitle : cleanedTitleRaw
        let normalizedTitle = cleanedTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalTitle = String(normalizedTitle.prefix(100))
        let finalSummary = String(cleanedSummary.prefix(2_000))
        guard !finalTitle.isEmpty else { return nil }
        return SessionSummaryPayload(title: finalTitle, summary: finalSummary)
    }
}
