import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

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
    /// Shared instance for views that need to read Hermes state but don't
    /// own the lifecycle (notably the Pi conversation list brand header
    /// which needs an `AssistantModelLens` but isn't otherwise wired to
    /// Hermes). Long-running views still inject their own instance for
    /// per-surface CONVERSATION state — but all production instances share
    /// the `HermesRuntimeStore.shared` catalog, so connections, models,
    /// and the persisted selection stay consistent across surfaces and the
    /// 6-op runtime refresh is coalesced globally.
    static let shared = HermesService(runtimeStore: .shared)

    /// The per-surface instance currently bound to the main chat transcript
    /// (`HermesChatView` registers itself on appear). Cross-cutting services
    /// that must read or mutate CONVERSATION state (selected session, sending
    /// a message into the visible chat) route through this instance instead
    /// of `.shared` — `.shared` deliberately carries no conversation state,
    /// so writes to it never reach the UI. Falls back to `.shared` (today's
    /// behavior) when no chat surface has appeared yet. Weak: cleared
    /// automatically when the owning surface's root view goes away.
    static weak var mainSurface: HermesService?

    // ── Per-surface conversation state (deliberately NOT shared; see doc) ──
    // Stored in `HermesConversationStateStore` (one per service instance);
    // computed proxies keep the public API identical and let @Observable
    // tracking flow through to the store's stored properties — the same
    // pattern as the runtime catalog proxies below.
    var messages: [HermesChatMessage] {
        get { conversation.messages }
        set { conversation.messages = newValue }
    }
    var selectedSessionID: String? {
        get { conversation.selectedSessionID }
        set { conversation.selectedSessionID = newValue }
    }
    var currentConversationTokenBurn: Int {
        get { conversation.currentConversationTokenBurn }
        set { conversation.currentConversationTokenBurn = newValue }
    }
    var isStreaming: Bool {
        get { conversation.isStreaming }
        set { conversation.isStreaming = newValue }
    }
    var lastError: String? {
        get { conversation.lastError }
        set { conversation.lastError = newValue }
    }
    var visibleCLIStatusText: String? {
        get { conversation.visibleCLIStatusText }
        set { conversation.visibleCLIStatusText = newValue }
    }
    var visibleCLIErrorText: String? {
        get { conversation.visibleCLIErrorText }
        set { conversation.visibleCLIErrorText = newValue }
    }

    /// Shared runtime catalog (connections / reachability / models /
    /// session-profile-job lists + persisted selection). Production
    /// surfaces inject `HermesRuntimeStore.shared`; tests and previews get
    /// an isolated store, preserving the historical per-instance behavior.
    let runtime: HermesRuntimeStore

    // ── Catalog proxies into the shared runtime store ──
    // Computed (not stored) so @Observable tracking flows through to the
    // store's stored properties: every surface invalidates on a catalog
    // change regardless of which `HermesService` instance wrote it.
    var connections: [HermesConnectionRecord] {
        get { runtime.connections }
        set { runtime.connections = newValue }
    }
    var selectedConnection: HermesConnectionRecord {
        get { runtime.selectedConnection }
        set { runtime.selectedConnection = newValue }
    }
    var sessions: [HermesSessionSummary] {
        get { runtime.sessions }
        set { runtime.sessions = newValue }
    }
    var profiles: [HermesRuntimeProfile] {
        get { runtime.profiles }
        set { runtime.profiles = newValue }
    }
    var modelOptions: [HermesRuntimeModelOption] {
        get { runtime.modelOptions }
        set { runtime.modelOptions = newValue }
    }
    var jobs: [HermesRuntimeJob] {
        get { runtime.jobs }
        set { runtime.jobs = newValue }
    }
    var selectedModelID: String? {
        get { runtime.selectedModelID }
        set { runtime.selectedModelID = newValue }
    }
    var favoriteModelIDs: [String] {
        get { runtime.favoriteModelIDs }
        set { runtime.favoriteModelIDs = newValue }
    }
    var isReachable: Bool {
        get { runtime.isReachable }
        set { runtime.isReachable = newValue }
    }
    var isLoadingRuntime: Bool {
        get { runtime.isLoadingRuntime }
        set { runtime.isLoadingRuntime = newValue }
    }
    var runtimeErrorText: String? {
        get { runtime.runtimeErrorText }
        set { runtime.runtimeErrorText = newValue }
    }

    private var currentTask: Task<Void, Never>?
    var baseURL: URL {
        get { runtime.baseURL }
        set { runtime.baseURL = newValue }
    }
    var selectedModelWasExplicit: Bool {
        get { runtime.selectedModelWasExplicit }
        set { runtime.selectedModelWasExplicit = newValue }
    }
    let urlSession: URLSession
    let functionsRepository: FunctionsRepository
    let connectionRepository: HermesConnectionListing
    let secretStore: HermesConnectionSecretStoring
    let relayTransport: HermesRelayTransporting
    let defaults: UserDefaults
    private let history: MobileChatHistoryStore
    // Refresh coalescing lives on the shared runtime store so concurrent
    // refreshes from ANY surface collapse to one 6-op fan-out.
    var runtimeGeneration: Int {
        get { runtime.runtimeGeneration }
        set { runtime.runtimeGeneration = newValue }
    }
    private var runtimeRefreshTask: Task<Void, Never>? {
        get { runtime.runtimeRefreshTask }
        set { runtime.runtimeRefreshTask = newValue }
    }
    private var runtimeRefreshGeneration: Int? {
        get { runtime.runtimeRefreshGeneration }
        set { runtime.runtimeRefreshGeneration = newValue }
    }
    /// SSE framing + streamed-event application (including the deliberate
    /// 80ms visible-text commit throttle) lives in `HermesStreamingEngine`;
    /// the service stays the transport/conversation coordinator. Lazy so
    /// the effect closures can capture `self`; ignored by observation —
    /// the engine reports state changes back through those closures only.
    @ObservationIgnored
    private lazy var streamingEngine = HermesStreamingEngine(
        commitMessage: { [weak self] message in
            self?.commitStreamedMessage(message)
        },
        setLastError: { [weak self] text in
            self?.lastError = text
        },
        recordUsage: { [weak self] stats, previousTotal in
            self?.recordUsage(stats, replacing: previousTotal)
        }
    )
    /// Per-thread transcript state + history persistence bridge lives in
    /// `HermesConversationStateStore` (the computed proxies above keep the
    /// public API identical). Lazy so the injected coordinator effects can
    /// capture `self`; ignored by observation — tracking flows through the
    /// store's own @Observable stored properties via those proxies.
    @ObservationIgnored
    private lazy var conversation = HermesConversationStateStore(
        history: history,
        activeModelName: { [weak self] in
            guard let self else { return nil }
            return self.activeModelName ?? self.selectedModelID
        },
        activeRequestedModelID: { [weak self] in
            self?.activeRequestedModelID
        },
        cancelActiveStream: { [weak self] in
            self?.currentTask?.cancel()
            self?.currentTask = nil
        }
    )
    /// Relay/transport routing decisions (usable relay candidates, suggested
    /// relay, send-time relay preference, endpoint validation) live in
    /// `HermesTransportSelector`; the service forwards so views and tests
    /// keep their existing API, and stays the coordinator that acts on the
    /// decisions. Lazy so the provider closure can capture `self`; ignored
    /// by observation — reads flow through to the @Observable runtime
    /// store's `connections`.
    @ObservationIgnored
    private lazy var transportSelector = HermesTransportSelector(
        connectionsProvider: { [weak self] in self?.connections ?? [] }
    )
    let remoteRelayChatCompletionTimeout: TimeInterval = 360
    let remoteRelayControlPlaneTimeout: TimeInterval = 90
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
    fileprivate var atomNavigatorAccessor: (() -> HermesAtomNavigator?)?

    // Relay candidate/eligibility decisions live in
    // `HermesTransportSelector`; these forwarders keep the API views and
    // tests bind to.
    var relayConnections: [HermesConnectionRecord] {
        transportSelector.relayConnections
    }

    var suggestedRelayConnection: HermesConnectionRecord? {
        transportSelector.suggestedRelayConnection
    }

    var isRemoteRelayEnabled: Bool {
        selectedConnection.mode == .relayLink
    }

    func preferredRelayConnection(refreshIfMissing: Bool = false) async -> HermesConnectionRecord? {
        if refreshIfMissing, relayConnections.isEmpty {
            await refreshConnections(refreshSelectedConnection: false)
        }
        return transportSelector.preferredRelayConnection(selected: selectedConnection)
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
        toolCatalog: MobileToolCatalog = .default,
        runtimeStore: HermesRuntimeStore? = nil
    ) {
        self.urlSession = urlSession
        self.functionsRepository = functionsRepository
        self.connectionRepository = connectionRepository
        self.secretStore = secretStore
        self.relayTransport = relayTransport
        self.defaults = defaults
        self.history = history
        self.toolCatalog = toolCatalog
        // Without an injected store each service gets an isolated catalog
        // (test/preview isolation + historical behavior); production
        // surfaces pass `.shared`. The store restores the persisted
        // model selection and favorites from `defaults` itself.
        self.runtime = runtimeStore ?? HermesRuntimeStore(defaults: defaults, baseURL: baseURL)
        history.loadFromDiskIfNeeded()
        SystemPermissionInboxStore.shared.retryHandler = { [weak self] item in
            self?.retryAfterSystemPermissionGrant(item: item)
        }
    }

    func loadHistory() {
        Task { @MainActor in
            await refreshRuntime()
        }
    }

    func refreshRuntime() async {
        if let runtimeRefreshTask, runtimeRefreshGeneration == runtimeGeneration {
            await runtimeRefreshTask.value
            return
        }

        runtimeRefreshTask?.cancel()

        let generation = runtimeGeneration
        runtimeRefreshGeneration = generation

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeRefresh()
        }
        runtimeRefreshTask = task
        await task.value

        if runtimeRefreshGeneration == generation {
            runtimeRefreshTask = nil
            runtimeRefreshGeneration = nil
        }
    }

    /// Skips the 6-op runtime fan-out while the shared catalog is fresh for
    /// the current connection generation — the warm path for tab returns
    /// and remounted surfaces. Anything that needs guaranteed-fresh data
    /// (pull-to-refresh, foreground transitions) calls `refreshRuntime()`.
    func refreshRuntimeIfStale(maxAge: TimeInterval = 120) async {
        if let completedAt = runtime.lastRefreshCompletedAt,
           runtime.lastRefreshCompletedGeneration == runtimeGeneration,
           Date().timeIntervalSince(completedAt) < maxAge {
            return
        }
        await refreshRuntime()
    }

    private func performRuntimeRefresh() async {
        let generation = runtimeGeneration
        isLoadingRuntime = true
        runtimeErrorText = nil
        defer {
            if generation == runtimeGeneration {
                isLoadingRuntime = false
                runtime.lastRefreshCompletedAt = Date()
                runtime.lastRefreshCompletedGeneration = generation
            }
        }

        async let connectionRefresh: Void = refreshConnections(generation: generation)
        async let reachabilityRefresh: Void = checkReachability(generation: generation)
        async let modelRefresh: Void = loadModels(generation: generation)
        async let sessionRefresh: Void = transportSelector.loadSessions(generation: generation, coordinator: self)
        async let profileRefresh: Void = transportSelector.loadProfiles(generation: generation, coordinator: self)
        async let jobRefresh: Void = transportSelector.loadJobs(generation: generation, coordinator: self)
        _ = await (connectionRefresh, reachabilityRefresh, modelRefresh, sessionRefresh, profileRefresh, jobRefresh)
    }

    // Connection / route management bodies live in
    // `HermesTransportSelector` (which operates on service state through
    // `HermesTransportCoordinating`); these pass-throughs keep the API
    // views and tests bind to.
    func refreshConnections(generation: Int? = nil, refreshSelectedConnection: Bool = true) async {
        await transportSelector.refreshConnections(
            generation: generation,
            refreshSelectedConnection: refreshSelectedConnection,
            coordinator: self
        )
    }

    @discardableResult
    func selectConnection(_ connection: HermesConnectionRecord, refresh: Bool = true) -> Bool {
        transportSelector.selectConnection(connection, refresh: refresh, coordinator: self)
    }

    @discardableResult
    func connectToSuggestedRelay(refresh: Bool = true) -> Bool {
        transportSelector.connectToSuggestedRelay(refresh: refresh, coordinator: self)
    }

    @discardableResult
    func setRemoteRelayEnabled(_ enabled: Bool, refresh: Bool = true) -> Bool {
        transportSelector.setRemoteRelayEnabled(enabled, refresh: refresh, coordinator: self)
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
        try await transportSelector.addDirectConnection(
            displayName: displayName,
            endpointURL: endpointURL,
            bearerToken: bearerToken,
            coordinator: self
        )
    }

    func revokeConnection(_ connection: HermesConnectionRecord) async throws {
        try await transportSelector.revokeConnection(connection, coordinator: self)
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
            let loaded = HermesWireValueParsing.parseSessionMessages(from: data)
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
            // Titles are plain-text chrome — flatten any markdown that leaked
            // in from assistant-derived previews.
            return HermesAtomParser.plainText(session.title ?? session.preview ?? "Hermes Session")
        }
        return String(sessionID.prefix(12))
    }

    func clearChat() {
        currentTask?.cancel()
        currentTask = nil
        conversation.cancelVisibleCLIObservation()
        visibleCLIStatusText = nil
        visibleCLIErrorText = nil
        messages.removeAll()
        lastError = nil
        isStreaming = false
        currentConversationTokenBurn = 0
    }

    func ensureDesktopGrantThreadID() -> String {
        if selectedSessionID == nil {
            selectedSessionID = UUID().uuidString
        }
        return selectedSessionID ?? UUID().uuidString
    }

    // MARK: - Mobile chat history bridge

    /// Restores a chat thread previously saved by the mobile history store.
    /// Used when the user taps an on-device row in the conversation list.
    /// Body lives in `HermesConversationStateStore` (which cancels the
    /// in-flight stream task via the injected effect).
    func loadMobileThread(id: String) {
        conversation.loadMobileThread(id: id)
    }

    /// Deletes a thread from the mobile history store. Clears the active chat
    /// when the deleted thread was the one currently open.
    func deleteMobileThread(id: String) {
        history.delete(threadID: id)
        if selectedSessionID == id {
            startNewSession()
        }
    }

    func persistCurrentThread() {
        conversation.persistCurrentThread()
    }

    // Model-selection policy bodies live in
    // `HermesModelSelectionEngine` (which operates on service state through
    // `HermesModelSelectionCoordinating`); these pass-throughs keep the API
    // views, tests, and the streaming/transport engines bind to.
    func selectModel(_ option: HermesRuntimeModelOption) {
        HermesModelSelectionEngine.selectModel(option, coordinator: self)
    }

    func clearSelectedModel() {
        HermesModelSelectionEngine.clearSelectedModel(coordinator: self)
    }

    func selectGatewayModelID(_ modelID: String) {
        HermesModelSelectionEngine.selectGatewayModelID(modelID, coordinator: self)
    }

    static func restoredModelID(_ stored: String?, defaults: UserDefaults, key: String) -> String? {
        guard let stored = stored?.nilIfBlank else { return nil }
        let canonical = AssistantModelIDCanonicalizer.canonicalizedPersistedSelection(stored)
        if canonical != stored {
            defaults.set(canonical, forKey: key)
        }
        return canonical
    }

    func persistResolvedSelectedModelID(_ modelID: String) {
        HermesModelSelectionEngine.persistResolvedSelectedModelID(modelID, coordinator: self)
    }

    #if DEBUG
    func selectModelIDForAutomation(_ modelID: String) {
        HermesModelSelectionEngine.selectModelIDForAutomation(modelID, coordinator: self)
    }
    #endif

    func isFavoriteModel(_ option: HermesRuntimeModelOption) -> Bool {
        HermesModelSelectionEngine.isFavoriteModel(option, coordinator: self)
    }

    func toggleFavoriteModel(_ option: HermesRuntimeModelOption) {
        HermesModelSelectionEngine.toggleFavoriteModel(option, coordinator: self)
    }

    var favoriteModelOptions: [HermesRuntimeModelOption] {
        HermesModelSelectionEngine.favoriteModelOptions(coordinator: self)
    }

    func validatedModelIDForMissionDispatch() throws -> String? {
        try HermesModelSelectionEngine.validatedModelIDForMissionDispatch(coordinator: self)
    }

    /// Retry the most recent user turn. Strips any assistant messages
    /// that came after the last user message (the failed/empty replies
    /// we want to redo) and re-sends the original prompt with its
    /// attachments. No-op while a stream is in flight or if there's no
    /// user turn to retry. The composer's pending input is left alone.
    func retryLastUserTurn(context: String? = nil) {
        guard !isStreaming else { return }
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return
        }
        let userMessage = messages[lastUserIndex]
        let trimmed = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !userMessage.attachments.isEmpty else { return }
        // Drop everything after the user turn we're retrying so the
        // history shown to the model and the user matches the
        // pre-failure state.
        if lastUserIndex + 1 < messages.count {
            messages.removeSubrange((lastUserIndex + 1)..<messages.count)
        }
        // Drop the user turn itself; sendMessage will re-append it
        // with a fresh streaming assistant placeholder. Keeps the
        // ordering invariants in `completionRequestBody` simple.
        messages.remove(at: lastUserIndex)
        sendMessage(trimmed, context: context, attachments: userMessage.attachments)
    }

    /// Phase 14 — Sentinel re-send fired when a macOS TCC grant lands
    /// and a failed tool call needs to be retried. Routes through the
    /// normal `sendMessage` path so transport, persistence, and tool
    /// loops behave identically to a user-typed message.
    func retryAfterSystemPermissionGrant(item: SystemPermissionItem) {
        guard !isStreaming else { return }
        let toolName = item.originatingToolName ?? "the previous tool"
        let sentinel = "Permission added on your Mac (\(item.kind.displayTitle)). Retry \(toolName) and finish the previous step."
        sendMessage(sentinel)
    }

    func sendMessage(_ text: String, context: String? = nil, attachments: [HermesAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow attachment-only messages (no text) so users can send a photo
        // and let the model describe / OCR it.
        guard !trimmed.isEmpty || !attachments.isEmpty, !isStreaming else { return }

        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E sendMessage beforePrefer selected=\(selectedConnection.id) mode=\(selectedConnection.mode.rawValue) reachable=\(isReachable) suggested=\(suggestedRelayConnection?.id ?? "none") selectedModel=\(selectedModelID ?? "nil") explicit=\(selectedModelWasExplicit)")
        #endif
        preferSuggestedRelayWhenLocalHostIsOffline()
        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E sendMessage afterPrefer selected=\(selectedConnection.id) mode=\(selectedConnection.mode.rawValue) reachable=\(isReachable) selectedModel=\(selectedModelID ?? "nil") explicit=\(selectedModelWasExplicit)")
        #endif

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
                try await streamingEngine.streamCompletion(coordinator: self, context: context)
            } catch {
                if !Task.isCancelled {
                    streamingEngine.handleStreamError(error, coordinator: self)
                } else {
                    isStreaming = false
                }
            }
            persistCurrentThread()
        }
    }

    // BurnBar Cloud Gateway turn lifecycle — bodies live in
    // `HermesConversationStateStore` (per-thread transcript mutation);
    // these pass-throughs keep the API HermesTabView and the gateway
    // sender bind to.
    func ensureBurnBarGatewayThreadID() -> String {
        conversation.ensureBurnBarGatewayThreadID()
    }

    func beginBurnBarGatewayTurn(displayText: String, wireText: String) -> String {
        conversation.beginBurnBarGatewayTurn(displayText: displayText, wireText: wireText)
    }

    func finishBurnBarGatewayTurn(placeholderID: String, reply: HermesGatewayMessageRecord) {
        conversation.finishBurnBarGatewayTurn(placeholderID: placeholderID, reply: reply)
    }

    func recordBurnBarGatewayReply(
        _ reply: HermesGatewayMessageRecord,
        threadID explicitThreadID: String = HermesGatewayMessageResolver.defaultThreadID,
        modelID: String? = nil,
        modelName: String? = nil
    ) {
        conversation.recordBurnBarGatewayReply(
            reply,
            threadID: explicitThreadID,
            modelID: modelID,
            modelName: modelName
        )
    }

    func failBurnBarGatewayTurn(placeholderID: String?, message: String) {
        conversation.failBurnBarGatewayTurn(placeholderID: placeholderID, message: message)
    }

    /// Visible Mac Terminal (CLI) send. Relay preference and the
    /// cancellable `currentTask` stay here; transcript staging, mission
    /// dispatch, and snapshot application live in
    /// `HermesConversationStateStore`.
    func sendVisibleCLIMessage(_ text: String, context: String? = nil, attachments: [HermesAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isStreaming else { return }

        guard attachments.isEmpty else {
            conversation.rejectVisibleCLIAttachmentTurn(text: trimmed, attachments: attachments)
            return
        }

        preferSuggestedRelayWhenLocalHostIsOffline()
        if selectedSessionID == nil {
            selectedSessionID = UUID().uuidString
        }
        guard let threadID = selectedSessionID else { return }

        currentTask?.cancel()
        currentTask = nil
        let placeholderID = conversation.beginVisibleCLITurn(userText: trimmed)
        let prompt = HermesConversationStateStore.visibleCLIPrompt(userText: trimmed, context: context)
        currentTask = Task { @MainActor [weak self] in
            await self?.conversation.dispatchVisibleCLIMission(
                prompt: prompt,
                threadID: threadID,
                placeholderID: placeholderID
            )
        }
    }

    private func preferSuggestedRelayWhenLocalHostIsOffline() {
        transportSelector.preferSuggestedRelayWhenLocalHostIsOffline(coordinator: self)
    }

    func refreshRelayDiscoveryBeforeLocalSendIfNeeded() async {
        await transportSelector.refreshRelayDiscoveryBeforeLocalSendIfNeeded(coordinator: self)
    }

    /// Replace the staged copy of an in-flight assistant message in
    /// `messages`. Exact behavior of the inline `firstIndex` commits the
    /// streaming code performed before the `HermesStreamingEngine`
    /// extraction: a message that is no longer part of the transcript is
    /// dropped silently.
    private func commitStreamedMessage(_ message: HermesChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }

    private func appendVisibleContent(_ content: String, to message: inout HermesChatMessage) {
        guard !content.isEmpty else { return }
        message.markFirstResponseChunk()
        // LOAD-BEARING: each tool-use iteration appends a NEW assistant
        // message but `lastStreamCommit` is shared service state and never
        // reset — first-bubble immediacy for every message rests entirely on
        // this empty-text check.
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

    /// Pull a `refusal` channel string off an OpenAI-shaped `delta` /
    /// `message` object. Some servers nest the refusal under `content`
    /// or as a structured object, so we run it through the same
    /// permissive value walker as visible content.
    private func refusalContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["refusal"])
    }

    /// Pull a reasoning-channel string off the same envelopes. Vendors
    /// disagree on the field name — DeepSeek and several OpenAI-compat
    /// gateways use `reasoning_content`, OpenAI Responses uses
    /// `reasoning`, and Anthropic-compat shims occasionally pass it
    /// through as `thinking`. We probe all three.
    private func reasoningContent(from item: [String: Any]?) -> String? {
        guard let item else { return nil }
        return visibleContentValue(item["reasoning_content"])
            ?? visibleContentValue(item["reasoningContent"])
            ?? visibleContentValue(item["reasoning"])
            ?? visibleContentValue(item["thinking"])
    }

    private func appendStreamedRefusal(_ chunk: String, to message: inout HermesChatMessage) {
        guard !chunk.isEmpty else { return }
        if message.streamedRefusal.isEmpty || chunk.hasPrefix(message.streamedRefusal) {
            message.streamedRefusal = chunk
        } else if chunk != message.streamedRefusal {
            message.streamedRefusal += chunk
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
    }

    private func appendStreamedReasoning(_ chunk: String, to message: inout HermesChatMessage) {
        guard !chunk.isEmpty else { return }
        if message.streamedReasoning.isEmpty || chunk.hasPrefix(message.streamedReasoning) {
            message.streamedReasoning = chunk
        } else if chunk != message.streamedReasoning {
            message.streamedReasoning += chunk
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
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

    var activeModelName: String? {
        HermesModelSelectionEngine.activeModelName(coordinator: self)
    }

    var activeRequestedModelID: String? {
        HermesModelSelectionEngine.activeRequestedModelID(coordinator: self)
    }

    func activeModelIDForRequest() throws -> String {
        try HermesModelSelectionEngine.activeModelIDForRequest(coordinator: self)
    }

    func checkReachability(generation: Int? = nil) async {
        await transportSelector.checkReachability(generation: generation, coordinator: self)
    }

    func loadModels(generation: Int) async {
        await transportSelector.loadModels(generation: generation, coordinator: self)
    }

    func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: endpoint(path), timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = try secretStore.load(connectionID: selectedConnection.id), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func relayPayload(
        operation: HermesRelayOperation,
        method: String,
        path: String? = nil,
        sessionID: String? = nil,
        body: Data? = nil,
        connection: HermesConnectionRecord? = nil
    ) -> HermesRelayPayload {
        let relay = connection ?? selectedConnection
        return HermesRelayPayload(
            connectionID: relay.id,
            relayPublicKey: relay.relayPublicKey,
            relayKeyVersion: relay.relayKeyVersion,
            relayEncryption: relay.relayEncryption,
            realtimeRelayURL: relay.realtimeRelayURL,
            operation: operation,
            method: method,
            path: path,
            sessionID: sessionID,
            body: body
        )
    }

    func macRelayPayloadForCLIAgentChat(
        body: Data,
        sessionID: String
    ) async throws -> HermesRelayPayload {
        try await transportSelector.macRelayPayloadForCLIAgentChat(
            body: body,
            sessionID: sessionID,
            coordinator: self
        )
    }

    func macRelayPayloadForCLIAgentSessionAction(
        body: Data,
        sessionID: String
    ) async throws -> HermesRelayPayload {
        try await transportSelector.macRelayPayloadForCLIAgentSessionAction(
            body: body,
            sessionID: sessionID,
            coordinator: self
        )
    }

    func fetchCLIRuntimeModelCatalog(runtime: AssistantRuntimeID) async throws -> CLIRuntimeModelCatalogResponse {
        let request = CLIRuntimeModelCatalogRequest(runtime: runtime.rawValue)
        let body = try JSONEncoder().encode(request)
        let payload = try await transportSelector.macRelayPayloadForCLIRuntimeModelCatalog(
            body: body,
            sessionID: "cli-model-catalog-\(runtime.rawValue)",
            coordinator: self
        )
        let data = try await relayTransport.sendUnary(payload, timeout: 20)
        return try JSONDecoder().decode(CLIRuntimeModelCatalogResponse.self, from: data)
    }

    private func endpoint(_ path: String) -> URL {
        let path = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(path)
    }

    /// Extracts a one-line human-readable summary from a (possibly partial)
    /// JSON tool-arguments string. Implementation moved to
    /// `HermesStreamingEngine.summarizeToolArguments`; this forwarder keeps
    /// the stable `HermesService.summarizeToolArguments` name callers and
    /// tests rely on.
    static func summarizeToolArguments(_ raw: String) -> String? {
        HermesStreamingEngine.summarizeToolArguments(raw)
    }

    // Endpoint validation + relay eligibility predicates moved verbatim to
    // `HermesTransportSelector`; these forwarders keep the names views,
    // tests, and the call sites in this file rely on.
    static func validatedEndpointURL(_ rawValue: String) -> URL? {
        HermesTransportSelector.validatedEndpointURL(rawValue)
    }

    static func isRelayConnectionFresh(_ connection: HermesConnectionRecord, now: Date = Date()) -> Bool {
        HermesTransportSelector.isRelayConnectionFresh(connection, now: now)
    }

    static func decodeStringArray(_ text: String?) -> [String] {
        guard let text,
              let data = text.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }
}

enum HermesServiceError: LocalizedError {
    case invalidResponse
    case httpStatus(code: Int)
    case decodingFailed
    case invalidURL
    case keychain(OSStatus)
    case selectedModelUnavailable(String)
    case selectedModelCatalogUnavailable(String)
    case noRouteEligibleModel
    case upstreamModelError(String)
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
        case .selectedModelUnavailable(let modelID):
            return "Selected Hermes model '\(modelID)' is not available on this Mac relay. Pick another model or refresh/restart the Mac Hermes gateway."
        case .selectedModelCatalogUnavailable(let modelID):
            return "Selected Hermes model '\(modelID)' has not been verified against this Mac relay's model catalog yet. Refresh the Mac Hermes gateway before sending, so the selected model is not silently rerouted."
        case .noRouteEligibleModel:
            return "No route-eligible Hermes model is currently advertised by this Mac relay. Add or enable a provider account with available quota, then refresh the Mac Hermes gateway."
        case .upstreamModelError(let message):
            return message
        case .relayUnavailable(let message):
            return message
        case .relayTimeout:
            return "Remote Hermes relay timed out before the selected Mac harness completed. No fallback was attempted, so the selected model is not silently rerouted."
        }
    }

    var stopsRelayFallback: Bool {
        switch self {
        case .selectedModelUnavailable,
             .selectedModelCatalogUnavailable,
             .noRouteEligibleModel,
             .upstreamModelError,
             .relayTimeout:
            return true
        case .invalidResponse,
             .httpStatus,
             .decodingFailed,
             .invalidURL,
             .keychain,
             .relayUnavailable:
            return false
        }
    }

    static func relayFailure(_ message: String?, fallback: String) -> HermesServiceError {
        let raw = message?.nilIfBlank ?? fallback
        if let upstream = upstreamModelErrorMessage(from: raw) {
            return .upstreamModelError(upstream)
        }
        return .relayUnavailable(raw)
    }

    static func shouldStopRelayFallback(_ error: Error) -> Bool {
        (error as? HermesServiceError)?.stopsRelayFallback ?? false
    }

    static func upstreamModelErrorMessage(from raw: String?) -> String? {
        guard let message = raw?.nilIfBlank else { return nil }
        let lower = message.lowercased()
        if lower.hasPrefix("hermes upstream model") {
            return message
        }

        let modelOrQuotaSignal = lower.contains("model")
            || lower.contains("quota")
            || lower.contains("limit")
            || lower.contains("route")
            || lower.contains("account")
            || lower.contains("provider")
            || lower.contains("auth")
        guard modelOrQuotaSignal else { return nil }

        let upstreamSignals = [
            "weekly/monthly limit exhausted",
            "limit exhausted",
            "quota",
            "insufficient_quota",
            "rate limit",
            "model_not_found",
            "model not found",
            "does not exist",
            "unsupported model",
            "no eligible openai-compatible route",
            "no eligible route",
            "add or enable an openai-family account",
            "api call failed after"
        ]
        guard upstreamSignals.contains(where: { lower.contains($0) }) else {
            return nil
        }
        return "Hermes upstream model failed: \(message)"
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

            if result.isError, let threadID = selectedSessionID {
                SystemPermissionTextClassifier.shared.observe(
                    toolName: result.toolName,
                    toolResultDetail: result.content,
                    toolCallId: result.toolCallID,
                    threadID: threadID
                )
            }
        }

        return results
    }
}

// The streaming engine reaches service-owned conversation/runtime state
// through this conformance; every requirement is satisfied by existing
// members, so the coordinator surface stays exactly what views and tests
// already bind to.
extension HermesService: HermesStreamingCoordinating {}

// The transport selector reaches service-owned connection/runtime state
// through this conformance; every requirement is satisfied by existing
// members.
extension HermesService: HermesTransportCoordinating {}

// The model-selection engine reaches the persisted selection, catalog,
// and favorites through this conformance.
extension HermesService: HermesModelSelectionCoordinating {}
