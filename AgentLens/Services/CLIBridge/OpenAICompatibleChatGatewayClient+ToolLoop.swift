import CryptoKit
import Foundation
import os
import OSLog
#if canImport(Darwin)
import Darwin
#endif
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

extension OpenAICompatibleChatGatewayClient {
    static func runToolEnabledLoop(
        url: URL,
        messages originalMessages: [[String: Any]],
        model: String,
        session: URLSession,
        bearerToken: String?,
        toolBroker: AgentToolBroker,
        continuation: AsyncThrowingStream<CLIChatStreamEvent, Error>.Continuation,
        plugins: [[String: any Sendable]]? = nil,
        additionalHeaders: [String: String] = [:],
        maxToolCalls: Int = 24
    ) async {
        defer { session.invalidateAndCancel() }
        var messages = originalMessages
        var totalToolCalls = 0

        do {
            while true {
                try Task.checkCancellation()
                var body: [String: Any] = [
                    "model": model,
                    "stream": false,
                    "messages": messages
                ]
                if let plugins, !plugins.isEmpty {
                    body["plugins"] = plugins
                }
                if totalToolCalls < maxToolCalls {
                    body["tools"] = toolBroker.openAITools
                    body["tool_choice"] = "auto"
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                Self.applyNoRetentionHeaders(to: &request)
                Self.applyAdditionalHeaders(additionalHeaders, to: &request)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.finish(throwing: CLIBridgeError.hermesSSEError(Self.errorDetail(statusCode: http.statusCode, data: data)))
                    return
                }

                let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] // try?-ok(JSON parse fallback)
                if let usage = OpenAICompatibleUsageParser.usage(from: obj) {
                    continuation.yield(.usage(usage))
                }

                let toolCalls = extractOpenAIToolCalls(from: obj)
                if toolCalls.isEmpty {
                    if let content = extractAssistantContent(from: obj), !content.isEmpty {
                        continuation.yield(.text(content))
                    }
                    continuation.finish()
                    return
                }

                messages.append(buildOpenAIAssistantMessage(from: obj))

                for call in toolCalls {
                    guard totalToolCalls < maxToolCalls else { break }
                    totalToolCalls += 1
                    let detail = summarizeToolArguments(call.arguments)
                    continuation.yield(.toolUse(name: call.name, detail: detail))
                    let result = await toolBroker.invokeOpenAITool(
                        name: call.name,
                        arguments: call.arguments,
                        callID: call.id,
                        runID: "chat-tools-\(UUID().uuidString)"
                    )
                    continuation.yield(.toolResult(name: call.name, detail: result.detail))
                    messages.append([
                        "role": "tool",
                        "tool_call_id": call.id,
                        "content": wrappedToolResultContent(toolName: call.name, content: result.content)
                    ])
                }

                if totalToolCalls >= maxToolCalls {
                    messages.append([
                        "role": "system",
                        "content": "The desktop tool-call budget for this response is exhausted. Finish with the information already gathered."
                    ])
                }
            }
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    static func extractOpenAIToolCalls(from obj: [String: Any]) -> [OpenAIToolCall] {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return toolCalls.compactMap { raw in
            guard let function = raw["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else {
                return nil
            }
            let id = (raw["id"] as? String) ?? "tool-\(UUID().uuidString)"
            let arguments: String
            if let string = function["arguments"] as? String {
                arguments = string
            } else if let object = function["arguments"] {
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) // try?-ok(JSON encode fallback)
                arguments = String(decoding: data, as: UTF8.self)
            } else {
                arguments = "{}"
            }
            return OpenAIToolCall(id: id, name: name, arguments: arguments)
        }
    }

    static func buildOpenAIAssistantMessage(from obj: [String: Any]) -> [String: Any] {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ["role": "assistant", "content": ""]
        }
        var assistant: [String: Any] = [
            "role": "assistant",
            "content": message["content"] ?? NSNull()
        ]
        if let toolCalls = message["tool_calls"] {
            assistant["tool_calls"] = toolCalls
        }
        return assistant
    }

    static func extractAssistantContent(from obj: [String: Any]) -> String? {
        guard let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message["content"] as? String
    }

    /// T-AI-01 + T-AI-06: every tool result re-entering the model context is
    /// default-deny wrapped as untrusted data and secret-scrubbed first. This is
    /// the single chokepoint for the in-process tool loop, so file reads, shell
    /// stdout/stderr, clipboard, browser screenshot OCR — and any unknown future
    /// tool — are all treated as data, never instructions, and never leak a
    /// credential value back to the provider.
    static func wrappedToolResultContent(toolName: String, content: String) -> String {
        let scrubbed = AgentSecretScrubber.scrub(content)
        guard UntrustedToolOutputPolicy.shouldWrap(toolName: toolName) else {
            return scrubbed
        }
        return LLMSafeContent.wrapUntrusted(
            scrubbed,
            provenance: "tool_result:\(toolName)"
        )
    }

    private static func summarizeToolArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { // try?-ok(summary parse fallback)
            for key in ["path", "command", "url", "selector", "text", "key", "value"] {
                if let value = obj[key] as? String, !value.isEmpty {
                    return String(value.prefix(160))
                }
            }
        }
        return String(trimmed.prefix(160))
    }
}
