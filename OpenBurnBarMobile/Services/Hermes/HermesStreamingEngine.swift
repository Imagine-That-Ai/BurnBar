import Foundation
import OpenBurnBarCore

/// Coordinator surface the streaming orchestration needs from
/// `HermesService`. The engine drives the full send pipeline (request
/// body, direct/relay/desktop-agent transports, the tool-use loop, and
/// stream-error rendering) while every piece of conversation/runtime
/// state it touches stays owned by the service and is reached through
/// this protocol — the same "engine logic, service state" split as the
/// init-injected effect closures.
@MainActor
protocol HermesStreamingCoordinating: AnyObject {
    var messages: [HermesChatMessage] { get set }
    var isStreaming: Bool { get set }
    var isReachable: Bool { get set }
    var lastError: String? { get set }
    var selectedConnection: HermesConnectionRecord { get }
    var selectedSessionID: String? { get }
    var selectedModelID: String? { get }
    var modelOptions: [HermesRuntimeModelOption] { get }
    var toolCatalog: MobileToolCatalog { get }
    var toolUseIterationCap: Int { get }
    var urlSession: URLSession { get }
    var relayTransport: HermesRelayTransporting { get }
    var remoteRelayChatCompletionTimeout: TimeInterval { get }
    var runtimeGeneration: Int { get }
    var activeRequestedModelID: String? { get }
    var activeModelName: String? { get }
    /// OpenRouter "Fusion" (`The Elder Wand`) plugin block for the active
    /// preset, or `nil` when no preset is active. When non-nil the engine
    /// injects it into the `/v1/chat/completions` body so the BurnBar daemon
    /// gateway's `ElderWandFusionOrchestrator` runs the panel + judge. The
    /// service is responsible for routing the request to the daemon gateway
    /// (port 8317) whenever this is non-nil.
    var activeElderWandPlugins: [[String: any Sendable]]? { get }
    /// Invoked at the canonical end-of-turn completion point. When the
    /// just-finished turn was a fusion run (`activeElderWandPlugins != nil`),
    /// the coordinator mints a fresh receipt token so the chat surface presents
    /// the end-of-session `FusionReceiptSheet`. A no-op for non-fusion turns.
    func presentFusionReceiptIfFusionRun()
    /// The itemized fusion session decoded from the daemon's final SSE frame
    /// (`openburnbar_fusion_spend`), or `nil` when the run produced none (the
    /// receipt then shows the authoritative quota ring only).
    var capturedFusionSpend: FusionSessionSpend? { get }
    /// Stash the itemized fusion session from the daemon's final SSE frame so the
    /// presented receipt upgrades from quota-only to itemized reactively (the
    /// frame arrives after the synthesis stream's `[DONE]`).
    func captureFusionSpend(_ session: FusionSessionSpend)
    func activeModelIDForRequest() throws -> String
    func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest
    func relayPayload(
        operation: HermesRelayOperation,
        method: String,
        path: String?,
        sessionID: String?,
        body: Data?,
        connection: HermesConnectionRecord?
    ) -> HermesRelayPayload
    func refreshRelayDiscoveryBeforeLocalSendIfNeeded() async
    func loadModels(generation: Int) async
    func persistCurrentThread()
    func shouldRunToolUseIteration(for message: HermesChatMessage) -> Bool
    func executeToolCalls(for message: inout HermesChatMessage) async -> [MobileToolExecutionResult]
}

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

    /// Itemized fusion session decoded from the daemon's final SSE frame during
    /// the stream; handed to the coordinator at the completion point (which holds
    /// the coordinator) so the receipt shows the breakdown. Reset per stream.
    private var pendingFusionSpend: FusionSessionSpend?

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
        pendingFusionSpend = nil
    }

    /// Hand any captured fusion spend to the coordinator, then trigger the
    /// receipt presentation. Called at every stream-completion exit so the
    /// itemized session (when present) is stashed before the receipt token is
    /// minted; a non-fusion turn is a no-op (no spend, present is a no-op too).
    private func finishFusionReceipt(_ coordinator: HermesStreamingCoordinating) {
        if let fusionSpend = pendingFusionSpend {
            coordinator.captureFusionSpend(fusionSpend)
            pendingFusionSpend = nil
        }
        coordinator.presentFusionReceiptIfFusionRun()
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

        // The Elder Wand emits a final SSE frame carrying the itemized fusion
        // session spend (after the synthesis stream's `[DONE]`), so iOS — which
        // runs fusion on the Mac over the relay with no local ledger — can show
        // the receipt. Capture it and stop: the frame carries no message content.
        if let spendValue = json[FusionSessionSpend.wireKey] {
            if let spendData = try? JSONSerialization.data(withJSONObject: spendValue),
               let session = try? JSONDecoder().decode(FusionSessionSpend.self, from: spendData) {
                pendingFusionSpend = session
            }
            return
        }

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

    // MARK: - Streaming orchestration (moved verbatim from HermesService)
    //
    // The whole send pipeline lives here: transport selection between
    // direct HTTP / Mac relay / desktop-agent relay, SSE consumption,
    // post-stream finalization, the tool-use loop (capped by
    // `coordinator.toolUseIterationCap`), and stream-error rendering.
    // All service state is reached via `HermesStreamingCoordinating`.

    func streamCompletion(coordinator: HermesStreamingCoordinating, context: String?, iteration: Int = 0) async throws {
        if iteration == 0 {
            await coordinator.refreshRelayDiscoveryBeforeLocalSendIfNeeded()
        }
        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E streamCompletion selected=\(coordinator.selectedConnection.id) mode=\(coordinator.selectedConnection.mode.rawValue) requestedModel=\(coordinator.activeRequestedModelID ?? "nil") modelOptions=\(coordinator.modelOptions.count)")
        #endif
        if coordinator.selectedConnection.mode == .relayLink {
            try await streamRelayCompletion(coordinator: coordinator, context: context, iteration: iteration)
            return
        }

        let body = try completionRequestBody(coordinator: coordinator, context: context)
        var request = try coordinator.makeRequest(path: "/v1/chat/completions", timeout: 60)
        request.httpMethod = "POST"
        request.httpBody = body

        let (stream, response) = try await coordinator.urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HermesServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw HermesServiceError.httpStatus(code: httpResponse.statusCode)
        }

        coordinator.isReachable = true

        var assistantMessage = HermesChatMessage(
            role: .assistant,
            text: "",
            requestedModelID: coordinator.activeRequestedModelID,
            modelName: coordinator.activeModelName,
            isStreaming: true,
            responseStartedAt: Date()
        )
        beginStream()
        coordinator.messages.append(assistantMessage)

        var eventLines: [String] = []
        do {
            for try await line in stream.lines {
                guard !Task.isCancelled else { break }
                for event in Self.consumeSSELine(line, eventLines: &eventLines) {
                    processSSEPayload(event, into: &assistantMessage)
                }
            }
        } catch {
            // The streaming engine's commit throttle can hold back up
            // to ~80ms of streamed text; flush the staged message before
            // rethrowing so the partial bubble keeps everything that arrived.
            if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                coordinator.messages[index] = assistantMessage
            }
            throw error
        }
        if !eventLines.isEmpty {
            processSSEPayload(eventLines.joined(separator: "\n"), into: &assistantMessage)
        }

        assistantMessage.isStreaming = false
        assistantMessage.toolCalls = assistantMessage.toolCalls.map {
            HermesToolCall(
                id: $0.id,
                name: $0.name,
                status: "done",
                arguments: $0.arguments,
                detail: $0.detail ?? Self.summarizeToolArguments($0.arguments)
            )
        }
        if assistantMessage.text.isEmpty && assistantMessage.toolCalls.isEmpty {
            let fallback = HermesChatMessage.emptyResponseFallback(
                refusal: assistantMessage.streamedRefusal,
                reasoning: assistantMessage.streamedReasoning,
                finishReason: assistantMessage.lastFinishReason
            )
            assistantMessage.text = fallback.text
            assistantMessage.isError = fallback.isError
            assistantMessage.outcome = fallback.outcome
        }
        assistantMessage.finalizeResponseMetrics()
        if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            coordinator.messages[index] = assistantMessage
        }
        try await runToolUseIterationIfNeeded(coordinator: coordinator, after: assistantMessage, context: context, iteration: iteration)
    }

    private func completionRequestBody(coordinator: HermesStreamingCoordinating, context: String?) throws -> Data {
        let model = try coordinator.activeModelIDForRequest()
        let capabilities = backendCapabilities(coordinator: coordinator, for: model)
        var inlineAttachmentBytesUsed = 0

        // Build encoder messages from history. We load attachment bytes for
        // user attachments only when the encoder can inline them. Workspace-
        // reference-only kinds stay as metadata, avoiding large Data reads.
        let workspaceURL = HermesAttachmentWorkspace.attachmentsRootIfReady
        let encoderMessages: [HermesAttachmentEncoder.Message] = try coordinator.messages.compactMap { message in
            let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Tool replies have an empty `text` only when something went
            // wrong upstream; keep them out of the wire payload. Assistant
            // turns with tool_calls but no text are valid and must be
            // replayed so the model sees its own prior calls.
            let hasReplayableToolCalls = message.role == .assistant
                && !message.toolCalls.isEmpty
            guard !message.isError,
                  message.role != .system,
                  hasReplayableToolCalls
                    || message.role == .tool
                    || !(content.isEmpty && message.attachments.isEmpty) else {
                return nil
            }
            let role: HermesAttachmentEncoder.Message.Role
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil
            case .tool: role = .tool
            }
            var bytesByID: [String: Data] = [:]
            if message.role == .user, !message.attachments.isEmpty, let workspaceURL {
                for attachment in message.attachments {
                    guard HermesAttachmentEncoder.shouldLoadAttachmentBytes(
                        for: attachment,
                        capabilities: capabilities
                    ) else {
                        continue
                    }
                    try Self.reserveInlineAttachmentBytes(
                        attachment.byteSize,
                        used: &inlineAttachmentBytesUsed
                    )
                    if let data = HermesAttachmentWorkspace.loadBytes(
                        for: attachment,
                        in: workspaceURL
                    ) {
                        let actualByteDelta = max(0, data.count - max(0, attachment.byteSize))
                        try Self.reserveInlineAttachmentBytes(
                            actualByteDelta,
                            used: &inlineAttachmentBytesUsed
                        )
                        bytesByID[attachment.id] = data
                    }
                }
            }
            let replayCalls: [HermesAttachmentEncoder.Message.ReplayToolCall]
            if hasReplayableToolCalls {
                replayCalls = message.toolCalls.map { call in
                    HermesAttachmentEncoder.Message.ReplayToolCall(
                        id: call.id,
                        name: call.name,
                        arguments: call.arguments
                    )
                }
            } else {
                replayCalls = []
            }
            return HermesAttachmentEncoder.Message(
                role: role,
                text: message.text,
                attachments: message.attachments,
                attachmentBytes: bytesByID,
                assistantToolCalls: replayCalls,
                toolCallID: message.toolCallID
            )
        }

        // Compose the canonical Hermes system prompt: atom directive +
        // dashboard context. The directive lives in OpenBurnBarCore and is
        // shared with the macOS app so atom emission stays consistent
        // across platforms.
        let trimmedContext = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dashboardContext = (trimmedContext?.isEmpty ?? true) ? nil : trimmedContext
        let promptBuilder = HermesSystemPromptBuilder(
            dashboardContext: dashboardContext,
            includesAtomDirective: true
        )
        let systemPrompt = promptBuilder.build()
        let workspaceForRefs = workspaceURL
        let requestMessages = HermesAttachmentEncoder.encodeMessages(
            systemPrompt: systemPrompt,
            messages: encoderMessages,
            capabilities: capabilities,
            workspaceAbsolutePath: { att in
                guard let workspaceForRefs else { return att.workspaceRelativePath }
                return workspaceForRefs.appendingPathComponent(att.workspaceRelativePath).path
            }
        )

        var payload: [String: Any] = [
            "model": model,
            "messages": requestMessages,
            "stream": true
        ]
        payload["stream_options"] = [
            "include_usage": true
        ]
        // Advertise on-device tools so the model can navigate the app, read
        // session metadata, and answer "are you online?" honestly. Empty
        // arrays are deliberately omitted — some upstream gateways
        // reject `tools: []` as malformed.
        let toolsArray = coordinator.toolCatalog.toolsWireArray()
        if !toolsArray.isEmpty {
            payload["tools"] = toolsArray
            // Default tool choice; left as a string for max compatibility
            // (a `{type, function}` object trips up some older relays).
            payload["tool_choice"] = "auto"
        }
        if let sessionID = coordinator.selectedSessionID {
            payload["session_id"] = sessionID
        }
        // The Elder Wand (OpenRouter "Fusion") plugin block. Present only when
        // a preset is active; mirrors the macOS payload shape verbatim
        // ([{ "id":"fusion", "analysis_models":[…], "model":<judge>,
        // "max_tool_calls":<n> }]). The BurnBar daemon gateway picks it up and
        // runs the panel + judge; non-fusion gateways ignore the unknown key.
        if let plugins = coordinator.activeElderWandPlugins, !plugins.isEmpty {
            payload["plugins"] = plugins
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func reserveInlineAttachmentBytes(_ byteCount: Int, used: inout Int) throws {
        let safeByteCount = max(0, byteCount)
        let remaining = max(0, HermesAttachmentLimits.maxInlineRequestBytes - used)
        guard safeByteCount <= remaining else {
            let limit = HermesAttachmentEncoder.formatBytes(HermesAttachmentLimits.maxInlineRequestBytes)
            throw HermesServiceError.relayUnavailable(
                "Selected attachments are too large to send inline together. Send fewer attachments at once, or keep large files as workspace references. Limit: \(limit)."
            )
        }
        used += safeByteCount
    }

    /// Capability hints used by the encoder. Defaults to vision-on,
    /// audio-off; refined when we learn more from `/v1/models`.
    private func backendCapabilities(coordinator: HermesStreamingCoordinating, for modelID: String) -> HermesBackendCapabilities {
        coordinator.modelOptions.first { $0.modelID.caseInsensitiveCompare(modelID) == .orderedSame }?
            .backendCapabilities
            ?? HermesBackendCapabilities.default
    }

    private func streamRelayCompletion(coordinator: HermesStreamingCoordinating, context: String?, iteration: Int = 0) async throws {
        await ensureRelayModelCatalogLoadedBeforeSend(coordinator: coordinator)
        if iteration == 0, shouldUseDesktopAgentRelay(coordinator: coordinator) {
            try await streamDesktopAgentRelayCompletion(coordinator: coordinator, context: context)
            return
        }
        let body = try completionRequestBody(coordinator: coordinator, context: context)
        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E streamRelayCompletion start connection=\(coordinator.selectedConnection.id) requestedModel=\(coordinator.activeRequestedModelID ?? "nil") bodyBytes=\(body.count)")
        #endif
        coordinator.isReachable = true

        var assistantMessage = HermesChatMessage(
            role: .assistant,
            text: "",
            requestedModelID: coordinator.activeRequestedModelID,
            modelName: coordinator.activeModelName,
            isStreaming: true,
            responseStartedAt: Date()
        )
        beginStream()
        coordinator.messages.append(assistantMessage)

        do {
            try await coordinator.relayTransport.sendStreaming(
                coordinator.relayPayload(operation: .chatCompletions, method: "POST", path: "/v1/chat/completions", sessionID: nil, body: body, connection: nil),
                timeout: coordinator.remoteRelayChatCompletionTimeout
            ) { event in
                self.processSSEPayload(event, into: &assistantMessage)
            }
        } catch {
            // The streaming engine's commit throttle can hold back up
            // to ~80ms of streamed text; flush the staged message before
            // rethrowing so the partial bubble keeps everything that arrived.
            if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                coordinator.messages[index] = assistantMessage
            }
            throw error
        }
        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E streamRelayCompletion finished connection=\(coordinator.selectedConnection.id)")
        #endif

        assistantMessage.isStreaming = false
        assistantMessage.toolCalls = assistantMessage.toolCalls.map {
            HermesToolCall(
                id: $0.id,
                name: $0.name,
                status: "done",
                arguments: $0.arguments,
                detail: $0.detail ?? Self.summarizeToolArguments($0.arguments)
            )
        }
        if assistantMessage.text.isEmpty && assistantMessage.toolCalls.isEmpty {
            let fallback = HermesChatMessage.emptyResponseFallback(
                refusal: assistantMessage.streamedRefusal,
                reasoning: assistantMessage.streamedReasoning,
                finishReason: assistantMessage.lastFinishReason
            )
            assistantMessage.text = fallback.text
            assistantMessage.isError = fallback.isError
            assistantMessage.outcome = fallback.outcome
        }
        assistantMessage.finalizeResponseMetrics()
        if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            coordinator.messages[index] = assistantMessage
        }
        try await runToolUseIterationIfNeeded(coordinator: coordinator, after: assistantMessage, context: context, iteration: iteration)
    }

    private func shouldUseDesktopAgentRelay(coordinator: HermesStreamingCoordinating) -> Bool {
        guard coordinator.selectedConnection.mode == .relayLink,
              let threadID = coordinator.selectedSessionID else { return false }
        return MobileAgentPermissionGrantController.shared.optimisticGrant(
            runtimeID: .hermes,
            threadID: threadID
        ) != nil
    }

    private func streamDesktopAgentRelayCompletion(coordinator: HermesStreamingCoordinating, context: String?) async throws {
        guard let threadID = coordinator.selectedSessionID else {
            throw HermesServiceError.relayUnavailable("Create a chat thread before granting desktop permissions.")
        }
        let prompt = coordinator.messages.last(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty else {
            throw HermesServiceError.relayUnavailable("Desktop agent relay needs a text prompt.")
        }
        let modelID = try coordinator.activeModelIDForRequest()
        var assistantMessage = HermesChatMessage(
            role: .assistant,
            text: "",
            requestedModelID: coordinator.activeRequestedModelID,
            modelName: coordinator.activeModelName,
            isStreaming: true,
            responseStartedAt: Date()
        )
        coordinator.messages.append(assistantMessage)

        try await CLIAgentRelayChatTransport.shared.stream(
            runtimeID: .hermes,
            threadID: threadID,
            prompt: prompt,
            title: HermesConversationStateStore.derivedTitle(from: coordinator.messages),
            modelID: modelID,
            parentSessionID: nil,
            resumeAction: "continue",
            onEvent: { event in
                if let text = event.text {
                    assistantMessage.text = text
                    SystemPermissionTextClassifier.shared.observeAssistantText(
                        text,
                        threadID: threadID,
                        toolCallId: assistantMessage.id
                    )
                }
                if let modelID = event.modelID {
                    assistantMessage.modelName = modelID
                }
                assistantMessage.isError = event.isError
                if event.isTerminal {
                    assistantMessage.isStreaming = false
                }
                if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
                    coordinator.messages[index] = assistantMessage
                }
            }
        )
        assistantMessage.isStreaming = false
        if assistantMessage.text.isEmpty {
            assistantMessage.text = "The Mac relay completed without returning text."
        }
        assistantMessage.finalizeResponseMetrics()
        if let index = coordinator.messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            coordinator.messages[index] = assistantMessage
        }
        coordinator.isStreaming = false
        // End-of-session receipt: when this was a fusion run, present the Elder
        // Wand receipt. No-op otherwise.
        finishFusionReceipt(coordinator)
    }

    private func ensureRelayModelCatalogLoadedBeforeSend(coordinator: HermesStreamingCoordinating) async {
        guard coordinator.selectedConnection.mode == .relayLink, coordinator.modelOptions.isEmpty else { return }
        if coordinator.selectedModelID?.nilIfBlank != nil {
            return
        }
        await coordinator.loadModels(generation: coordinator.runtimeGeneration)
    }

    /// Shared post-stream step: if the assistant turn produced tool
    /// calls that the on-device catalog can execute, run them, append
    /// the matching `role: .tool` reply messages, and re-stream so the
    /// model can produce a final natural-language reply incorporating
    /// the results. Iteration cap protects against infinite tool loops.
    private func runToolUseIterationIfNeeded(
        coordinator: HermesStreamingCoordinating,
        after message: HermesChatMessage,
        context: String?,
        iteration: Int
    ) async throws {
        guard coordinator.shouldRunToolUseIteration(for: message) else {
            coordinator.isStreaming = false
            // The turn is fully complete (no tool iteration follows): present
            // the Elder Wand receipt when this was a fusion run. No-op
            // otherwise. Fires once per run because the tool-use loop re-enters
            // `streamCompletion` and only returns to a terminal exit here when
            // the run is truly finished.
            finishFusionReceipt(coordinator)
            return
        }
        guard iteration < coordinator.toolUseIterationCap else {
            // Cap exceeded — leave the pills as "done" but stop looping.
            coordinator.isStreaming = false
            finishFusionReceipt(coordinator)
            return
        }

        var mutableMessage = message
        await coordinator.executeToolCalls(for: &mutableMessage)
        // `executeToolCalls` already appended the tool reply messages
        // and rewrote `messages` with updated call statuses. Persist
        // the running thread so iOS history reflects the in-flight
        // tool exchange (useful when the app is backgrounded mid-loop).
        coordinator.persistCurrentThread()

        // Re-enter — the next iteration sees the tool replies via the
        // `completionRequestBody` encoder and emits a follow-up turn.
        try await streamCompletion(coordinator: coordinator, context: context, iteration: iteration + 1)
    }

    func handleStreamError(_ error: Error, coordinator: HermesStreamingCoordinating) {
        coordinator.isStreaming = false
        coordinator.isReachable = false

        let displayText: String
        if let hermesError = error as? HermesServiceError {
            displayText = hermesError.localizedDescription
        } else if let firestoreError = error as? FirestoreError {
            switch firestoreError {
            case .firebaseUnavailable:
                displayText = "Firebase is not configured for this build, so Remote Relay is unavailable."
            case .notAuthenticated:
                displayText = "Sign in with the same OpenBurnBar account on this iPhone/iPad to use Remote Relay."
            case .decodingFailed(let message):
                displayText = message
            }
        } else if let urlError = error as? URLError {
            if urlError.code == .cannotConnectToHost || urlError.code == .notConnectedToInternet {
                if coordinator.selectedConnection.mode == .relayLink {
                    displayText = "Remote Hermes relay is offline. Keep OpenBurnBar running on your Mac, signed in to this account, with Hermes reachable there."
                } else {
                    displayText = "Hermes is not reachable. Use a Remote Relay connection when your iPhone is away from your home network, or make sure both devices are on the same network."
                }
            } else {
                displayText = "Connection error: \(urlError.localizedDescription)"
            }
        } else {
            displayText = "Connection error: \(error.localizedDescription)"
        }

        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E streamError selected=\(coordinator.selectedConnection.id) mode=\(coordinator.selectedConnection.mode.rawValue) error=\(error.localizedDescription) display=\(displayText)")
        #endif

        let errorMessage = HermesChatMessage(
            role: .assistant,
            text: displayText,
            isError: true
        )
        if let index = coordinator.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming && $0.text.isEmpty && $0.toolCalls.isEmpty }) {
            coordinator.messages[index] = errorMessage
        } else {
            coordinator.messages.append(errorMessage)
        }
        coordinator.lastError = displayText
    }
}
