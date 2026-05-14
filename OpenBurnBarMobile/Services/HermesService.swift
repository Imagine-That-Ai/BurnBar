import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Hermes Chat Message

enum HermesTokenCountSource: String, Equatable {
    case providerUsage
    case estimatedText
}

/// Where the elapsed time used for `tokensPerSecond` came from.
///
/// - `providerEvalDuration`: server-reported generation duration (e.g. Ollama's
///   `eval_duration` nanoseconds, or any other provider-supplied number we
///   normalise to seconds). This is the only fully trustworthy source — the
///   provider measured it next to the model.
/// - `wallClock`: time between the first SSE chunk we received and the final
///   chunk. Reliable for non-buffered streams but easily skewed by relays or
///   proxies that buffer a whole response into a single burst.
/// - `bufferedWallClock`: same as `wallClock`, but the elapsed window was
///   short enough to be physically implausible for the reported token count.
///   We expose the marker so the UI can suppress the (lying) rate instead of
///   shipping "720 tok/s on a 31B local model" type numbers.
enum HermesGenerationDurationSource: String, Equatable {
    case providerEvalDuration
    case wallClock
    case bufferedWallClock
}

struct HermesTokenUsageStats: Equatable {
    var promptTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    /// Generation duration (output-only) if the provider reported it. Already
    /// normalised to seconds. Ollama's `eval_duration` is in nanoseconds and is
    /// converted before reaching this struct.
    var generationDurationSeconds: TimeInterval?
    /// End-to-end provider wall-clock (input + generation), for diagnostics.
    var totalDurationSeconds: TimeInterval?
}

struct HermesChatMessage: Identifiable, Equatable {
    /// Wall-clock generation windows shorter than this are treated as buffered
    /// SSE bursts (a relay or proxy delivered the whole answer at once). We
    /// suppress the rate in that case rather than print physically impossible
    /// numbers like "720 tok/s on a 31B local model".
    static let minimumTrustworthyWallClockDurationSeconds: TimeInterval = 0.1

    let id: String
    let role: HermesChatRole
    var text: String
    var toolCalls: [HermesToolCall]
    /// Files the user attached to this message. Persisted with the chat so
    /// attachments stay visible after a session is reopened.
    var attachments: [HermesAttachment]
    /// What the user (or selected favourite) asked Hermes to use. Stays stable
    /// for the lifetime of the message so we can show "Asked: …" honestly even
    /// when the server picked a different model.
    var requestedModelID: String?
    /// What the server told us it actually ran, parsed from streamed
    /// `"model"` fields. `nil` until the first SSE chunk that includes it
    /// arrives; some servers never emit it.
    var responseModelID: String?
    /// Display-friendly model name (`responseModelID` when present, otherwise
    /// `requestedModelID`-derived). Kept for backwards compatibility with
    /// existing UI code that already reads `modelName`.
    var modelName: String?
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool
    var responseStartedAt: Date?
    var firstResponseChunkAt: Date?
    var responseCompletedAt: Date?
    var outputTokenCount: Int?
    var totalTokenCount: Int?
    var tokenCountSource: HermesTokenCountSource?
    /// Provider-reported generation duration in seconds (Ollama
    /// `eval_duration`, OpenAI-style `generation_time`, etc.). When present
    /// we use this for `tokensPerSecond` instead of wall-clock.
    var providerGenerationDurationSeconds: TimeInterval?
    /// Provider-reported total wall-clock duration in seconds, surfaced for
    /// diagnostics and accessibility text.
    var providerTotalDurationSeconds: TimeInterval?
    /// For `role == .tool` messages, the upstream `tool_calls[].id` this
    /// reply answers. Always non-nil for tool messages, always nil for
    /// other roles. The encoder uses this to emit
    /// `{role: "tool", tool_call_id: "..."}` on the wire.
    var toolCallID: String?

    init(
        id: String = UUID().uuidString,
        role: HermesChatRole,
        text: String,
        toolCalls: [HermesToolCall] = [],
        attachments: [HermesAttachment] = [],
        requestedModelID: String? = nil,
        responseModelID: String? = nil,
        modelName: String? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false,
        responseStartedAt: Date? = nil,
        firstResponseChunkAt: Date? = nil,
        responseCompletedAt: Date? = nil,
        outputTokenCount: Int? = nil,
        totalTokenCount: Int? = nil,
        tokenCountSource: HermesTokenCountSource? = nil,
        providerGenerationDurationSeconds: TimeInterval? = nil,
        providerTotalDurationSeconds: TimeInterval? = nil,
        toolCallID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.attachments = attachments
        self.requestedModelID = requestedModelID
        self.responseModelID = responseModelID
        self.modelName = modelName
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
        self.responseStartedAt = responseStartedAt
        self.firstResponseChunkAt = firstResponseChunkAt
        self.responseCompletedAt = responseCompletedAt
        self.outputTokenCount = outputTokenCount
        self.totalTokenCount = totalTokenCount
        self.tokenCountSource = tokenCountSource
        self.providerGenerationDurationSeconds = providerGenerationDurationSeconds
        self.providerTotalDurationSeconds = providerTotalDurationSeconds
        self.toolCallID = toolCallID
    }

    /// Wall-clock generation duration: time from the first received chunk to
    /// completion. Only safe when the stream wasn't proxy-buffered.
    var wallClockGenerationDurationSeconds: TimeInterval? {
        guard role == .assistant else { return nil }
        let start = firstResponseChunkAt ?? responseStartedAt
        let end = responseCompletedAt ?? (isStreaming ? Date() : nil)
        guard let start, let end else { return nil }
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    /// Best available generation duration. Prefers the provider-reported
    /// number (truthful, measured server-side); falls back to wall-clock when
    /// no provider value is available.
    var generationDurationSeconds: TimeInterval? {
        if let providerGenerationDurationSeconds, providerGenerationDurationSeconds > 0 {
            return providerGenerationDurationSeconds
        }
        return wallClockGenerationDurationSeconds
    }

    var totalResponseDurationSeconds: TimeInterval? {
        if let providerTotalDurationSeconds, providerTotalDurationSeconds > 0 {
            return providerTotalDurationSeconds
        }
        guard role == .assistant,
              let start = responseStartedAt,
              let end = responseCompletedAt ?? (isStreaming ? Date() : nil) else {
            return nil
        }
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    /// Where the generation duration we'd publish actually came from. When
    /// the wall-clock window is implausibly short for the reported token
    /// count, we mark it `bufferedWallClock` and suppress the rate.
    var generationDurationSource: HermesGenerationDurationSource? {
        guard role == .assistant else { return nil }
        if let providerGenerationDurationSeconds, providerGenerationDurationSeconds > 0 {
            return .providerEvalDuration
        }
        guard let wall = wallClockGenerationDurationSeconds else { return nil }
        if wall < Self.minimumTrustworthyWallClockDurationSeconds {
            return .bufferedWallClock
        }
        return .wallClock
    }

    var tokensPerSecond: Double? {
        guard role == .assistant,
              !isError,
              let outputTokenCount,
              outputTokenCount > 0,
              let source = generationDurationSource else {
            return nil
        }
        switch source {
        case .providerEvalDuration:
            guard let providerGenerationDurationSeconds,
                  providerGenerationDurationSeconds > 0 else { return nil }
            return Double(outputTokenCount) / providerGenerationDurationSeconds
        case .wallClock:
            guard let wall = wallClockGenerationDurationSeconds, wall > 0 else { return nil }
            return Double(outputTokenCount) / wall
        case .bufferedWallClock:
            // Stream was proxy-buffered. Refusing to publish a rate is the
            // honest answer — better silent than 720 tok/s on a 31B model.
            return nil
        }
    }

    var isTokensPerSecondEstimated: Bool {
        // Honest definition: a published rate counts as "estimated" unless
        // *both* the token count and the generation duration came from the
        // provider. The `~` prefix is the user-visible signal that
        // something in the rate computation isn't fully trustworthy.
        //   provider usage  + provider eval duration → exact (no `~`)
        //   provider usage  + wall-clock             → estimated (`~`)
        //   text estimate   + anything               → estimated (`~`)
        if tokenCountSource == .estimatedText { return true }
        if generationDurationSource == .wallClock { return true }
        return false
    }

    var tokensPerSecondDisplayText: String? {
        guard let tokensPerSecond else { return nil }
        let value: String
        if tokensPerSecond >= 100 {
            value = String(format: "%.0f", tokensPerSecond)
        } else if tokensPerSecond >= 10 {
            value = String(format: "%.1f", tokensPerSecond)
        } else {
            value = String(format: "%.2f", tokensPerSecond)
        }
        let prefix = isTokensPerSecondEstimated ? "~" : ""
        return "\(prefix)\(value) tok/s"
    }

    /// `true` once the server has echoed any `"model"` field. `false` for
    /// servers that silently swallow the model param — useful for surfacing a
    /// "server didn't confirm model" affordance in the UI.
    var serverConfirmedModel: Bool {
        responseModelID?.nilIfBlank != nil
    }

    /// `true` when the server explicitly told us it ran a different model than
    /// what the client requested. Comparison ignores casing/whitespace.
    var serverRoutedToDifferentModel: Bool {
        guard let requested = requestedModelID?.nilIfBlank?.lowercased(),
              let response = responseModelID?.nilIfBlank?.lowercased(),
              requested != response else {
            return false
        }
        return true
    }

    mutating func markResponseStarted(at date: Date = Date()) {
        if responseStartedAt == nil {
            responseStartedAt = date
        }
    }

    mutating func markFirstResponseChunk(at date: Date = Date()) {
        markResponseStarted(at: date)
        if firstResponseChunkAt == nil {
            firstResponseChunkAt = date
        }
    }

    mutating func applyTokenUsage(_ usage: HermesTokenUsageStats) {
        if let totalTokens = usage.totalTokens, totalTokens > 0 {
            self.totalTokenCount = totalTokens
        }
        if let outputTokens = usage.outputTokens, outputTokens > 0 {
            self.outputTokenCount = outputTokens
            self.tokenCountSource = .providerUsage
        }
        if let provided = usage.generationDurationSeconds, provided > 0 {
            self.providerGenerationDurationSeconds = provided
        }
        if let totalProvided = usage.totalDurationSeconds, totalProvided > 0 {
            self.providerTotalDurationSeconds = totalProvided
        }
    }

    /// Records the model id the server tells us it ran. Stable: only the
    /// first non-blank value sticks per turn so a downstream chunk that
    /// echoes a different alias can't quietly overwrite it.
    mutating func applyResponseModelID(_ rawValue: String?) {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return }
        if responseModelID?.nilIfBlank == nil {
            responseModelID = trimmed
        }
        // Always reflect the most recent confirmed value in `modelName` so
        // existing UI bindings update without extra code.
        modelName = trimmed
    }

    mutating func finalizeResponseMetrics(at date: Date = Date()) {
        guard role == .assistant else { return }
        markResponseStarted(at: timestamp)
        responseCompletedAt = date

        guard !isError,
              outputTokenCount == nil,
              let estimated = Self.estimatedOutputTokens(for: text) else {
            return
        }
        outputTokenCount = estimated
        tokenCountSource = .estimatedText
    }

    static func estimatedOutputTokens(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let characterEstimate = Int((Double(trimmed.count) / 4.0).rounded(.up))
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let wordEstimate = Int((Double(wordCount) * 1.3).rounded(.up))
        return max(1, max(characterEstimate, wordEstimate))
    }
}
/// One tool the model decided to invoke in the current assistant turn.
///
/// `name` lands first (the OpenAI streaming protocol sends it on the *first*
/// tool-call delta). `arguments` is accumulated across subsequent deltas — each
/// streamed fragment is appended in order, since they are partial JSON strings
/// that only parse correctly once concatenated. `detail` is a human-readable
/// preview derived from `arguments` (e.g. the file path passed to `read_file`)
/// so the mobile pill can show *what the model is doing*, not just *that it is
/// using a tool*.
struct HermesToolCall: Identifiable, Equatable {
    let id: String
    var name: String
    var status: String
    /// Raw concatenated JSON arguments string. Streamed incrementally.
    var arguments: String
    /// Short human-readable preview of the arguments (path, command, query…).
    /// Computed once the model emits enough fragments to parse usefully.
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

enum HermesChatRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
    /// Reply produced by a local `MobileTool` execution. Always paired
    /// with a `toolCallID` referencing the assistant's prior
    /// `tool_calls[].id` so the upstream API can stitch the call and
    /// reply together. Tool messages are sent to the upstream model
    /// in the next turn's `messages` array but are *hidden* from the
    /// visible chat UI (they're context, not conversation).
    case tool
}

struct HermesRelayPayload: Sendable {
    var connectionID: String
    var relayPublicKey: String?
    var relayKeyVersion: Int?
    var relayEncryption: String?
    var realtimeRelayURL: String?
    var operation: HermesRelayOperation
    var method: String
    var path: String?
    var sessionID: String?
    var body: Data?
}

@MainActor
protocol HermesRelayTransporting: AnyObject {
    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data
    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws
}

protocol HermesConnectionSecretStoring: AnyObject {
    func save(_ value: String, connectionID: String) throws
    func load(connectionID: String) throws -> String?
    func delete(connectionID: String) throws
}

@MainActor
protocol HermesConnectionListing: AnyObject {
    func listHermesConnections() async throws -> [HermesConnectionRecord]
}

@MainActor
final class FirestoreHermesConnectionRepository: HermesConnectionListing {
    static let shared = FirestoreHermesConnectionRepository()

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }

