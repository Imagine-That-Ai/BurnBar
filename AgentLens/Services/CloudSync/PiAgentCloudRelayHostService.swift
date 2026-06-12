import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

// MARK: - Pi Agent Remote Relay Host

private enum PiAgentRealtimeRelayProtocol {
    static let version = 1
}

@MainActor
final class PiAgentCloudRelayHostService {
    private let db: Firestore
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let urlSession: URLSession
    private let relayKeyStore: PiAgentRelayKeyStore
    private var heartbeatTask: Task<Void, Never>?
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var processingRequestIDs: Set<String> = []

    init(
        db: Firestore = Firestore.firestore(),
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        urlSession: URLSession = .shared,
        relayKeyStore: PiAgentRelayKeyStore = PiAgentRelayKeyStore()
    ) {
        self.db = db
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.urlSession = urlSession
        self.relayKeyStore = relayKeyStore
    }

    var connectionID: String {
        "pi-relay-\(Self.safeIdentifier(accountManager.deviceId))"
    }

    private static let cadenceIDPiHeartbeat = "pi-agent-relay-host-heartbeat"

    func start() {
        guard heartbeatTask == nil else { return }
        // Coordinator-managed cadence: 30 s active, 5 min background,
        // paused on display sleep, gated on cloud sync. Same pattern as
        // the Hermes relay host heartbeat — Firestore writes that have
        // no business running while the laptop sleeps.
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceIDPiHeartbeat,
                activeInterval: 30,
                backgroundInterval: 300,
                sleepInterval: nil,
                isEnabled: { [weak self] in
                    self?.accountManager.isCloudSyncEnabled ?? false
                },
                fireImmediately: true,
                cancellableInFlight: false,
                work: { [weak self] in
                    await self?.refreshRelayHost()
                }
            )
        )
        heartbeatTask = Task { @MainActor in }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceIDPiHeartbeat)
        listener?.remove()
        listener = nil
        listenerUID = nil
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        processingRequestIDs.removeAll()
    }

    private func refreshRelayHost() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              let uid = Auth.auth().currentUser?.uid else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            return
        }

        guard settingsManager.piRemoteRelayEnabled else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            await publishRelayOffline(uid: uid)
            return
        }

        await publishRelayConnection(uid: uid)
        ensureRequestListener(uid: uid)
    }

    private func publishRelayOffline(uid: String) async {
        let now = Self.iso8601.string(from: Date())
        let ref = db.collection("users").document(uid).collection("pi_agent_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            var data: [String: Any] = [
                "id": connectionID,
                "displayName": Host.current().localizedName.map { "\($0) Pi Relay" } ?? "Mac Pi Relay",
                "mode": PiConnectionMode.relayLink.rawValue,
                "status": PiConnectionStatus.offline.rawValue,
                "capabilities": ["chat_completions", "remote_relay"],
                "advertisedModel": FieldValue.delete(),
                "updatedAt": now,
                "schemaVersion": 2
            ]
            if let publicKey = try? relayKeyStore.existingPublicKeyBase64() {
                data["relayPublicKey"] = publicKey
                data["relayKeyVersion"] = PiAgentRelayCrypto.keyVersion
                data["relayEncryption"] = PiAgentRelayCrypto.algorithm
            }
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.silentFailure("pi_agent_relay_offline_publish_failed", error: error)
        }
    }

    private func publishRelayConnection(uid: String) async {
        let relayPrivateKey: PiAgentRelayPrivateKey
        do {
            relayPrivateKey = try relayKeyStore.privateKey()
        } catch {
            AppLogger.network.error(
                "pi_agent_relay_key_unavailable",
                metadata: ["error": error.localizedDescription]
            )
            await publishRelayOffline(uid: uid)
            return
        }

        let baseURL = piAgentBaseURL()
        let bearerToken = resolvedBearerToken()
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapter = PiAgentRuntimeAdapter(
            preferredInstanceID: preferred.isEmpty ? nil : preferred,
            redisURL: redisRaw.isEmpty ? nil : URL(string: redisRaw)
        )
        let status = await adapter.refreshManagedStatus(baseURL: baseURL, bearerToken: bearerToken)
        let now = Self.iso8601.string(from: Date())
        var data: [String: Any] = [
            "id": connectionID,
            "displayName": Host.current().localizedName.map { "\($0) Pi Relay" } ?? "Mac Pi Relay",
            "mode": PiConnectionMode.relayLink.rawValue,
            "status": status.gatewayRunning ? PiConnectionStatus.online.rawValue : PiConnectionStatus.offline.rawValue,
            "endpointURL": baseURL.absoluteString,
            "capabilities": ["chat_completions", "models", "remote_relay"],
            "relayPublicKey": relayPrivateKey.publicKeyBase64,
            "relayKeyVersion": PiAgentRelayCrypto.keyVersion,
            "relayEncryption": PiAgentRelayCrypto.algorithm,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        if status.gatewayRunning {
            data["lastSeenAt"] = now
        }
        if let modelName = status.modelName, !modelName.isEmpty {
            data["advertisedModel"] = modelName
            data["models"] = [[
                "id": "pi:\(modelName)",
                "providerID": "pi",
                "providerName": "Pi",
                "modelID": modelName,
                "displayName": modelName,
                "instanceID": status.selectedInstanceID ?? "default",
                "schemaVersion": 1
            ]]
        } else {
            data["advertisedModel"] = FieldValue.delete()
            data["models"] = FieldValue.delete()
        }
        if let selected = status.selectedInstanceID {
            data["selectedInstanceID"] = selected
        }
        if !redisRaw.isEmpty {
            data["redisURL"] = redisRaw
        }
        if !status.instances.isEmpty {
            data["instances"] = status.instances.map { instance in
                var record: [String: Any] = [
                    "id": instance.id,
                    "displayName": instance.displayName,
                    "endpointURL": instance.gatewayBaseURL?.absoluteString ?? baseURL.absoluteString,
                    "status": instance.isOnline ? PiConnectionStatus.online.rawValue : PiConnectionStatus.offline.rawValue,
                    "capabilities": ["chat_completions"],
                    "schemaVersion": 1
                ]
                if let modelName = status.modelName, !modelName.isEmpty {
                    record["modelName"] = modelName
                }
                if instance.isOnline {
                    record["lastSeenAt"] = now
                }
                return record
            }
        }
        if let realtimeURL = URL(string: settingsManager.piRealtimeRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           realtimeURL.scheme == "wss" {
            data["realtimeRelayURL"] = realtimeURL.absoluteString
            data["realtimeRelayStatus"] = "online"
            data["realtimeRelayProtocolVersion"] = PiAgentRealtimeRelayProtocol.version
        }

        let ref = db.collection("users").document(uid).collection("pi_agent_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.error(
                "pi_agent_relay_connection_publish_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func ensureRequestListener(uid: String) {
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = db.collection("users").document(uid)
            .collection("pi_agent_relay_requests")
            .whereField("connectionId", isEqualTo: connectionID)
            .whereField("status", isEqualTo: PiAgentRelayRequestStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    AppLogger.network.error(
                        "pi_agent_relay_listener_failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    Task { @MainActor [weak self] in
                        self?.listener?.remove()
                        self?.listener = nil
                        self?.listenerUID = nil
                    }
                    return
                }
                guard let documents = snapshot?.documents, !documents.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handlePendingRelayDocuments(documents, uid: uid)
                }
            }
    }

    private func handlePendingRelayDocuments(_ documents: [QueryDocumentSnapshot], uid: String) {
        for document in documents
        where !processingRequestIDs.contains(document.documentID) && requestTasks[document.documentID] == nil {
            let requestID = document.documentID
            processingRequestIDs.insert(requestID)
            let task = Task { @MainActor in
                defer {
                    processingRequestIDs.remove(requestID)
                    requestTasks.removeValue(forKey: requestID)
                }
                await processRelayRequest(reference: document.reference, uid: uid)
            }
            requestTasks[requestID] = task
        }
    }

    private func processRelayRequest(reference: DocumentReference, uid: String) async {
        var context: PiAgentRelayRequestContext?
        do {
            guard let claimedRequest = try await claimRelayRequest(reference: reference) else { return }
            let data = claimedRequest.data
            guard let operationText = data["operation"] as? String,
                  let operation = PiAgentRelayOperation(rawValue: operationText) else {
                try await failRelayRequest(reference: reference, message: "Malformed relay request.")
                return
            }
            let requestID = (data["id"] as? String) ?? reference.documentID
            guard !isExpired(data["expiresAt"]) else {
                try await reference.setData([
                    "status": PiAgentRelayRequestStatus.expired.rawValue,
                    "updatedAt": Self.iso8601.string(from: Date())
                ], merge: true)
                return
            }
            let prepared = try decryptRelayRequest(data, uid: uid, requestID: requestID)
            context = prepared.context
            switch operation {
            case .chatCompletions:
                try await forwardStreamingRequest(reference: reference, context: prepared.context, data: prepared.data)
            case .models, .sessions, .sessionDetail:
                try await forwardUnaryRequest(reference: reference, context: prepared.context, operation: operation, data: prepared.data)
            }
        } catch {
            try? await failRelayRequest(reference: reference, message: error.localizedDescription, context: context)
        }
    }

    private func decryptRelayRequest(
        _ data: [String: Any],
        uid: String,
        requestID: String
    ) throws -> (data: [String: Any], context: PiAgentRelayRequestContext) {
        guard uid.isEmpty == false,
              data["relayEncryption"] as? String == PiAgentRelayCrypto.algorithm,
              let wrappedKey = data["wrappedKey"] as? String,
              let payloadCiphertext = data["payloadCiphertext"] as? String else {
            throw PiAgentRelayHostError.encryptionRequired
        }
        let connectionID = (data["connectionId"] as? String) ?? self.connectionID
        let privateKey = try relayKeyStore.privateKey()
        let keyData = try PiAgentRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: PiAgentRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let plaintext = try PiAgentRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: PiAgentRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let payload = try JSONDecoder().decode(PiAgentRelayEncryptedRequestPayload.self, from: plaintext)
        var decrypted = data
        decrypted["path"] = payload.path
        decrypted["sessionId"] = payload.sessionId
        decrypted["body"] = payload.body
        return (
            decrypted,
            PiAgentRelayRequestContext(uid: uid, requestID: requestID, connectionID: connectionID, keyData: keyData)
        )
    }

    private func claimRelayRequest(reference: DocumentReference) async throws -> ClaimedRelayRequest? {
        try await withCheckedThrowingContinuation { continuation in
            db.runTransaction({ transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(reference)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                guard var data = snapshot.data(),
                      data["status"] as? String == PiAgentRelayRequestStatus.pending.rawValue else {
                    return NSNull()
                }
                let now = Self.iso8601.string(from: Date())
                transaction.setData([
                    "status": PiAgentRelayRequestStatus.claimed.rawValue,
                    "claimedAt": now,
                    "claimedBy": self.connectionID,
                    "updatedAt": now
                ], forDocument: reference, merge: true)
                data["status"] = PiAgentRelayRequestStatus.claimed.rawValue
                data["claimedBy"] = self.connectionID
                return data as NSDictionary
            }, completion: { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if result is NSNull {
                    continuation.resume(returning: nil)
                    return
                }
                guard let data = result as? [String: Any] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ClaimedRelayRequest(data: data))
            })
        }
    }

    private func forwardUnaryRequest(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        operation: PiAgentRelayOperation,
        data: [String: Any]
    ) async throws {
        let request = try makeForwardRequest(operation: operation, data: data)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw PiAgentRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw PiAgentRelayHostError.httpStatus(statusCode)
        }
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let chunkCount = try await writeRelayChunk(reference: reference, context: context, sequence: 0, kind: .data, data: bodyText)
        try await completeRelayRequest(reference: reference, chunkCount: chunkCount)
    }

    private func forwardStreamingRequest(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        data: [String: Any]
    ) async throws {
        var request = try makeForwardRequest(operation: .chatCompletions, data: data)
        request.httpMethod = "POST"
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw PiAgentRelayHostError.requestNoLongerActive
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": PiAgentRelayRequestStatus.streaming.rawValue,
            "updatedAt": now
        ], merge: true)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw PiAgentRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw PiAgentRelayHostError.httpStatus(statusCode)
        }

        var eventLines: [String] = []
        var sequence = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in HermesRelayHostService.consumeSSELine(line, eventLines: &eventLines) {
                let writtenChunks = try await writeRelayChunk(reference: reference, context: context, sequence: sequence, kind: .sse, data: event)
                sequence += writtenChunks
            }
        }
        if !eventLines.isEmpty {
            let writtenChunks = try await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: sequence,
                kind: .sse,
                data: eventLines.joined(separator: "\n")
            )
            sequence += writtenChunks
        }
        try await completeRelayRequest(reference: reference, chunkCount: sequence)
    }

    private func makeForwardRequest(operation: PiAgentRelayOperation, data: [String: Any]) throws -> URLRequest {
        let path = try relayPath(operation: operation, data: data)
        guard let url = URL(string: path, relativeTo: piAgentBaseURLWithTrailingSlash())?.absoluteURL else {
            throw PiAgentRelayHostError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: operation == .chatCompletions ? 120 : 20)
        request.httpMethod = operation == .chatCompletions ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = resolvedBearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if operation == .chatCompletions {
            guard let body = data["body"] as? String,
                  let bodyData = body.data(using: .utf8) else {
                throw PiAgentRelayHostError.missingBody
            }
            request.httpBody = bodyData
        }
        return request
    }

    private func relayPath(operation: PiAgentRelayOperation, data: [String: Any]) throws -> String {
        switch operation {
        case .chatCompletions:
            return "v1/chat/completions"
        case .models:
            return "v1/models"
        case .sessions:
            return "api/sessions"
        case .sessionDetail:
            guard let sessionID = data["sessionId"] as? String,
                  !sessionID.isEmpty else {
                throw PiAgentRelayHostError.invalidPath
            }
            let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
            return "api/sessions/\(encoded)"
        }
    }

    @discardableResult
    private func writeRelayChunk(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        sequence: Int,
        kind: PiAgentRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws -> Int {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw PiAgentRelayHostError.requestNoLongerActive
        }

        if kind == .data, let data {
            let fragments = HermesRelayHostService.relayDataFragments(data)
            for (offset, fragment) in fragments.enumerated() {
                try await writeRelayChunkDocument(reference: reference, context: context, sequence: sequence + offset, kind: kind, data: fragment, error: error)
            }
            return fragments.count
        }

        if let data, data.utf8.count > HermesRelayHostService.maxRelayChunkDataBytes {
            throw PiAgentRelayHostError.payloadTooLarge
        }
        try await writeRelayChunkDocument(reference: reference, context: context, sequence: sequence, kind: kind, data: data, error: error.map { String($0.prefix(2_000)) })
        return 1
    }

    private func writeRelayChunkDocument(
        reference: DocumentReference,
        context: PiAgentRelayRequestContext,
        sequence: Int,
        kind: PiAgentRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws {
        let now = Self.iso8601.string(from: Date())
        let chunkID = String(format: "%08d", sequence)
        let plaintext = error ?? data ?? ""
        let payload: [String: Any] = [
            "id": chunkID,
            "requestId": context.requestID,
            "sequence": sequence,
            "kind": kind.rawValue,
            "ciphertext": try PiAgentRelayCrypto.sealToBase64(
                plaintext: Data(plaintext.utf8),
                keyData: context.keyData,
                aad: PiAgentRelayCrypto.chunkAAD(
                    uid: context.uid,
                    connectionID: context.connectionID,
                    requestID: context.requestID,
                    sequence: sequence,
                    kind: kind.rawValue
                )
            ),
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        try await reference.collection("chunks").document(chunkID).setData(payload, merge: false)
    }

    private func completeRelayRequest(reference: DocumentReference, chunkCount: Int) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else { return }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": PiAgentRelayRequestStatus.completed.rawValue,
            "chunkCount": chunkCount,
            "completedAt": now,
            "updatedAt": now
        ], merge: true)
    }

    private func failRelayRequest(
        reference: DocumentReference,
        message: String,
        context: PiAgentRelayRequestContext? = nil
    ) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else { return }
        let now = Self.iso8601.string(from: Date())
        var statusUpdate: [String: Any] = [
            "status": PiAgentRelayRequestStatus.failed.rawValue,
            "updatedAt": now
        ]
        if let context {
            _ = try? await writeRelayChunk(
                reference: reference,
                context: context,
                sequence: 0,
                kind: .error,
                error: String(message.prefix(2_000))
            )
            statusUpdate["chunkCount"] = 1
        }
        try await reference.setData(statusUpdate, merge: true)
    }

    private func relayRequestCanReceiveOutput(reference: DocumentReference) async throws -> Bool {
        let snapshot = try await reference.getDocument()
        guard let statusText = snapshot.data()?["status"] as? String,
              let status = PiAgentRelayRequestStatus(rawValue: statusText) else {
            return false
        }
        return status == .claimed || status == .streaming
    }

    private func piAgentBaseURL() -> URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private func piAgentBaseURLWithTrailingSlash() -> URL {
        let url = piAgentBaseURL()
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
    }

    private func resolvedBearerToken() -> String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func isExpired(_ raw: Any?) -> Bool {
        guard let text = raw as? String,
              let date = Self.iso8601.date(from: text) ?? Self.iso8601NoFraction.date(from: text) else {
            return false
        }
        return date <= Date()
    }

    private static func safeIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let lowered = raw.lowercased()
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty ? "mac" : collapsed
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601NoFraction = ISO8601DateFormatter()
}

