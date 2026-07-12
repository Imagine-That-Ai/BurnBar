import Foundation

public struct HermesStreamParseResult: Sendable, Equatable {
    public var events: [HermesStreamEvent]
    public var done: Bool
    public var streamedText: Bool

    public init(events: [HermesStreamEvent], done: Bool, streamedText: Bool) {
        self.events = events
        self.done = done
        self.streamedText = streamedText
    }
}

public struct HermesOpenAICompatibleStreamParser: Sendable {
    private var pendingToolCalls: [Int: PendingToolCall] = [:]

    private struct PendingToolCall: Sendable {
        var id: String
        var index: Int
        var name: String
        var arguments: String
    }

    public init() {}

    public mutating func events(fromSSELine line: String) -> HermesStreamParseResult {
        guard line.hasPrefix("data:") else {
            return HermesStreamParseResult(events: [], done: false, streamedText: false)
        }
        let payload: String
        if line.hasPrefix("data: ") {
            payload = String(line.dropFirst("data: ".count))
        } else {
            payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        }
        return events(fromDataPayload: payload)
    }

    public mutating func events(fromSSEEvent event: String) -> HermesStreamParseResult {
        let dataLines = Self.dataPayloadLines(fromSSEEvent: event)
        guard !dataLines.isEmpty else {
            return HermesStreamParseResult(events: [], done: false, streamedText: false)
        }
        return events(fromDataPayload: dataLines.joined(separator: "\n"))
    }

