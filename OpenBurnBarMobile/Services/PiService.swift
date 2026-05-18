import Foundation
import OpenBurnBarCore

// MARK: - Pi Chat Message
//
// PiService is a focused sibling of HermesService for the mobile Assistants
// surface. It keeps the same observable shape (connections / selectedConnection /
// modelOptions / runtime status) used by `AssistantConnectionSheet` and
// `AssistantSettingsView` so a single view can drive both runtimes.

enum PiChatRole: String, Codable, Equatable {
    case user, assistant, system
    /// On-device tool reply. Same semantics as `HermesChatRole.tool` —
    /// the body is the JSON returned by a `MobileTool`, the `toolCallID`
    /// references the assistant's prior `tool_calls[].id`, and the
    /// reply is filtered from the visible chat list.
    case tool
}

/// One tool the Pi-served model decided to invoke during this turn. Pi proxies
/// OpenAI-compatible chat completions, so the streaming protocol matches
/// `HermesToolCall` — `name` arrives first, `arguments` is concatenated across
/// chunks, and `detail` is a short human-readable preview suitable for a pill.
struct PiToolCall: Identifiable, Equatable {
    let id: String
    var name: String
    var status: String
    var arguments: String
    var detail: String?

    init(
        id: String,
        name: String,
        status: String,
        arguments: String = "",
        detail: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.arguments = arguments
        self.detail = detail
    }
}

struct PiChatMessage: Identifiable, Equatable {
    let id: String
    let role: PiChatRole
    var text: String
    var modelName: String?
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool
    var toolCalls: [PiToolCall]
    /// For `role == .tool`, the upstream `tool_calls[].id` this reply
    /// answers. Required when role is `.tool`; always nil otherwise.
    var toolCallID: String?
    /// Transient SSE state — accumulated `delta.refusal` text. See
    /// `HermesChatMessage.streamedRefusal` for the rationale; Pi shares
    /// the same OpenAI-compatible streaming contract.
    var streamedRefusal: String = ""
    /// Transient SSE state — accumulated reasoning channel text.
    var streamedReasoning: String = ""
    /// Last `choices[].finish_reason` observed for this turn.
    var lastFinishReason: String?
    /// First-class outcome — drives the Pi bubble's badge / retry pill.
    /// Always `.normal` for user/system/tool messages.
    var outcome: PiChatMessageOutcome = .normal

    init(
        id: String = UUID().uuidString,
        role: PiChatRole,
        text: String,
        modelName: String? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false,
        toolCalls: [PiToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.modelName = modelName
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    /// Body + error styling to use when the upstream Pi stream finished
    /// without producing any visible `content` or executable
    /// `tool_calls`. Mirrors `HermesChatMessage.emptyResponseFallback`:
    /// refusal first, reasoning second (with a clear marker), then a
    /// `finish_reason`-keyed message. Kept duplicated rather than
    /// shared because Pi messages aren't Hermes messages and we want
    /// the runtime label in the user-facing copy.
    static func emptyResponseFallback(
        refusal: String,
        reasoning: String,
        finishReason: String?
    ) -> (text: String, isError: Bool, outcome: PiChatMessageOutcome) {
        let trimmedRefusal = refusal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRefusal.isEmpty {
            return (trimmedRefusal, false, .refusal)
        }
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReasoning.isEmpty {
            return (trimmedReasoning, false, .reasoningFallback)
        }
        switch finishReason?.lowercased() {
        case "length":
            return (
                "Pi hit its reply length cap before finishing. Try a shorter prompt or switch to a model with a larger reply ceiling.",
                true,
                .lengthCap
            )
        case "content_filter":
            return (
                "Pi blocked this reply for content safety. Try rewording the prompt or switch models.",
                true,
                .contentFilter
            )
        case "tool_calls":
            return (
                "Pi asked to use a tool but didn't follow up with a reply. Try again or switch models.",
                true,
                .toolCallNoFollowUp
            )
        default:
            return (
                "Pi returned no text. Try again or switch models.",
                true,
                .empty
            )
        }
    }
}

/// Pi's mirror of `HermesChatMessageOutcome` — kept as a separate
/// type so the runtime label (`Pi` vs. `Hermes`) and any
/// runtime-specific outcomes can diverge later without retrofitting
/// a shared enum.
enum PiChatMessageOutcome: String, Equatable, Sendable {
    case normal
    case refusal
    case reasoningFallback
    case lengthCap
    case contentFilter
    case toolCallNoFollowUp
    case empty

    var supportsRetry: Bool {
        switch self {
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty: return true
        case .normal, .refusal, .reasoningFallback: return false
        }
    }

    var badgeLabel: String? {
        switch self {
        case .normal: return nil
        case .refusal: return "Declined"
        case .reasoningFallback: return "Reasoning channel"
        case .lengthCap: return "Reply truncated"
        case .contentFilter: return "Filtered"
        case .toolCallNoFollowUp: return "Tool call dropped"
        case .empty: return "No reply"
        }
    }

    var badgeSymbol: String? {
        switch self {
        case .normal: return nil
        case .refusal: return "hand.raised.fill"
        case .reasoningFallback: return "brain"
        case .lengthCap: return "scissors"
        case .contentFilter: return "shield.lefthalf.filled"
        case .toolCallNoFollowUp: return "wrench.and.screwdriver"
        case .empty: return "exclamationmark.bubble"
        }
    }
}

enum PiServiceError: LocalizedError {
    case selectedModelUnavailable(String)
    case selectedModelCatalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .selectedModelUnavailable(let modelID):
            return "Selected Pi model '\(modelID)' is not available on this Mac Pi harness. Pick another model or refresh/restart the Mac Pi gateway."
        case .selectedModelCatalogUnavailable(let modelID):
            return "Selected Pi model '\(modelID)' has not been verified against this Mac Pi harness catalog yet. Refresh the Mac Pi gateway before sending, so the selected model is not silently rerouted."
        }
    }
}

