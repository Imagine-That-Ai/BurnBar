import Foundation
import OpenBurnBarCore

/// Relay/transport routing decisions for the Hermes chat surface: which
/// `HermesConnectionRecord`s are usable Mac relay candidates, which relay
/// to suggest, which relay a send should prefer, and which endpoint URLs
/// the direct-HTTP transport accepts.
///
/// All decision bodies were moved verbatim from `HermesService`; the
/// service keeps thin forwarders so its existing API surface
/// (`service.relayConnections`, `service.suggestedRelayConnection`,
/// `HermesService.validatedEndpointURL`, `HermesService.isRelayConnectionFresh`)
/// stays unchanged for views and tests. The selector never mutates service
/// state — `HermesService` remains the coordinator that *acts* on these
/// decisions (`selectConnection`, discovery refreshes, user-facing error
/// copy).
///
/// The live connection catalog is threaded via `connectionsProvider` at
/// init so the selector always evaluates against the shared runtime store
/// the service proxies expose. Reads stay synchronous on the main actor,
/// so @Observable tracking flows through to SwiftUI exactly as it did when
/// these bodies were inline on the service.
/// Coordinator surface the connection/route management needs from
/// `HermesService`. The selector owns the management bodies (connection
/// catalog refresh, selection, pairing, reachability, runtime catalog
/// loads, CLI relay payload resolution) while every piece of runtime
/// state they touch stays owned by the service and is reached through
/// this protocol.
@MainActor
protocol HermesTransportCoordinating: AnyObject {
    var connections: [HermesConnectionRecord] { get set }
    var selectedConnection: HermesConnectionRecord { get set }
    var selectedSessionID: String? { get set }
    var selectedModelID: String? { get set }
    var selectedModelWasExplicit: Bool { get set }
    var sessions: [HermesSessionSummary] { get set }
    var profiles: [HermesRuntimeProfile] { get set }
    var modelOptions: [HermesRuntimeModelOption] { get set }
    var jobs: [HermesRuntimeJob] { get set }
    var favoriteModelOptions: [HermesRuntimeModelOption] { get }
    var isReachable: Bool { get set }
    var isRemoteRelayEnabled: Bool { get }
    var lastError: String? { get set }
    var runtimeErrorText: String? { get set }
    var runtimeGeneration: Int { get set }
    var baseURL: URL { get set }
    var defaults: UserDefaults { get }
    var urlSession: URLSession { get }
    var relayTransport: HermesRelayTransporting { get }
    var connectionRepository: HermesConnectionListing { get }
    var functionsRepository: FunctionsRepository { get }
    var secretStore: HermesConnectionSecretStoring { get }
    var remoteRelayControlPlaneTimeout: TimeInterval { get }
    func makeRequest(path: String, timeout: TimeInterval) throws -> URLRequest
    func relayPayload(
        operation: HermesRelayOperation,
        method: String,
        path: String?,
        sessionID: String?,
        body: Data?,
        connection: HermesConnectionRecord?
    ) -> HermesRelayPayload
    func createPairingCode(displayName: String?) async throws -> HermesPairingSessionRecord
    func persistResolvedSelectedModelID(_ modelID: String)
    func refreshRuntime() async
}

@MainActor
final class HermesTransportSelector {
    private let connectionsProvider: () -> [HermesConnectionRecord]

    init(connectionsProvider: @escaping () -> [HermesConnectionRecord]) {
        self.connectionsProvider = connectionsProvider
    }

    // MARK: - Relay candidate selection

    var relayConnections: [HermesConnectionRecord] {
        connectionsProvider().filter { connection in
            connection.mode == .relayLink
                && connection.status == .online
                && Self.canAttemptRelayConnection(connection)
        }
    }