private enum PiAgentRelayHostError: LocalizedError {
    case invalidPath
    case missingBody
    case invalidResponse
    case httpStatus(Int)
    case requestNoLongerActive
    case payloadTooLarge
    case encryptionRequired

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Pi Agent relay request path is invalid."
        case .missingBody:
            return "Pi Agent relay chat request is missing a body."
        case .invalidResponse:
            return "Pi Agent returned an invalid relay response."
        case .httpStatus(let code):
            return "Pi Agent returned HTTP \(code)."
        case .requestNoLongerActive:
            return "Pi Agent relay request is no longer active."
        case .payloadTooLarge:
            return "Pi Agent relay response chunk is too large to relay safely."
        case .encryptionRequired:
            return "Pi Agent relay requests must be encrypted."
        }
    }
}

private struct PiAgentRelayRequestContext {
    let uid: String
    let requestID: String
    let connectionID: String
    let keyData: Data
}

struct PiAgentRelayKeyStore {
    private let keychain: KeychainStore
    private let account = "settings.chat.piagent.relay.p256.v1"
    private let fallbackCacheKey: String

    init(
        keychain: KeychainStore = KeychainStore(
            service: "com.openburnbar.pi-agent-relay",
            legacyServices: []
        ),
        fallbackCacheKey: String = "com.openburnbar.pi-agent-relay.p256.v1"
    ) {
        self.keychain = keychain
        self.fallbackCacheKey = fallbackCacheKey
    }

