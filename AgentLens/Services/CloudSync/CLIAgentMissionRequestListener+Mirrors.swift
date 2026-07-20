import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Direct CLI stream mirror and locked process output.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class DirectCLIStreamMirror: Sendable {
    struct State {
        var stdoutBuffer = ""
        var stderrBuffer = ""
        var assistantDeltaBuffer = ""
        var assistantDeltaTranscript = ""
        var latestAssistantMessage = ""
        var latestResultText = ""
        var lastReasoningEventCount = 0
    }

    let state = Locked(State())
    let assistantDeltaFlushThreshold = 480
    let reasoningEventStep = 500

    func consumeStdout(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: \.stdoutBuffer, eventSink: eventSink)
    }

    func consumeStderr(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: \.stderrBuffer, eventSink: eventSink)
    }

    func consume(
        _ text: String,
        buffer: WritableKeyPath<State, String>,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        let incomingLooksStructured = text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
        let (bufferedLooksStructured, completeLines) = state.withLock { state -> (Bool, [String]) in
            state[keyPath: buffer] += text
            let lines = state[keyPath: buffer].components(separatedBy: .newlines)
            state[keyPath: buffer] = lines.last ?? ""
            let bufferedLooksStructured = state[keyPath: buffer].trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
            return (bufferedLooksStructured, Array(lines.dropLast()))
        }

        var emitted = incomingLooksStructured || bufferedLooksStructured
        for rawLine in completeLines {
            guard let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                continue
            }
            if line.first == "{" {
                emitted = true
            }
            if let event = parseJSONLine(line) {
                eventSink(event)
                emitted = true
            }
        }
        return emitted
    }

    func parseJSONLine(_ line: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              // try?-ok(optional jsonline parse)
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        if let event = parseCodex(object: object, type: type) {
            return event
        }
        if let event = parseOpenClaude(object: object, type: type) {
            return event
        }
        if let event = parsePi(object: object, type: type) {
            return event
        }
        return nil
    }

    func parseCodex(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        if type == "thread.started" || type == "turn.started" {
            return .toolResult(
                type == "thread.started" ? "Codex session initialized." : "Codex turn started.",
                title: "LLM call started"
            )
        }

        if type == "item.started" || type == "item.completed" || type == "item.finished" {
            guard let item = object["item"] as? [String: Any],
                  let itemType = item["type"] as? String
            else { return nil }

            if itemType == "agent_message",
               let fullText = (item["text"] as? String)?.nilIfEmpty {
                let delta = state.withLock { state -> String? in
                    let previous = state.latestAssistantMessage
                    state.latestAssistantMessage = fullText
                    guard fullText.hasPrefix(previous) else { return fullText }
                    return String(fullText.dropFirst(previous.count)).nilIfEmpty
                }
                return delta.map { .assistant($0) }
            }

            if itemType == "command_execution" {
                let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if type == "item.started" {
                    return .toolCall(
                        command.map { String($0.prefix(180)) } ?? "Codex command started.",
                        title: "Bash",
                        toolName: "Bash"
                    )
                }
                let output = ((item["output"] as? String)
                    ?? (item["stdout"] as? String)
                    ?? (item["stderr"] as? String)
                    ?? (item["result"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                return .toolResult(
                    output.map { String($0.prefix(400)) }
                        ?? command.map { "Completed: \(String($0.prefix(180)))" }
                        ?? "Codex command completed.",
                    title: "Bash",
                    toolName: "Bash"
                )
            }

            if itemType == "error",
               let message = (item["message"] as? String)?.nilIfEmpty {
                return .toolResult(message, title: "Codex error", isError: true)
            }
        }

        if type == "turn.completed",
           let usage = object["usage"] as? [String: Any] {
            return .toolResult(formatUsage(usage), title: "LLM usage")
        }

        if type == "error" {
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? "Codex reported an error."
            return .toolResult(message, title: "Codex error", isError: true)
        }
        return nil
    }

    func parseOpenClaude(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        if type == "system",
           let subtype = object["subtype"] as? String,
           subtype == "init" {
            let model = object["model"] as? String
            let sessionID = object["session_id"] as? String
            return .toolResult(
                ["OpenClaude session initialized", model.map { "model=\($0)" }, sessionID.map { "session=\($0)" }]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                title: "LLM call started"
            )
        }

        if type == "stream_event",
           let event = object["event"] as? [String: Any],
           let streamType = event["type"] as? String {
            if streamType == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = (delta["text"] as? String)?.nilIfEmpty {
                return appendAssistantDelta(text)
            }
            if streamType == "content_block_stop" || streamType == "message_stop" {
                return flushAssistantDelta()
            }
            if streamType == "message_delta",
               let usage = event["usage"] as? [String: Any] {
                return .toolResult(formatUsage(usage), title: "LLM usage")
            }
        }

        if type == "assistant",
           let message = object["message"] as? [String: Any] {
            _ = flushAssistantDelta()
            return parseAssistantMessage(message, title: "Assistant", captureAsFinal: true)
        }

        if type == "result" {
            if let flushed = flushAssistantDelta() {
                return flushed
            }
            let result = (object["result"] as? String)?.nilIfEmpty
            if let result {
                storeResultText(result)
            }
            let stopReason = object["stop_reason"] as? String
            let duration = object["duration_ms"] as? Int
            let cost = object["total_cost_usd"] as? Double
            let summary = [
                result.map { "result=\($0)" },
                stopReason.map { "stopReason=\($0)" },
                duration.map { "durationMs=\($0)" },
                cost.map { "costUsd=\($0)" }
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            return summary.nilIfEmpty.map { .toolResult($0, title: "LLM result") }
        }
        return nil
    }

    func parsePi(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        if type == "session",
           let id = object["id"] as? String {
            return .toolResult("Pi session initialized\nsession=\(id)", title: "LLM call started")
        }

        if type == "message_start",
           let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            let api = message["api"] as? String
            let provider = message["provider"] as? String
            let model = message["model"] as? String
            return .toolResult(
                ["Pi assistant message started", api.map { "api=\($0)" }, provider.map { "provider=\($0)" }, model.map { "model=\($0)" }]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                title: "LLM call started"
            )
        }

        if type == "message_update",
           let update = object["assistantMessageEvent"] as? [String: Any],
           let updateType = update["type"] as? String {
            if updateType == "text_delta",
               let text = (update["delta"] as? String)?.nilIfEmpty {
                return appendAssistantDelta(text)
            }
            if updateType == "text_start",
               let partial = update["partial"] as? [String: Any] {
                return parseAssistantMessage(partial, title: "Assistant", captureAsFinal: false)
            }
            if updateType == "thinking_start" || updateType == "thinking_delta" || updateType == "thinking_end" {
                let count = ((update["partial"] as? [String: Any])?["content"] as? [[String: Any]])?
                    .compactMap { item -> String? in
                        guard (item["type"] as? String) == "thinking" else { return nil }
                        return item["thinking"] as? String
                    }
                    .joined(separator: "\n")
                    .count ?? 0
                if updateType == "thinking_start" {
                    state.withLock { $0.lastReasoningEventCount = 0 }
                    return .toolResult("Reasoning stream started.", title: "Reasoning")
                }
                if updateType == "thinking_end" {
                    state.withLock { $0.lastReasoningEventCount = count }
                    return .toolResult("Reasoning stream completed (\(count) chars available from runtime).", title: "Reasoning")
                }
                return state.withLock { state -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? in
                    guard count >= state.lastReasoningEventCount + reasoningEventStep else {
                        return nil
                    }
                    state.lastReasoningEventCount = count
                    return .toolResult("Reasoning stream updated (\(count) chars available from runtime).", title: "Reasoning")
                }
            }
        }

        if type == "message_end",
           let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            if let flushed = flushAssistantDelta() {
                return flushed
            }
            let assistantEvent = parseAssistantMessage(message, title: "Assistant", captureAsFinal: true)
            if let usage = message["usage"] as? [String: Any] {
                return .toolResult(formatUsage(usage), title: "LLM usage")
            }
            return assistantEvent
        }

        if type == "turn_end",
           let results = object["toolResults"] as? [[String: Any]],
           !results.isEmpty {
            let rendered = results.compactMap { result -> String? in
                if let name = result["toolName"] as? String {
                    return "\(name): \(result)"
                }
                return "\(result)"
            }.joined(separator: "\n\n")
            return rendered.nilIfEmpty.map { .toolResult($0, title: "Tool results") }
        }
        return nil
    }

    func appendAssistantDelta(_ text: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        state.withLock { state in
            state.assistantDeltaTranscript += text
            state.assistantDeltaBuffer += text
            let shouldFlush = state.assistantDeltaBuffer.count >= assistantDeltaFlushThreshold
                || text.contains("\n")
                || text.contains(". ")
                || text.contains(": ")
            guard shouldFlush else { return nil }
            return Self.flushAssistantDelta(&state)
        }
    }

    func flushAssistantDelta() -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        state.withLock { Self.flushAssistantDelta(&$0) }
    }

    static func flushAssistantDelta(_ state: inout State) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        let text = state.assistantDeltaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        state.assistantDeltaBuffer = ""
        return text.nilIfEmpty.map { .assistant($0, title: "Assistant delta") }
    }

    func parseAssistantMessage(
        _ message: [String: Any],
        title: String,
        captureAsFinal: Bool
    ) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        var textParts: [String] = []
        var toolEvents: [CLIAgentMissionRequestListener.DirectCLIStreamEvent] = []
        for item in content {
            guard let itemType = item["type"] as? String else { continue }
            switch itemType {
            case "text":
                if let text = (item["text"] as? String)?.nilIfEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                let name = (item["name"] as? String) ?? "Tool"
                let input = item["input"].map { "\($0)" } ?? ""
                toolEvents.append(.toolCall("\(name): \(input)", title: name, toolName: name))
            default:
                continue
            }
        }
        if let toolEvent = toolEvents.first {
            return toolEvent
        }
        let text = textParts.joined(separator: "\n")
        if captureAsFinal, let finalText = text.nilIfEmpty {
            storeAssistantMessage(finalText)
        }
        return text.nilIfEmpty.map { .assistant($0, title: title) }
    }

    func formatUsage(_ usage: [String: Any]) -> String {
        usage.keys.sorted().map { key in
            "\(key)=\(usage[key] ?? "")"
        }.joined(separator: "\n")
    }

    func storeAssistantMessage(_ text: String) {
        state.withLock { $0.latestAssistantMessage = text }
    }

    func storeResultText(_ text: String) {
        state.withLock { $0.latestResultText = text }
    }

    func finalOutputSnapshot(fallback: String?) -> String {
        _ = flushAssistantDelta()
        let candidates = state.withLock { state in
            [
                state.latestResultText,
                state.latestAssistantMessage,
                state.assistantDeltaTranscript,
                fallback ?? ""
            ]
        }
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

final class LockedProcessOutput: Sendable {
    struct State {
        var stdout = ""
        var stderr = ""
    }

    let state = Locked(State())

    func appendStdout(_ text: String) { state.withLock { $0.stdout += text } }
    func appendStderr(_ text: String) { state.withLock { $0.stderr += text } }
    func snapshot() -> (stdout: String, stderr: String) {
        state.withLock { ($0.stdout, $0.stderr) }
    }
}
