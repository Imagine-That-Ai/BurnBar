import Foundation
import OpenBurnBarCore

/// SSE / streaming framing engine for the Hermes chat surface.
///
/// Owns the per-stream `HermesOpenAICompatibleStreamParser` (the canonical
/// OpenAI-compatible chunk decoder in OpenBurnBarCore) plus everything that
/// turns raw SSE payloads into mutations of an in-flight
/// `HermesChatMessage`: event framing, typed-event application, card
/// absorption, tool-call delta folding, and the deliberate 80ms commit
/// throttle for visible-text deltas (see `project_hermes_streaming_throttle`
/// — do NOT restore per-token freshness).
///
/// The engine never touches `HermesService` state directly. Its three
/// observable side effects are injected at init:
/// - `commitMessage`: replace the staged copy of the in-flight message in
///   the conversation transcript (the service performs the exact
///   `firstIndex(where: id ==)` lookup the inline code used to do).
/// - `setLastError`: surface a stream-level error string.
/// - `recordUsage`: fold token-usage stats into the per-conversation burn
///   counter (`stats`, previous total for the message).
///
/// All method bodies were moved verbatim from `HermesService`; only the
/// inline `messages[index] = message` commits, `lastError` writes, and the
/// `recordUsage(_:replacing:)` call were rewritten onto the injected
/// closures.
@MainActor
final class HermesStreamingEngine {
    private var streamEventParser = HermesOpenAICompatibleStreamParser()
    /// Last time a streaming text delta was committed via `commitMessage`.
    /// `appendVisibleContent` throttles those commits so per-token SSE
    /// events don't invalidate every `@Observable` reader; structural
    /// events and end-of-stream finalization still commit immediately.
    private var lastStreamCommit = ContinuousClock.now
    /// Minimum spacing between throttled streaming text commits.
    private static let streamCommitInterval: Duration = .milliseconds(80)

    private let commitMessage: (HermesChatMessage) -> Void
    private let setLastError: (String) -> Void
    private let recordUsage: (HermesTokenUsageStats, Int?) -> Void

    init(
        commitMessage: @escaping (HermesChatMessage) -> Void,
        setLastError: @escaping (String) -> Void,
        recordUsage: @escaping (HermesTokenUsageStats, Int?) -> Void
    ) {
        self.commitMessage = commitMessage
        self.setLastError = setLastError
        self.recordUsage = recordUsage
    }

    /// Reset the per-stream parser state. Called once at the start of each
    /// upstream stream (mirrors the old inline
    /// `streamEventParser = HermesOpenAICompatibleStreamParser()` resets).
    /// `lastStreamCommit` deliberately persists across streams, exactly as
    /// it did when it lived on the service.
    func beginStream() {
        streamEventParser = HermesOpenAICompatibleStreamParser()
    }

    func processSSEPayload(_ payload: String, into message: inout HermesChatMessage) {
        for event in Self.sseEvents(from: payload) {
            processSSEEvent(event, into: &message)
        }
    }

    /// Hermes Square §6.6 — extract any `card` / `cards` payloads from a
    /// JSON object and append them to the in-flight message. Idempotent:
    /// duplicate envelopes (matched by content hash via `CardEnvelope.id`)
    /// are skipped so re-emitted chunks don't double-render.
    private func absorbCards(from json: [String: Any], into message: inout HermesChatMessage) {
        var newCards: [CardEnvelope] = []
        if let single = json["card"] {
            if let envelope = Self.cardEnvelope(from: single) {
                newCards.append(envelope)
            }
        }
        if let batch = json["cards"] as? [Any] {
            for entry in batch {
                if let envelope = Self.cardEnvelope(from: entry) {
                    newCards.append(envelope)
                }
            }
        }
        guard !newCards.isEmpty else { return }
        let existingIDs = Set(message.cards.map(\.id))
        let appended = newCards.filter { !existingIDs.contains($0.id) }
        if !appended.isEmpty {
            message.cards.append(contentsOf: appended)
            commitMessage(message)
        }
    }

    /// Best-effort decode of a single card-shaped JSON value into a
    /// `CardEnvelope`. Accepts both the canonical
    /// `{"kind": ..., "payload": ...}` shape and a bare dictionary the
    /// envelope encoder produces. Returns nil when the value isn't a
    /// dictionary; the 2 MB budget gate is enforced via
    /// `CardEnvelope.fromJSON`.
    private static func cardEnvelope(from value: Any) -> CardEnvelope? {
        guard let dict = value as? [String: Any] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        let declaredKind = dict["kind"] as? String
        let envelope = CardEnvelope.fromJSON(data, declaredKind: declaredKind)
        // Filter the meaningless `.unknown(decode_failed)` so we don't
        // pollute the bubble with parse errors.
        if case .unknown(let label) = envelope, label == "decode_failed" {
            return nil
        }
        return envelope
    }