        let db = firestoreProvider()
        let snapshot = try await db.collection("users")
            .document(uid)
            .collection("hermes_connections")
            .getDocuments()

        var records: [HermesConnectionRecord] = []
        records.reserveCapacity(snapshot.documents.count)
        var decodeFailures: [String] = []

        for document in snapshot.documents {
            do {
                if let record = try Self.decodeConnectionDocument(
                    document.data(),
                    documentID: document.documentID
                ) {
                    records.append(record)
                }
            } catch {
                decodeFailures.append("\(document.documentID): \(error.localizedDescription)")
            }
        }

        if records.isEmpty, !snapshot.documents.isEmpty {
            let message = decodeFailures.first ?? "Firestore returned Hermes connection documents in an unsupported shape."
            throw FirestoreError.decodingFailed("Could not read Hermes connection document \(message)")
        }

        return records.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    static func decodeConnectionDocument(
        _ rawData: [String: Any],
        documentID: String
    ) throws -> HermesConnectionRecord? {
        var data = rawData
        if data["id"] == nil {
            data["id"] = documentID
        }

        let sanitized = FirestoreRepository.shared.sanitizeForJSON(data)
        let jsonData = try JSONSerialization.data(withJSONObject: sanitized)
        let record = try JSONDecoder().decode(HermesConnectionRecord.self, from: jsonData)
        return record.status == .revoked ? nil : record
    }
}

// MARK: - Hermes Service

@Observable
@MainActor
final class HermesService {
    var messages: [HermesChatMessage] = []
    var connections: [HermesConnectionRecord] = [HermesConnectionRecord.localDefault]
    var selectedConnection: HermesConnectionRecord = .localDefault
    var sessions: [HermesSessionSummary] = []
    var profiles: [HermesRuntimeProfile] = []
    var modelOptions: [HermesRuntimeModelOption] = []
    var jobs: [HermesRuntimeJob] = []
    var selectedSessionID: String?
    var selectedModelID: String?
    var favoriteModelIDs: [String] = []
    var currentConversationTokenBurn = 0
    var isStreaming = false
    var lastError: String?
    var isReachable = false
    var isLoadingRuntime = false
    var runtimeErrorText: String?

    private var currentTask: Task<Void, Never>?
    private var baseURL: URL
    private let urlSession: URLSession
    private let functionsRepository: FunctionsRepository
    private let connectionRepository: HermesConnectionListing
    private let secretStore: HermesConnectionSecretStoring
    private let relayTransport: HermesRelayTransporting
    private let defaults: UserDefaults
    private let history: MobileChatHistoryStore
    private var runtimeGeneration = 0
    private var runtimeRefreshTask: Task<Void, Never>?
    private let selectedConnectionDefaultsKey = "hermes.selectedConnectionID"
    private let selectedModelDefaultsKey = "hermes.selectedModelID"
    private let favoriteModelsDefaultsKey = "hermes.favoriteModelIDs"
    /// Catalog of `MobileTool` implementations the chat surface advertises to
    /// the upstream LLM. Defaults to the canonical production set; tests
    /// inject custom catalogs (empty for "no tools" runs, fakes for
    /// deterministic execution coverage).
    let toolCatalog: MobileToolCatalog
    /// Hard cap on how many tool-execution → re-stream loops a single user
    /// turn can drive. Each iteration is one upstream call; we stop here
    /// even if the model keeps requesting more tools so the user never
    /// sees an unbounded chat hang.
    private let maxToolUseIterations: Int = 5
    /// Atom navigator installed by the chat surface so the
    /// `burnbar_atom_open` tool can drive in-app navigation. Optional —
    /// previews / tests can run without one. Held weakly via an
    /// `AnyObject` proxy so the service never extends the view's
    /// lifetime.
    private weak var toolAtomNavigatorReference: AnyObject?
    /// Closure form of the navigator hook. Lets us forward
    /// `MobileToolContext.atomNavigator` to whatever the chat surface
    /// installed without smuggling protocols through Swift's weak
    /// machinery.
    fileprivate var atomNavigatorAccessor: (() -> HermesAtomNavigator?)? = nil

    var relayConnections: [HermesConnectionRecord] {
        connections.filter { connection in
            connection.mode == .relayLink
                && connection.status == .online
                && Self.hasUsableRelayEncryption(connection)
        }
    }

    var suggestedRelayConnection: HermesConnectionRecord? {
        relayConnections.sorted { lhs, rhs in
            let lhsLastSeen = lhs.lastSeenAt ?? lhs.updatedAt
            let rhsLastSeen = rhs.lastSeenAt ?? rhs.updatedAt
            return lhsLastSeen > rhsLastSeen
        }.first
    }