    var suggestedRelayConnection: HermesConnectionRecord? {
        relayConnections.max { lhs, rhs in
            let lhsFresh = Self.isRelayConnectionFresh(lhs)
            let rhsFresh = Self.isRelayConnectionFresh(rhs)
            if lhsFresh != rhsFresh {
                return !lhsFresh && rhsFresh
            }
            let lhsLastSeen = lhs.lastSeenAt ?? lhs.updatedAt
            let rhsLastSeen = rhs.lastSeenAt ?? rhs.updatedAt
            return lhsLastSeen < rhsLastSeen
        }
    }

    /// Pure decision core of `HermesService.preferredRelayConnection` —
    /// the optional discovery refresh that precedes it stays on the
    /// service.
    func preferredRelayConnection(selected: HermesConnectionRecord) -> HermesConnectionRecord? {
        if selected.mode == .relayLink,
           let selectedRelay = relayConnections.first(where: { $0.id == selected.id }) {
            return selectedRelay
        }
        if selected.mode == .relayLink,
           Self.canAttemptRelayConnection(selected) {
            return selected
        }

        return suggestedRelayConnection ?? relayConnections.first
    }

    // MARK: - Record-level eligibility predicates

    static func canAttemptRelayConnection(_ connection: HermesConnectionRecord) -> Bool {
        connection.mode == .relayLink
            && connection.status == .online
            && hasUsableRelayEncryption(connection)
            && isRelayConnectionFresh(connection)
    }

    static func hasUsableRelayEncryption(_ connection: HermesConnectionRecord) -> Bool {
        connection.relayEncryption == HermesRelayCrypto.relayEncryptionV3
            && connection.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3
            && (connection.relayPublicKey?.isEmpty == false)
    }

    // macOS publishes this heartbeat every 30 s while active and every 5 min
    // in the background. Give background cadence, App Nap, and Firestore cache
    // propagation enough slack without accepting truly abandoned relay docs.
    nonisolated static let relayFreshnessWindow: TimeInterval = 30 * 60

    static func isRelayConnectionFresh(_ connection: HermesConnectionRecord, now: Date = Date()) -> Bool {
        guard connection.mode == .relayLink else { return true }
        let heartbeat = connection.realtimeRelayLastSeenAt
            ?? connection.lastSeenAt
            ?? connection.updatedAt
        return now.timeIntervalSince(heartbeat) <= relayFreshnessWindow
    }

    static func advertisesCLIModelCatalog(_ connection: HermesConnectionRecord) -> Bool {
        connection.capabilities.contains("cli_agent_model_catalog")
            || connection.capabilities.contains(HermesRelayOperation.cliAgentModelCatalog.rawValue)
    }

    // MARK: - Direct-HTTP endpoint validation

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

    // MARK: - Connection / route management (moved verbatim from HermesService)
    //
    // Catalog refresh, selection + persistence, pairing, revocation,
    // relay preference, reachability, the 6-op runtime catalog loads,
    // and CLI relay payload resolution. All service state is reached via
    // `HermesTransportCoordinating`.

