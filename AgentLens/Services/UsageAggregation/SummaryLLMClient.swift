import Foundation

// MARK: - Session Summary Payload

/// JSON payload returned by LLM summary endpoints.
struct SessionSummaryPayload: Decodable {
    let title: String
    let summary: String
}

// MARK: - OpenAI-Compatible Chat Response

/// The one parser for an OpenAI-compatible `/chat/completions` response body.
///
/// `SummaryLLMClient` and `MemoryExtractionLLMClient` are deliberate siblings —
/// same request shape, same "return nil on any failure" posture — and each one
/// carried a verbatim copy of this walk (`choices[0].message.content`, string or
/// content-block array). Two copies of a wire-format reader is two places for the
/// two lanes to start disagreeing about what a compliant server returned, so this
/// is the single implementation both call.
///
/// Untyped by necessity: the body is third-party JSON whose `content` is either a
/// `String` or an array of blocks, so a `Decodable` model would need a custom
/// `init(from:)` that reproduces exactly this branch.
enum OpenAICompatibleChatResponse {
    /// The assistant's reply text, or `nil` when the body is not JSON, carries no
    /// choice, or carries a `content` this client cannot read. An all-empty block
    /// array is `nil` rather than `""`, matching what both call sites did before.
    static func assistantText(fromResponseBody data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(decode LLM JSON)
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
                block["text"] as? String
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
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
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": maxOutputTokens
        ]
        if model.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveContains("gpt-5.5") {
            body["reasoning_effort"] = "high"
        }

        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else { return nil } // try?-ok(encode request, skip)
        request.httpBody = requestBody

        guard let (data, response) = try? await URLSession.shared.data(for: request), // try?-ok(network fetch, skip)
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else {
            return nil
        }
        return OpenAICompatibleChatResponse.assistantText(fromResponseBody: data)
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
                "num_predict": maxOutputTokens
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { // try?-ok(encode request, skip)
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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], // try?-ok(decode LLM JSON)
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
           let decoded = try? JSONDecoder().decode(SessionSummaryPayload.self, from: data) { // try?-ok(parse LLM output)
            return decoded
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}")
        else {
            return nil
        }
        let candidate = String(trimmed[start ... end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionSummaryPayload.self, from: data) // try?-ok(parse LLM output)
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