    var hasPendingRelaySuggestion: Bool {
        guard let relay = suggestedRelayConnection else { return false }
        return selectedConnection.id != relay.id
    }

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:8642")!,
        urlSession: URLSession = .shared,
        functionsRepository: FunctionsRepository = .shared,
        connectionRepository: HermesConnectionListing = FirestoreHermesConnectionRepository.shared,
        secretStore: HermesConnectionSecretStoring = HermesConnectionSecretStore.shared,
        relayTransport: HermesRelayTransporting = HermesCompositeRelayTransport.shared,
        defaults: UserDefaults = .standard,
        history: MobileChatHistoryStore = .shared,
        toolCatalog: MobileToolCatalog = .default
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.functionsRepository = functionsRepository
        self.connectionRepository = connectionRepository
        self.secretStore = secretStore
        self.relayTransport = relayTransport
        self.defaults = defaults
        self.history = history
        self.toolCatalog = toolCatalog
        self.selectedModelID = defaults.string(forKey: selectedModelDefaultsKey)
        self.favoriteModelIDs = Self.decodeStringArray(defaults.string(forKey: favoriteModelsDefaultsKey))
        history.loadFromDiskIfNeeded()
    }

    func loadHistory() {
        Task { @MainActor in
            await refreshRuntime()
        }
    }

    func refreshRuntime() async {
        if let runtimeRefreshTask {
            await runtimeRefreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeRefresh()
        }
        runtimeRefreshTask = task
        await task.value
        runtimeRefreshTask = nil
    }

    private func performRuntimeRefresh() async {
        let generation = runtimeGeneration
        isLoadingRuntime = true
        runtimeErrorText = nil
        defer {
            if generation == runtimeGeneration {
                isLoadingRuntime = false
            }
        }

        async let connectionRefresh: Void = refreshConnections(generation: generation)
        async let reachabilityRefresh: Void = checkReachability(generation: generation)
        async let modelRefresh: Void = loadModels(generation: generation)
        async let sessionRefresh: Void = loadSessions(generation: generation)
        async let profileRefresh: Void = loadProfiles(generation: generation)
        async let jobRefresh: Void = loadJobs(generation: generation)
        _ = await (connectionRefresh, reachabilityRefresh, modelRefresh, sessionRefresh, profileRefresh, jobRefresh)
    }

    func refreshConnections(generation: Int? = nil) async {
        do {
            var remoteConnections = try await connectionRepository.listHermesConnections()
            if remoteConnections.isEmpty {
                remoteConnections = []
            }
            guard generation == nil || generation == runtimeGeneration else { return }
            connections = [HermesConnectionRecord.localDefault] + remoteConnections
            let persistedID = defaults.string(forKey: selectedConnectionDefaultsKey)
            let targetID = selectedConnection.id == HermesConnectionRecord.localDefault.id ? persistedID : selectedConnection.id
            if let targetID,
               let current = connections.first(where: { $0.id == targetID }),
               current.mode == .relayLink {
                if Self.hasUsableRelayEncryption(current), current.id == selectedConnection.id {
                    selectedConnection = current
                } else if Self.hasUsableRelayEncryption(current) {
                    _ = selectConnection(current)
                } else {
                    selectedConnection = .localDefault
                    defaults.removeObject(forKey: selectedConnectionDefaultsKey)
                    runtimeErrorText = "Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic."
                }
            } else if let targetID,
                      let current = connections.first(where: { $0.id == targetID }),
                      let endpoint = Self.validatedEndpointURL(current.endpointURL ?? "") {
                if current.id == selectedConnection.id {
                    selectedConnection = current
                    baseURL = endpoint
                } else {
                    _ = selectConnection(current)
                }
            } else if let current = connections.first(where: { $0.id == selectedConnection.id }) {
                selectedConnection = current
            }
        } catch {
            guard generation == nil || generation == runtimeGeneration else { return }
            if connections.isEmpty {
                connections = [HermesConnectionRecord.localDefault]
            }
            runtimeErrorText = "Could not load Hermes connections: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func selectConnection(_ connection: HermesConnectionRecord, refresh: Bool = true) -> Bool {
        let endpoint: URL?
        if connection.mode == .relayLink {
            guard Self.hasUsableRelayEncryption(connection) else {
                lastError = "Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic."
                runtimeErrorText = lastError
                return false
            }
            endpoint = nil
        } else if let validated = Self.validatedEndpointURL(connection.endpointURL ?? "") {
            endpoint = validated
        } else {
            lastError = "This Hermes connection has an invalid or unsupported URL."
            runtimeErrorText = lastError
            return false
        }
        runtimeGeneration += 1
        selectedConnection = connection
        selectedSessionID = nil
        selectedModelID = defaults.string(forKey: selectedModelDefaultsKey)
        sessions = []
        profiles = []
        modelOptions = []
        jobs = []
        isReachable = false
        if let endpoint {
            baseURL = endpoint
        }
        defaults.set(connection.id, forKey: selectedConnectionDefaultsKey)
        if refresh {
            Task { @MainActor in
                await refreshRuntime()
            }
        }
        return true
    }

    @discardableResult
    func connectToSuggestedRelay(refresh: Bool = true) -> Bool {
        guard let relay = suggestedRelayConnection else {
            lastError = "No signed-in Mac Hermes relay is available yet. On your Mac, keep OpenBurnBar open, sign in, and enable Hermes Remote Relay."
            runtimeErrorText = lastError
            return false
        }
        return selectConnection(relay, refresh: refresh)
    }

    func createPairingCode(displayName: String? = nil) async throws -> HermesPairingSessionRecord {
        try await functionsRepository.createHermesPairing(
            platform: "ios",
            displayName: displayName
        )
    }

    func addDirectConnection(
        displayName: String,
        endpointURL: String,
        bearerToken: String? = nil
    ) async throws {
        guard let endpoint = Self.validatedEndpointURL(endpointURL) else {
            throw HermesServiceError.invalidURL
        }
        let connectionId = "ios-\(UUID().uuidString.lowercased())"
        let model = modelOptions.first?.modelID
        do {
            let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try await validateDirectEndpoint(endpoint, bearerToken: token)
            let pairing = try await createPairingCode(displayName: displayName)
            if !token.isEmpty {
                try secretStore.save(token, connectionID: connectionId)
            }
            let connection = try await functionsRepository.completeHermesPairing(
            pairingId: pairing.id,
            code: pairing.code,
            connectionId: connectionId,
            displayName: displayName,
            endpointURL: endpoint.absoluteString,
            advertisedModel: model
            )
            connections = [HermesConnectionRecord.localDefault] + connections
                .filter { $0.id != HermesConnectionRecord.localDefault.id && $0.id != connection.id }
            connections.append(connection)
            selectConnection(connection)
        } catch {
            try? secretStore.delete(connectionID: connectionId)
            throw error
        }
    }

    private func validateDirectEndpoint(_ endpoint: URL, bearerToken: String) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"), timeoutInterval: 8)
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesServiceError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesServiceError.httpStatus(code: statusCode)
        }
    }

    func revokeConnection(_ connection: HermesConnectionRecord) async throws {
        guard connection.id != HermesConnectionRecord.localDefault.id else { return }
        try await functionsRepository.revokeHermesConnection(connectionId: connection.id)
        try? secretStore.delete(connectionID: connection.id)
        if selectedConnection.id == connection.id {
            _ = selectConnection(.localDefault)
        }
        await refreshConnections()
    }

    func startNewSession() {
        selectedSessionID = nil
        clearChat()
    }

    func resumeSession(_ session: HermesSessionSummary) async {
        selectedSessionID = session.id
        currentTask?.cancel()
        isStreaming = false
        lastError = nil
        currentConversationTokenBurn = 0
        do {
            let pathID = session.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? session.id
            let data: Data
            if selectedConnection.mode == .relayLink {
                data = try await relayTransport.sendUnary(
                    relayPayload(operation: .sessionDetail, method: "GET", path: "/api/sessions/\(pathID)", sessionID: session.id),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await urlSession.data(for: makeRequest(path: "/api/sessions/\(pathID)", timeout: 8))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    messages = []
                    return
                }
                data = directData
            }
            let loaded = parseSessionMessages(from: data)
            if loaded.isEmpty {
                messages = []
            } else {
                messages = loaded
            }
        } catch {
            messages = []
            runtimeErrorText = "Could not load the selected Hermes transcript: \(error.localizedDescription)"
        }
    }

    func sessionTitle(for sessionID: String) -> String {
        if let session = sessions.first(where: { $0.id == sessionID }) {
            return session.title ?? session.preview ?? "Hermes Session"
        }
        return String(sessionID.prefix(12))
    }

    func clearChat() {
        currentTask?.cancel()
        currentTask = nil
        messages.removeAll()
        lastError = nil
        isStreaming = false
        currentConversationTokenBurn = 0
    }

    // MARK: - Mobile chat history bridge

    /// Restores a chat thread previously saved by the mobile history store.
    /// Used when the user taps an on-device row in the conversation list.
    func loadMobileThread(id: String) {
        guard let thread = history.thread(id: id),
              thread.runtime == AssistantRuntimeID.hermes.rawValue else { return }
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
        lastError = nil
        selectedSessionID = thread.id
        messages = thread.messages.map { Self.convertFromStore($0) }
    }

    /// Deletes a thread from the mobile history store. Clears the active chat
    /// when the deleted thread was the one currently open.
    func deleteMobileThread(id: String) {
        history.delete(threadID: id)
        if selectedSessionID == id {
            startNewSession()
        }
    }

    private func persistCurrentThread() {
        guard let id = selectedSessionID, !messages.isEmpty else { return }
        let now = Date()
        let createdAt = history.thread(id: id)?.createdAt ?? messages.first?.timestamp ?? now
        let title = Self.derivedTitle(from: messages)
        let preview = Self.derivedPreview(from: messages)
        let storedMessages = messages.compactMap(Self.convertToStore)
        guard !storedMessages.isEmpty else { return }
        let thread = MobileChatThread(
            id: id,
            runtime: AssistantRuntimeID.hermes.rawValue,
            title: title,
            preview: preview,
            modelName: activeModelName ?? selectedModelID,
            createdAt: createdAt,
            updatedAt: now,
            messages: storedMessages
        )
        history.upsert(thread)
    }

    private static func convertToStore(_ message: HermesChatMessage) -> MobileChatMessage? {
        // Skip streaming-only placeholders that have no content yet AND no
        // attachments — attachment-only sends are intentional and must persist.
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !message.toolCalls.isEmpty || !message.attachments.isEmpty else { return nil }
        // Tool reply messages are ephemeral context — they exist only to
        // bridge a single assistant tool-call turn to its follow-up
        // natural-language turn. Once the conversation is reloaded the
        // user expects to start a new prompt, so persisting tool
        // results would only clutter the visible transcript.
        if message.role == .tool { return nil }
        let role: String
        switch message.role {
        case .user: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        case .tool: return nil
        }
        let storedAttachments = message.attachments.map { attachment in
            MobileChatAttachment(
                id: attachment.id,
                kind: attachment.kind.rawValue,
                displayName: attachment.displayName,
                mimeType: attachment.mimeType,
                byteSize: attachment.byteSize,
                workspaceRelativePath: attachment.workspaceRelativePath,
                thumbnailPNG: attachment.thumbnailPNG,
                extractedTextPreview: attachment.extractedTextPreview
            )
        }
        let storedToolCalls = message.toolCalls.map {
            MobileChatToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                detail: $0.detail
            )
        }
        let usage: MobileChatTokenUsage? = {
            let hasUsageSignal = message.outputTokenCount != nil
                || message.totalTokenCount != nil
                || message.providerGenerationDurationSeconds != nil
                || message.providerTotalDurationSeconds != nil
                || message.responseStartedAt != nil
                || message.firstResponseChunkAt != nil
                || message.responseCompletedAt != nil
            guard hasUsageSignal else { return nil }
            return MobileChatTokenUsage(
                outputTokens: message.outputTokenCount,
                totalTokens: message.totalTokenCount,
                source: message.tokenCountSource?.rawValue,
                providerGenerationDurationSeconds: message.providerGenerationDurationSeconds,
                providerTotalDurationSeconds: message.providerTotalDurationSeconds,
                responseStartedAt: message.responseStartedAt,
                firstResponseChunkAt: message.firstResponseChunkAt,
                responseCompletedAt: message.responseCompletedAt
            )
        }()
        let hasHermesMetadata = message.requestedModelID != nil
            || message.responseModelID != nil
            || !storedToolCalls.isEmpty
            || usage != nil
        let metadata = hasHermesMetadata ? MobileChatHermesMetadata(
            requestedModelID: message.requestedModelID,
            responseModelID: message.responseModelID,
            toolCalls: storedToolCalls,
            usage: usage
        ) : nil
        return MobileChatMessage(
            id: message.id,
            role: role,
            text: message.text,
            timestamp: message.timestamp,
            modelName: message.modelName,
            isError: message.isError,
            attachments: storedAttachments,
            toolCalls: storedToolCalls,
            hermes: metadata
        )
    }

    private static func convertFromStore(_ message: MobileChatMessage) -> HermesChatMessage {
        let role: HermesChatRole
        switch message.role {
        case "user": role = .user
        case "system": role = .system
        case "tool": role = .tool
        default: role = .assistant
        }
        let restoredAttachments: [HermesAttachment] = message.attachments.compactMap { stored in
            guard let kind = HermesAttachmentKind(rawValue: stored.kind) else { return nil }
            return HermesAttachment(
                id: stored.id,
                kind: kind,
                displayName: stored.displayName,
                mimeType: stored.mimeType,
                byteSize: stored.byteSize,
                workspaceRelativePath: stored.workspaceRelativePath,
                thumbnailPNG: stored.thumbnailPNG,
                extractedTextPreview: stored.extractedTextPreview
            )
        }
        // Prefer the top-level toolCalls list; fall back to the legacy
        // hermes.toolCalls block for threads written by older builds.
        let storedToolCalls = message.toolCalls.isEmpty
            ? (message.hermes?.toolCalls ?? [])
            : message.toolCalls
        let restoredToolCalls = storedToolCalls.map {
            HermesToolCall(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                arguments: "",
                detail: $0.detail
            )
        }
        let usage = message.hermes?.usage
        return HermesChatMessage(
            id: message.id,
            role: role,
            text: message.text,
            toolCalls: restoredToolCalls,
            attachments: restoredAttachments,
            requestedModelID: message.hermes?.requestedModelID,
            responseModelID: message.hermes?.responseModelID,
            modelName: message.modelName,
            timestamp: message.timestamp,
            isStreaming: false,
            isError: message.isError,
            responseStartedAt: usage?.responseStartedAt,
            firstResponseChunkAt: usage?.firstResponseChunkAt,
            responseCompletedAt: usage?.responseCompletedAt,
            outputTokenCount: usage?.outputTokens,
            totalTokenCount: usage?.totalTokens,
            tokenCountSource: usage?.source.flatMap { HermesTokenCountSource(rawValue: $0) },
            providerGenerationDurationSeconds: usage?.providerGenerationDurationSeconds,
            providerTotalDurationSeconds: usage?.providerTotalDurationSeconds
        )
    }

    private static func derivedTitle(from messages: [HermesChatMessage]) -> String {
        if let firstUser = messages.first(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
           !firstUser.isEmpty {
            return String(firstUser.prefix(64))
        }
        return "Hermes conversation"
    }

    private static func derivedPreview(from messages: [HermesChatMessage]) -> String {
        if let last = messages.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .text.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            return String(last.prefix(140))
        }
        return ""
    }

    func selectModel(_ option: HermesRuntimeModelOption) {
        selectedModelID = option.modelID
        defaults.set(option.modelID, forKey: selectedModelDefaultsKey)
    }

    func isFavoriteModel(_ option: HermesRuntimeModelOption) -> Bool {
        favoriteModelIDs.contains(option.modelID)
    }

    func toggleFavoriteModel(_ option: HermesRuntimeModelOption) {
        if let index = favoriteModelIDs.firstIndex(of: option.modelID) {
            favoriteModelIDs.remove(at: index)
        } else {
            favoriteModelIDs.append(option.modelID)
        }
        defaults.set(Self.encodeStringArray(favoriteModelIDs), forKey: favoriteModelsDefaultsKey)
    }

    var favoriteModelOptions: [HermesRuntimeModelOption] {
        let optionsByID = modelOptions.reduce(into: [String: HermesRuntimeModelOption]()) { partialResult, option in
            partialResult[option.modelID] = option
        }
        return favoriteModelIDs.compactMap { optionsByID[$0] }
    }

    func sendMessage(_ text: String, context: String? = nil, attachments: [HermesAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow attachment-only messages (no text) so users can send a photo
        // and let the model describe / OCR it.
        guard (!trimmed.isEmpty || !attachments.isEmpty), !isStreaming else { return }

        preferSuggestedRelayWhenLocalHostIsOffline()

        // Mint a local session id for brand-new chats so we can mirror the
        // transcript even when the host or relay never assigns one.
        if selectedSessionID == nil {
            selectedSessionID = UUID().uuidString
        }

        let userMessage = HermesChatMessage(
            role: .user,
            text: trimmed,
            attachments: attachments
        )
        messages.append(userMessage)
        isStreaming = true
        lastError = nil
        persistCurrentThread()

        currentTask?.cancel()
        currentTask = Task { @MainActor in
            do {
                try await streamCompletion(context: context)
            } catch {
                if !Task.isCancelled {
                    handleStreamError(error)
                } else {
                    isStreaming = false
                }
            }
            persistCurrentThread()
        }
    }

    private func preferSuggestedRelayWhenLocalHostIsOffline() {
        guard selectedConnection.id == HermesConnectionRecord.localDefault.id,
              !isReachable,
              let relay = suggestedRelayConnection else {
            return
        }
        _ = selectConnection(relay, refresh: false)
    }

    private func streamCompletion(context: String?, iteration: Int = 0) async throws {
        if selectedConnection.mode == .relayLink {
            try await streamRelayCompletion(context: context, iteration: iteration)
            return
        }

        var request = try makeRequest(path: "/v1/chat/completions", timeout: 60)
        request.httpMethod = "POST"
        request.httpBody = try completionRequestBody(context: context)

        let (stream, response) = try await urlSession.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HermesServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw HermesServiceError.httpStatus(code: httpResponse.statusCode)
        }

        isReachable = true

        var assistantMessage = HermesChatMessage(
            role: .assistant,
            text: "",
            requestedModelID: activeRequestedModelID,
            modelName: activeModelName,
            isStreaming: true,
            responseStartedAt: Date()
        )
        messages.append(assistantMessage)

        var eventLines: [String] = []
        for try await line in stream.lines {
            guard !Task.isCancelled else { break }
            for event in Self.consumeSSELine(line, eventLines: &eventLines) {
                processSSEPayload(event, into: &assistantMessage)
            }
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
            assistantMessage.text = "Hermes finished without returning text. Try again or switch models."
            assistantMessage.isError = true
        }
        assistantMessage.finalizeResponseMetrics()
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
        }
        try await runToolUseIterationIfNeeded(after: assistantMessage, context: context, iteration: iteration)
    }

    private func completionRequestBody(context: String?) throws -> Data {
        let model = selectedModelID ?? selectedConnection.advertisedModel ?? "hermes"

        // Build encoder messages from history. We load attachment bytes for
        // each user message that carries attachments so the encoder can emit
        // image_url / input_audio parts inline.
        let workspaceURL = HermesAttachmentWorkspace.attachmentsRootIfReady
        let encoderMessages: [HermesAttachmentEncoder.Message] = messages.compactMap { message in
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
                    if let data = HermesAttachmentWorkspace.loadBytes(
                        for: attachment,
                        in: workspaceURL
                    ) {
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
            capabilities: backendCapabilities,
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
        let toolsArray = toolCatalog.toolsWireArray()
        if !toolsArray.isEmpty {
            payload["tools"] = toolsArray
            // Default tool choice; left as a string for max compatibility
            // (a `{type, function}` object trips up some older relays).
            payload["tool_choice"] = "auto"
        }
        if let selectedSessionID {
            payload["session_id"] = selectedSessionID
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Capability hints used by the encoder. Defaults to vision-on,
    /// audio-off; refined when we learn more from `/v1/models`.
    private var backendCapabilities: HermesBackendCapabilities {
        HermesBackendCapabilities.default
    }

    private func streamRelayCompletion(context: String?, iteration: Int = 0) async throws {
        let body = try completionRequestBody(context: context)
        isReachable = true

        var assistantMessage = HermesChatMessage(
            role: .assistant,
            text: "",
            requestedModelID: activeRequestedModelID,
            modelName: activeModelName,
            isStreaming: true,
            responseStartedAt: Date()
        )
        messages.append(assistantMessage)

        try await relayTransport.sendStreaming(
            relayPayload(operation: .chatCompletions, method: "POST", path: "/v1/chat/completions", body: body),
            timeout: 120
        ) { event in
            self.processSSEPayload(event, into: &assistantMessage)
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
            assistantMessage.text = "Hermes finished without returning text. Try again or switch models."
            assistantMessage.isError = true
        }
        assistantMessage.finalizeResponseMetrics()
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
        }
        try await runToolUseIterationIfNeeded(after: assistantMessage, context: context, iteration: iteration)
    }

    /// Shared post-stream step: if the assistant turn produced tool
    /// calls that the on-device catalog can execute, run them, append
    /// the matching `role: .tool` reply messages, and re-stream so the
    /// model can produce a final natural-language reply incorporating
    /// the results. Iteration cap protects against infinite tool loops.
    private func runToolUseIterationIfNeeded(
        after message: HermesChatMessage,
        context: String?,
        iteration: Int
    ) async throws {
        guard shouldRunToolUseIteration(for: message) else {
            isStreaming = false
            return
        }
        guard iteration < maxToolUseIterations else {
            // Cap exceeded — leave the pills as "done" but stop looping.
            isStreaming = false
            return
        }

        var mutableMessage = message
        await executeToolCalls(for: &mutableMessage)
        // `executeToolCalls` already appended the tool reply messages
        // and rewrote `messages` with updated call statuses. Persist
        // the running thread so iOS history reflects the in-flight
        // tool exchange (useful when the app is backgrounded mid-loop).
        persistCurrentThread()

        // Re-enter — the next iteration sees the tool replies via the
        // `completionRequestBody` encoder and emits a follow-up turn.
        try await streamCompletion(context: context, iteration: iteration + 1)
    }

    private func processSSEPayload(_ payload: String, into message: inout HermesChatMessage) {
        for event in Self.sseEvents(from: payload) {
            processSSEEvent(event, into: &message)
        }
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
        if data == "[DONE]" { return }

        guard let jsonData = data.data(using: .utf8) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        if let usage = json["usage"] as? [String: Any],
           let stats = tokenUsageStats(from: usage) {
            applyTokenUsage(stats, to: &message)
        }

        // Ollama emits eval_count / eval_duration / total_duration as
        // top-level keys on the final chunk rather than under "usage". Treat
        // them like an inline usage record so the rate stays honest for
        // local-runtime conversations.
        if let stats = tokenUsageStats(from: json),
           stats.outputTokens != nil
                || stats.totalTokens != nil
                || stats.generationDurationSeconds != nil
                || stats.totalDurationSeconds != nil {
            applyTokenUsage(stats, to: &message)
        }

        if let modelName = modelNameValue(item: json) {
            message.applyResponseModelID(modelName)
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        }

        if let error = json["error"] as? [String: Any],
           let messageText = error["message"] as? String {
            self.lastError = messageText
            message.text = messageText
            message.isError = true
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
            return
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else { return }

        let delta = first["delta"] as? [String: Any]
        let finalMessage = first["message"] as? [String: Any]

        if let content = visibleContent(from: delta)
            ?? visibleContent(from: finalMessage)
            ?? stringValue(first["text"]) {
            appendVisibleContent(content, to: &message)
        }

        if let toolCalls = toolCalls(from: delta) ?? toolCalls(from: finalMessage) {
            mergeToolCalls(toolCalls, into: &message)
        }
    }

    private func tokenUsageStats(from usage: [String: Any]) -> HermesTokenUsageStats? {
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

        let generationDuration = Self.durationSecondsFromUsage(
            usage,
            keys: [
                "eval_duration", "evalDuration",       // Ollama (nanoseconds)
                "generation_duration", "generationDuration",
                "completion_duration", "completionDuration",
                "output_duration", "outputDuration",
                "generation_time", "generationTime"
            ]
        )

        let totalDuration = Self.durationSecondsFromUsage(
            usage,
            keys: [
                "total_duration", "totalDuration",     // Ollama (nanoseconds)
                "request_duration", "requestDuration",
                "elapsed_time", "elapsedTime",
                "duration"
            ]
        )

        guard promptTokens != nil
                || outputTokens != nil
                || totalTokens != nil
                || generationDuration != nil
                || totalDuration != nil else { return nil }
        return HermesTokenUsageStats(
            promptTokens: promptTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            generationDurationSeconds: generationDuration,
            totalDurationSeconds: totalDuration
        )
    }

    /// Reads provider-supplied durations and normalises them to seconds.
    ///
    /// Ollama emits `eval_duration` / `total_duration` in nanoseconds; OpenAI
    /// previews and most relays use seconds; some custom servers use
    /// milliseconds. We pick a unit by magnitude and only return values when
    /// they are strictly positive.
    private static func durationSecondsFromUsage(
        _ usage: [String: Any],
        keys: [String]
    ) -> TimeInterval? {
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
            // Heuristic unit detection. Ollama nanoseconds are the only
            // case in the wild that goes above ~1e6 for a single LLM turn.
            // Below 1.0 we assume seconds (sub-second responses are real).
            if value >= 1_000_000_000 {
                return value / 1_000_000_000.0    // ns → s
            } else if value >= 10_000 {
                return value / 1_000.0            // ms → s
            } else {
                return value                      // already seconds
            }
        }
        return nil
    }

    private func applyTokenUsage(_ stats: HermesTokenUsageStats, to message: inout HermesChatMessage) {
        recordUsage(stats, replacing: message.totalTokenCount)
        message.applyTokenUsage(stats)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }

    private func appendVisibleContent(_ content: String, to message: inout HermesChatMessage) {
        guard !content.isEmpty else { return }
        message.markFirstResponseChunk()
        if message.text.isEmpty || content.hasPrefix(message.text) {
            message.text = content
        } else if content != message.text {
            message.text += content
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }

    private func visibleContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["content"])
            ?? visibleContentValue(item["text"])
            ?? visibleContentValue(item["output_text"])
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

    private func toolCalls(from item: [String: Any]?) -> [[String: Any]]? {
        guard let item else { return nil }
        if let calls = item["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            return calls
        }
        if let calls = item["toolCalls"] as? [[String: Any]], !calls.isEmpty {
            return calls
        }
        if let call = item["function_call"] as? [String: Any] {
            return [call]
        }
        if let call = item["functionCall"] as? [String: Any] {
            return [call]
        }
        return nil
    }

    private func recordUsage(_ stats: HermesTokenUsageStats, replacing previousTotal: Int?) {
        guard let total = stats.totalTokens, total > 0 else { return }
        let prior = max(previousTotal ?? 0, 0)
        let delta = max(0, total - prior)
        currentConversationTokenBurn += delta
    }

    private func handleStreamError(_ error: Error) {
        isStreaming = false
        isReachable = false

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
                if selectedConnection.mode == .relayLink {
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

        let errorMessage = HermesChatMessage(
            role: .assistant,
            text: displayText,
            isError: true
        )
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming && $0.text.isEmpty && $0.toolCalls.isEmpty }) {
            messages[index] = errorMessage
        } else {
            messages.append(errorMessage)
        }
        lastError = displayText
    }

    private var activeModelName: String? {
        if let selectedModelID,
           let option = modelOptions.first(where: { $0.modelID == selectedModelID }) {
            return option.displayName.nilIfBlank ?? option.modelID.nilIfBlank
        }
        return selectedModelID?.nilIfBlank ?? selectedConnection.advertisedModel?.nilIfBlank
    }

    /// Raw model id we send in the `"model"` field of the chat completion
    /// request. Stored on the message as `requestedModelID` so we can be
    /// honest about what we asked for, even if the server reports something
    /// else back.
    private var activeRequestedModelID: String? {
        selectedModelID?.nilIfBlank
            ?? selectedConnection.advertisedModel?.nilIfBlank
    }

    func checkReachability(generation: Int? = nil) async {
        do {
            guard generation == nil || generation == runtimeGeneration else { return }
            if selectedConnection.mode == .relayLink {
                _ = try await relayTransport.sendUnary(
                    relayPayload(operation: .models, method: "GET", path: "/v1/models"),
                    timeout: 20
                )
                guard generation == nil || generation == runtimeGeneration else { return }
                isReachable = true
            } else {
                let request = try makeRequest(path: "/v1/models", timeout: 5)
                let (_, response) = try await urlSession.data(for: request)
                guard generation == nil || generation == runtimeGeneration else { return }
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    isReachable = (200..<300).contains(statusCode)
                    if statusCode == 401 || statusCode == 403 {
                        runtimeErrorText = "Hermes rejected this connection. Check the API_SERVER_KEY saved for this host."
                    }
                } else {
                    isReachable = false
                }
            }
        } catch {
            guard generation == nil || generation == runtimeGeneration else { return }
            isReachable = false
            if selectedConnection.mode == .relayLink {
                if let firestoreError = error as? FirestoreError,
                   case .notAuthenticated = firestoreError {
                    runtimeErrorText = "Sign in with the same OpenBurnBar account on this iPhone/iPad to use Remote Relay."
                } else if let hermesError = error as? HermesServiceError {
                    runtimeErrorText = hermesError.localizedDescription
                } else {
                    runtimeErrorText = "Remote Hermes relay is offline. Keep OpenBurnBar running on your Mac, signed in to this account, with Hermes reachable there."
                }
            } else {
                runtimeErrorText = "Hermes is not reachable at \(baseURL.absoluteString)."
            }
        }
    }

    private func loadModels(generation: Int) async {
        do {
            let data: Data
            if selectedConnection.mode == .relayLink {
                data = try await relayTransport.sendUnary(
                    relayPayload(operation: .models, method: "GET", path: "/v1/models"),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await urlSession.data(for: makeRequest(path: "/v1/models", timeout: 8))
                guard generation == runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == runtimeGeneration else { return }
            let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            var options = Self.modelOptions(from: decoded.data)
            if selectedConnection.mode != .relayLink {
                options = Self.mergedModelOptions(
                    primary: options,
                    secondary: await directGatewayModelOptions()
                )
            }
            modelOptions = options
            if let selectedModelID, !modelOptions.contains(where: { $0.modelID == selectedModelID }) {
                self.selectedModelID = favoriteModelOptions.first?.modelID ?? modelOptions.first?.modelID
            } else if selectedModelID == nil {
                selectedModelID = favoriteModelOptions.first?.modelID ?? modelOptions.first?.modelID
            }
        } catch {
            guard generation == runtimeGeneration else { return }
            modelOptions = []
        }
    }

    private func directGatewayModelOptions() async -> [HermesRuntimeModelOption] {
        guard let url = directGatewayModelsURL() else { return [] }
        do {
            let (data, response) = try await urlSession.data(for: URLRequest(url: url, timeoutInterval: 4))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
            return Self.modelOptions(from: decoded.data)
        } catch {
            return []
        }
    }

    private func directGatewayModelsURL() -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.host != nil else {
            return nil
        }
        components.port = 8317
        components.path = "/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func modelOptions(from models: [OpenAIModel]) -> [HermesRuntimeModelOption] {
        models.map { model in
            let provider = providerMetadata(for: model)
            return HermesRuntimeModelOption(
                providerID: provider.id,
                providerName: provider.name,
                modelID: model.id,
                displayName: model.displayName ?? model.name ?? providerDisplayName(forModelID: model.id)
            )
        }
    }

    private static func providerMetadata(for model: OpenAIModel) -> (id: String, name: String) {
        let rawProviderID = model.providerID ?? model.ownedBy ?? "hermes"
        let searchText = [
            model.providerID,
            model.ownedBy,
            model.providerName,
            model.id,
            model.displayName,
            model.name
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        if searchText.contains("minimax") || searchText.contains("abab") {
            return ("minimax", "MiniMax")
        }
        if searchText.contains("zai") || searchText.contains("z.ai") || searchText.contains("zhipu") || searchText.contains("glm") {
            return ("zai", "Z.AI / GLM")
        }
        if searchText.contains("kimi") || searchText.contains("moonshot") {
            return ("kimi-coding", "Kimi / Kimi Coding Plan")
        }
        if searchText.contains("ollama-local") || searchText.contains("ollama local") {
            return ("ollama-local", "Ollama Local")
        }
        if searchText.contains("lmstudio-local") || searchText.contains("lm studio") || searchText.contains("lmstudio") {
            return ("lmstudio-local", "LM Studio Local")
        }
        if searchText.contains("local-openai") || searchText.contains("openai compatible local") {
            return ("local-openai", "Local OpenAI-Compatible")
        }

        let providerName = model.providerName
            ?? AgentProvider.fromProviderID(ProviderID(rawValue: rawProviderID))?.displayName
            ?? rawProviderID
        return (rawProviderID, providerName)
    }

    private static func providerDisplayName(forModelID modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                if token.uppercased() == token { return String(token) }
                return token.prefix(1).uppercased() + String(token.dropFirst())
            }
            .joined(separator: " ")
    }

    private static func mergedModelOptions(
        primary: [HermesRuntimeModelOption],
        secondary: [HermesRuntimeModelOption]
    ) -> [HermesRuntimeModelOption] {
        var seen = Set<String>()
        var merged: [HermesRuntimeModelOption] = []
        for option in primary + secondary where seen.insert(option.modelID).inserted {
            merged.append(option)
        }
        return merged
    }

    private func loadSessions(generation: Int) async {
        do {
            let data: Data
            if selectedConnection.mode == .relayLink {
                data = try await relayTransport.sendUnary(
                    relayPayload(operation: .sessions, method: "GET", path: "/api/sessions"),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await urlSession.data(for: makeRequest(path: "/api/sessions", timeout: 8))
                guard generation == runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == runtimeGeneration else { return }
            sessions = parseSessions(from: data)
        } catch {
            guard generation == runtimeGeneration else { return }
            sessions = []
        }
    }

    private func loadProfiles(generation: Int) async {
        do {
            let data: Data
            if selectedConnection.mode == .relayLink {
                data = try await relayTransport.sendUnary(
                    relayPayload(operation: .profiles, method: "GET", path: "/api/profiles"),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await urlSession.data(for: makeRequest(path: "/api/profiles", timeout: 8))
                guard generation == runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == runtimeGeneration else { return }
            profiles = parseProfiles(from: data)
        } catch {
            guard generation == runtimeGeneration else { return }
            profiles = []
        }
    }

    private func loadJobs(generation: Int) async {
        do {
            let data: Data
            if selectedConnection.mode == .relayLink {
                data = try await relayTransport.sendUnary(
                    relayPayload(operation: .jobs, method: "GET", path: "/api/jobs"),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await urlSession.data(for: makeRequest(path: "/api/jobs", timeout: 8))
                guard generation == runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == runtimeGeneration else { return }
            jobs = parseJobs(from: data)
        } catch {
            guard generation == runtimeGeneration else { return }
            jobs = []
        }
    }

    private func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try secretStore.load(connectionID: selectedConnection.id), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func relayPayload(
        operation: HermesRelayOperation,
        method: String,
        path: String? = nil,
        sessionID: String? = nil,
        body: Data? = nil
    ) -> HermesRelayPayload {
        HermesRelayPayload(
            connectionID: selectedConnection.id,
            relayPublicKey: selectedConnection.relayPublicKey,
            relayKeyVersion: selectedConnection.relayKeyVersion,
            relayEncryption: selectedConnection.relayEncryption,
            realtimeRelayURL: selectedConnection.realtimeRelayURL,
            operation: operation,
            method: method,
            path: path,
            sessionID: sessionID,
            body: body
        )
    }

    private func endpoint(_ path: String) -> URL {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(path)
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
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
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

    private func parseSessions(from data: Data) -> [HermesSessionSummary] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawSessions: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawSessions = array
        } else if let dict = object as? [String: Any],
                  let array = dict["sessions"] as? [[String: Any]] {
            rawSessions = array
        } else {
            rawSessions = []
        }

        return rawSessions.compactMap { item in
            let id = stringValue(item["id"]) ?? stringValue(item["session_id"]) ?? stringValue(item["sessionId"])
            guard let id, !id.isEmpty else { return nil }
            return HermesSessionSummary(
                id: id,
                title: stringValue(item["title"]),
                preview: stringValue(item["preview"]) ?? stringValue(item["summary"]),
                source: stringValue(item["source"]),
                model: modelNameValue(item: item),
                startedAt: dateValue(item["started_at"]) ?? dateValue(item["created_at"]) ?? dateValue(item["createdAt"]),
                lastActiveAt: dateValue(item["last_active_at"]) ?? dateValue(item["updated_at"]) ?? dateValue(item["updatedAt"]),
                endedAt: dateValue(item["ended_at"]),
                isActive: boolValue(item["is_active"]) ?? boolValue(item["active"]) ?? false,
                messageCount: intValue(item["message_count"]) ?? intValue(item["messageCount"]) ?? 0,
                toolCallCount: intValue(item["tool_call_count"]) ?? intValue(item["toolCallCount"]) ?? 0,
                inputTokens: intValue(item["input_tokens"]) ?? intValue(item["inputTokens"]) ?? 0,
                outputTokens: intValue(item["output_tokens"]) ?? intValue(item["outputTokens"]) ?? 0
            )
        }
    }

    private func parseSessionMessages(from data: Data) -> [HermesChatMessage] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawMessages: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawMessages = array
        } else if let dict = object as? [String: Any] {
            rawMessages = (dict["messages"] as? [[String: Any]])
                ?? (dict["turns"] as? [[String: Any]])
                ?? (dict["events"] as? [[String: Any]])
                ?? []
        } else {
            rawMessages = []
        }
        return rawMessages.compactMap { item in
            guard let roleText = stringValue(item["role"]) ?? stringValue(item["type"]),
                  let role = HermesChatRole(rawValue: roleText) else {
                return nil
            }
            let content = stringValue(item["content"])
                ?? stringValue(item["text"])
                ?? stringValue(item["message"])
                ?? ""
            guard !content.isEmpty || role == .assistant else { return nil }
            let resolvedModel = role == .assistant ? modelNameValue(item: item) : nil
            return HermesChatMessage(
                id: stringValue(item["id"]) ?? UUID().uuidString,
                role: role,
                text: content,
                requestedModelID: stringValue(item["requested_model_id"])
                    ?? stringValue(item["requestedModelId"])
                    ?? stringValue(item["requested_model"]),
                responseModelID: role == .assistant ? resolvedModel : nil,
                modelName: resolvedModel,
                timestamp: dateValue(item["timestamp"]) ?? dateValue(item["created_at"]) ?? Date(),
                isStreaming: false,
                isError: false,
                responseStartedAt: dateValue(item["response_started_at"]) ?? dateValue(item["responseStartedAt"]),
                firstResponseChunkAt: dateValue(item["first_response_chunk_at"]) ?? dateValue(item["firstResponseChunkAt"]),
                responseCompletedAt: dateValue(item["response_completed_at"]) ?? dateValue(item["responseCompletedAt"]),
                outputTokenCount: intValue(item["output_tokens"]) ?? intValue(item["outputTokens"]) ?? intValue(item["completion_tokens"]) ?? intValue(item["completionTokens"]),
                totalTokenCount: intValue(item["total_tokens"]) ?? intValue(item["totalTokens"]),
                tokenCountSource: tokenCountSourceValue(item["token_count_source"]) ?? tokenCountSourceValue(item["tokenCountSource"])
            )
        }
    }

    private func parseProfiles(from data: Data) -> [HermesRuntimeProfile] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawProfiles: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawProfiles = array
        } else if let dict = object as? [String: Any],
                  let array = dict["profiles"] as? [[String: Any]] {
            rawProfiles = array
        } else {
            rawProfiles = []
        }

        return rawProfiles.compactMap { item in
            guard let name = stringValue(item["name"]) ?? stringValue(item["id"]) else { return nil }
            return HermesRuntimeProfile(
                name: name,
                model: stringValue(item["model"]),
                provider: stringValue(item["provider"]),
                skillCount: intValue(item["skill_count"]) ?? intValue(item["skillCount"]) ?? 0
            )
        }
    }

    private func parseJobs(from data: Data) -> [HermesRuntimeJob] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rawJobs: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rawJobs = array
        } else if let dict = object as? [String: Any],
                  let array = dict["jobs"] as? [[String: Any]] {
            rawJobs = array
        } else {
            rawJobs = []
        }

        return rawJobs.compactMap { item in
            let id = stringValue(item["id"]) ?? stringValue(item["job_id"]) ?? stringValue(item["jobId"])
            guard let id else { return nil }
            return HermesRuntimeJob(
                id: id,
                name: stringValue(item["name"]),
                prompt: stringValue(item["prompt"]) ?? stringValue(item["description"]) ?? "Hermes job",
                scheduleDisplay: stringValue(item["schedule"]) ?? stringValue(item["cron"]),
                state: stringValue(item["state"]) ?? stringValue(item["status"]) ?? "unknown",
                enabled: boolValue(item["enabled"]) ?? true,
                lastRunAt: dateValue(item["last_run_at"]) ?? dateValue(item["lastRunAt"]),
                nextRunAt: dateValue(item["next_run_at"]) ?? dateValue(item["nextRunAt"]),
                lastError: stringValue(item["last_error"]) ?? stringValue(item["lastError"])
            )
        }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    private func modelNameValue(item: [String: Any]) -> String? {
        stringValue(item["model"])
            ?? stringValue(item["model_id"])
            ?? stringValue(item["modelId"])
            ?? stringValue(item["model_name"])
            ?? stringValue(item["modelName"])
            ?? stringValue(item["selected_model"])
            ?? stringValue(item["selectedModel"])
    }

    private func tokenCountSourceValue(_ value: Any?) -> HermesTokenCountSource? {
        guard let rawValue = stringValue(value) else { return nil }
        if let source = HermesTokenCountSource(rawValue: rawValue) {
            return source
        }
        switch rawValue.lowercased() {
        case "provider", "provider_usage", "exact":
            return .providerUsage
        case "estimated", "estimated_text", "approximate":
            return .estimatedText
        default:
            return nil
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let value = value as? TimeInterval { return Date(timeIntervalSince1970: value) }
        guard let value = value as? String else { return nil }
        return Self.iso8601WithFractionalSeconds.date(from: value) ?? Self.iso8601.date(from: value)
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601 = ISO8601DateFormatter()

    static func validatedEndpointURL(_ rawValue: String) -> URL? {
        guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return nil
        }
        if scheme == "https" {
            return url
        }
        if scheme == "http", host == "localhost" || host == "127.0.0.1" || Self.isPrivateIPv4(host) {
            return url
        }
        return nil
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    private static func hasUsableRelayEncryption(_ connection: HermesConnectionRecord) -> Bool {
        connection.relayEncryption == HermesRelayCrypto.algorithm
            && (connection.relayPublicKey?.isEmpty == false)
    }

    private static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    private static func decodeStringArray(_ text: String?) -> [String] {
        guard let text,
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }
}

@MainActor
final class HermesCompositeRelayTransport: HermesRelayTransporting {
    static let shared = HermesCompositeRelayTransport(
        realtime: HermesRealtimeRelayTransport.shared,
        fallback: FirestoreHermesRelayTransport.shared
    )

    private let realtime: HermesRelayTransporting
    private let fallback: HermesRelayTransporting

    init(realtime: HermesRelayTransporting, fallback: HermesRelayTransporting) {
        self.realtime = realtime
        self.fallback = fallback
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        do {
            return try await realtime.sendUnary(payload, timeout: timeout)
        } catch {
            return try await fallback.sendUnary(payload, timeout: timeout)
        }
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        do {
            try await realtime.sendStreaming(payload, timeout: timeout, onSSEEvent: onSSEEvent)
        } catch {
            try await fallback.sendStreaming(payload, timeout: timeout, onSSEEvent: onSSEEvent)
        }
    }
}

@MainActor
final class HermesRealtimeRelayTransport: HermesRelayTransporting {
    static let shared = HermesRealtimeRelayTransport()

    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        var fragments: [Int: String] = [:]
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .data:
                fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
            case .error:
                throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes realtime relay failed.")
            case .sse:
                break
            }
        }
        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return Data(body.utf8)
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        try await send(payload, timeout: timeout) { chunk in
            switch chunk.kind {
            case .sse:
                if let data = chunk.data ?? chunk.text, !data.isEmpty {
                    onSSEEvent(data)
                }
            case .error:
                throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes realtime relay stream failed.")
            case .data:
                break
            }
        }
    }

    private func send(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onChunk: (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        guard let relayURL = realtimeRelayURL(for: payload) else {
            throw HermesServiceError.relayUnavailable("Realtime relay URL is not configured.")
        }
        guard payload.connectionID != HermesConnectionRecord.localDefault.id else {
            throw HermesServiceError.relayUnavailable("Select a Remote Relay Hermes connection first.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.algorithm,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic.")
        }

        let requestID = "rt_\(UUID().uuidString.lowercased())"
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let bodyString = payload.body.flatMap { String(data: $0, encoding: .utf8) }
        let encryptedPayload = HermesRelayEncryptedRequestPayload(
            path: payload.path,
            sessionId: payload.sessionID,
            body: bodyString
        )
        let plaintext = try JSONEncoder().encode(encryptedPayload)
        let requestAAD = HermesRelayCrypto.requestAAD(uid: uid, connectionID: payload.connectionID, requestID: requestID)
        let keyAAD = HermesRelayCrypto.keyAAD(uid: uid, connectionID: payload.connectionID, requestID: requestID)

        var request = URLRequest(url: relayURL, timeoutInterval: timeout)
        request.setValue("Bearer \(try await firebaseIDToken())", forHTTPHeaderField: "Authorization")
        request.setValue(try await appCheckToken(), forHTTPHeaderField: "X-Firebase-AppCheck")
        request.setValue(
            HermesRealtimeRelayProtocol.clientRoleHeaderValue,
            forHTTPHeaderField: HermesRealtimeRelayProtocol.roleHeaderName
        )
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }

        let startFrame = HermesRealtimeRelayFrame(
            type: .requestStart,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID,
            payload: HermesRealtimeRelayPayload(
                operation: payload.operation,
                method: payload.method,
                payloadCiphertext: try HermesRelayCrypto.sealToBase64(
                    plaintext: plaintext,
                    keyData: keyData,
                    aad: requestAAD
                ),
                wrappedKey: try HermesRelayCrypto.wrapSymmetricKey(
                    keyData,
                    recipientPublicKeyBase64: relayPublicKey,
                    aad: keyAAD
                ),
                relayEncryption: HermesRelayCrypto.algorithm,
                relayKeyVersion: payload.relayKeyVersion ?? HermesRelayCrypto.keyVersion
            )
        )
        try await task.send(.data(encoder.encode(startFrame)))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frame = try await receiveFrame(
                from: task,
                timeout: max(0, deadline.timeIntervalSinceNow)
            )
            guard frame.uid == uid,
                  frame.connectionId == payload.connectionID,
                  frame.requestId == requestID else {
                continue
            }
            switch frame.type {
            case .responseChunk:
                guard let chunk = try chunkRecord(from: frame, uid: uid, keyData: keyData) else { continue }
                try onChunk(chunk)
            case .responseComplete:
                return
            case .responseError:
                throw HermesServiceError.relayUnavailable(frame.payload?.error ?? "Hermes realtime relay failed.")
            case .ping:
                try await task.send(.data(encoder.encode(HermesRealtimeRelayFrame(
                    type: .pong,
                    uid: uid,
                    connectionId: payload.connectionID,
                    requestId: requestID
                ))))
            case .hostRegister, .hostReady, .requestStart, .requestCancel, .pong:
                break
            }
        }

        try? await task.send(.data(encoder.encode(HermesRealtimeRelayFrame(
            type: .requestCancel,
            uid: uid,
            connectionId: payload.connectionID,
            requestId: requestID
        ))))
        throw HermesServiceError.relayTimeout
    }

    private func chunkRecord(from frame: HermesRealtimeRelayFrame, uid: String, keyData: Data) throws -> HermesRelayChunkRecord? {
        guard let payload = frame.payload,
              let sequence = payload.sequence,
              let kind = payload.kind,
              let requestID = frame.requestId else {
            return nil
        }
        if kind == .error {
            return HermesRelayChunkRecord(
                id: String(format: "%08d", sequence),
                requestId: requestID,
                sequence: sequence,
                kind: kind,
                error: payload.error ?? "Hermes realtime relay failed.",
                schemaVersion: 2
            )
        }
        guard let ciphertext = payload.ciphertext else {
            throw HermesServiceError.relayUnavailable("Realtime relay returned a chunk without ciphertext.")
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: frame.connectionId,
                requestID: requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        return HermesRelayChunkRecord(
            id: String(format: "%08d", sequence),
            requestId: requestID,
            sequence: sequence,
            kind: kind,
            data: String(data: plaintext, encoding: .utf8) ?? "",
            schemaVersion: 2
        )
    }

    private func receiveFrame(from task: URLSessionWebSocketTask) async throws -> HermesRealtimeRelayFrame {
        try Self.decodeFrame(try await task.receive())
    }

    private func receiveFrame(
        from task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> HermesRealtimeRelayFrame {
        guard timeout > 0 else {
            throw HermesServiceError.relayTimeout
        }
        return try await withThrowingTaskGroup(of: HermesRealtimeRelayFrame.self) { group in
            group.addTask {
                try Self.decodeFrame(try await task.receive())
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.timeoutNanoseconds(timeout))
                throw HermesServiceError.relayTimeout
            }
            guard let frame = try await group.next() else {
                throw HermesServiceError.relayTimeout
            }
            group.cancelAll()
            return frame
        }
    }

    private nonisolated static func decodeFrame(
        _ message: URLSessionWebSocketTask.Message
    ) throws -> HermesRealtimeRelayFrame {
        switch message {
        case .data(let data):
            return try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: data)
        case .string(let string):
            return try JSONDecoder().decode(HermesRealtimeRelayFrame.self, from: Data(string.utf8))
        @unknown default:
            throw HermesServiceError.invalidResponse
        }
    }

    private nonisolated static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        let capped = min(max(timeout, 0.001), 3_600)
        return UInt64(capped * 1_000_000_000)
    }

    private func realtimeRelayURL(for payload: HermesRelayPayload) -> URL? {
        let raw = payload.realtimeRelayURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Bundle.main.object(forInfoDictionaryKey: "HermesRealtimeRelayURL") as? String
            ?? ""
        guard !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme == "wss" || url.scheme == "ws" {
            return url
        }
        return nil
    }

    private func firebaseIDToken() async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let user = Auth.auth().currentUser else {
            throw FirestoreError.notAuthenticated
        }
        return try await withCheckedThrowingContinuation { continuation in
            user.getIDToken { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: FirestoreError.notAuthenticated)
                }
            }
        }
    }

    private func appCheckToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            AppCheck.appCheck().token(forcingRefresh: false) { token, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let token, !token.token.isEmpty {
                    continuation.resume(returning: token.token)
                } else {
                    continuation.resume(throwing: HermesServiceError.relayUnavailable("App Check token is unavailable."))
                }
            }
        }
    }
}

