import Foundation
import OpenBurnBarCore

enum ClaudeCodeStreamJSONParser {
    /// Emits ordered `.text` / `.toolUse` events for one NDJSON line from Claude Code `stream-json`.
    static func events(fromLine line: String) -> [CLIChatStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject else { // try?-ok(malformed line skipped)
            return []
        }

        if let message = obj["message"] as? UntypedJSONObject,
           let content = message["content"] as? [UntypedJSONObject], !content.isEmpty {
            var out: [CLIChatStreamEvent] = []
            for block in content {
                let kind = block["type"] as? String ?? ""
                if kind == "text", let text = block["text"] as? String, !text.isEmpty {
                    out.append(.text(text))
                } else if kind == "tool_use", let pair = toolUsePayload(from: block) {
                    out.append(.toolUse(name: pair.0, detail: pair.1))
                } else if kind == "tool_result", let pair = toolResultPayload(from: block) {
                    out.append(.toolResult(name: pair.0, detail: pair.1))
                }
            }
            if !out.isEmpty { return out }
        }

        if (obj["type"] as? String) == "tool_use", let pair = toolUsePayload(from: obj) {
            return [.toolUse(name: pair.0, detail: pair.1)]
        }

        if (obj["type"] as? String) == "tool_result", let pair = toolResultPayload(from: obj) {
            return [.toolResult(name: pair.0, detail: pair.1)]
        }

        if let text = extractStreamJSONText(from: obj), !text.isEmpty {
            return [.text(text)]
        }

        return []
    }

    private static func toolUsePayload(from obj: UntypedJSONObject) -> (String, String?)? {
        let name = (obj["name"] as? String) ?? (obj["tool"] as? String)
        guard let name, !name.isEmpty else { return nil }
        return (name, toolInputSummary(obj["input"] as? UntypedJSONObject))
    }

    private static func toolResultPayload(from obj: UntypedJSONObject) -> (String, String?)? {
        let name = (obj["name"] as? String)
            ?? (obj["tool"] as? String)
            ?? (obj["tool_name"] as? String)
            ?? (obj["tool_use_id"] as? String)
            ?? "Tool result"
        return (name, toolResultSummary(from: obj))
    }

    private static func toolInputSummary(_ input: UntypedJSONObject?) -> String? {
        guard let input else { return nil }
        if let p = input["path"] as? String ?? input["file_path"] as? String, !p.isEmpty { return p }
        if let c = input["command"] as? String, !c.isEmpty { return String(c.prefix(160)) }
        if let p = input["pattern"] as? String, !p.isEmpty { return p }
        if let q = input["query"] as? String, !q.isEmpty { return String(q.prefix(120)) }
        return nil
    }