    nonisolated static func sseEvents(from payload: String) -> [String] {
        let normalized = payload
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .flatMap { block -> [String] in
                let lines = block
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let hasOnlyDataOrComments = lines.allSatisfy { line in
                    line.hasPrefix("data:") || line.hasPrefix(":")
                }
                let dataLines = lines.filter { $0.hasPrefix("data:") }
                if hasOnlyDataOrComments, dataLines.count > 1 {
                    return dataLines
                }
                return [block]
            }
    }

    nonisolated static func consumeSSELine(_ rawLine: String, eventLines: inout [String]) -> [String] {
        let line = rawLine.trimmingCharacters(in: .newlines)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard !eventLines.isEmpty else { return [] }
            let event = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true)
            return [event]
        }
        if line.hasPrefix("data:"),
           eventLines.contains(where: { $0.hasPrefix("data:") }) {
            let event = eventLines.joined(separator: "\n")
            eventLines.removeAll(keepingCapacity: true)
            eventLines.append(line)
            return [event]
        }
        eventLines.append(line)
        return []
    }

    private func processSSEEvent(_ event: String, into message: inout HermesChatMessage) {
        var dataLines: [String] = []
        for line in event.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix("data: ") {
                dataLines.append(String(line.dropFirst(6)))
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(":") || line.isEmpty {
                continue
            }
        }

        let data = dataLines.joined(separator: "\n")
        guard !data.isEmpty else { return }
        if data == "[DONE]" {
            let parsed = streamEventParser.events(fromDataPayload: data)
            for event in parsed.events {
                apply(event, to: &message)
            }
            return
        }

        guard let jsonData = data.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        if let modelName = modelNameValue(item: json) {
            message.applyResponseModelID(modelName)
            commitMessage(message)
        }

        if let error = json["error"] as? [String: Any],
           let messageText = error["message"] as? String {
            setLastError(messageText)
            message.text = messageText
            message.isError = true
            message.outcome = .empty
            commitMessage(message)
            return
        }
        if let upstreamError = streamingUpstreamErrorMessage(from: json) {
            setLastError(upstreamError)
            message.text = upstreamError
            message.isError = true
            message.outcome = .empty
            commitMessage(message)
            return
        }

        // Hermes Square §6.6 — typed UI card extraction. Agents emit
        // `card: {...}` for a single envelope or `cards: [{...}]` for a
        // batch. We decode through `CardEnvelope.fromJSON` so the 2 MB
        // budget gate runs uniformly and oversized payloads collapse to
        // a `.tooLarge` stub instead of corrupting the stream.
        absorbCards(from: json, into: &message)

        if let choices = json["choices"] as? [[String: Any]],
           let first = choices.first {
            // Some agents emit cards inside the choice/delta envelope (e.g.,
            // when the runtime wraps everything in OpenAI's choices[] shape).
            // Honour both placements.
            absorbCards(from: first, into: &message)
            if let deltaObject = first["delta"] as? [String: Any] {
                absorbCards(from: deltaObject, into: &message)
            }
        }

        let parsed = streamEventParser.events(fromJSONObject: json)
        for event in parsed.events {
            apply(event, to: &message)
        }
    }

    private func apply(_ event: HermesStreamEvent, to message: inout HermesChatMessage) {
        switch event {
        case .messageChunk(let text):
            appendVisibleContent(text, to: &message)
        case .reasoningChunk(let text):
            appendStreamedReasoning(text, to: &message)
        case .refusalChunk(let text):
            appendStreamedRefusal(text, to: &message)
        case .toolCallChunk(let id, let index, let name, let argumentsDelta):
            var raw: [String: Any] = [
                "id": id,
                "index": index,
                "function": ["arguments": argumentsDelta]
            ]
            if let name, !name.isEmpty {
                raw["function"] = [
                    "name": name,
                    "arguments": argumentsDelta
                ]
            }
            mergeToolCalls([raw], into: &message)
        case .toolCallFinished(let id, let name, let arguments):
            markToolCallFinished(id: id, name: name, arguments: arguments, in: &message)
        case .messageStop(let finishReason, let outcome, let usage):
            if let usage {
                applyTokenUsage(usage, to: &message)
            }
            var didUpdateTerminalFields = false
            if let finishReason, message.lastFinishReason != finishReason {
                message.lastFinishReason = finishReason
                didUpdateTerminalFields = true
            }
            if outcome != .normal, message.outcome != outcome {
                message.outcome = outcome
                didUpdateTerminalFields = true
            }
            if didUpdateTerminalFields {
                commitMessage(message)
            }
        case .notice(let level, let text):
            if level == "error" {
                setLastError(text)
                message.text = text
                message.isError = true
                message.outcome = .empty
                commitMessage(message)
            }
        case .toolResult, .longToolHint:
            break
        }
    }

    private func applyTokenUsage(_ stats: HermesTokenUsageStats, to message: inout HermesChatMessage) {
        recordUsage(stats, message.totalTokenCount)
        message.applyTokenUsage(stats)
        commitMessage(message)
    }

    private func appendVisibleContent(_ content: String, to message: inout HermesChatMessage) {
        guard !content.isEmpty else { return }
        message.markFirstResponseChunk()
        let isFirstChunk = message.text.isEmpty
        if message.text.isEmpty || content.hasPrefix(message.text) {
            message.text = content
        } else if content != message.text {
            message.text += content
        }
        // Per-token commits invalidate every `@Observable` reader of
        // `messages`, so text deltas commit at most every ~80ms. The first
        // chunk commits immediately (the bubble appears instantly); the
        // staged copy keeps accumulating either way, and structural events
        // plus the end-of-stream finalize commit unconditionally, so no
        // trailing text is ever lost.
        let now = ContinuousClock.now
        guard isFirstChunk || now - lastStreamCommit >= Self.streamCommitInterval else { return }
        lastStreamCommit = now
        commitMessage(message)
    }

    private func visibleContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["content"])
            ?? visibleContentValue(item["text"])
            ?? visibleContentValue(item["output_text"])
    }

    private func appendStreamedRefusal(_ chunk: String, to message: inout HermesChatMessage) {
        guard !chunk.isEmpty else { return }
        if message.streamedRefusal.isEmpty || chunk.hasPrefix(message.streamedRefusal) {
            message.streamedRefusal = chunk
        } else if chunk != message.streamedRefusal {
            message.streamedRefusal += chunk
        }
        commitMessage(message)
    }

    private func appendStreamedReasoning(_ chunk: String, to message: inout HermesChatMessage) {
        guard !chunk.isEmpty else { return }
        if message.streamedReasoning.isEmpty || chunk.hasPrefix(message.streamedReasoning) {
            message.streamedReasoning = chunk
        } else if chunk != message.streamedReasoning {
            message.streamedReasoning += chunk
        }
        commitMessage(message)
    }

    private func streamingUpstreamErrorMessage(from json: [String: Any]) -> String? {
        if let hermes = json["hermes"] as? [String: Any],
           boolValue(hermes["failed"]) == true
            || boolValue(hermes["completed"]) == false && stringValue(hermes["error"]) != nil {
            let message = stringValue(hermes["error"])
                ?? stringValue(hermes["message"])
                ?? "Hermes reported that the upstream model request failed."
            return HermesServiceError.upstreamModelErrorMessage(from: message)
                ?? "Hermes upstream model failed: \(message)"
        }
        guard let choices = json["choices"] as? [[String: Any]] else {
            return nil
        }
        for choice in choices {
            let finishReason = stringValue(choice["finish_reason"])
                ?? stringValue(choice["finishReason"])
            guard finishReason?.lowercased() == "error" else { continue }
            let message = visibleContent(from: choice["delta"] as? [String: Any])
                ?? visibleContent(from: choice["message"] as? [String: Any])
                ?? stringValue(choice["text"])
                ?? stringValue(json["error"])
                ?? stringValue(json["message"])
                ?? "Hermes reported that the upstream model request failed."
            return HermesServiceError.upstreamModelErrorMessage(from: message)
                ?? "Hermes upstream model failed: \(message)"
        }
        return nil
    }

    private func visibleContentValue(_ raw: Any?) -> String? {
        if let value = raw as? String {
            return value.isEmpty ? nil : value
        }
        if let object = raw as? [String: Any] {
            return visibleContentValue(object["text"])
                ?? visibleContentValue(object["value"])
                ?? visibleContentValue(object["content"])
        }
        if let array = raw as? [Any] {
            let joined = array.compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let object = part as? [String: Any] else { return nil }
                return visibleContentValue(object["text"])
                    ?? visibleContentValue(object["value"])
                    ?? visibleContentValue(object["content"])
            }
            .joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Folds an OpenAI-compatible `tool_calls` delta into the assistant message.
    ///
    /// The streaming protocol gives us one slice per chunk — the first chunk
    /// for a given `index` usually contains `function.name`, then subsequent
    /// chunks for the same `index` carry partial `function.arguments` strings
    /// that must be concatenated in order. Once we have enough of the argument
    /// JSON to parse, we extract a short `detail` preview (path, command,
    /// query, etc.) so the mobile pill can show *what* the model is doing.
    private func mergeToolCalls(_ rawToolCalls: [[String: Any]], into message: inout HermesChatMessage) {
        if !rawToolCalls.isEmpty {
            message.markFirstResponseChunk()
        }
        for raw in rawToolCalls {
            let function = raw["function"] as? [String: Any]
            let nameFragment = stringValue(function?["name"]) ?? stringValue(raw["name"])
            let argsFragment = stringValue(function?["arguments"]) ?? stringValue(raw["arguments"])

            // Prefer the OpenAI-style `index` for stable accumulation across
            // chunks. Fall back to the provider-supplied id when present.
            // As a last resort, synthesize a stable id from the current call
            // count so the pill still appears even with broken protocol.
            let indexHint: Int? = intValue(raw["index"])
            let idFromPayload = stringValue(raw["id"])
            let resolvedID: String
            if let indexHint, indexHint >= 0, indexHint < message.toolCalls.count {
                resolvedID = message.toolCalls[indexHint].id
            } else if let id = idFromPayload {
                resolvedID = id
            } else if let index = indexHint {
                resolvedID = "tool-index-\(index)"
            } else {
                resolvedID = "tool-\(message.toolCalls.count + 1)"
            }

            if let index = message.toolCalls.firstIndex(where: { $0.id == resolvedID }) {
                if let nameFragment, !nameFragment.isEmpty {
                    message.toolCalls[index].name = nameFragment
                }
                if let argsFragment, !argsFragment.isEmpty {
                    message.toolCalls[index].arguments += argsFragment
                }
                message.toolCalls[index].status = "running"
                message.toolCalls[index].detail = Self.summarizeToolArguments(
                    message.toolCalls[index].arguments
                ) ?? message.toolCalls[index].detail
            } else {
                let name = nameFragment?.isEmpty == false ? nameFragment! : "Hermes tool"
                let arguments = argsFragment ?? ""
                message.toolCalls.append(
                    HermesToolCall(
                        id: resolvedID,
                        name: name,
                        status: "running",
                        arguments: arguments,
                        detail: Self.summarizeToolArguments(arguments)
                    )
                )
            }
        }
        commitMessage(message)
    }

    private func markToolCallFinished(id: String, name: String, arguments: String, in message: inout HermesChatMessage) {
        message.markFirstResponseChunk()
        if let index = message.toolCalls.firstIndex(where: { $0.id == id }) {
            if !name.isEmpty {
                message.toolCalls[index].name = name
            }
            if message.toolCalls[index].arguments.isEmpty {
                message.toolCalls[index].arguments = arguments
            }
            message.toolCalls[index].detail = Self.summarizeToolArguments(
                message.toolCalls[index].arguments
            ) ?? message.toolCalls[index].detail
        } else {
            message.toolCalls.append(
                HermesToolCall(
                    id: id,
                    name: name.isEmpty ? "Hermes tool" : name,
                    status: "running",
                    arguments: arguments,
                    detail: Self.summarizeToolArguments(arguments)
                )
            )
        }
        commitMessage(message)
    }

    /// Extracts a one-line human-readable summary from a (possibly partial)
    /// JSON arguments string. Recognises the keys we see most often in tool
    /// invocations (file paths, shell commands, search queries, URLs).
    ///
    /// Returns `nil` when nothing meaningful can be extracted — the caller
    /// should keep any prior detail in that case so a partial chunk doesn't
    /// wipe out a previously-resolved label.
    static func summarizeToolArguments(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["path", "file_path", "command", "pattern", "query", "url", "prompt"] {
                if let value = obj[key] as? String, !value.isEmpty {
                    return String(value.prefix(200))
                }
            }
            for (_, value) in obj.sorted(by: { $0.key < $1.key }) {
                if let str = value as? String, !str.isEmpty {
                    return String(str.prefix(200))
                }
            }
        }

        // Mid-stream: arguments may still be partial JSON. Try a permissive
        // regex-ish pull on the keys the user cares about, before giving up.
        for key in ["path", "file_path", "command", "pattern", "query", "url", "prompt"] {
            let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                in: trimmed,
                range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
               ),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: trimmed) {
                let value = String(trimmed[range])
                if !value.isEmpty { return String(value.prefix(200)) }
            }
        }

        return nil
    }

    // MARK: - Value coercion (shared with HermesService's wire decoders)

    private func stringValue(_ value: Any?) -> String? {
        HermesWireValueParsing.stringValue(value)
    }

    private func modelNameValue(item: [String: Any]) -> String? {
        HermesWireValueParsing.modelNameValue(item: item)
    }

    private func intValue(_ value: Any?) -> Int? {
        HermesWireValueParsing.intValue(value)
    }

    private func boolValue(_ value: Any?) -> Bool? {
        HermesWireValueParsing.boolValue(value)
    }
}