@MainActor
final class FirestoreHermesRelayTransport: HermesRelayTransporting {
    static let shared = FirestoreHermesRelayTransport()

    private let injectedDB: Firestore?
    private var db: Firestore { injectedDB ?? Firestore.firestore() }
    private let pollIntervalNanoseconds: UInt64

    private struct RelayRequestHandle {
        let requestID: String
        let connectionID: String
        let keyData: Data
    }

    init(db: Firestore? = nil, pollIntervalNanoseconds: UInt64 = 250_000_000) {
        self.injectedDB = db
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        let handle = try await createRelayRequest(payload, timeout: timeout)
        var fragments: [Int: String] = [:]
        do {
            try await pollRelay(
                handle: handle,
                timeout: timeout,
                onChunk: { chunk in
                    switch chunk.kind {
                    case .data:
                        fragments[chunk.sequence] = chunk.data ?? chunk.text ?? ""
                    case .error:
                        throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes relay request failed.")
                    case .sse:
                        break
                    }
                }
            )
        } catch {
            try? await cancelRelayRequest(handle.requestID)
            throw error
        }
        let body = fragments
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        return Data(body.utf8)
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        let handle = try await createRelayRequest(payload, timeout: timeout)
        do {
            try await pollRelay(
                handle: handle,
                timeout: timeout,
                onChunk: { chunk in
                    switch chunk.kind {
                    case .sse:
                        if let data = chunk.data ?? chunk.text, !data.isEmpty {
                            onSSEEvent(data)
                        }
                    case .error:
                        throw HermesServiceError.relayUnavailable(chunk.error ?? "Hermes relay stream failed.")
                    case .data:
                        break
                    }
                }
            )
        } catch {
            try? await cancelRelayRequest(handle.requestID)
            throw error
        }
    }

