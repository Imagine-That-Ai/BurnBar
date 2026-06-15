import Foundation
import OpenBurnBarCore

// MARK: - Elder Wand server-side tool loop
//
// An in-process, OpenAI-Chat-Completions-shaped tool loop the fusion
// orchestrator runs for each panel model and the judge. It speaks OpenAI wire
// format on the way in (the daemon executors translate to Anthropic when the
// resolved route is Anthropic-family), buffers each turn (`stream:false`),
// parses `tool_calls`, runs `web_search` / `web_fetch` via `ElderWandWebTools`,
// feeds the results back as `tool` messages, and loops until the model stops
// calling tools or the `max_tool_calls` budget is exhausted.
//
// The loop calls into the gateway via an injected `chat` closure that performs
// one buffered completion on an already-resolved route — so the loop has no
// knowledge of routing, credentials, or HTTP. It accumulates token usage
// across every turn so the orchestrator can record one usage event per
// sub-call.

/// One buffered completion on a resolved route. The orchestrator supplies this,
/// wiring it to the concrete executor (`proxyChatCompletions` / `proxyMessages`)
/// for the route. Always invoked with an OpenAI Chat Completions body that has
/// `stream:false`.
typealias ElderWandChatTurn = @Sendable (_ body: Data) async throws -> BurnBarProviderProxyResponse

/// Result of running the tool loop for one model.
struct ElderWandToolLoopResult: Sendable {
    /// The model's final assistant text (after any tool calls resolved).
    let text: String
    /// Aggregate token usage across every turn, summed so the orchestrator
    /// records a single usage event for this sub-call.
    let usage: BurnBarProviderProxyUsage?
    /// How many tool calls were actually executed (for diagnostics).
    let toolCallsExecuted: Int
}

struct ElderWandToolLoop: Sendable {
    private let tools: [ElderWandTool]
    private let recursionMarkerKey: String
    private let recursionMarkerValue: String
    private let logger: BurnBarDaemonLogger

