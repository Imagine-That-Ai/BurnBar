import Foundation
import OpenBurnBarCore

enum ClaudeCodeStreamJSONParser {
    /// Emits ordered `.text` / `.toolUse` events for one NDJSON line from Claude Code `stream-json`.
    static func events(fromLine line: String) -> [CLIChatStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]], !content.isEmpty {
            var out: [CLIChatStreamEvent] = []
            for block in content {
                let kind = block["type"] as? String ?? ""
                if kind == "text", let text = block["text"] as? String, !text.isEmpty {
                    out.append(.text(text))
                } else if kind == "tool_use", let pair = toolUsePayload(from: block) {
                    out.append(.toolUse(name: pair.0, detail: pair.1))
                }
            }
            if !out.isEmpty { return out }
        }

        if (obj["type"] as? String) == "tool_use", let pair = toolUsePayload(from: obj) {
            return [.toolUse(name: pair.0, detail: pair.1)]
        }

        if let text = extractStreamJSONText(from: obj), !text.isEmpty {
            return [.text(text)]
        }

        return []
    }

    private static func toolUsePayload(from obj: [String: Any]) -> (String, String?)? {
        let name = (obj["name"] as? String) ?? (obj["tool"] as? String)
        guard let name, !name.isEmpty else { return nil }
        return (name, toolInputSummary(obj["input"] as? [String: Any]))
    }

    private static func toolInputSummary(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        if let p = input["path"] as? String ?? input["file_path"] as? String, !p.isEmpty { return p }
        if let c = input["command"] as? String, !c.isEmpty { return String(c.prefix(160)) }
        if let p = input["pattern"] as? String, !p.isEmpty { return p }
        if let q = input["query"] as? String, !q.isEmpty { return String(q.prefix(120)) }
        return nil
    }

    private static func extractStreamJSONText(from obj: [String: Any]) -> String? {
        if let delta = obj["delta"] as? [String: Any] {
            if let text = delta["text"] as? String { return text }
            if let inner = delta["delta"] as? [String: Any], let text = inner["text"] as? String {
                return text
            }
        }

        if let message = obj["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for block in content {
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text
                }
            }
        }

        if let event = obj["event"] as? [String: Any],
           let delta = event["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        return nil
    }
}

struct CodexExecJSONLParser {
    private var lastAgentMessagePrefixLength = 0
    private var lastAgentMessageItemId: String?

