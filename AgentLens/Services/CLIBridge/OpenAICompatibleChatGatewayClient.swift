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
        let result = await probeWithModels(baseURL: baseURL, bearerToken: bearerToken)
        return (result.available, result.modelName)
    }

    static func probeWithModels(baseURL: URL, bearerToken: String?) async -> (available: Bool, modelName: String?, models: [HermesAdvertisedModel]) {
        guard let url = modelsURL(baseURL: baseURL) else { return (false, nil, []) }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return (false, nil, []) }
            return (
                true,
                OpenAICompatibleModelListParser.modelName(from: data),
                OpenAICompatibleModelListParser.hermesAdvertisedModels(from: data)
            )
        } catch {
            return (false, nil, [])
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
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil,
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

        let messages = Self.buildMessages(
            systemPrompt: systemPrompt,
            history: history,
            attachmentBytes: attachmentBytes,
            capabilities: capabilities,
            workspaceURL: workspaceURL
        )

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
        messages: [[String: Any]],
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

    /// Builds the OpenAI-compatible `messages` array. When attachments are
    /// present anywhere in the history, the user-message bodies switch to the
    /// multimodal `content: [parts]` shape. Pure-text histories keep the
    /// legacy `{role, content: String}` form so older relays don't choke on
    /// unknown content types.
    static func buildMessages(
        systemPrompt: String,
        history: [ChatMessageRecord],
        attachmentBytes: [String: Data] = [:],
        capabilities: HermesBackendCapabilities = .default,
        workspaceURL: URL? = nil
    ) -> [[String: Any]] {
        let encoderMessages = history.compactMap { msg -> HermesAttachmentEncoder.Message? in
            let role: HermesAttachmentEncoder.Message.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            }
            // Pull this message's worth of attachment bytes from the caller-
            // supplied map (only the latest user message normally provides
            // bytes; persisted history attaches by metadata only).
            var msgBytes: [String: Data] = [:]
            for att in msg.attachments {
                if let data = attachmentBytes[att.id] {
                    msgBytes[att.id] = data
                }
            }
            return HermesAttachmentEncoder.Message(
                role: role,
                text: msg.content,
                attachments: msg.attachments,
                attachmentBytes: msgBytes
            )
        }
        return HermesAttachmentEncoder.encodeMessages(
            systemPrompt: systemPrompt,
            messages: encoderMessages,
            capabilities: capabilities,
            workspaceAbsolutePath: { att in
                guard let workspaceURL else { return att.workspaceRelativePath }
                return workspaceURL.appendingPathComponent(att.workspaceRelativePath).path
            }
        )
    }
}