    private func createRelayRequest(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> RelayRequestHandle {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        guard payload.connectionID != HermesConnectionRecord.localDefault.id else {
            throw HermesServiceError.relayUnavailable("Select a Remote Relay Hermes connection first.")
        }
        guard payload.relayEncryption == HermesRelayCrypto.algorithm,
              let relayPublicKey = payload.relayPublicKey,
              !relayPublicKey.isEmpty else {
            throw HermesServiceError.relayUnavailable("Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic.")
        }
        let requestID = "relay_\(UUID().uuidString.lowercased())"
        let now = Date()
        let expiresAt = now.addingTimeInterval(max(timeout, 30))
        let keyData = try HermesRelayCrypto.generateSymmetricKeyData()
        let bodyString: String?
        if let body = payload.body {
            guard let value = String(data: body, encoding: .utf8) else {
                throw HermesServiceError.decodingFailed
            }
            bodyString = value
        } else {
            bodyString = nil
        }
        let encryptedPayload = HermesRelayEncryptedRequestPayload(
            path: payload.path,
            sessionId: payload.sessionID,
            body: bodyString
        )
        let plaintext = try JSONEncoder().encode(encryptedPayload)
        let requestAAD = HermesRelayCrypto.requestAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )
        let keyAAD = HermesRelayCrypto.keyAAD(
            uid: uid,
            connectionID: payload.connectionID,
            requestID: requestID
        )
        let data: [String: Any] = [
            "id": requestID,
            "connectionId": payload.connectionID,
            "operation": payload.operation.rawValue,
            "status": HermesRelayRequestStatus.pending.rawValue,
            "method": payload.method.uppercased(),
            "payloadCiphertext": try HermesRelayCrypto.sealToBase64(
                plaintext: plaintext,
                keyData: keyData,
                aad: requestAAD
            ),
            "wrappedKey": try HermesRelayCrypto.wrapSymmetricKey(
                keyData,
                recipientPublicKeyBase64: relayPublicKey,
                aad: keyAAD
            ),
            "relayEncryption": HermesRelayCrypto.algorithm,
            "relayKeyVersion": payload.relayKeyVersion ?? HermesRelayCrypto.keyVersion,
            "chunkCount": 0,
            "createdAt": Self.iso8601.string(from: now),
            "updatedAt": Self.iso8601.string(from: now),
            "expiresAt": Self.iso8601.string(from: expiresAt),
            "expireAt": Timestamp(date: expiresAt),
            "schemaVersion": 2
        ]
        try await requestRef(uid: uid, requestID: requestID).setData(data, merge: false)
        return RelayRequestHandle(requestID: requestID, connectionID: payload.connectionID, keyData: keyData)
    }