    init(
        tools: [ElderWandTool],
        recursionMarkerKey: String,
        recursionMarkerValue: String,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "elder-wand-tool-loop")
    ) {
        self.tools = tools
        self.recursionMarkerKey = recursionMarkerKey
        self.recursionMarkerValue = recursionMarkerValue
        self.logger = logger
    }

    /// Run the bounded tool loop for one model.
    ///
    /// - Parameters:
    ///   - model: the wire model slug to send (the originating/panel/judge id).
    ///   - systemPrompt: optional system instruction prepended to the messages.
    ///   - userMessagesJSON: the OpenAI-shape `messages` array, serialized to
    ///     JSON (`Data` is `Sendable`, so it crosses the orchestrator's task-group
    ///     boundary cleanly; the loop deserializes it into a local, non-`Sendable`
    ///     `[[String: Any]]` it owns and never shares).
    ///   - maxToolCalls: total tool-call budget (already clamped to 1...16).
    ///   - chat: performs one buffered completion on the resolved route.
    func run(
        model: String,
        systemPrompt: String?,
        userMessagesJSON: Data,
        maxToolCalls: Int,
        chat: ElderWandChatTurn
    ) async throws -> ElderWandToolLoopResult {
        var messages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        if let decoded = try? JSONSerialization.jsonObject(with: userMessagesJSON) as? [[String: Any]] {
            messages.append(contentsOf: decoded)
        }

        let toolSchemas = tools.map { Self.foundationObject(from: $0.schema) }
        let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        var totalToolCalls = 0
        var accumulated = ElderWandUsageAccumulator()
        let budget = max(0, maxToolCalls)

        // Hard ceiling on iterations independent of tool budget so a model that
        // never emits a tool call (or always does) still terminates.
        let maxIterations = budget + 2
        for _ in 0...maxIterations {
            try Task.checkCancellation()

            // Recursion guard: inner sub-call bodies deliberately omit the
            // `plugins` block, so even if one re-entered `handleChatCompletions`
            // its `activeFusionPlugin` would be nil and fusion would not
            // re-trigger. (`recursionMarkerKey`/`Value` remain available for the
            // gateway's belt-and-suspenders header/body detection but are not
            // written onto the wire body, so no non-standard key leaks upstream.)
            var body: [String: Any] = [
                "model": model,
                "stream": false,
                "messages": messages
            ]
            if totalToolCalls < budget, !toolSchemas.isEmpty {
                body["tools"] = toolSchemas
                body["tool_choice"] = "auto"
            }

            let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
            let response = try await chat(bodyData)
            accumulated.add(response.usage)

            let object = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
            let toolCalls = Self.extractToolCalls(from: object)

            if toolCalls.isEmpty || totalToolCalls >= budget {
                let content = Self.extractAssistantContent(from: object) ?? ""
                return ElderWandToolLoopResult(
                    text: content,
                    usage: accumulated.snapshot(),
                    toolCallsExecuted: totalToolCalls
                )
            }

            // Append the assistant turn that requested the tools, then run them.
            messages.append(Self.assistantMessage(from: object))
            for call in toolCalls {
                guard totalToolCalls < budget else { break }
                totalToolCalls += 1
                let resultText: String
                if let tool = toolsByName[call.name] {
                    resultText = await tool.invoke(call.arguments)
                } else {
                    resultText = "Tool \"\(call.name)\" is not available."
                }
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": resultText
                ])
            }
            if totalToolCalls >= budget {
                messages.append([
                    "role": "system",
                    "content": "The tool-call budget for this response is exhausted. "
                        + "Finish your answer using the information already gathered."
                ])
            }
        }

        // Iteration ceiling hit without a tool-free turn: do one final
        // tool-less completion so we always return real model text.
        let finalBody: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": messages,
            "tool_choice": "none"
        ]
        let finalData = (try? JSONSerialization.data(withJSONObject: finalBody, options: [])) ?? Data("{}".utf8)
        let finalResponse = try await chat(finalData)
        accumulated.add(finalResponse.usage)
        let finalObject = (try? JSONSerialization.jsonObject(with: finalResponse.body) as? [String: Any]) ?? [:]
        let content = Self.extractAssistantContent(from: finalObject) ?? ""
        return ElderWandToolLoopResult(
            text: content,
            usage: accumulated.snapshot(),
            toolCallsExecuted: totalToolCalls
        )
    }

    // MARK: - OpenAI wire parsing

    struct ParsedToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    static func extractToolCalls(from object: [String: Any]) -> [ParsedToolCall] {
        guard let choices = object["choices"] as? [[String: Any]],
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
            } else if let nested = function["arguments"] {
                let data = (try? JSONSerialization.data(withJSONObject: nested, options: [.sortedKeys]))
                    ?? Data("{}".utf8)
                arguments = String(decoding: data, as: UTF8.self)
            } else {
                arguments = "{}"
            }
            return ParsedToolCall(id: id, name: name, arguments: arguments)
        }
    }

    static func assistantMessage(from object: [String: Any]) -> [String: Any] {
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ["role": "assistant", "content": ""]
        }
        var assistant: [String: Any] = ["role": "assistant"]
        if let content = message["content"] as? String {
            assistant["content"] = content
        } else {
            // OpenAI requires `content` present (may be null) alongside tool_calls.
            assistant["content"] = NSNull()
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            assistant["tool_calls"] = toolCalls
        }
        return assistant
    }

    static func extractAssistantContent(from object: [String: Any]) -> String? {
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message["content"] as? String
    }

    // MARK: - BurnBarJSONValue → Foundation object

    /// Convert a `BurnBarJSONValue` tool schema into the `Any`-typed Foundation
    /// object `JSONSerialization` expects when building the request body.
    static func foundationObject(from value: BurnBarJSONValue) -> Any {
        switch value {
        case .string(let string):
            return string
        case .number(let number):
            return number
        case .bool(let bool):
            return bool
        case .null:
            return NSNull()
        case .array(let array):
            return array.map { foundationObject(from: $0) }
        case .object(let object):
            var result: [String: Any] = [:]
            for (key, nested) in object {
                result[key] = foundationObject(from: nested)
            }
            return result
        }
    }
}

/// Sums token usage across the turns of one tool-loop sub-call so the
/// orchestrator records a single usage event for it. Confidence collapses to
/// the lowest seen (any estimate makes the total an estimate).
private struct ElderWandUsageAccumulator {
    private var input = 0
    private var output = 0
    private var cacheCreation = 0
    private var cacheRead = 0
    private var reasoning = 0
    private var sawAny = false
    private var confidence: BurnBarUsageConfidence = .exact

    mutating func add(_ usage: BurnBarProviderProxyUsage?) {
        guard let usage else { return }
        sawAny = true
        input += usage.inputTokens
        output += usage.outputTokens
        cacheCreation += usage.cacheCreationTokens
        cacheRead += usage.cacheReadTokens
        reasoning += usage.reasoningTokens
        confidence = ElderWandUsageAccumulator.lower(confidence, usage.confidence)
    }

    func snapshot() -> BurnBarProviderProxyUsage? {
        guard sawAny else { return nil }
        return BurnBarProviderProxyUsage(
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            reasoningTokens: reasoning,
            confidence: confidence
        )
    }

    private static func lower(
        _ lhs: BurnBarUsageConfidence,
        _ rhs: BurnBarUsageConfidence
    ) -> BurnBarUsageConfidence {
        func rank(_ value: BurnBarUsageConfidence) -> Int {
            switch value {
            case .exact: return 4
            case .derivedExact: return 3
            case .highConfidenceEstimate: return 2
            case .lowConfidenceEstimate: return 1
            case .unknown: return 0
            }
        }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }
}
