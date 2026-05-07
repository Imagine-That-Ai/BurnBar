import Foundation
import FirebaseAuth
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Hermes Chat Message

struct HermesChatMessage: Identifiable, Equatable {
    let id: String
    let role: HermesChatRole
    var text: String
    var toolCalls: [HermesToolCall]
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool

    init(
        id: String = UUID().uuidString,
        role: HermesChatRole,
        text: String,
        toolCalls: [HermesToolCall] = [],
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
    }
}

struct HermesToolCall: Identifiable, Equatable {
    let id: String
    var name: String
    var status: String
}

enum HermesChatRole: String, Equatable, Sendable {
    case user
    case assistant
    case system
}

struct HermesRelayPayload: Sendable {
    var connectionID: String
    var relayPublicKey: String?
    var relayKeyVersion: Int?
    var relayEncryption: String?
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
    private var runtimeGeneration = 0
    private var runtimeRefreshTask: Task<Void, Never>?
    private let selectedConnectionDefaultsKey = "hermes.selectedConnectionID"
    private let selectedModelDefaultsKey = "hermes.selectedModelID"
    private let favoriteModelsDefaultsKey = "hermes.favoriteModelIDs"

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
        relayTransport: HermesRelayTransporting = FirestoreHermesRelayTransport.shared,
        defaults: UserDefaults = .standard
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.functionsRepository = functionsRepository
        self.connectionRepository = connectionRepository
        self.secretStore = secretStore
        self.relayTransport = relayTransport
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: selectedModelDefaultsKey)
        self.favoriteModelIDs = Self.decodeStringArray(defaults.string(forKey: favoriteModelsDefaultsKey))
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

    func sendMessage(_ text: String, context: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        preferSuggestedRelayWhenLocalHostIsOffline()

        let userMessage = HermesChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        isStreaming = true
        lastError = nil

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

    private func streamCompletion(context: String?) async throws {
        if selectedConnection.mode == .relayLink {
            try await streamRelayCompletion(context: context)
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

        var assistantMessage = HermesChatMessage(role: .assistant, text: "", isStreaming: true)
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
            HermesToolCall(id: $0.id, name: $0.name, status: "done")
        }
        if assistantMessage.text.isEmpty && assistantMessage.toolCalls.isEmpty {
            assistantMessage.text = "Hermes finished without returning text. Try again or switch models."
            assistantMessage.isError = true
        }
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
        }
        isStreaming = false
    }

    private func completionRequestBody(context: String?) throws -> Data {
        let model = selectedModelID ?? selectedConnection.advertisedModel ?? "hermes"
        var requestMessages = messages.compactMap { message -> [String: String]? in
            let content = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isError, !content.isEmpty else { return nil }
            return ["role": message.role.rawValue, "content": message.text]
        }
        if let context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestMessages.insert(["role": HermesChatRole.system.rawValue, "content": context], at: 0)
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": requestMessages,
            "stream": true
        ]
        if let selectedSessionID {
            payload["session_id"] = selectedSessionID
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func streamRelayCompletion(context: String?) async throws {
        let body = try completionRequestBody(context: context)
        isReachable = true

        var assistantMessage = HermesChatMessage(role: .assistant, text: "", isStreaming: true)
        messages.append(assistantMessage)

        try await relayTransport.sendStreaming(
            relayPayload(operation: .chatCompletions, method: "POST", path: "/v1/chat/completions", body: body),
            timeout: 120
        ) { event in
            self.processSSEPayload(event, into: &assistantMessage)
        }

        assistantMessage.isStreaming = false
        assistantMessage.toolCalls = assistantMessage.toolCalls.map {
            HermesToolCall(id: $0.id, name: $0.name, status: "done")
        }
        if assistantMessage.text.isEmpty && assistantMessage.toolCalls.isEmpty {
            assistantMessage.text = "Hermes finished without returning text. Try again or switch models."
            assistantMessage.isError = true
        }
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
        }
        isStreaming = false
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

        if let usage = json["usage"] as? [String: Any] {
            recordUsage(usage)
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
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else { return }

        if let content = delta["content"] as? String {
            message.text += content
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            }
        }
        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
            mergeToolCalls(toolCalls, into: &message)
        }
    }

    private func recordUsage(_ usage: [String: Any]) {
        let total = intValue(usage["total_tokens"])
            ?? intValue(usage["totalTokens"])
            ?? ((intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"]) ?? 0)
                + (intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"]) ?? 0))
        guard total > 0 else { return }
        currentConversationTokenBurn += total
    }

    private func handleStreamError(_ error: Error) {
        isStreaming = false
        isReachable = false

        let displayText: String
        if let hermesError = error as? HermesServiceError {
            displayText = hermesError.localizedDescription
        } else if let firestoreError = error as? FirestoreError {
            switch firestoreError {
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
            modelOptions = decoded.data.map {
                let providerID = $0.ownedBy ?? $0.providerID ?? "hermes"
                let providerName = $0.providerName
                    ?? AgentProvider.fromProviderID(ProviderID(rawValue: providerID))?.displayName
                    ?? providerID
                return HermesRuntimeModelOption(
                    providerID: providerID,
                    providerName: providerName,
                    modelID: $0.id,
                    displayName: $0.displayName ?? $0.name
                )
            }
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

    private func mergeToolCalls(_ rawToolCalls: [[String: Any]], into message: inout HermesChatMessage) {
        for raw in rawToolCalls {
            let id = stringValue(raw["id"]) ?? "tool-\(message.toolCalls.count + 1)"
            let function = raw["function"] as? [String: Any]
            let name = stringValue(function?["name"]) ?? stringValue(raw["name"]) ?? "Hermes tool"
            if let index = message.toolCalls.firstIndex(where: { $0.id == id }) {
                message.toolCalls[index].name = name
                message.toolCalls[index].status = "running"
            } else {
                message.toolCalls.append(HermesToolCall(id: id, name: name, status: "running"))
            }
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        }
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
                model: stringValue(item["model"]),
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
            return HermesChatMessage(
                id: stringValue(item["id"]) ?? UUID().uuidString,
                role: role,
                text: content,
                timestamp: dateValue(item["timestamp"]) ?? dateValue(item["created_at"]) ?? Date(),
                isStreaming: false,
                isError: false
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
        if let value = value as? String, !value.isEmpty { return value }
        return nil
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
final class FirestoreHermesRelayTransport: HermesRelayTransporting {
    static let shared = FirestoreHermesRelayTransport()

    private let db: Firestore
    private let pollIntervalNanoseconds: UInt64

    private struct RelayRequestHandle {
        let requestID: String
        let connectionID: String
        let keyData: Data
    }

    init(db: Firestore = Firestore.firestore(), pollIntervalNanoseconds: UInt64 = 250_000_000) {
        self.db = db
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
