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
}

struct PiChatMessage: Identifiable, Equatable {
    let id: String
    let role: PiChatRole
    var text: String
    var modelName: String?
    let timestamp: Date
    var isStreaming: Bool
    var isError: Bool

    init(
        id: String = UUID().uuidString,
        role: PiChatRole,
        text: String,
        modelName: String? = nil,
        timestamp: Date = Date(),
        isStreaming: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.modelName = modelName
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isError = isError
    }
}

// MARK: - Pi Service

@MainActor
@Observable
final class PiService {
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

    private let urlSession: URLSession
    private let defaults: UserDefaults
    private var currentTask: Task<Void, Never>?

    private let selectedConnectionDefaultsKey = "pi.selectedConnectionID"
    private let selectedModelDefaultsKey = "pi.selectedModelID"
    private let favoriteModelsDefaultsKey = "pi.favoriteModelIDs"
    private let savedConnectionsDefaultsKey = "pi.savedConnections"

    init(
        urlSession: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.urlSession = urlSession
        self.defaults = defaults
        self.selectedModelID = defaults.string(forKey: selectedModelDefaultsKey)
        self.favoriteModelIDs = Self.decodeStringArray(defaults.string(forKey: favoriteModelsDefaultsKey))
        // Restore previously-added direct URLs.
        if let saved = Self.decodeRecords(defaults.data(forKey: savedConnectionsDefaultsKey)) {
            connections = [PiConnectionRecord.localDefault] + saved
        }
        if let savedSelectedID = defaults.string(forKey: selectedConnectionDefaultsKey),
           let match = connections.first(where: { $0.id == savedSelectedID }) {
            selectedConnection = match
        }
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
        selectedModelID = option.modelID
        defaults.set(option.modelID, forKey: selectedModelDefaultsKey)
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

    func send(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(PiChatMessage(role: .user, text: trimmed))
        var assistant = PiChatMessage(role: .assistant, text: "", modelName: selectedModelID, isStreaming: true)
        messages.append(assistant)
        let assistantID = assistant.id
        isStreaming = true

        let baseURL = resolvedBaseURL
        let bearer = resolvedBearerToken
        let model = selectedModelID

        currentTask?.cancel()
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isStreaming = false
                if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    self.messages[idx].isStreaming = false
                }
            }
            do {
                try await self.streamChat(
                    baseURL: baseURL,
                    bearerToken: bearer,
                    model: model,
                    prompt: trimmed
                ) { delta in
                    if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                        var msg = self.messages[idx]
                        msg.text += delta
                        self.messages[idx] = msg
                    }
                }
            } catch {
                if let idx = self.messages.firstIndex(where: { $0.id == assistantID }) {
                    var msg = self.messages[idx]
                    msg.isError = true
                    msg.text = "Pi error: \(error.localizedDescription)"
                    self.messages[idx] = msg
                }
                self.lastError = error.localizedDescription
            }
            _ = assistant
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    func clear() {
        messages.removeAll()
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
            if selectedModelID == nil {
                selectedModelID = decoded.first?.modelID
            }
        } catch {
            runtimeErrorText = "Failed to list Pi models: \(error.localizedDescription)"
        }
    }

    private func streamChat(
        baseURL: URL,
        bearerToken: String?,
        model: String?,
        prompt: String,
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard let endpoint = URL(string: "v1/chat/completions", relativeTo: baseURL) else {
            throw NSError(domain: "PiService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": model ?? "pi",
            "stream": true,
            "messages": messages.compactMap { msg -> [String: Any]? in
                guard !msg.isError else { return nil }
                return ["role": msg.role.rawValue, "content": msg.text]
            } + [["role": "user", "content": prompt]]
        ]
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
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty else { continue }
            await MainActor.run { onDelta(content) }
        }
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
            let provider = (entry["owned_by"] as? String) ?? "pi"
            return HermesRuntimeModelOption(
                providerID: provider,
                providerName: provider.capitalized,
                modelID: id,
                displayName: id
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
}
