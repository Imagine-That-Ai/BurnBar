import Foundation
import OpenBurnBarCore

// MARK: - Chart Studio Hermes Bridge
//
// One-shot, non-streaming-into-chat bridge for Chart Studio. Uses the same
// `HermesService` connection (local LAN endpoint or Remote Relay) but emits
// progressive raw text via an `AsyncThrowingStream` so the canvas can show
// a streaming skeleton without leaking studio prompts into the main chat
// transcript.

@MainActor
final class ChartStudioHermesBridge {

    enum Event: Sendable {
        case partial(String)         // accumulated raw text so far
        case completed(String)       // full final raw text
    }

    enum BridgeError: LocalizedError {
        case notConfigured(String)
        case http(Int)
        case transport(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notConfigured(let m): return m
            case .http(let c):          return "Hermes returned HTTP \(c)."
            case .transport(let m):     return m
            case .empty:                return "Hermes returned no content."
            }
        }
    }

    private let service: HermesService

    init(service: HermesService) {
        self.service = service
    }

    /// Send a Chart Studio request. Returns an async stream of events ending
    /// in `.completed` (or throws). The user's prompt is concatenated with
    /// the system prompt provided by `ChartStudioPromptEngine`.
    func send(prompt: String, systemPrompt: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [service] in
                do {
                    try await Self.run(
                        service: service,
                        prompt: prompt,
                        systemPrompt: systemPrompt,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func run(
        service: HermesService,
        prompt: String,
        systemPrompt: String,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        let body = try requestBody(
            model: service.preferredStudioModelID(),
            systemPrompt: systemPrompt,
            userPrompt: prompt
        )

        if service.selectedConnection.mode == .relayLink {
            try await runRelay(service: service, body: body, continuation: continuation)
            return
        }

        try await runDirect(service: service, body: body, continuation: continuation)
    }

    // MARK: - Direct (LAN / localhost)

    private static func runDirect(
        service: HermesService,
        body: Data,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        guard let url = service.studioEndpointURL() else {
            throw BridgeError.notConfigured("Hermes endpoint missing — pick a connection.")
        }

        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = service.studioBearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.transport("Invalid response.")
        }
        guard http.statusCode == 200 else {
            throw BridgeError.http(http.statusCode)
        }

        var accumulated = ""
        for try await line in stream.lines {
            try Task.checkCancellation()
            for delta in Self.parseSSEDeltas(rawLine: line) {
                guard !delta.isEmpty else { continue }
                accumulated.append(delta)
                continuation.yield(.partial(accumulated))
            }
        }

        guard !accumulated.isEmpty else { throw BridgeError.empty }
        continuation.yield(.completed(accumulated))
        continuation.finish()
    }

    // MARK: - Relay

    private static func runRelay(
        service: HermesService,
        body: Data,
        continuation: AsyncThrowingStream<Event, Error>.Continuation
    ) async throws {
        var accumulated = ""
        try await service.studioRelaySend(body: body) { event in
            for delta in Self.parseSSEDeltas(rawLine: event) {
                guard !delta.isEmpty else { continue }
                accumulated.append(delta)
                continuation.yield(.partial(accumulated))
            }
        }
        guard !accumulated.isEmpty else { throw BridgeError.empty }
        continuation.yield(.completed(accumulated))
        continuation.finish()
    }

    // MARK: - Body

    private static func requestBody(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) throws -> Data {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userPrompt]
            ],
            "stream": true,
            "temperature": 0.2,
            "response_format": ["type": "json_object"]
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    // MARK: - SSE delta extraction

    /// Pulls the streamed `delta.content` text out of one or more SSE blocks.
    /// Tolerates blank lines, multi-line `data:` frames, and the OpenAI-shape
    /// `[DONE]` sentinel. Returns plain text deltas the caller appends.
    nonisolated static func parseSSEDeltas(rawLine: String) -> [String] {
        let normalized = rawLine
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var out: [String] = []

        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Each block can have multiple `data:` lines.
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(line)
                let payload: String
                if line.hasPrefix("data: ") {
                    payload = String(line.dropFirst(6))
                } else if line.hasPrefix("data:") {
                    payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else {
                    continue
                }
                if payload == "[DONE]" { continue }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first {
                    if let delta = first["delta"] as? [String: Any],
                       let content = delta["content"] as? String, !content.isEmpty {
                        out.append(content)
                    } else if let message = first["message"] as? [String: Any],
                              let content = message["content"] as? String, !content.isEmpty {
                        out.append(content)
                    }
                }
            }
        }
        return out
    }
}

// MARK: - HermesService Studio Hooks

extension HermesService {
    /// Tightly-scoped accessors used by `ChartStudioHermesBridge`. We expose
    /// only what the bridge needs and keep all chat/state logic untouched.

    func preferredStudioModelID() -> String {
        selectedModelID ?? selectedConnection.advertisedModel ?? "hermes"
    }

    func studioEndpointURL() -> URL? {
        guard let endpointString = selectedConnection.endpointURL,
              let url = URL(string: endpointString) else {
            // Fallback to localhost (matches the default `baseURL` used by the
            // chat path).
            return URL(string: "http://127.0.0.1:8642/v1/chat/completions")
        }
        return url.appendingPathComponent("v1/chat/completions")
    }

    func studioBearerToken() -> String? {
        guard let token = try? HermesConnectionSecretStore.shared.load(connectionID: selectedConnection.id),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Send a Studio request through the relay path. Handed a raw HTTP body
    /// (JSON) and a closure that receives raw SSE event blocks.
    func studioRelaySend(
        body: Data,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        let payload = HermesRelayPayload(
            connectionID: selectedConnection.id,
            relayPublicKey: selectedConnection.relayPublicKey,
            relayKeyVersion: selectedConnection.relayKeyVersion,
            relayEncryption: selectedConnection.relayEncryption,
            operation: .chatCompletions,
            method: "POST",
            path: "/v1/chat/completions",
            sessionID: nil,
            body: body
        )
        try await FirestoreHermesRelayTransport.shared.sendStreaming(
            payload,
            timeout: 120,
            onSSEEvent: onSSEEvent
        )
    }
}