    func refreshConnections(generation: Int? = nil, refreshSelectedConnection: Bool = true, coordinator: HermesTransportCoordinating) async {
        do {
            let listedConnections = try await coordinator.connectionRepository.listHermesConnections()
            let replacementIDs = Self.replacementConnectionIDs(in: listedConnections)
            let remoteConnections = Self.coalescedConnectionRecords(listedConnections)
            guard generation == nil || generation == coordinator.runtimeGeneration else { return }
            coordinator.connections = [HermesConnectionRecord.localDefault] + remoteConnections
            #if DEBUG
            print("OpenBurnBarMobile Hermes E2E connections loaded total=\(coordinator.connections.count) relayUsable=\(relayConnections.count) selected=\(coordinator.selectedConnection.id) selectedMode=\(coordinator.selectedConnection.mode.rawValue)")
            #endif
            let persistedID = coordinator.defaults.string(forKey: HermesRuntimeStore.selectedConnectionDefaultsKey)
            let rawTargetID = coordinator.selectedConnection.id == HermesConnectionRecord.localDefault.id ? persistedID : coordinator.selectedConnection.id
            let targetID = rawTargetID.flatMap { replacementIDs[$0] ?? $0 }
            if let targetID,
               let current = coordinator.connections.first(where: { $0.id == targetID }),
               current.mode == .relayLink {
                if Self.canAttemptRelayConnection(current), current.id == coordinator.selectedConnection.id {
                    coordinator.selectedConnection = current
                } else if Self.canAttemptRelayConnection(current) {
                    _ = selectConnection(current, refresh: refreshSelectedConnection, coordinator: coordinator)
                } else if Self.hasUsableRelayEncryption(current) {
                    coordinator.selectedConnection = .localDefault
                    coordinator.defaults.removeObject(forKey: HermesRuntimeStore.selectedConnectionDefaultsKey)
                    coordinator.runtimeErrorText = "That Mac relay stopped checking in. Open or restart OpenBurnBar on the Mac, then refresh."
                } else {
                    coordinator.selectedConnection = .localDefault
                    coordinator.defaults.removeObject(forKey: HermesRuntimeStore.selectedConnectionDefaultsKey)
                    coordinator.runtimeErrorText = "Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic."
                }
            } else if let targetID,
                      let current = coordinator.connections.first(where: { $0.id == targetID }),
                      let endpoint = Self.validatedEndpointURL(current.endpointURL ?? "") {
                if current.id == coordinator.selectedConnection.id {
                    coordinator.selectedConnection = current
                    coordinator.baseURL = endpoint
                } else {
                    _ = selectConnection(current, refresh: refreshSelectedConnection, coordinator: coordinator)
                }
            } else if let current = coordinator.connections.first(where: { $0.id == coordinator.selectedConnection.id }) {
                coordinator.selectedConnection = current
            }
        } catch {
            guard generation == nil || generation == coordinator.runtimeGeneration else { return }
            if coordinator.connections.isEmpty {
                coordinator.connections = [HermesConnectionRecord.localDefault]
            }
            coordinator.runtimeErrorText = "Could not load Hermes connections: \(error.localizedDescription)"
        }
    }

    private static func replacementConnectionIDs(in records: [HermesConnectionRecord]) -> [String: String] {
        let recordIDs = Set(records.map(\.id))
        return records.reduce(into: [String: String]()) { result, record in
            guard let replacementID = record.replacedByConnectionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !replacementID.isEmpty,
                  recordIDs.contains(replacementID)
            else { return }
            result[record.id] = replacementID
        }
    }

    private static func coalescedConnectionRecords(_ records: [HermesConnectionRecord]) -> [HermesConnectionRecord] {
        let replacements = replacementConnectionIDs(in: records)
        guard !replacements.isEmpty else { return records }
        return records.filter { replacements[$0.id] == nil }
    }

    @discardableResult
    func selectConnection(_ connection: HermesConnectionRecord, refresh: Bool = true, coordinator: HermesTransportCoordinating) -> Bool {
        let endpoint: URL?
        if connection.mode == .relayLink {
            guard Self.hasUsableRelayEncryption(connection) else {
                coordinator.lastError = "Update OpenBurnBar on your Mac and re-enable Remote Relay so this iPhone/iPad can use encrypted relay traffic."
                coordinator.runtimeErrorText = coordinator.lastError
                return false
            }
            guard connection.status == .online else {
                coordinator.lastError = "That Mac relay stopped checking in. Open or restart OpenBurnBar on the Mac, then refresh."
                coordinator.runtimeErrorText = coordinator.lastError
                return false
            }
            guard Self.isRelayConnectionFresh(connection) else {
                coordinator.lastError = "That Mac relay stopped checking in. Open or restart OpenBurnBar on the Mac, then refresh."
                coordinator.runtimeErrorText = coordinator.lastError
                return false
            }
            endpoint = nil
        } else if let validated = Self.validatedEndpointURL(connection.endpointURL ?? "") {
            endpoint = validated
        } else {
            coordinator.lastError = "This Hermes connection has an invalid or unsupported URL."
            coordinator.runtimeErrorText = coordinator.lastError
            return false
        }
        coordinator.runtimeGeneration += 1
        coordinator.selectedConnection = connection
        coordinator.selectedSessionID = nil
        coordinator.selectedModelID = HermesService.restoredModelID(
            coordinator.defaults.string(forKey: HermesRuntimeStore.selectedModelDefaultsKey),
            defaults: coordinator.defaults,
            key: HermesRuntimeStore.selectedModelDefaultsKey
        )
        coordinator.selectedModelWasExplicit = coordinator.selectedModelID?.nilIfBlank != nil
        coordinator.sessions = []
        coordinator.profiles = []
        coordinator.modelOptions = []
        coordinator.jobs = []
        coordinator.isReachable = false
        if let endpoint {
            coordinator.baseURL = endpoint
        }
        coordinator.runtimeErrorText = nil
        coordinator.lastError = nil
        coordinator.defaults.set(connection.id, forKey: HermesRuntimeStore.selectedConnectionDefaultsKey)
        if refresh {
            Task { @MainActor in
                await coordinator.refreshRuntime()
            }
        }
        return true
    }

