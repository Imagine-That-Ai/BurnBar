import Foundation

// MARK: - Memory Extraction LLM Client
//
// Stateless, `Sendable` client for calling Ollama and OpenAI-compatible completion
// endpoints to extract durable memories. A direct sibling of `SummaryLLMClient`: same
// request/response shape, same error posture (returns `nil` on any failure, never
// throws), so it is safe to call from concurrent workers. All mutable cooldown /
// progress state stays in the caller (`ChatTranscriptExtractor`).
//
// The only material differences from `SummaryLLMClient` are the system prompt (memory
// extraction, not summarization) and an OpenAI `response_format: json_object` hint so
// compliant servers return strict JSON. The hint is best-effort; the parser tolerates
// prose-wrapped JSON either way.

/// Stateless request/response I/O for the memory-extraction LLM calls.
struct MemoryExtractionLLMClient: Sendable {

    // MARK: - OpenAI-Compatible Completion

    /// Calls an OpenAI-compatible `/chat/completions` endpoint and returns the
    /// assistant's reply text, or `nil` on any failure.
    func callOpenAICompatibleCompletion(
        baseURL: String,
        apiKey: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        timeout: Double,
        maxOutputTokens: Int,
        includeOpenRouterHeaders: Bool
    ) async -> String? {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedBase + "/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if apiKey.isEmpty == false {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if includeOpenRouterHeaders {
            request.setValue("OpenBurnBar", forHTTPHeaderField: "X-Title")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.1,
            "max_tokens": maxOutputTokens,
            "response_format": ["type": "json_object"]
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

    /// Calls a local Ollama `/api/generate` endpoint and returns the raw response
    /// text plus a cooldown hint, or `(nil, shouldCooldown)` on failure. Mirrors
    /// `SummaryLLMClient.callOllama` so cooldown bookkeeping stays in the caller.
    func callOllama(
        baseURL: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        timeout: Double,
        maxOutputTokens: Int
    ) async -> (text: String?, shouldCooldown: Bool) {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: base)?.appendingPathComponent("api/generate"),
              model.isEmpty == false
        else {
            return (nil, false)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "prompt": userPrompt,
            "stream": false,
            "format": "json",
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
        return (text, false)
    }
}