    func privateKey() throws -> PiAgentRelayPrivateKey {
        do {
            if let stored = try keychain.string(for: account),
               let data = Data(base64Encoded: stored),
               let key = try? PiAgentRelayPrivateKey(rawRepresentation: data) {
                return key
            }
            let key = PiAgentRelayCrypto.generatePrivateKey()
            do {
                try keychain.set(key.rawRepresentation.base64EncodedString(), for: account)
                return key
            } catch {
                AppLogger.network.notice(
                    "pi_agent_relay_keychain_ephemeral_fallback",
                    metadata: ["error": error.localizedDescription]
                )
                return try cachedFallbackPrivateKey()
            }
        } catch {
            AppLogger.network.notice(
                "pi_agent_relay_keychain_read_failed_using_ephemeral",
                metadata: ["error": error.localizedDescription]
            )
            return try cachedFallbackPrivateKey()
        }
    }

    func existingPublicKeyBase64() throws -> String? {
        do {
            guard let stored = try keychain.string(for: account),
                  let data = Data(base64Encoded: stored) else {
                return try cachedFallbackPublicKeyBase64()
            }
            return try PiAgentRelayPrivateKey(rawRepresentation: data).publicKeyBase64
        } catch {
            AppLogger.network.notice(
                "pi_agent_relay_keychain_public_key_failed_using_ephemeral",
                metadata: ["error": error.localizedDescription]
            )
            return try cachedFallbackPublicKeyBase64()
        }
    }

    private func cachedFallbackPrivateKey() throws -> PiAgentRelayPrivateKey {
        let data = RelayEphemeralKeyCache.shared.data(for: fallbackCacheKey) {
            PiAgentRelayCrypto.generatePrivateKey().rawRepresentation
        }
        return try PiAgentRelayPrivateKey(rawRepresentation: data)
    }

    private func cachedFallbackPublicKeyBase64() throws -> String? {
        guard let data = RelayEphemeralKeyCache.shared.existingData(for: fallbackCacheKey) else {
            return nil
        }
        return try PiAgentRelayPrivateKey(rawRepresentation: data).publicKeyBase64
    }
}