    private func pollRelay(
        handle: RelayRequestHandle,
        timeout: TimeInterval,
        onChunk: (HermesRelayChunkRecord) throws -> Void
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw FirestoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw FirestoreError.notAuthenticated
        }
        let request = requestRef(uid: uid, requestID: handle.requestID)
        let deadline = Date().addingTimeInterval(timeout)
        var lastSequence = -1
        while Date() < deadline {
            try Task.checkCancellation()

            let chunkSnapshot = try await request
                .collection("chunks")
                .whereField("sequence", isGreaterThan: lastSequence)
                .order(by: "sequence")
                .getDocuments()
            for document in chunkSnapshot.documents {
                if let chunk = decodeChunk(document.data(), docID: document.documentID) {
                    try onChunk(decryptChunkIfNeeded(chunk, uid: uid, handle: handle))
                    lastSequence = max(lastSequence, chunk.sequence)
                }
            }

            let requestSnapshot = try await request.getDocument()
            let requestData = requestSnapshot.data() ?? [:]
            guard let statusText = requestData["status"] as? String,
                  let status = HermesRelayRequestStatus(rawValue: statusText) else {
                throw HermesServiceError.relayUnavailable("Remote Hermes relay request disappeared.")
            }
            switch status {
            case .completed:
                let expectedChunkCount = requestData["chunkCount"] as? Int ?? 0
                if expectedChunkCount == 0 || lastSequence + 1 >= expectedChunkCount {
                    return
                }
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            case .failed:
                let error = requestData["error"] as? String
                throw HermesServiceError.relayUnavailable(error ?? "Remote Hermes relay failed.")
            case .cancelled, .expired:
                throw HermesServiceError.relayUnavailable("Remote Hermes relay request was \(status.rawValue).")
            case .pending, .claimed, .streaming:
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
        try? await cancelRelayRequest(handle.requestID)
        throw HermesServiceError.relayTimeout
    }

    private func decryptChunkIfNeeded(
        _ chunk: HermesRelayChunkRecord,
        uid: String,
        handle: RelayRequestHandle
    ) throws -> HermesRelayChunkRecord {
        guard chunk.schemaVersion >= 2 || chunk.ciphertext != nil else {
            return chunk
        }
        guard let ciphertext = chunk.ciphertext else {
            throw HermesServiceError.relayUnavailable("Remote Hermes relay returned an encrypted chunk without ciphertext.")
        }
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: handle.keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: uid,
                connectionID: handle.connectionID,
                requestID: handle.requestID,
                sequence: chunk.sequence,
                kind: chunk.kind.rawValue
            )
        )
        let text = String(data: plaintext, encoding: .utf8) ?? ""
        switch chunk.kind {
        case .error:
            return HermesRelayChunkRecord(
                id: chunk.id,
                requestId: chunk.requestId,
                sequence: chunk.sequence,
                kind: chunk.kind,
                error: text,
                schemaVersion: chunk.schemaVersion
            )
        case .data, .sse:
            return HermesRelayChunkRecord(
                id: chunk.id,
                requestId: chunk.requestId,
                sequence: chunk.sequence,
                kind: chunk.kind,
                data: text,
                schemaVersion: chunk.schemaVersion
            )
        }
    }

    private func cancelRelayRequest(_ requestID: String) async throws {
        guard FirebaseApp.app() != nil else { return }
        guard let uid = Auth.auth().currentUser?.uid else { return }
        try await requestRef(uid: uid, requestID: requestID).setData([
            "status": HermesRelayRequestStatus.cancelled.rawValue,
            "updatedAt": Self.iso8601.string(from: Date())
        ], merge: true)
    }

    private func requestRef(uid: String, requestID: String) -> DocumentReference {
        db.collection("users").document(uid).collection("hermes_relay_requests").document(requestID)
    }

    private func decodeChunk(_ data: [String: Any], docID: String) -> HermesRelayChunkRecord? {
        guard let requestID = data["requestId"] as? String,
              let sequence = data["sequence"] as? Int,
              let kindText = data["kind"] as? String,
              let kind = HermesRelayChunkKind(rawValue: kindText) else {
            return nil
        }
        return HermesRelayChunkRecord(
            id: data["id"] as? String ?? docID,
            requestId: requestID,
            sequence: sequence,
            kind: kind,
            data: data["data"] as? String,
            text: data["text"] as? String,
            error: data["error"] as? String,
            ciphertext: data["ciphertext"] as? String,
            schemaVersion: data["schemaVersion"] as? Int ?? 1
        )
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

enum HermesServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(code: Int)
    case decodingFailed
    case invalidURL
    case keychain(OSStatus)
    case relayUnavailable(String)
    case relayTimeout

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Hermes server."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Hermes rejected the saved API key. Check API_SERVER_KEY for this host."
            }
            return "Hermes returned HTTP \(code)."
        case .decodingFailed:
            return "Failed to decode the response stream."
        case .invalidURL:
            return "Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts."
        case .keychain(let status):
            return "Could not update the Hermes API key in Keychain (\(status))."
        case .relayUnavailable(let message):
            return message
        case .relayTimeout:
            return "Remote Hermes relay timed out. Keep OpenBurnBar running on your Mac and try again."
        }
    }
}