// MARK: - Pi Service

@MainActor
@Observable
final class PiService {
    /// Shared instance for views that need to read Pi state but don't own
    /// the lifecycle (notably the conversation-list brand header which
    /// needs an `AssistantModelLens` but doesn't otherwise touch Pi).
    /// Long-running views should still inject their own instance.
    @MainActor static let shared = PiService()

    var messages: [PiChatMessage] = []
    var connections: [PiConnectionRecord] = [PiConnectionRecord.localDefault]
    var selectedConnection: PiConnectionRecord = .localDefault
    var modelOptions: [HermesRuntimeModelOption] = []
    var selectedModelID: String?
    var favoriteModelIDs: [String] = []
    var isStreaming = false
    var isReachable = false
    var isLoadingRuntime = false
    var runtimeErrorText: String?
    var lastError: String?

    /// Identifier for the conversation currently in `messages`. Mints on the
    /// first send of a fresh thread so chat history can survive app relaunches.
    private(set) var currentThreadID: String?

    private let urlSession: URLSession
    private let defaults: UserDefaults
    private let history: MobileChatHistoryStore
    private var currentTask: Task<Void, Never>?

    private let selectedConnectionDefaultsKey = "pi.selectedConnectionID"
    private let selectedModelDefaultsKey = "pi.selectedModelID"
    private let favoriteModelsDefaultsKey = "pi.favoriteModelIDs"
    private let savedConnectionsDefaultsKey = "pi.savedConnections"
    private var selectedModelWasExplicit = false

    /// Catalog the service advertises to the upstream Pi runtime. Same
    /// catalog Hermes uses; injectable for tests.
    let toolCatalog: MobileToolCatalog
    /// Hard cap on tool-execution loops per user turn. Matches Hermes.
    private let maxToolUseIterations: Int = 5
    /// Closure that resolves the currently-installed `HermesAtomNavigator`,
    /// or `nil` when no chat surface is mounted. Set via
    /// `setToolAtomNavigator(_:)`.
    fileprivate var atomNavigatorAccessor: (() -> HermesAtomNavigator?)? = nil
    /// Weak storage backing `atomNavigatorAccessor`. Kept out of the
    /// public surface to discourage callers from reaching past the
    /// accessor.
    private weak var toolAtomNavigatorReference: AnyObject?