    @discardableResult
    func connectToSuggestedRelay(refresh: Bool = true, coordinator: HermesTransportCoordinating) -> Bool {
        guard let relay = suggestedRelayConnection else {
            coordinator.lastError = "No signed-in Mac Hermes relay is available yet. On your Mac, keep OpenBurnBar open, sign in, and enable Hermes Remote Relay."
            coordinator.runtimeErrorText = coordinator.lastError
            return false
        }
        return selectConnection(relay, refresh: refresh, coordinator: coordinator)
    }

    @discardableResult
    func setRemoteRelayEnabled(_ enabled: Bool, refresh: Bool = true, coordinator: HermesTransportCoordinating) -> Bool {
        if enabled {
            if coordinator.isRemoteRelayEnabled, Self.canAttemptRelayConnection(coordinator.selectedConnection) {
                return true
            }
            return connectToSuggestedRelay(refresh: refresh, coordinator: coordinator)
        }

        guard coordinator.isRemoteRelayEnabled else {
            return true
        }
        return selectConnection(.localDefault, refresh: refresh, coordinator: coordinator)
    }

    func addDirectConnection(
        displayName: String,
        endpointURL: String,
        bearerToken: String? = nil,
        coordinator: HermesTransportCoordinating
    ) async throws {
        guard let endpoint = Self.validatedEndpointURL(endpointURL) else {
            throw HermesServiceError.invalidURL
        }
        let connectionId = "ios-\(UUID().uuidString.lowercased())"
        let model = coordinator.modelOptions.first?.modelID
        do {
            let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try await validateDirectEndpoint(endpoint, bearerToken: token, coordinator: coordinator)
            let pairing = try await coordinator.createPairingCode(displayName: displayName)
            if !token.isEmpty {
                try coordinator.secretStore.save(token, connectionID: connectionId)
            }
            let connection = try await coordinator.functionsRepository.completeHermesPairing(
            pairingId: pairing.id,
            code: pairing.code,
            connectionId: connectionId,
            displayName: displayName,
            endpointURL: endpoint.absoluteString,
            advertisedModel: model
            )
            coordinator.connections = [HermesConnectionRecord.localDefault] + coordinator.connections
                .filter { $0.id != HermesConnectionRecord.localDefault.id && $0.id != connection.id }
            coordinator.connections.append(connection)
            selectConnection(connection, coordinator: coordinator)
        } catch {
            try? coordinator.secretStore.delete(connectionID: connectionId)
            throw error
        }
    }