final class HermesConnectionSecretStore: HermesConnectionSecretStoring {
    static let shared = HermesConnectionSecretStore()

    private let keychainService = "com.openburnbar.mobile.hermes-connection"

    func save(_ value: String, connectionID: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionID
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HermesServiceError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw HermesServiceError.keychain(status)
        }
    }

    func load(connectionID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionID,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw HermesServiceError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(connectionID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: connectionID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesServiceError.keychain(status)
        }
    }
}

private struct OpenAIModelsResponse: Decodable {
    var data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    var id: String
    var ownedBy: String?
    var providerID: String?
    var providerName: String?
    var displayName: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
        case providerID = "provider_id"
        case providerName = "provider_name"
        case displayName = "display_name"
        case name
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Tool Use Loop Support
//
// Surfaces the `MobileToolCatalog` to the chat view + executes any tool
// calls a streamed assistant turn produced. After execution we append
// `role: .tool` reply messages to `messages` so the next
// `streamCompletion(...)` iteration replays both the prior assistant call
// and the tool result up to the upstream model.

extension HermesService: MobileToolContext {
    /// Install / replace the navigator the `burnbar_atom_open` tool uses
    /// to drive in-app navigation. Pass `nil` to disconnect (useful when
    /// the host view disappears). Held weakly so the service never
    /// extends the navigator's lifetime.
    public func setToolAtomNavigator(_ navigator: HermesAtomNavigator?) {
        if let navigator {
            // Capture as `AnyObject` so the weak slot accepts existential
            // protocol types (the protocol is `AnyObject`-constrained).
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
        sessions.map { session in
            MobileToolSessionSummary(
                id: session.id,
                title: session.title,
                preview: session.preview,
                model: session.model,
                messageCount: session.messageCount,
                toolCallCount: session.toolCallCount,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                lastActiveAt: session.lastActiveAt ?? session.startedAt
            )
        }
    }

    public var runtimeStatusSnapshot: MobileToolRuntimeStatus {
        MobileToolRuntimeStatus(
            runtime: "hermes",
            isReachable: isReachable,
            connectionName: selectedConnection.displayName.nilIfBlank,
            connectionMode: selectedConnection.mode.rawValue,
            selectedModelID: selectedModelID?.nilIfBlank,
            advertisedModel: selectedConnection.advertisedModel?.nilIfBlank,
            lastError: lastError?.nilIfBlank
        )
    }
}

extension HermesService {
    /// `true` when the assistant turn produced tool calls we should
    /// execute. Iteration cap is enforced by the caller via
    /// `maxToolUseIterations`.
    func shouldRunToolUseIteration(for message: HermesChatMessage) -> Bool {
        guard !toolCatalog.tools.isEmpty,
              !message.toolCalls.isEmpty,
              !message.isError else {
            return false
        }
        return true
    }

