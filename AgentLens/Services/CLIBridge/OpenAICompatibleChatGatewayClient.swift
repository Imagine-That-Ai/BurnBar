import Foundation
import OpenBurnBarCore

enum OpenAICompatibleModelProbe {
    static func modelsURL(baseURL: URL) -> URL? {
        URL(string: "v1/models", relativeTo: baseURL)?.absoluteURL
    }

    static func probe(baseURL: URL, bearerToken: String?) async -> Bool {
        await probeWithModel(baseURL: baseURL, bearerToken: bearerToken).available
    }

    static func probeWithModel(baseURL: URL, bearerToken: String?) async -> (available: Bool, modelName: String?) {
        guard let url = modelsURL(baseURL: baseURL) else { return (false, nil) }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return (false, nil) }
            return (true, OpenAICompatibleModelListParser.modelName(from: data))
        } catch {
            return (false, nil)
        }
    }
}

struct OpenAICompatibleChatGatewayClient: Sendable {
    let runtime: CLIBridgeStreamRuntimeCoordinator

    /// Shared SSE path for Hermes gateway API and OpenClaw gateway (OpenAI-compatible).
    func runStream(
        baseURL: URL,
        model: String,
        systemPrompt: String,
        history: [ChatMessageRecord],
        bearerToken: String?,
        unavailableError: CLIBridgeError,
        httpStreamID: UInt64,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation
    ) async {
        defer {
            Task.detached { [runtime] in
                await runtime.clearHTTPStreamTask(streamID: httpStreamID)
            }
        }

        guard let url = URL(string: "v1/chat/completions", relativeTo: baseURL)?.absoluteURL else {
            continuation.finish(throwing: unavailableError)
            return
        }

        let messages = Self.buildMessages(systemPrompt: systemPrompt, history: history)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var streamedAnyContent = false
        var parser = OpenAICompatibleSSEParser()
        do {
            let body: [String: Any] = [
                "model": model,
                "stream": true,
                "messages": messages,
                "stream_options": ["include_usage": true]
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await session.bytes(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                continuation.finish(throwing: CLIBridgeError.hermesSSEError("HTTP \(http.statusCode)"))
                return
            }

            for try await line in bytes.lines {
                try Task.checkCancellation()

                let result = parser.events(fromLine: line)
                for event in result.events {
                    continuation.yield(event)
                }
                if result.streamedText {
                    streamedAnyContent = true
                }
                if result.done {
                    break
                }
            }
        } catch is CancellationError {
            continuation.finish()
            return
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if !streamedAnyContent {
            do {
                try Task.checkCancellation()
                let content = try await Self.nonStreamingFallback(
                    url: url,
                    messages: messages,
                    model: model,
                    session: session,
                    bearerToken: bearerToken
                )
                if !content.content.isEmpty {
                    continuation.yield(.text(content.content))
                }
                if let usage = content.usage {
                    continuation.yield(.usage(usage))
                }
            } catch is CancellationError {
                // Stream cancellation is a normal user action.
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        continuation.finish()
    }

    static func nonStreamingFallback(
        url: URL,
        messages: [[String: String]],
        model: String,
        session: URLSession,
        bearerToken: String?
    ) async throws -> (content: String, usage: CLIUsageSnapshot?) {
        let body: [String: Any] = ["model": model, "stream": false, "messages": messages]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CLIBridgeError.hermesSSEError("HTTP \(http.statusCode)")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            return ("", OpenAICompatibleUsageParser.usage(from: obj))
        }

        return (content, OpenAICompatibleUsageParser.usage(from: obj))
    }

    static func buildMessages(
        systemPrompt: String,
        history: [ChatMessageRecord]
    ) -> [[String: String]] {
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in history {
            let role: String
            switch msg.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: continue
            }
            guard !msg.content.isEmpty else { continue }
            messages.append(["role": role, "content": msg.content])
        }
        return messages
    }
}