    public mutating func events(fromDataPayload payload: String) -> HermesStreamParseResult {
        if payload == "[DONE]" {
            return HermesStreamParseResult(events: flushPendingToolCalls(), done: true, streamedText: false)
        }

        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HermesStreamParseResult(events: [], done: false, streamedText: false)
        }
        return events(fromJSONObject: obj)
    }

    public mutating func events(fromJSONObject obj: [String: Any]) -> HermesStreamParseResult {
        var events: [HermesStreamEvent] = []
        var streamedText = false

        if let usage = Self.tokenUsageStats(from: obj["usage"] as? [String: Any] ?? obj),
           usage.outputTokens != nil
                || usage.totalTokens != nil
                || usage.promptTokens != nil
                || usage.generationDurationSeconds != nil
                || usage.totalDurationSeconds != nil {
            events.append(.messageStop(finishReason: nil, outcome: .normal, usage: usage))
        }

        if let error = Self.errorMessage(from: obj) {
            events.append(.notice(level: "error", text: error))
            return HermesStreamParseResult(events: events, done: false, streamedText: false)
        }

        guard let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first else {
            if let text = Self.visibleContentValue(obj["content"])
                ?? Self.visibleContentValue(obj["output_text"])
                ?? Self.visibleContentValue(obj["text"]) {
                events.append(.messageChunk(text: text))
                streamedText = !text.isEmpty
            }
            return HermesStreamParseResult(events: events, done: false, streamedText: streamedText)
        }

        let delta = choice["delta"] as? [String: Any]
        let finalMessage = choice["message"] as? [String: Any]

        if let refusal = Self.refusalContent(from: delta) ?? Self.refusalContent(from: finalMessage),
           !refusal.isEmpty {
            events.append(.refusalChunk(text: refusal))
        }

        if let reasoning = Self.reasoningContent(from: delta) ?? Self.reasoningContent(from: finalMessage),
           !reasoning.isEmpty {
            events.append(.reasoningChunk(text: reasoning))
        }

        if let toolCalls = Self.toolCalls(from: delta) ?? Self.toolCalls(from: finalMessage) {
            events.append(contentsOf: ingestToolCalls(toolCalls))
        }

        if let text = Self.visibleContent(from: delta)
            ?? Self.visibleContent(from: finalMessage)
            ?? Self.stringValue(choice["text"]),
           !text.isEmpty {
            events.append(contentsOf: flushPendingToolCalls())
            events.append(.messageChunk(text: text))
            streamedText = true
        }

        let finishReason = Self.stringValue(choice["finish_reason"])
            ?? Self.stringValue(choice["finishReason"])
        if let finishReason {
            events.append(contentsOf: flushPendingToolCalls())
            events.append(.messageStop(finishReason: finishReason, outcome: .normal, usage: nil))
        }

        return HermesStreamParseResult(events: events, done: false, streamedText: streamedText)
    }

    private mutating func ingestToolCalls(_ rawToolCalls: [[String: Any]]) -> [HermesStreamEvent] {
        var events: [HermesStreamEvent] = []
        for raw in rawToolCalls {
            let index = Self.intValue(raw["index"]) ?? 0
            let function = raw["function"] as? [String: Any] ?? [:]
            let idFragment = Self.stringValue(raw["id"])
            let nameFragment = Self.stringValue(function["name"]) ?? Self.stringValue(raw["name"])
            let argsFragment = Self.stringValue(function["arguments"]) ?? Self.stringValue(raw["arguments"]) ?? ""
            let id = idFragment
                ?? pendingToolCalls[index]?.id
                ?? "tool-index-\(index)"
            let name = nameFragment ?? pendingToolCalls[index]?.name ?? ""
            let previousArguments = pendingToolCalls[index]?.arguments ?? ""
            pendingToolCalls[index] = PendingToolCall(
                id: id,
                index: index,
                name: name,
                arguments: previousArguments + argsFragment
            )
            events.append(.toolCallChunk(
                id: id,
                index: index,
                name: nameFragment,
                argumentsDelta: argsFragment
            ))
        }
        return events
    }

    private mutating func flushPendingToolCalls() -> [HermesStreamEvent] {
        guard !pendingToolCalls.isEmpty else { return [] }
        let calls = pendingToolCalls.keys.sorted().compactMap { pendingToolCalls[$0] }
        pendingToolCalls.removeAll()
        return calls.map { call in
            .toolCallFinished(
                id: call.id,
                name: call.name.isEmpty ? "tool" : call.name,
                arguments: call.arguments
            )
        }
    }

    public static func dataPayloadLines(fromSSEEvent event: String) -> [String] {
        event
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { rawLine -> String? in
                let line = String(rawLine)
                if line.hasPrefix("data: ") {
                    return String(line.dropFirst("data: ".count))
                }
                if line.hasPrefix("data:") {
                    return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
    }

    public static func tokenUsageStats(from usage: [String: Any]) -> HermesTokenUsageStats? {
        let promptTokens = intValue(usage["prompt_tokens"])
            ?? intValue(usage["promptTokens"])
            ?? intValue(usage["input_tokens"])
            ?? intValue(usage["inputTokens"])
            ?? intValue(usage["prompt_eval_count"])
            ?? intValue(usage["promptEvalCount"])

        let outputTokens = intValue(usage["completion_tokens"])
            ?? intValue(usage["completionTokens"])
            ?? intValue(usage["output_tokens"])
            ?? intValue(usage["outputTokens"])
            ?? intValue(usage["eval_count"])
            ?? intValue(usage["evalCount"])

        let totalTokens = intValue(usage["total_tokens"])
            ?? intValue(usage["totalTokens"])
            ?? intValue(usage["total_token_count"])
            ?? intValue(usage["totalTokenCount"])
            ?? {
                let total = (promptTokens ?? 0) + (outputTokens ?? 0)
                return total > 0 ? total : nil
            }()

        let generationDuration = durationSecondsFromUsage(
            usage,
            keys: [
                "eval_duration", "evalDuration",
                "generation_duration", "generationDuration",
                "completion_duration", "completionDuration",
                "output_duration", "outputDuration",
                "generation_time", "generationTime"
            ]
        )

        let totalDuration = durationSecondsFromUsage(
            usage,
            keys: [
                "total_duration", "totalDuration",
                "request_duration", "requestDuration",
                "elapsed_time", "elapsedTime",
                "duration"
            ]
        )

        guard promptTokens != nil
                || outputTokens != nil
                || totalTokens != nil
                || generationDuration != nil
                || totalDuration != nil else {
            return nil
        }
        return HermesTokenUsageStats(
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            generationDurationSeconds: generationDuration,
            totalDurationSeconds: totalDuration
        )
    }

    private static func toolCalls(from item: [String: Any]?) -> [[String: Any]]? {
        guard let item else { return nil }
        if let calls = item["tool_calls"] as? [[String: Any]], !calls.isEmpty { return calls }
        if let calls = item["toolCalls"] as? [[String: Any]], !calls.isEmpty { return calls }
        if let single = item["function_call"] as? [String: Any] { return [single] }
        return nil
    }

    private static func visibleContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["content"])
            ?? visibleContentValue(item["text"])
            ?? visibleContentValue(item["output_text"])
    }

    private static func refusalContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["refusal"])
    }

    private static func reasoningContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["reasoning_content"])
            ?? visibleContentValue(item["reasoningContent"])
            ?? visibleContentValue(item["reasoning"])
            ?? visibleContentValue(item["thinking"])
    }

    private static func visibleContentValue(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text
        case let array as [Any]:
            let joined = array.compactMap(visibleContentValue).joined()
            return joined.isEmpty ? nil : joined
        case let object as [String: Any]:
            return visibleContentValue(object["text"])
                ?? visibleContentValue(object["value"])
                ?? visibleContentValue(object["content"])
        default:
            return nil
        }
    }

    private static func errorMessage(from obj: [String: Any]) -> String? {
        if let error = obj["error"] as? [String: Any] {
            return stringValue(error["message"])
                ?? stringValue(error["error"])
                ?? stringValue(error["detail"])
        }
        return stringValue(obj["error"])
            ?? stringValue(obj["message_error"])
    }

    private static func durationSecondsFromUsage(_ usage: [String: Any], keys: [String]) -> TimeInterval? {
        for key in keys {
            guard let raw = usage[key] else { continue }
            let value: Double?
            if let number = raw as? NSNumber {
                value = number.doubleValue
            } else if let string = raw as? String {
                value = Double(string)
            } else {
                value = nil
            }
            guard let value, value.isFinite, value > 0 else { continue }
            if value >= 1_000_000_000 {
                return value / 1_000_000_000.0
            } else if value >= 10_000 {
                return value / 1_000.0
            } else {
                return value
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