    /// Public cap. Test injection point; in production we always use the
    /// instance value.
    var toolUseIterationCap: Int { maxToolUseIterations }

    /// Read-only accessor for the Insights bridge so the OpenBurnBarCore
    /// Hermes adapter can target the same `/v1/chat/completions` endpoint
    /// the chat surface is already using. Tracks `setBaseURL`-driven
    /// connection switches so a freshly-selected relay routes Insights
    /// follow-ups through the same path as chat replies. The bridge
    /// gates the actual registration on `isReachable`, so a stale URL
    /// here never produces a broken Hermes catalog entry.
    var insightsBaseURL: URL { baseURL }

    /// Best-effort authorization header the Insights bridge passes to
    /// the Hermes relay. Local LAN sessions are unauthenticated; hosted
    /// relays send the user's relay credential. The bridge calls into
    /// `secretStore` directly for relay credentials, so this hook stays
    /// nil in production and only exists for the LAN path's diagnostic
    /// banner.
    var insightsAuthorizationHeader: String? { nil }

    /// Execute every tool call on `message`, append a matching tool-role
    /// reply message to `messages` for each, and stamp the call's
    /// `status` so the pill reflects success / failure. Returns the list
    /// of results in input order (mainly for tests).
    @discardableResult
    func executeToolCalls(
        for message: inout HermesChatMessage
    ) async -> [MobileToolExecutionResult] {
        guard !message.toolCalls.isEmpty else { return [] }
        let pending = message.toolCalls.map { call in
            PendingToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }
        let executor = MobileToolExecutor(catalog: toolCatalog)
        let results = await executor.execute(pending, context: self)

        var updated = message
        var statusByID: [String: String] = [:]
        for result in results {
            statusByID[result.toolCallID] = result.isError ? "failed" : "done"
        }
        updated.toolCalls = updated.toolCalls.map { call in
            HermesToolCall(
                id: call.id,
                name: call.name,
                status: statusByID[call.id] ?? call.status,
                arguments: call.arguments,
                detail: call.detail ?? Self.summarizeToolArguments(call.arguments)
            )
        }
        message = updated

        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }

        for result in results {
            let reply = HermesChatMessage(
                role: .tool,
                text: result.content,
                isError: result.isError,
                toolCallID: result.toolCallID
            )
            messages.append(reply)
        }

        return results
    }
}