    init(
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard,
        history: MobileChatHistoryStore = .shared,
        toolCatalog: MobileToolCatalog = .default
    ) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.history = history
        self.toolCatalog = toolCatalog
        self.selectedModelID = Self.restoredModelID(
            defaults.string(forKey: selectedModelDefaultsKey),
            defaults: defaults,
            key: selectedModelDefaultsKey
        )
        self.selectedModelWasExplicit = self.selectedModelID?.nilIfBlank != nil
        self.favoriteModelIDs = Self.decodeStringArray(defaults.string(forKey: favoriteModelsDefaultsKey))
        // Restore previously-added direct URLs.
        if let saved = Self.decodeRecords(defaults.data(forKey: savedConnectionsDefaultsKey)) {
            connections = [PiConnectionRecord.localDefault] + saved
        }
        if let savedSelectedID = defaults.string(forKey: selectedConnectionDefaultsKey),
           let match = connections.first(where: { $0.id == savedSelectedID }) {
            selectedConnection = match
        }
        history.loadFromDiskIfNeeded()
    }

    // MARK: - Runtime

    var favoriteModelOptions: [HermesRuntimeModelOption] {
        modelOptions.filter { favoriteModelIDs.contains($0.modelID) }
    }

    func loadHistory() {
        Task { @MainActor in await refreshRuntime() }
    }

    func refreshRuntime() async {
        isLoadingRuntime = true
        runtimeErrorText = nil
        defer { isLoadingRuntime = false }
        await probeReachability()
        if isReachable {
            await loadModels()
        }
    }

    func refreshConnections() async {
        // Pi connections are local-only today; remote-relay sync is wired in
        // a future wave (see Plan 2 §8). We still re-validate the endpoint so
        // the UI status dot reflects the latest probe.
        await probeReachability()
    }

    @discardableResult
    func selectConnection(_ connection: PiConnectionRecord) -> Bool {
        guard connections.contains(where: { $0.id == connection.id }) else { return false }
        selectedConnection = connection
        selectedModelID = Self.restoredModelID(
            defaults.string(forKey: selectedModelDefaultsKey),
            defaults: defaults,
            key: selectedModelDefaultsKey
        )
        selectedModelWasExplicit = selectedModelID?.nilIfBlank != nil
        modelOptions = []
        defaults.set(connection.id, forKey: selectedConnectionDefaultsKey)
        Task { @MainActor in await refreshRuntime() }
        return true
    }

    @discardableResult
    func addDirectConnection(name: String, urlString: String, bearerToken: String?) -> PiConnectionRecord? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return nil }
        guard let endpoint = URL(string: trimmedURL), endpoint.scheme != nil else { return nil }
        let record = PiConnectionRecord(
            id: "direct-\(UUID().uuidString)",
            displayName: trimmedName,
            mode: .directURL,
            status: .pending,
            endpointURL: endpoint.absoluteString,
            capabilities: ["chat_completions"],
            createdAt: Date(),
            updatedAt: Date()
        )
        connections.append(record)
        persistConnections()
        // Stash bearer with the record id in defaults — encrypted at rest by iOS
        // file protection. Plan 2 §"Pi keychain handling" delegates to Keychain
        // when the cross-platform helper exists.
        if let bearerToken, !bearerToken.isEmpty {
            defaults.set(bearerToken, forKey: bearerTokenDefaultsKey(for: record.id))
        }
        _ = selectConnection(record)
        return record
    }

    func revokeConnection(_ connection: PiConnectionRecord) async throws {
        connections.removeAll { $0.id == connection.id }
        defaults.removeObject(forKey: bearerTokenDefaultsKey(for: connection.id))
        if selectedConnection.id == connection.id {
            selectedConnection = .localDefault
            defaults.removeObject(forKey: selectedConnectionDefaultsKey)
        }
        persistConnections()
    }

    func selectModel(_ option: HermesRuntimeModelOption) {
        let raw = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(raw)
        let resolved = !modelOptions.isEmpty
            ? AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(raw, in: modelOptions)
            : requested
        let modelID = resolved ?? requested
        selectedModelID = modelID
        selectedModelWasExplicit = true
        defaults.set(modelID, forKey: selectedModelDefaultsKey)
    }

    func clearSelectedModel() {
        selectedModelID = nil
        selectedModelWasExplicit = false
        defaults.removeObject(forKey: selectedModelDefaultsKey)
    }

    func validatedModelIDForMissionDispatch() throws -> String? {
        guard let selectedModelID = selectedModelID?.nilIfBlank else { return nil }
        if selectedModelWasExplicit {
            guard !modelOptions.isEmpty else {
                throw PiServiceError.selectedModelCatalogUnavailable(selectedModelID)
            }
            guard let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) else {
                throw PiServiceError.selectedModelUnavailable(selectedModelID)
            }
            persistResolvedSelectedModelID(resolved)
            return resolved
        }
        return canonicalizedSelectedModelID(selectedModelID)
    }

    private static func restoredModelID(_ stored: String?, defaults: UserDefaults, key: String) -> String? {
        guard let stored = stored?.nilIfBlank else { return nil }
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: key)
        }
        return canonical
    }

    private func canonicalizedSelectedModelID(_ modelID: String) -> String {
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(modelID)
        persistResolvedSelectedModelID(canonical)
        return canonical
    }

    private func persistResolvedSelectedModelID(_ modelID: String) {
        guard selectedModelID != modelID else { return }
        selectedModelID = modelID
        if selectedModelWasExplicit {
            defaults.set(modelID, forKey: selectedModelDefaultsKey)
        }
    }

    func isFavoriteModel(_ option: HermesRuntimeModelOption) -> Bool {
        favoriteModelIDs.contains(option.modelID)
    }

    func toggleFavoriteModel(_ option: HermesRuntimeModelOption) {
        if let idx = favoriteModelIDs.firstIndex(of: option.modelID) {
            favoriteModelIDs.remove(at: idx)
        } else {
            favoriteModelIDs.append(option.modelID)
        }
        defaults.set(Self.encodeStringArray(favoriteModelIDs), forKey: favoriteModelsDefaultsKey)
    }

    // MARK: - Send

    /// Retry the most recent user turn — drops everything after it,
    /// removes the user turn itself, then re-sends via `send`. Mirrors
    /// `HermesService.retryLastUserTurn`.
    func retryLastUserTurn() {
        guard !isStreaming else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let trimmed = messages[lastUserIndex].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if lastUserIndex + 1 < messages.count {
            messages.removeSubrange((lastUserIndex + 1)..<messages.count)
        }
        messages.remove(at: lastUserIndex)
        send(prompt: trimmed)
    }

    func send(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if currentThreadID == nil { currentThreadID = UUID().uuidString }

        messages.append(PiChatMessage(role: .user, text: trimmed))
        isStreaming = true
        persistCurrentThread()

        let baseURL = resolvedBaseURL
        let bearer = resolvedBearerToken
        let model: String
        do {
            model = try activeModelIDForRequest()
        } catch {
            lastError = error.localizedDescription
            messages.append(
                PiChatMessage(
                    role: .assistant,
                    text: "Pi error: \(error.localizedDescription)",
                    isError: true
                )
            )
            persistCurrentThread()
            isStreaming = false
            return
        }

        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStreaming = false; self.persistCurrentThread() }
            do {
                try await self.runStreamingLoop(
                    baseURL: baseURL,
                    bearerToken: bearer,
                    model: model,
                    iteration: 0
                )
            } catch {
                self.lastError = error.localizedDescription
                // Replace the most recent streaming assistant turn (if any)
                // with an error placeholder so the user sees the failure
                // rather than a silent empty bubble.
                if let idx = self.messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
                    var msg = self.messages[idx]
                    msg.isStreaming = false
                    msg.isError = true
                    msg.text = "Pi error: \(error.localizedDescription)"
                    self.messages[idx] = msg
                } else {
                    self.messages.append(
                        PiChatMessage(
                            role: .assistant,
                            text: "Pi error: \(error.localizedDescription)",
                            isError: true
                        )
                    )
                }
            }
        }
    }

    /// One iteration of the streaming + tool-execution loop. Appends a
    /// fresh streaming assistant placeholder, drives `streamChat` against
    /// it, then either executes the tool calls and recurses or completes
    /// the user turn.
    @MainActor
    private func runStreamingLoop(
        baseURL: URL,
        bearerToken: String?,
        model: String?,
        iteration: Int
    ) async throws {
        let assistant = PiChatMessage(
            role: .assistant,
            text: "",
            modelName: model,
            isStreaming: true
        )
        messages.append(assistant)
        let assistantID = assistant.id

        do {
            try await self.streamChat(
                baseURL: baseURL,
                bearerToken: bearerToken,
                model: model,
                onTextDelta: { [weak self] delta in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        msg.text += delta
                        self.messages[idx] = msg
                    }
                },
                onToolCallDelta: { [weak self] calls in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        PiService.mergeToolCalls(calls, into: &msg)
                        self.messages[idx] = msg
                    }
                },
                onRefusalDelta: { [weak self] chunk in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        if msg.streamedRefusal.isEmpty || chunk.hasPrefix(msg.streamedRefusal) {
                            msg.streamedRefusal = chunk
                        } else if chunk != msg.streamedRefusal {
                            msg.streamedRefusal += chunk
                        }
                        self.messages[idx] = msg
                    }
                },
                onReasoningDelta: { [weak self] chunk in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        if msg.streamedReasoning.isEmpty || chunk.hasPrefix(msg.streamedReasoning) {
                            msg.streamedReasoning = chunk
                        } else if chunk != msg.streamedReasoning {
                            msg.streamedReasoning += chunk
                        }
                        self.messages[idx] = msg
                    }
                },
                onFinishReason: { [weak self] reason in
                    guard let self else { return }
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        msg.lastFinishReason = reason
                        self.messages[idx] = msg
                    }
                }
            )
        } catch {
            if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
                var msg = messages[idx]
                msg.isStreaming = false
                messages[idx] = msg
            }
            throw error
        }

        // Promote the streaming placeholder to its final state.
        var finalMessage: PiChatMessage?
        if let idx = messages.firstIndex(where: { $0.id == assistantID }) {
            var msg = messages[idx]
            msg.isStreaming = false
            msg.toolCalls = msg.toolCalls.map { tc in
                PiToolCall(
                    id: tc.id,
                    name: tc.name,
                    status: "done",
                    arguments: tc.arguments,
                    detail: tc.detail ?? PiService.summarizeToolArguments(tc.arguments)
                )
            }
            // Rescue empty turns the same way Hermes does — refusal,
            // then reasoning hoist, then a finish-reason-keyed message.
            if msg.text.isEmpty && msg.toolCalls.isEmpty {
                let fallback = PiChatMessage.emptyResponseFallback(
                    refusal: msg.streamedRefusal,
                    reasoning: msg.streamedReasoning,
                    finishReason: msg.lastFinishReason
                )
                msg.text = fallback.text
                msg.isError = fallback.isError
                msg.outcome = fallback.outcome
            }
            messages[idx] = msg
            finalMessage = msg
        }

        guard let assistantMessage = finalMessage,
              !toolCatalog.tools.isEmpty,
              !assistantMessage.toolCalls.isEmpty,
              !assistantMessage.isError,
              iteration < maxToolUseIterations else {
            return
        }

        var mutableMessage = assistantMessage
        await executeToolCalls(for: &mutableMessage)
        persistCurrentThread()

        try await runStreamingLoop(
            baseURL: baseURL,
            bearerToken: bearerToken,
            model: model,
            iteration: iteration + 1
        )
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    /// Starts a brand-new conversation in memory without deleting the previously
    /// active thread (it remains in the chat history list).
    func startNewThread() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
        messages.removeAll()
        currentThreadID = nil
        lastError = nil
    }

    /// Restores `messages` from a persisted thread. Used when the user taps a
    /// row in the chat history list.
    func loadThread(id: String) {
        guard let thread = history.thread(id: id), thread.runtime == AssistantRuntimeID.pi.rawValue else { return }
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
        currentThreadID = thread.id
        messages = thread.messages.map { Self.convertFromStore($0) }
    }

    /// Removes a persisted thread (also clears the active chat when it matches).
    func deleteThread(id: String) {
        history.delete(threadID: id)
        if currentThreadID == id {
            startNewThread()
        }
    }

    // MARK: - Persistence bridge

    /// Subset of `messages` that should round-trip through persistence.
    /// Tool reply messages are ephemeral context — once the model
    /// produced its final natural-language turn the tool results no
    /// longer help the user when they resume the thread.
    private var persistableMessages: [PiChatMessage] {
        messages.filter { $0.role != .tool }
    }

    private func persistCurrentThread() {
        guard let id = currentThreadID, !persistableMessages.isEmpty else { return }
        let now = Date()
        let createdAt = history.thread(id: id)?.createdAt ?? now
        let title = Self.derivedTitle(from: persistableMessages)
        let preview = Self.derivedPreview(from: persistableMessages)
        let storedMessages = persistableMessages.map(Self.convertToStore)
        let thread = MobileChatThread(
            id: id,
            runtime: AssistantRuntimeID.pi.rawValue,
            title: title,
            preview: preview,
            modelName: selectedModelID,
            createdAt: createdAt,
            updatedAt: now,
            messages: storedMessages
        )
        history.upsert(thread)
    }

    /// Test-only entry point into the persistence converter so unit tests can
    /// verify the tool-call roundtrip without standing up a full service. Kept
    /// `internal` so production callers continue to route through the
    /// private converter.
    static func testHook_convertToStore(_ message: PiChatMessage) -> MobileChatMessage {
        convertToStore(message)
    }

    /// Test-only entry point into the persistence converter. See
    /// `testHook_convertToStore` for the contract.
    static func testHook_convertFromStore(_ message: MobileChatMessage) -> PiChatMessage {
        convertFromStore(message)
    }

    private static func convertToStore(_ message: PiChatMessage) -> MobileChatMessage {
        let storedToolCalls = message.toolCalls.map {
            MobileChatToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                detail: $0.detail
            )
        }
        return MobileChatMessage(
            id: message.id,
            role: message.role.rawValue,
            text: message.text,
            timestamp: message.timestamp,
            modelName: message.modelName,
            isError: message.isError,
            toolCalls: storedToolCalls
        )
    }

    private static func convertFromStore(_ message: MobileChatMessage) -> PiChatMessage {
        let restoredToolCalls = message.toolCalls.map {
            PiToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                arguments: "",
                detail: $0.detail
            )
        }
        return PiChatMessage(
            id: message.id,
            role: PiChatRole(rawValue: message.role) ?? .assistant,
            text: message.text,
            modelName: message.modelName,
            timestamp: message.timestamp,
            isStreaming: false,
            isError: message.isError,
            toolCalls: restoredToolCalls
        )
    }

    private static func derivedTitle(from messages: [PiChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            return String(firstUser.prefix(64))
        }
        return "New Pi chat"
    }

    private static func derivedPreview(from messages: [PiChatMessage]) -> String {
        if let last = messages.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            return String(last.prefix(140))
        }
        return ""
    }

    // MARK: - HTTP

    private func probeReachability() async {
        guard let endpoint = URL(string: "v1/models", relativeTo: resolvedBaseURL) else {
            isReachable = false
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        request.httpMethod = "GET"
        if let token = resolvedBearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await urlSession.data(for: request)
            if let http = response as? HTTPURLResponse {
                isReachable = (200..<300).contains(http.statusCode)
                if !isReachable {
                    runtimeErrorText = "Pi gateway returned HTTP \(http.statusCode)."
                }
            } else {
                isReachable = false
            }
        } catch {
            isReachable = false
            runtimeErrorText = "Pi gateway not reachable: \(error.localizedDescription)"
        }
    }

    private func loadModels() async {
        guard let endpoint = URL(string: "v1/models", relativeTo: resolvedBaseURL) else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: 4)
        if let token = resolvedBearerToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, _) = try await urlSession.data(for: request)
            let decoded = Self.parseModels(data: data)
            modelOptions = decoded
            if let selectedModelID,
               let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) {
                persistResolvedSelectedModelID(resolved)
                runtimeErrorText = nil
            } else if let selectedModelID, !modelOptions.contains(where: { $0.modelID == selectedModelID && $0.isRouteEligible }) {
                if selectedModelWasExplicit {
                    runtimeErrorText = "Selected Pi model '\(selectedModelID)' is not advertised by this Mac Pi harness. Pick a listed model or refresh the Mac provider catalog."
                } else {
                    self.selectedModelID = favoriteModelOptions.first { $0.isRouteEligible }?.modelID
                        ?? decoded.first { $0.isRouteEligible }?.modelID
                        ?? decoded.first?.modelID
                    selectedModelWasExplicit = false
                }
            } else if selectedModelID == nil {
                selectedModelID = favoriteModelOptions.first { $0.isRouteEligible }?.modelID
                    ?? decoded.first { $0.isRouteEligible }?.modelID
                    ?? decoded.first?.modelID
                selectedModelWasExplicit = false
            }
        } catch {
            runtimeErrorText = "Failed to list Pi models: \(error.localizedDescription)"
        }
    }

    private func activeModelIDForRequest() throws -> String {
        if let selectedModelID = selectedModelID?.nilIfBlank {
            if selectedModelWasExplicit {
                guard !modelOptions.isEmpty else {
                    throw PiServiceError.selectedModelCatalogUnavailable(selectedModelID)
                }
                guard let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: modelOptions) else {
                    throw PiServiceError.selectedModelUnavailable(selectedModelID)
                }
                persistResolvedSelectedModelID(resolved)
                return resolved
            }
            return canonicalizedSelectedModelID(selectedModelID)
        }
        return selectedConnection.advertisedModel?.nilIfBlank ?? "pi"
    }

    private func streamChat(
        baseURL: URL,
        bearerToken: String?,
        model: String?,
        onTextDelta: @escaping (String) -> Void,
        onToolCallDelta: @escaping ([[String: Any]]) -> Void,
        onRefusalDelta: @escaping (String) -> Void = { _ in },
        onReasoningDelta: @escaping (String) -> Void = { _ in },
        onFinishReason: @escaping (String) -> Void = { _ in }
    ) async throws {
        guard let endpoint = URL(string: "v1/chat/completions", relativeTo: baseURL) else {
            throw NSError(domain: "PiService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model ?? "pi",
            "stream": true,
            "messages": Self.wireMessages(from: messages)
        ]
        let toolsArray = toolCatalog.toolsWireArray()
        if !toolsArray.isEmpty {
            body["tools"] = toolsArray
            body["tool_choice"] = "auto"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (stream, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "PiService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Pi gateway HTTP \(http.statusCode)"])
        }

        for try await line in stream.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }
            guard let data = payload.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            // Some Pi backends only ever send the final assistant turn as a
            // `message` object (no streaming `delta` chain). Handle both.
            let delta = first["delta"] as? [String: Any]
            let finalMessage = first["message"] as? [String: Any]

            if let content = Self.contentString(from: delta)
                ?? Self.contentString(from: finalMessage) {
                if !content.isEmpty {
                    await MainActor.run { onTextDelta(content) }
                }
            }

            // Mirror Hermes — capture refusal / reasoning / finish_reason
            // so we can rescue an empty turn instead of leaving the
            // assistant bubble silent.
            if let refusal = Self.refusalString(from: delta)
                ?? Self.refusalString(from: finalMessage) {
                await MainActor.run { onRefusalDelta(refusal) }
            }
            if let reasoning = Self.reasoningString(from: delta)
                ?? Self.reasoningString(from: finalMessage) {
                await MainActor.run { onReasoningDelta(reasoning) }
            }
            if let finishRaw = first["finish_reason"] ?? first["finishReason"],
               let finish = Self.nonBlankString(finishRaw) {
                await MainActor.run { onFinishReason(finish) }
            }

            if let calls = Self.toolCallsArray(from: delta)
                ?? Self.toolCallsArray(from: finalMessage) {
                await MainActor.run { onToolCallDelta(calls) }
            }
        }
    }

    private static func refusalString(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        guard let raw = item["refusal"] else { return nil }
        return contentString(from: ["content": raw])
    }

    private static func reasoningString(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        for key in ["reasoning_content", "reasoningContent", "reasoning", "thinking"] {
            if let value = item[key],
               let extracted = contentString(from: ["content": value]) {
                return extracted
            }
        }
        return nil
    }

    private static func nonBlankString(_ value: Any) -> String? {
        guard let s = value as? String else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    private static func contentString(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        if let value = item["content"] as? String, !value.isEmpty { return value }
        if let parts = item["content"] as? [Any] {
            let joined = parts.compactMap { part -> String? in
                if let text = part as? String { return text }
                guard let obj = part as? [String: Any] else { return nil }
                return obj["text"] as? String ?? obj["value"] as? String
            }
            .joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    private static func toolCallsArray(from item: [String: Any]?) -> [[String: Any]]? {
        guard let item else { return nil }
        if let calls = item["tool_calls"] as? [[String: Any]], !calls.isEmpty { return calls }
        if let calls = item["toolCalls"] as? [[String: Any]], !calls.isEmpty { return calls }
        if let call = item["function_call"] as? [String: Any] { return [call] }
        if let call = item["functionCall"] as? [String: Any] { return [call] }
        return nil
    }

    /// Folds an OpenAI-compatible `tool_calls` delta into the assistant
    /// message. Mirrors `HermesService.mergeToolCalls` — the streaming protocol
    /// splits a single tool call across many chunks (name first, then
    /// successive partial `arguments` strings), so we accumulate by index/id
    /// and recompute the `detail` preview as more JSON arrives.
    static func mergeToolCalls(_ rawToolCalls: [[String: Any]], into message: inout PiChatMessage) {
        for raw in rawToolCalls {
            let function = raw["function"] as? [String: Any]
            let nameFragment = stringValue(function?["name"]) ?? stringValue(raw["name"])
            let argsFragment = stringValue(function?["arguments"]) ?? stringValue(raw["arguments"])
            let indexHint = intValue(raw["index"])
            let idFromPayload = stringValue(raw["id"])

            let resolvedID: String
            if let indexHint, indexHint >= 0, indexHint < message.toolCalls.count {
                resolvedID = message.toolCalls[indexHint].id
            } else if let id = idFromPayload {
                resolvedID = id
            } else if let index = indexHint {
                resolvedID = "pi-tool-index-\(index)"
            } else {
                resolvedID = "pi-tool-\(message.toolCalls.count + 1)"
            }

            if let idx = message.toolCalls.firstIndex(where: { $0.id == resolvedID }) {
                if let nameFragment, !nameFragment.isEmpty {
                    message.toolCalls[idx].name = nameFragment
                }
                if let argsFragment, !argsFragment.isEmpty {
                    message.toolCalls[idx].arguments += argsFragment
                }
                message.toolCalls[idx].status = "running"
                if let summary = summarizeToolArguments(message.toolCalls[idx].arguments) {
                    message.toolCalls[idx].detail = summary
                }
            } else {
                let name = nameFragment?.isEmpty == false ? nameFragment! : "Pi tool"
                let arguments = argsFragment ?? ""
                message.toolCalls.append(
                    PiToolCall(
                        id: resolvedID,
                        name: name,
                        status: "running",
                        arguments: arguments,
                        detail: summarizeToolArguments(arguments)
                    )
                )
            }
        }
    }

    /// Short human-readable preview pulled out of a (possibly partial) JSON
    /// arguments string. Mirrors the Hermes summarizer so the two assistant
    /// runtimes render identical pills.
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

    private static func stringValue(_ raw: Any?) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    // MARK: - Helpers

    var resolvedBaseURL: URL {
        if let raw = selectedConnection.endpointURL,
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return url
        }
        return AssistantRuntimeID.pi.defaultGatewayURL
    }

    var resolvedBearerToken: String? {
        let token = defaults.string(forKey: bearerTokenDefaultsKey(for: selectedConnection.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }

    private func bearerTokenDefaultsKey(for connectionID: String) -> String {
        "pi.bearer.\(connectionID)"
    }

    private func persistConnections() {
        let saveable = connections.filter { $0.id != PiConnectionRecord.localDefault.id }
        if let data = try? JSONEncoder().encode(saveable) {
            defaults.set(data, forKey: savedConnectionsDefaultsKey)
        }
    }

    private static func decodeRecords(_ data: Data?) -> [PiConnectionRecord]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([PiConnectionRecord].self, from: data)
    }

    private static func parseModels(data: Data) -> [HermesRuntimeModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let raw = (object["data"] as? [[String: Any]]) ?? []
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let provider = (entry["provider_id"] as? String)
                ?? (entry["owned_by"] as? String)
                ?? "pi"
            let providerName = (entry["provider_name"] as? String)
                ?? provider.capitalized
            return HermesRuntimeModelOption(
                providerID: provider,
                providerName: providerName,
                modelID: id,
                displayName: (entry["display_name"] as? String) ?? id,
                accountID: entry["account_id"] as? String,
                accountLabel: entry["account_label"] as? String,
                sourceID: entry["source_id"] as? String,
                sourceKind: entry["source_kind"] as? String,
                capabilities: entry["capabilities"] as? [String] ?? [],
                quotaState: entry["quota_state"] as? String,
                routeEligible: entry["route_eligible"] as? Bool,
                lastError: entry["last_error"] as? String
            )
        }
    }

    private static func decodeStringArray(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    private static func encodeStringArray(_ arr: [String]) -> String {
        (try? JSONEncoder().encode(arr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Build the OpenAI-compatible `messages` wire array from the local
    /// `PiChatMessage` history. Skips error placeholders and the
    /// streaming-in-flight assistant turn (it has no committed body
    /// yet). Tool replies and assistant turns with `tool_calls` get the
    /// extended shape required by the Chat Completions API.
    static func wireMessages(from messages: [PiChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in messages where !msg.isError {
            if msg.isStreaming { continue }
            switch msg.role {
            case .system:
                if !msg.text.isEmpty {
                    out.append(["role": "system", "content": msg.text])
                }
            case .user:
                if !msg.text.isEmpty {
                    out.append(["role": "user", "content": msg.text])
                }
            case .assistant:
                if !msg.toolCalls.isEmpty {
                    let toolCalls: [[String: Any]] = msg.toolCalls.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": [
                                "name": call.name,
                                "arguments": call.arguments
                            ] as [String: Any]
                        ] as [String: Any]
                    }
                    var entry: [String: Any] = [
                        "role": "assistant",
                        "tool_calls": toolCalls
                    ]
                    entry["content"] = msg.text.isEmpty ? (NSNull() as Any) : msg.text
                    out.append(entry)
                } else if !msg.text.isEmpty {
                    out.append(["role": "assistant", "content": msg.text])
                }
            case .tool:
                guard let id = msg.toolCallID, !id.isEmpty, !msg.text.isEmpty else { continue }
                out.append([
                    "role": "tool",
                    "tool_call_id": id,
                    "content": msg.text
                ])
            }
        }
        return out
    }
}

// MARK: - Tool Use Loop

extension PiService: MobileToolContext {
    /// Install / replace the navigator the `burnbar_atom_open` tool uses.
    /// Same contract as `HermesService.setToolAtomNavigator`.
    public func setToolAtomNavigator(_ navigator: HermesAtomNavigator?) {
        if let navigator {
            let weakRef = navigator as AnyObject
            self.toolAtomNavigatorReference = weakRef
            self.atomNavigatorAccessor = { [weak weakRef] in
                weakRef as? HermesAtomNavigator
            }
        } else {
            self.toolAtomNavigatorReference = nil
            self.atomNavigatorAccessor = nil
        }
    }

    public var atomNavigator: HermesAtomNavigator? {
        atomNavigatorAccessor?()
    }

    public var availableSessions: [MobileToolSessionSummary] {
        // Pi doesn't (yet) maintain a session list mirror — keep the
        // surface honest by returning empty. The tool reports
        // `total_available: 0` and the model recovers gracefully.
        []
    }

    public var runtimeStatusSnapshot: MobileToolRuntimeStatus {
        MobileToolRuntimeStatus(
            runtime: "pi",
            isReachable: isReachable,
            connectionName: selectedConnection.displayName.nilIfBlank,
            connectionMode: selectedConnection.mode.rawValue,
            selectedModelID: selectedModelID?.nilIfBlank,
            advertisedModel: selectedConnection.advertisedModel?.nilIfBlank,
            lastError: lastError?.nilIfBlank
        )
    }

    /// Execute the streamed tool calls on `message`, append matching
    /// `role: .tool` replies to `messages`, and stamp the call statuses
    /// for the pill UI.
    @discardableResult
    func executeToolCalls(
        for message: inout PiChatMessage
    ) async -> [MobileToolExecutionResult] {
        guard !message.toolCalls.isEmpty else { return [] }
        let pending = message.toolCalls.map { call in
            PendingToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }
        let executor = MobileToolExecutor(catalog: toolCatalog)
        let results = await executor.execute(pending, context: self)

        var updated = message
        var statusByID: [String: String] = [:]
        for r in results {
            statusByID[r.toolCallID] = r.isError ? "failed" : "done"
        }
        updated.toolCalls = updated.toolCalls.map { call in
            PiToolCall(
                id: call.id,
                name: call.name,
                status: statusByID[call.id] ?? call.status,
                arguments: call.arguments,
                detail: call.detail ?? PiService.summarizeToolArguments(call.arguments)
            )
        }
        message = updated

        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx] = message
        }

        for r in results {
            let reply = PiChatMessage(
                role: .tool,
                text: r.content,
                isError: r.isError,
                toolCallID: r.toolCallID
            )
            messages.append(reply)
        }
        return results
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