    mutating func events(fromLine line: String) -> (events: [CLIChatStreamEvent], error: CLIBridgeError?) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }

        var events: [CLIChatStreamEvent] = []
        if let type = obj["type"] as? String {
            if type == "turn.started" || type == "thread.started" {
                lastAgentMessagePrefixLength = 0
                lastAgentMessageItemId = nil
                if type == "turn.started" {
                    events.append(.toolUse(name: "Codex", detail: "Thinking…"))
                }
            }
            if type == "error" {
                let msg = (obj["message"] as? String)
                    ?? (obj["error"] as? String)
                    ?? "Codex reported an error"
                return (events, Self.eventError(from: msg))
            }
        }

        if let toolEvent = Self.toolEvent(from: obj) {
            events.append(toolEvent)
        }

        guard let fullText = Self.extractAgentMessageText(from: obj), !fullText.isEmpty else {
            return (events, nil)
        }

        if let itemId = Self.agentMessageItemId(from: obj), itemId != lastAgentMessageItemId {
            lastAgentMessagePrefixLength = 0
            lastAgentMessageItemId = itemId
        }

        if fullText.count < lastAgentMessagePrefixLength {
            lastAgentMessagePrefixLength = 0
        }

        if fullText.count > lastAgentMessagePrefixLength {
            let previousPrefixLength = lastAgentMessagePrefixLength
            let start = fullText.index(fullText.startIndex, offsetBy: previousPrefixLength)
            let delta = String(fullText[start...])
            lastAgentMessagePrefixLength = fullText.count
            if !delta.isEmpty {
                let eventType = obj["type"] as? String ?? ""
                let shouldSoftStream = eventType == "item.completed"
                    && previousPrefixLength == 0
                    && delta.count >= 120
                if shouldSoftStream {
                    events.append(contentsOf: Self.chunkedText(delta).map(CLIChatStreamEvent.text))
                } else {
                    events.append(.text(delta))
                }
            }
        }

        return (events, nil)
    }

    static func extractAgentMessageText(from obj: [String: Any]) -> String? {
        let type = obj["type"] as? String ?? ""

        if type == "item.completed" || type == "item.updated" || type == "item.started" {
            if let item = obj["item"] as? [String: Any],
               (item["type"] as? String) == "agent_message" {
                if let text = item["text"] as? String { return text }
            }
        }

        if let item = obj["item"] as? [String: Any],
           (item["type"] as? String) == "agent_message",
           let text = item["text"] as? String {
            return text
        }

        if let message = obj["message"] as? [String: Any],
           let text = message["text"] as? String {
            return text
        }

        return nil
    }

    static func agentMessageItemId(from obj: [String: Any]) -> String? {
        guard let item = obj["item"] as? [String: Any],
              (item["type"] as? String) == "agent_message" else {
            return nil
        }
        if let id = item["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func toolEvent(from obj: [String: Any]) -> CLIChatStreamEvent? {
        guard (obj["type"] as? String) == "item.started",
              let item = obj["item"] as? [String: Any],
              (item["type"] as? String) == "command_execution" else {
            return nil
        }
        let command = (item["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command, !command.isEmpty else {
            return .toolUse(name: "Bash", detail: nil)
        }
        return .toolUse(name: "Bash", detail: String(command.prefix(180)))
    }

    static func eventError(from message: String) -> CLIBridgeError {
        if let detail = CLIQuotaExhaustionClassifier.classify(for: .codex, in: message) {
            return .quotaExhausted(detail)
        }
        return .codexEvent(message)
    }

    static func chunkedText(_ text: String, maxChunkLength: Int = 44) -> [String] {
        guard maxChunkLength > 0 else { return [text] }
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(min(maxChunkLength, text.count))

        for character in text {
            current.append(character)
            if character == "\n" || current.count >= maxChunkLength {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}

enum OpenAICompatibleUsageParser {
    static func usage(from obj: [String: Any]) -> CLIUsageSnapshot? {
        let usage = (obj["usage"] as? [String: Any]) ?? obj

        func firstInt(paths: [[String]]) -> Int {
            for path in paths {
                var cursor: Any = usage
                var valid = true
                for key in path {
                    guard let dict = cursor as? [String: Any], let next = dict[key] else {
                        valid = false
                        break
                    }
                    cursor = next
                }
                guard valid else { continue }
                if let value = cursor as? Int { return max(value, 0) }
                if let value = cursor as? Int64 { return max(Int(value), 0) }
                if let value = cursor as? Double { return max(Int(value.rounded()), 0) }
                if let value = cursor as? NSNumber { return max(value.intValue, 0) }
                if let value = cursor as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let intValue = Int(trimmed) { return max(intValue, 0) }
                    if let doubleValue = Double(trimmed) { return max(Int(doubleValue.rounded()), 0) }
                }
            }
            return 0
        }

        let inputTokens = firstInt(paths: [
            ["input_tokens"],
            ["prompt_tokens"],
            ["inputTokens"],
            ["promptTokens"]
        ])
        let outputTokens = firstInt(paths: [
            ["output_tokens"],
            ["completion_tokens"],
            ["outputTokens"],
            ["completionTokens"]
        ])
        let cacheCreationTokens = firstInt(paths: [
            ["cache_creation_input_tokens"],
            ["cache_creation_tokens"],
            ["cacheCreationTokens"]
        ])
        let cacheReadTokens = firstInt(paths: [
            ["cache_read_input_tokens"],
            ["cache_read_tokens"],
            ["cacheReadTokens"],
            ["cached_tokens"],
            ["cachedTokens"],
            ["prompt_tokens_details", "cached_tokens"],
            ["promptTokensDetails", "cachedTokens"]
        ])
        let reasoningTokens = firstInt(paths: [
            ["thinking_tokens"],
            ["reasoning_tokens"],
            ["thinkingTokens"],
            ["reasoningTokens"],
            ["completion_tokens_details", "reasoning_tokens"],
            ["output_tokens_details", "reasoning_tokens"]
        ])

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 || reasoningTokens > 0 else {
            return nil
        }

        return CLIUsageSnapshot(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens
        )
    }
}

struct OpenAICompatibleSSEParser {
    /// Accumulates tool_call argument fragments across streaming deltas.
    /// OpenAI-compatible APIs send tool_calls as multiple deltas: the first has the
    /// function name, subsequent deltas carry incremental `arguments` strings for the
    /// same index. We buffer these and flush completed tool calls when content appears
    /// or the stream ends.
    private var pendingToolCalls: [Int: PendingToolCall] = [:]

    private struct PendingToolCall {
        let index: Int
        var name: String
        var arguments: String
    }

    mutating func events(fromLine line: String) -> (events: [CLIChatStreamEvent], done: Bool, streamedText: Bool) {
        guard line.hasPrefix("data: ") else { return ([], false, false) }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]" else {
            // Stream finished — flush any buffered tool calls.
            let flushed = flushPendingToolCalls()
            return (flushed, true, false)
        }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], false, false)
        }

        var events: [CLIChatStreamEvent] = []
        if let usage = OpenAICompatibleUsageParser.usage(from: obj) {
            events.append(.usage(usage))
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first,
              let delta = choice["delta"] as? [String: Any] else {
            return (events, false, false)
        }

        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let index = tc["index"] as? Int ?? 0
                let function = tc["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                let argsFragment = function["arguments"] as? String ?? ""

                if var existing = pendingToolCalls[index] {
                    // Subsequent delta — append arguments.
                    if !name.isEmpty && existing.name.isEmpty {
                        existing.name = name
                    }
                    existing.arguments += argsFragment
                    pendingToolCalls[index] = existing
                } else if !name.isEmpty {
                    // First delta for this tool call — has the name.
                    pendingToolCalls[index] = PendingToolCall(
                        index: index,
                        name: name,
                        arguments: argsFragment
                    )
                } else if !argsFragment.isEmpty {
                    // Argument-only delta for a tool call we haven't seen a name for yet.
                    // Create a placeholder — the name should arrive in an earlier or
                    // concurrent delta. If it never does, we'll synthesize a generic name
                    // at flush time.
                    pendingToolCalls[index] = PendingToolCall(
                        index: index,
                        name: "",
                        arguments: argsFragment
                    )
                }
            }
        }

        // When the model switches from tool calls to text content, all pending tool calls
        // are complete — flush them before the text event.
        if let content = delta["content"] as? String, !content.isEmpty {
            events.append(contentsOf: flushPendingToolCalls())
            events.append(.text(content))
            return (events, false, true)
        }

        // Also flush if finish_reason indicates the assistant is done with tool calls but
        // hasn't started emitting text yet (some APIs set finish_reason on a delta that
        // only carries content or is empty).
        if let finishReason = choice["finish_reason"] as? String, finishReason == "stop" || finishReason == "tool_calls" {
            events.append(contentsOf: flushPendingToolCalls())
        }

        return (events, false, false)
    }

    /// Emits `.toolUse` events for all buffered tool calls and clears the buffer.
    private mutating func flushPendingToolCalls() -> [CLIChatStreamEvent] {
        guard !pendingToolCalls.isEmpty else { return [] }
        let sorted = pendingToolCalls.keys.sorted()
        var events: [CLIChatStreamEvent] = []
        for index in sorted {
            guard let tc = pendingToolCalls[index] else { continue }
            let name = tc.name.isEmpty ? "tool" : tc.name
            let detail = summarizeToolArguments(tc.arguments)
            events.append(.toolUse(name: name, detail: detail))
        }
        pendingToolCalls.removeAll()
        return events
    }

    /// Extracts a human-readable summary from raw JSON arguments.
    /// Prioritizes: path → file_path → command → pattern → query, then falls back to
    /// a truncated raw-string preview.
    private func summarizeToolArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try JSON parse for known key extraction.
        if let obj = try? JSONSerialization.jsonObject(with: trimmed.data(using: .utf8) ?? Data()) as? [String: Any] {
            for key in ["path", "file_path", "command", "pattern", "query", "url"] {
                if let value = obj[key] as? String, !value.isEmpty {
                    return String(value.prefix(200))
                }
            }
            // Fall back to first string value.
            for (_, value) in obj.sorted(by: { $0.key < $1.key }) {
                if let str = value as? String, !str.isEmpty {
                    return String(str.prefix(200))
                }
            }
        }

        // Not valid JSON or no interesting keys — return a truncated preview.
        return String(trimmed.prefix(200))
    }
}

enum OpenAICompatibleModelListParser {
    static func modelName(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let models = obj["data"] as? [[String: Any]],
           let first = models.first,
           let id = first["id"] as? String, !id.isEmpty {
            return id
        }
        if let model = obj["model"] as? String, !model.isEmpty {
            return model
        }
        return nil
    }
}

extension CLIBridge {
    nonisolated static func openAICompatibleUsage(from obj: [String: Any]) -> CLIUsageSnapshot? {
        OpenAICompatibleUsageParser.usage(from: obj)
    }

    nonisolated static func codexEventError(from message: String) -> CLIBridgeError {
        CodexExecJSONLParser.eventError(from: message)
    }
}