    private func validateDirectEndpoint(_ endpoint: URL, bearerToken: String, coordinator: HermesTransportCoordinating) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/models"), timeoutInterval: 8)
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await coordinator.urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesServiceError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesServiceError.httpStatus(code: statusCode)
        }
    }

    func revokeConnection(_ connection: HermesConnectionRecord, coordinator: HermesTransportCoordinating) async throws {
        guard connection.id != HermesConnectionRecord.localDefault.id else { return }
        try await coordinator.functionsRepository.revokeHermesConnection(connectionId: connection.id)
        try? coordinator.secretStore.delete(connectionID: connection.id)
        if coordinator.selectedConnection.id == connection.id {
            _ = selectConnection(.localDefault, coordinator: coordinator)
        }
        await refreshConnections(coordinator: coordinator)
    }

    func preferSuggestedRelayWhenLocalHostIsOffline(coordinator: HermesTransportCoordinating) {
        guard coordinator.selectedConnection.id == HermesConnectionRecord.localDefault.id else {
            #if DEBUG
            print("OpenBurnBarMobile Hermes E2E relayPrefer skip selectedIsNotLocal selected=\(coordinator.selectedConnection.id)")
            #endif
            return
        }
        guard !coordinator.isReachable else {
            #if DEBUG
            print("OpenBurnBarMobile Hermes E2E relayPrefer skip localMarkedReachable")
            #endif
            return
        }
        guard let relay = suggestedRelayConnection else {
            #if DEBUG
            print("OpenBurnBarMobile Hermes E2E relayPrefer skip noSuggestedRelay connectionCount=\(coordinator.connections.count)")
            #endif
            return
        }
        #if DEBUG
        print("OpenBurnBarMobile Hermes E2E relayPrefer selecting relay=\(relay.id) advertisedModel=\(relay.advertisedModel ?? "nil")")
        #endif
        _ = selectConnection(relay, refresh: false, coordinator: coordinator)
    }

    func refreshRelayDiscoveryBeforeLocalSendIfNeeded(coordinator: HermesTransportCoordinating) async {
        guard coordinator.selectedConnection.id == HermesConnectionRecord.localDefault.id else { return }
        guard !coordinator.isReachable else { return }

        if suggestedRelayConnection == nil {
            await refreshConnections(refreshSelectedConnection: false, coordinator: coordinator)
        }

        preferSuggestedRelayWhenLocalHostIsOffline(coordinator: coordinator)
    }

    func checkReachability(generation: Int? = nil, coordinator: HermesTransportCoordinating) async {
        do {
            guard generation == nil || generation == coordinator.runtimeGeneration else { return }
            if coordinator.selectedConnection.mode == .relayLink {
                guard Self.canAttemptRelayConnection(coordinator.selectedConnection) else {
                    coordinator.isReachable = false
                    coordinator.runtimeErrorText = "That Mac relay stopped checking in. Open or restart OpenBurnBar on the Mac, then refresh."
                    return
                }
                _ = try await coordinator.relayTransport.sendUnary(
                    coordinator.relayPayload(operation: .models, method: "GET", path: "/v1/models", sessionID: nil, body: nil, connection: nil),
                    timeout: coordinator.remoteRelayControlPlaneTimeout
                )
                guard generation == nil || generation == coordinator.runtimeGeneration else { return }
                coordinator.isReachable = true
            } else {
                let request = try coordinator.makeRequest(path: "/v1/models", timeout: 5)
                let (_, response) = try await coordinator.urlSession.data(for: request)
                guard generation == nil || generation == coordinator.runtimeGeneration else { return }
                if let statusCode = (response as? HTTPURLResponse)?.statusCode {
                    coordinator.isReachable = (200..<300).contains(statusCode)
                    if statusCode == 401 || statusCode == 403 {
                        coordinator.runtimeErrorText = "Hermes rejected this connection. Check the API_SERVER_KEY saved for this host."
                    }
                } else {
                    coordinator.isReachable = false
                }
            }
        } catch {
            guard generation == nil || generation == coordinator.runtimeGeneration else { return }
            coordinator.isReachable = false
            if coordinator.selectedConnection.mode == .relayLink {
                if let firestoreError = error as? FirestoreError,
                   case .notAuthenticated = firestoreError {
                    coordinator.runtimeErrorText = "Sign in with the same OpenBurnBar account on this iPhone/iPad to use Remote Relay."
                } else if let hermesError = error as? HermesServiceError {
                    coordinator.runtimeErrorText = hermesError.localizedDescription
                } else {
                    coordinator.runtimeErrorText = "Remote Hermes relay is offline. Keep OpenBurnBar running on your Mac, signed in to this account, with Hermes reachable there."
                }
            } else {
                coordinator.runtimeErrorText = "Hermes is not reachable at \(coordinator.baseURL.absoluteString)."
            }
        }
    }

    func loadModels(generation: Int, coordinator: HermesTransportCoordinating) async {
        do {
            let data: Data
            if coordinator.selectedConnection.mode == .relayLink {
                data = try await coordinator.relayTransport.sendUnary(
                    coordinator.relayPayload(operation: .models, method: "GET", path: "/v1/models", sessionID: nil, body: nil, connection: nil),
                    timeout: coordinator.remoteRelayControlPlaneTimeout
                )
            } else {
                let (directData, response) = try await coordinator.urlSession.data(for: coordinator.makeRequest(path: "/v1/models", timeout: 8))
                guard generation == coordinator.runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == coordinator.runtimeGeneration else { return }
            var options = try HermesWireValueParsing.parseModelOptions(from: data)
            if coordinator.selectedConnection.mode != .relayLink {
                options = HermesWireValueParsing.mergedModelOptions(
                    primary: options,
                    secondary: await directGatewayModelOptions(coordinator: coordinator)
                )
            }
            coordinator.modelOptions = options
            if let selectedModelID = coordinator.selectedModelID,
               let resolved = AssistantModelIDCanonicalizer.resolveRouteEligibleModelID(selectedModelID, in: coordinator.modelOptions) {
                coordinator.persistResolvedSelectedModelID(resolved)
                coordinator.runtimeErrorText = nil
            } else if let selectedModelID = coordinator.selectedModelID, !coordinator.modelOptions.contains(where: { $0.modelID == selectedModelID && $0.isRouteEligible }) {
                if coordinator.selectedModelWasExplicit {
                    coordinator.runtimeErrorText = "Selected Hermes model '\(selectedModelID)' is not advertised by this Mac relay. Pick a listed model or refresh the Mac provider catalog."
                } else {
                    coordinator.selectedModelID = Self.preferredRouteEligibleModelID(
                        in: coordinator.modelOptions,
                        favorites: coordinator.favoriteModelOptions
                    )
                    coordinator.selectedModelWasExplicit = false
                    coordinator.runtimeErrorText = coordinator.selectedModelID == nil && !coordinator.modelOptions.isEmpty
                        ? HermesServiceError.noRouteEligibleModel.localizedDescription
                        : nil
                }
            } else if coordinator.selectedModelID == nil {
                coordinator.selectedModelID = Self.preferredRouteEligibleModelID(
                    in: coordinator.modelOptions,
                    favorites: coordinator.favoriteModelOptions
                )
                coordinator.selectedModelWasExplicit = false
                coordinator.runtimeErrorText = coordinator.selectedModelID == nil && !coordinator.modelOptions.isEmpty
                    ? HermesServiceError.noRouteEligibleModel.localizedDescription
                    : nil
            }
        } catch {
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.modelOptions = []
        }
    }

    private func directGatewayModelOptions(coordinator: HermesTransportCoordinating) async -> [HermesRuntimeModelOption] {
        guard let url = directGatewayModelsURL(coordinator: coordinator) else { return [] }
        do {
            let (data, response) = try await coordinator.urlSession.data(for: URLRequest(url: url, timeoutInterval: 4))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return try HermesWireValueParsing.parseModelOptions(from: data)
        } catch {
            return []
        }
    }

    private func directGatewayModelsURL(coordinator: HermesTransportCoordinating) -> URL? {
        guard var components = URLComponents(url: coordinator.baseURL, resolvingAgainstBaseURL: false),
              components.host != nil else {
            return nil
        }
        components.port = 8317
        components.path = "/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func isLocalOnlyModelOption(_ option: HermesRuntimeModelOption) -> Bool {
        let text = "\(option.providerID) \(option.providerName) \(option.modelID) \(option.displayName)"
            .lowercased()
        return text.contains("ollama")
            || text.contains("lmstudio")
            || text.contains("lm studio")
            || text.contains("local")
    }

    static func preferredRouteEligibleModelID(
        in options: [HermesRuntimeModelOption],
        favorites: [HermesRuntimeModelOption]
    ) -> String? {
        favorites.first { $0.isRouteEligible && !isLocalOnlyModelOption($0) }?.modelID
            ?? favorites.first { $0.isRouteEligible }?.modelID
            ?? options.first { $0.isRouteEligible && !isLocalOnlyModelOption($0) }?.modelID
            ?? options.first { $0.isRouteEligible }?.modelID
    }

    func loadSessions(generation: Int, coordinator: HermesTransportCoordinating) async {
        do {
            let data: Data
            if coordinator.selectedConnection.mode == .relayLink {
                data = try await coordinator.relayTransport.sendUnary(
                    coordinator.relayPayload(operation: .sessions, method: "GET", path: "/api/sessions", sessionID: nil, body: nil, connection: nil),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await coordinator.urlSession.data(for: coordinator.makeRequest(path: "/api/sessions", timeout: 8))
                guard generation == coordinator.runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.sessions = HermesWireValueParsing.parseSessions(from: data)
        } catch {
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.sessions = []
        }
    }

    func loadProfiles(generation: Int, coordinator: HermesTransportCoordinating) async {
        do {
            let data: Data
            if coordinator.selectedConnection.mode == .relayLink {
                data = try await coordinator.relayTransport.sendUnary(
                    coordinator.relayPayload(operation: .profiles, method: "GET", path: "/api/profiles", sessionID: nil, body: nil, connection: nil),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await coordinator.urlSession.data(for: coordinator.makeRequest(path: "/api/profiles", timeout: 8))
                guard generation == coordinator.runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.profiles = HermesWireValueParsing.parseProfiles(from: data)
        } catch {
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.profiles = []
        }
    }

    func loadJobs(generation: Int, coordinator: HermesTransportCoordinating) async {
        do {
            let data: Data
            if coordinator.selectedConnection.mode == .relayLink {
                data = try await coordinator.relayTransport.sendUnary(
                    coordinator.relayPayload(operation: .jobs, method: "GET", path: "/api/jobs", sessionID: nil, body: nil, connection: nil),
                    timeout: 20
                )
            } else {
                let (directData, response) = try await coordinator.urlSession.data(for: coordinator.makeRequest(path: "/api/jobs", timeout: 8))
                guard generation == coordinator.runtimeGeneration else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
                data = directData
            }
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.jobs = HermesWireValueParsing.parseJobs(from: data)
        } catch {
            guard generation == coordinator.runtimeGeneration else { return }
            coordinator.jobs = []
        }
    }

    private func resolveCLIAgentModelCatalogRelayConnection(coordinator: HermesTransportCoordinating) async throws -> HermesConnectionRecord {
        if coordinator.selectedConnection.mode != .relayLink || suggestedRelayConnection == nil {
            await refreshConnections(refreshSelectedConnection: false, coordinator: coordinator)
        }
        if coordinator.selectedConnection.mode != .relayLink {
            _ = connectToSuggestedRelay(refresh: false, coordinator: coordinator)
        }
        if Self.advertisesCLIModelCatalog(coordinator.selectedConnection),
           coordinator.selectedConnection.mode == .relayLink {
            return coordinator.selectedConnection
        }

        await refreshConnections(refreshSelectedConnection: false, coordinator: coordinator)
        if Self.advertisesCLIModelCatalog(coordinator.selectedConnection),
           coordinator.selectedConnection.mode == .relayLink {
            return coordinator.selectedConnection
        }

        if let relay = relayConnections.first(where: Self.advertisesCLIModelCatalog(_:)) {
            return relay
        }

        if let runtimeError = coordinator.runtimeErrorText,
           runtimeError.contains("Could not load Hermes connections") {
            switch CloudErrorClassification.classify(message: runtimeError) {
            case .permissionDenied:
                throw HermesServiceError.relayUnavailable(
                    "Could not load relay connections: sign out and sign back in with the same account you use on your Mac, then try again."
                )
            case .appCheckBlocked:
                throw HermesServiceError.relayUnavailable(
                    "Could not load relay connections: App Check rejected this device. Reinstall from the official channel or register a debug token."
                )
            case .notAuthenticated:
                throw HermesServiceError.relayUnavailable(
                    "Could not load relay connections: sign in to discover models from your paired Mac."
                )
            default:
                break
            }
        }

        if !relayConnections.isEmpty {
            throw HermesServiceError.relayUnavailable(
                "Your Mac relay is online but has not published live CLI model discovery yet. Update or restart OpenBurnBar on the Mac."
            )
        }
        throw HermesServiceError.relayUnavailable(
            "No paired Mac relay is available for CLI model discovery. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay."
        )
    }

    func macRelayPayloadForCLIAgentChat(
        body: Data,
        sessionID: String,
        coordinator: HermesTransportCoordinating
    ) async throws -> HermesRelayPayload {
        if coordinator.selectedConnection.mode != .relayLink || suggestedRelayConnection == nil {
            await refreshConnections(refreshSelectedConnection: false, coordinator: coordinator)
        }
        if coordinator.selectedConnection.mode != .relayLink {
            _ = connectToSuggestedRelay(refresh: false, coordinator: coordinator)
        }
        guard coordinator.selectedConnection.mode == .relayLink else {
            throw HermesServiceError.relayUnavailable(
                "No paired Mac relay is available for Codex or Claude chat. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay."
            )
        }
        guard coordinator.selectedConnection.capabilities.contains("cli_agent_chat") else {
            throw HermesServiceError.relayUnavailable(
                "Your Mac relay is online but does not advertise Codex/Claude chat yet. Update or restart OpenBurnBar on the Mac."
            )
        }
        return coordinator.relayPayload(
            operation: .cliAgentChat,
            method: "POST",
            path: "/v1/cli-agent/chat",
            sessionID: sessionID,
            body: body,
            connection: nil
        )
    }

    func macRelayPayloadForCLIAgentSessionAction(
        body: Data,
        sessionID: String,
        coordinator: HermesTransportCoordinating
    ) async throws -> HermesRelayPayload {
        if coordinator.selectedConnection.mode != .relayLink || suggestedRelayConnection == nil {
            await refreshConnections(refreshSelectedConnection: false, coordinator: coordinator)
        }
        if coordinator.selectedConnection.mode != .relayLink {
            _ = connectToSuggestedRelay(refresh: false, coordinator: coordinator)
        }
        guard coordinator.selectedConnection.mode == .relayLink else {
            throw HermesServiceError.relayUnavailable(
                "No paired Mac relay is available for CLI session restart. Keep OpenBurnBar open on your Mac, sign in, and enable Hermes Remote Relay."
            )
        }
        guard coordinator.selectedConnection.capabilities.contains("cli_agent_session_action") else {
            throw HermesServiceError.relayUnavailable(
                "Your Mac relay is online but does not advertise CLI session restart yet. Update or restart OpenBurnBar on the Mac."
            )
        }
        return coordinator.relayPayload(
            operation: .cliAgentSessionAction,
            method: "POST",
            path: "/v1/cli-agent/session-action",
            sessionID: sessionID,
            body: body,
            connection: nil
        )
    }

    func macRelayPayloadForCLIRuntimeModelCatalog(
        body: Data,
        sessionID: String,
        coordinator: HermesTransportCoordinating
    ) async throws -> HermesRelayPayload {
        let connection = try await resolveCLIAgentModelCatalogRelayConnection(coordinator: coordinator)
        return coordinator.relayPayload(
            operation: .cliAgentModelCatalog,
            method: "POST",
            path: "/v1/cli-agent/model-catalog",
            sessionID: sessionID,
            body: body,
            connection: connection
        )
    }
}