    private static func toolResultSummary(from obj: UntypedJSONObject) -> String? {
        if let content = obj["content"] as? String, !content.isEmpty {
            return String(content.prefix(400))
        }
        if let text = obj["text"] as? String, !text.isEmpty {
            return String(text.prefix(400))
        }
        if let output = obj["output"] as? String, !output.isEmpty {
            return String(output.prefix(400))
        }
        if let content = obj["content"] as? [UntypedJSONObject] {
            let joined = content.compactMap { block in
                (block["text"] as? String) ?? (block["content"] as? String)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : String(joined.prefix(400))
        }
        return nil
    }

    private static func extractStreamJSONText(from obj: UntypedJSONObject) -> String? {
        if let delta = obj["delta"] as? UntypedJSONObject {
            if let text = delta["text"] as? String { return text }
            if let inner = delta["delta"] as? UntypedJSONObject, let text = inner["text"] as? String {
                return text
            }
        }

        if let message = obj["message"] as? UntypedJSONObject,
           let content = message["content"] as? [UntypedJSONObject] {
            for block in content {
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    return text
                }
            }
        }

        if let event = obj["event"] as? UntypedJSONObject,
           let delta = event["delta"] as? UntypedJSONObject,
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject else { // try?-ok(malformed line skipped)
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

    static func extractAgentMessageText(from obj: UntypedJSONObject) -> String? {
        let type = obj["type"] as? String ?? ""

        if type == "item.completed" || type == "item.updated" || type == "item.started" {
            if let item = obj["item"] as? UntypedJSONObject,
               (item["type"] as? String) == "agent_message" {
                if let text = item["text"] as? String { return text }
            }
        }

        if let item = obj["item"] as? UntypedJSONObject,
           (item["type"] as? String) == "agent_message",
           let text = item["text"] as? String {
            return text
        }

        if let message = obj["message"] as? UntypedJSONObject,
           let text = message["text"] as? String {
            return text
        }

        return nil
    }

    static func agentMessageItemId(from obj: UntypedJSONObject) -> String? {
        guard let item = obj["item"] as? UntypedJSONObject,
              (item["type"] as? String) == "agent_message" else {
            return nil
        }
        if let id = item["id"] as? String, !id.isEmpty { return id }
        return nil
    }

    static func toolEvent(from obj: UntypedJSONObject) -> CLIChatStreamEvent? {
        let type = obj["type"] as? String
        guard let item = obj["item"] as? UntypedJSONObject,
              (item["type"] as? String) == "command_execution" else {
            return nil
        }
        let command = (item["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if type == "item.completed" || type == "item.finished" {
            let output = (item["output"] as? String)
                ?? (item["stdout"] as? String)
                ?? (item["stderr"] as? String)
                ?? (item["result"] as? String)
            let trimmedOutput = output?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmedOutput.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) }
            return .toolResult(name: "Bash", detail: detail ?? command.map { "Completed: \(String($0.prefix(180)))" })
        }
        guard type == "item.started" else {
            return nil
        }
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

struct GenericCLIJSONOrTextParser {
    private var emittedText = ""

    mutating func events(fromLine line: String) -> [CLIChatStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject else { // try?-ok(falls back to raw text)
            return [.text(line + "\n")]
        }

        var events: [CLIChatStreamEvent] = []
        if let usage = OpenAICompatibleUsageParser.usage(from: obj) {
            events.append(.usage(usage))
        }
        if let tool = Self.toolEvent(from: obj) {
            events.append(tool)
        }
        guard let text = Self.extractText(from: obj)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return events
        }
        if text.hasPrefix(emittedText), text.count > emittedText.count {
            let start = text.index(text.startIndex, offsetBy: emittedText.count)
            let delta = String(text[start...])
            emittedText = text
            events.append(.text(delta))
        } else if text != emittedText {
            emittedText = text
            events.append(contentsOf: CodexExecJSONLParser.chunkedText(text).map(CLIChatStreamEvent.text))
        }
        return events
    }

    private static func extractText(from obj: UntypedJSONObject) -> String? {
        for key in ["text", "response", "output", "result", "content", "answer"] {
            if let text = obj[key] as? String, !text.isEmpty {
                return text
            }
        }
        if let message = obj["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = obj["message"] as? UntypedJSONObject {
            if let text = message["text"] as? String, !text.isEmpty { return text }
            if let content = message["content"] as? String, !content.isEmpty { return content }
            if let content = message["content"] as? [UntypedJSONObject] {
                let joined = content.compactMap { block in
                    (block["text"] as? String) ?? (block["content"] as? String)
                }
                .joined(separator: "\n")
                if !joined.isEmpty { return joined }
            }
        }
        if let delta = obj["delta"] as? UntypedJSONObject {
            if let text = delta["text"] as? String, !text.isEmpty { return text }
            if let content = delta["content"] as? String, !content.isEmpty { return content }
        }
        if let choices = obj["choices"] as? [UntypedJSONObject] {
            let joined = choices.compactMap { choice in
                if let text = choice["text"] as? String { return text }
                if let delta = choice["delta"] as? UntypedJSONObject {
                    return (delta["content"] as? String) ?? (delta["text"] as? String)
                }
                if let message = choice["message"] as? UntypedJSONObject {
                    return (message["content"] as? String) ?? (message["text"] as? String)
                }
                return nil
            }
            .joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func toolEvent(from obj: UntypedJSONObject) -> CLIChatStreamEvent? {
        let name = (obj["tool"] as? String)
            ?? (obj["tool_name"] as? String)
            ?? (obj["name"] as? String)
        guard let name, !name.isEmpty else { return nil }
        let kind = ((obj["type"] as? String) ?? (obj["event"] as? String) ?? "").lowercased()
        let detail = (obj["detail"] as? String)
            ?? (obj["command"] as? String)
            ?? (obj["path"] as? String)
            ?? (obj["output"] as? String).map { String($0.prefix(400)) }
        if kind.contains("result") || kind.contains("complete") || kind.contains("output") {
            return .toolResult(name: name, detail: detail)
        }
        return .toolUse(name: name, detail: detail)
    }
}

/// Parses the single structured JSON object emitted by `fx ask --json`.
///
/// fx prints one JSON object per invocation (fields: `output`, `exit_code`,
/// `model`, `session_id`, `steps`, `tool_calls`, and an `error` field on
/// failure). The object may span multiple stdout lines, so this parser
/// accumulates raw lines until the buffer parses as a complete JSON object,
/// then emits the whole payload at once. Anything that never parses is
/// surfaced as plain text so a human-readable fx message still reaches the
/// chat bubble.
struct FxAskJSONParser {
    private var buffer = ""
    private var emitted = false

    mutating func events(fromLine line: String) -> (events: [CLIChatStreamEvent], error: CLIBridgeError?) {
        guard !emitted else { return ([], nil) }

        if !buffer.isEmpty {
            buffer += "\n"
        }
        buffer += line

        guard let data = buffer.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject else { // try?-ok(incomplete object, keep buffering)
            return ([], nil)
        }

        emitted = true
        var events: [CLIChatStreamEvent] = []

        if let error = Self.errorMessage(from: obj) {
            return (events, .fxError(error))
        }

        if let sessionID = (obj["session_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            events.append(.sessionID(sessionID))
        }

        if let output = (obj["output"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            events.append(contentsOf: CodexExecJSONLParser.chunkedText(output).map(CLIChatStreamEvent.text))
        }

        if let toolCalls = obj["tool_calls"] as? [UntypedJSONObject] {
            for call in toolCalls {
                let name = (call["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let name, !name.isEmpty else { continue }
                let status = (call["status"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let detail = (call["detail"] as? String)
                    ?? (call["command"] as? String)
                    ?? (call["path"] as? String)
                if status == "error" || status == "failed" {
                    events.append(.toolResult(name: name, detail: detail))
                } else {
                    events.append(.toolUse(name: name, detail: detail))
                }
            }
        }

        if events.isEmpty {
            // Structured but empty: fall back to the raw payload so the user
            // still sees something rather than a silent bubble.
            events.append(.text(buffer))
        }
        return (events, nil)
    }

    /// Flushes a successful process whose stdout never formed the documented
    /// JSON object. fx can print a human-readable auth/setup message, and a
    /// truncated or schema-drifted payload is still more useful in the bubble
    /// than a silent successful response.
    mutating func finish() -> (events: [CLIChatStreamEvent], error: CLIBridgeError?) {
        guard !emitted else { return ([], nil) }
        emitted = true
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? ([], nil) : ([.text(text)], nil)
    }

    private static func errorMessage(from obj: UntypedJSONObject) -> String? {
        if let error = obj["error"] as? String, !error.isEmpty {
            return error
        }
        if let error = obj["error"] as? UntypedJSONObject {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let text = error["text"] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}

enum OpenAICompatibleUsageParser {
    static func usage(from obj: UntypedJSONObject) -> CLIUsageSnapshot? {
        let usage = (obj["usage"] as? UntypedJSONObject) ?? obj

        func firstInt(paths: [[String]]) -> Int {
            for path in paths {
                var cursor: Any = usage
                var valid = true
                for key in path {
                    guard let dict = cursor as? UntypedJSONObject, let next = dict[key] else {
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

        var inputTokens = firstInt(paths: [
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
        let exclusiveCacheReadTokens = firstInt(paths: [
            ["cache_read_input_tokens"],
            ["cache_read_tokens"],
            ["cacheReadTokens"]
        ])
        let inclusiveCacheReadTokens = firstInt(paths: [
            ["input_cached_tokens"],
            ["inputCachedTokens"],
            ["cached_tokens"],
            ["cachedTokens"],
            ["prompt_tokens_details", "cached_tokens"],
            ["promptTokensDetails", "cachedTokens"],
            ["input_tokens_details", "cached_tokens"],
            ["inputTokensDetails", "cachedTokens"],
            ["cached_input_tokens"],
            ["cachedInputTokens"]
        ])
        let cacheReadTokens = exclusiveCacheReadTokens > 0 ? exclusiveCacheReadTokens : inclusiveCacheReadTokens
        if inclusiveCacheReadTokens > 0 && exclusiveCacheReadTokens == 0 {
            inputTokens = max(inputTokens - inclusiveCacheReadTokens, 0)
        }
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
    private var parser = HermesOpenAICompatibleStreamParser()

    mutating func events(fromLine line: String) -> (events: [CLIChatStreamEvent], done: Bool, streamedText: Bool) {
        let result = parser.events(fromSSELine: line)
        var events: [CLIChatStreamEvent] = []
        if let payload = Self.payload(fromSSELine: line),
           payload != "[DONE]",
           let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject, // try?-ok(usage skipped if unparsable)
           let usage = OpenAICompatibleUsageParser.usage(from: obj) {
            events.append(.usage(usage))
        }

        for event in result.events {
            switch event {
            case .messageChunk(let text):
                events.append(.text(text))
            case .reasoningChunk(let text):
                events.append(.reasoning(text))
            case .refusalChunk(let text):
                events.append(.refusal(text))
            case .toolCallFinished(_, let name, let arguments):
                events.append(.toolUse(name: name, detail: summarizeToolArguments(arguments)))
            case .toolResult(_, let name, let detail):
                events.append(.toolResult(name: name, detail: detail))
            case .toolCallChunk, .longToolHint, .notice, .messageStop:
                break
            }
        }

        return (events, result.done, result.streamedText)
    }

    private static func payload(fromSSELine line: String) -> String? {
        if line.hasPrefix("data: ") {
            return String(line.dropFirst("data: ".count))
        }
        if line.hasPrefix("data:") {
            return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Extracts a human-readable summary from raw JSON arguments.
    /// Prioritizes: path → file_path → command → pattern → query, then falls back to
    /// a truncated raw-string preview.
    private func summarizeToolArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try JSON parse for known key extraction.
        if let obj = try? JSONSerialization.jsonObject(with: trimmed.data(using: .utf8) ?? Data()) as? UntypedJSONObject { // try?-ok(falls back to preview)
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
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject else { return nil } // try?-ok(unparsable model list)
        if let models = obj["data"] as? [UntypedJSONObject],
           let first = models.first,
           let id = first["id"] as? String, !id.isEmpty {
            return id
        }
        if let model = obj["model"] as? String, !model.isEmpty {
            return model
        }
        return nil
    }

    static func hermesAdvertisedModels(from data: Data) -> [HermesAdvertisedModel] {
        advertisedModels(from: data).compactMap { model in
            guard let family = hermesFamily(
                modelID: model.id,
                displayName: model.displayName,
                providerID: model.providerID ?? "",
                providerName: model.providerName ?? ""
            ) else {
                return nil
            }
            return HermesAdvertisedModel(id: model.id, displayName: model.displayName, family: family)
        }
    }

    static func advertisedModels(from data: Data) -> [OpenAICompatibleAdvertisedModel] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? UntypedJSONObject, // try?-ok(unparsable model list)
              let models = obj["data"] as? [UntypedJSONObject] else { return [] }
        var seen = Set<String>()
        return models.compactMap { raw in
            guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
            guard seen.insert(id).inserted else { return nil }
            let displayName = (raw["display_name"] as? String)
                ?? (raw["displayName"] as? String)
                ?? (raw["name"] as? String)
                ?? id
            let providerID = (raw["provider_id"] as? String)
                ?? (raw["providerID"] as? String)
                ?? (raw["provider"] as? String)
                ?? (raw["owned_by"] as? String)
                ?? ""
            let providerName = (raw["provider_name"] as? String)
                ?? (raw["providerName"] as? String)
                ?? ""
            let routeEligible = (raw["route_eligible"] as? Bool)
                ?? (raw["routeEligible"] as? Bool)
                ?? (raw["enabled"] as? Bool)
                ?? true
            return OpenAICompatibleAdvertisedModel(
                id: id,
                displayName: displayName,
                providerID: providerID.isEmpty ? nil : providerID,
                providerName: providerName.isEmpty ? nil : providerName,
                routeEligible: routeEligible,
                modelCapabilities: modelCapabilities(
                    from: raw["model_capabilities"] ?? raw["modelCapabilities"]
                )
            )
        }
    }

    private static func modelCapabilities(from value: Any?) -> ModelIOCapabilities? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { // try?-ok(capabilities optional)
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ModelIOCapabilities.self, from: data) // try?-ok(capabilities optional)
    }

    private static func hermesFamily(
        modelID: String,
        displayName: String,
        providerID: String,
        providerName: String
    ) -> HermesModelID? {
        let haystack = [modelID, displayName, providerID, providerName]
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if haystack.contains("claude") || haystack.contains("anthropic") { return .claude }
        if haystack.contains("codex") || haystack.contains("openai") || haystack.hasPrefix("gpt-") { return .codex }
        if haystack.contains("zai") || haystack.contains("z.ai") || haystack.contains("glm") { return .zai }
        if haystack.contains("kimi") || haystack.contains("moonshot") { return .kimi }
        if haystack.contains("minimax") { return .minimax }
        if haystack.contains("ollama") || haystack.contains("llama") || haystack.contains("mistral") || haystack.contains("qwen") { return .ollama }
        return nil
    }
}

extension CLIBridge {
    nonisolated static func openAICompatibleUsage(from obj: UntypedJSONObject) -> CLIUsageSnapshot? {
        OpenAICompatibleUsageParser.usage(from: obj)
    }

    nonisolated static func codexEventError(from message: String) -> CLIBridgeError {
        CodexExecJSONLParser.eventError(from: message)
    }
}
