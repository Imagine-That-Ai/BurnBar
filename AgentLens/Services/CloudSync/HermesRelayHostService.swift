import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarMedia

// MARK: - Hermes Remote Relay Host

@MainActor
final class HermesRelayHostService {
    private let db: Firestore
    private let accountManager: AccountManager
    private let settingsManager: SettingsManager
    private let urlSession: URLSession
    private let relayKeyStore: HermesRelayKeyStore
    private let realtimeRelayClient: HermesRealtimeRelayHosting
    private let cliChatDispatcher: CLIAgentRelayChatDispatcher?
    private let cliModelCatalogDispatcher: CLIRuntimeModelCatalogDispatcher?
    private var computerUseControlDispatcher: ControlFrameDispatcher?
    private var heartbeatTask: Task<Void, Never>?
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var processingRequestIDs: Set<String> = []
    /// Retained Mercury file-transfer service so its persistent control
    /// stream + `@Published` state survive the lifetime of the Hermes
    /// session. The Mac chat input reads this property via
    /// `HermesRelayHostService` to drive paperclip + drag-and-drop
    /// sends.
    @MainActor private(set) var mercuryFileTransfer: MacFileTransferService?
    @MainActor private weak var mercuryRouter: MercuryRouter?

    /// Mercury Phase 8 — the registry the iroh client hands inbound
    /// `media.control` streams to. Surfaced so the runtime context can
    /// build `MercuryPeerSource` against the same registry instance.
    @MainActor private(set) var mercuryControlStreamRegistry: MediaControlStreamRegistry?

    init(
        db: Firestore = Firestore.firestore(),
        accountManager: AccountManager = .shared,
        settingsManager: SettingsManager = .shared,
        urlSession: URLSession = .shared,
        relayKeyStore: HermesRelayKeyStore = HermesRelayKeyStore(),
        realtimeRelayClient: HermesRealtimeRelayHosting? = nil,
        cliChatDispatcher: CLIAgentRelayChatDispatcher? = nil,
        cliModelCatalogDispatcher: CLIRuntimeModelCatalogDispatcher? = nil
    ) {
        self.db = db
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.urlSession = urlSession
        self.relayKeyStore = relayKeyStore
        self.cliChatDispatcher = cliChatDispatcher
        self.cliModelCatalogDispatcher = cliModelCatalogDispatcher
        if let realtimeRelayClient {
            self.realtimeRelayClient = realtimeRelayClient
        } else {
            let forceIrohTransport: Bool = {
                #if DEBUG
                ProcessInfo.processInfo.environment["OPENBURNBAR_ENABLE_IROH_TRANSPORT"] == "1"
                #else
                false
                #endif
            }()
            if settingsManager.hermesIrohTransportEnabled || forceIrohTransport {
                let irohClient = HermesIrohRelayHostClient(
                    accountManager: accountManager,
                    settingsManager: settingsManager,
                    relayKeyStore: relayKeyStore,
                    urlSession: urlSession
                )
                // Mercury Phase 1b + Risk-1 fix — wire the Mac
                // file-transfer service AND the persistent media
                // control-stream registry. Returns nil on builds that
                // don't link the xcframework (loopback dev path).
                if let fileTransferService = MediaFileTransferServiceFactory.make() {
                    let controlRegistry = MediaControlStreamRegistry()
                    self.mercuryControlStreamRegistry = controlRegistry
                    let macFileTransfer = MacFileTransferService(
                        service: fileTransferService,
                        settingsProvider: { @MainActor [settingsManager] in
                            settingsManager.mediaBlobTransferEnabled
                        },
                        controlStreamRegistry: controlRegistry
                    )
                    macFileTransfer.setComputerUseControlDispatcher(computerUseControlDispatcher)
                    // Per-request dispatch (chat-piggyback path) — used
                    // when an advertise rides an active chat response
                    // stream rather than the long-lived control stream.
                    irohClient.mediaDispatcher = { @Sendable frame, ackSender in
                        await macFileTransfer.handleAdvertise(frame: frame, ackSender: ackSender)
                    }
                    // Control-stream registrar (Risk-1 fix) — when iOS
                    // dials a stream and classifies it as
                    // `media.control`, the request handler hands it
                    // here. MacFileTransferService owns the long-lived
                    // read loop and uses the same stream for outbound
                    // pushes.
                    irohClient.mediaControlRegistrar = { @Sendable stream, uid, connectionID in
                        await macFileTransfer.mountControlStream(
                            stream,
                            uid: uid,
                            connectionID: connectionID
                        )
                    }
                    self.mercuryFileTransfer = macFileTransfer
                }
                irohClient.cliChatDispatcher = cliChatDispatcher
                irohClient.cliModelCatalogDispatcher = cliModelCatalogDispatcher
                irohClient.setControlDispatcher(computerUseControlDispatcher)
                self.realtimeRelayClient = irohClient
            } else {
                self.realtimeRelayClient = DisabledHermesRealtimeRelayHostClient()
            }
        }
    }

    func setComputerUseControlDispatcher(_ dispatcher: ControlFrameDispatcher?) {
        computerUseControlDispatcher = dispatcher
        mercuryFileTransfer?.setComputerUseControlDispatcher(dispatcher)
        if let irohClient = realtimeRelayClient as? HermesIrohRelayHostClient {
            irohClient.setControlDispatcher(dispatcher)
        } else if let fanout = realtimeRelayClient as? HermesRelayHostFanout {
            fanout.setControlDispatcher(dispatcher)
        }
    }

    /// Mercury Phase 8 — attach the router so the persistent
    /// `media.control` stream's read loop fans inbound mirror /
    /// presence frames into it. The closure stays alive as long as
    /// `mercuryFileTransfer` does, which matches the lifetime of the
    /// iroh client.
    @MainActor
    func attachMercuryRouter(_ router: MercuryRouter) {
        mercuryRouter = router
        installMercuryRouterIfPossible()
    }

    @MainActor
    private func installMercuryRouterIfPossible() {
        guard let router = mercuryRouter,
              let transfer = mercuryFileTransfer else { return }
        transfer.setMercuryDispatcher { @Sendable frame, controlStreamID, reply in
            await router.handleFrame(
                frame,
                controlStreamID: controlStreamID,
                replySender: reply
            )
        }
        transfer.setMercuryControlStreamCloseHandler { @Sendable _, connectionID, controlStreamID, removedLast in
            await router.handleControlStreamClosed(
                connectionID: connectionID,
                controlStreamID: controlStreamID,
                removedLastStreamForConnection: removedLast
            )
        }
    }

    var connectionID: String {
        "relay-\(Self.safeIdentifier(accountManager.deviceId))"
    }

    private static let cadenceIDHermesHeartbeat = "hermes-relay-host-heartbeat"

    func start() {
        guard heartbeatTask == nil else { return }
        // Coordinator-managed: 30 s active, 5 min in the background,
        // paused on display sleep, gated on cloud sync being enabled.
        // The relay host heartbeat is a Firestore write — exactly the
        // class of background work that should not run on a sleeping
        // laptop.
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: Self.cadenceIDHermesHeartbeat,
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
        BackgroundCadenceCoordinator.shared.unregister(id: Self.cadenceIDHermesHeartbeat)
        listener?.remove()
        listener = nil
        listenerUID = nil
        for task in requestTasks.values {
            task.cancel()
        }
        requestTasks.removeAll()
        processingRequestIDs.removeAll()
        realtimeRelayClient.stop()
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
            realtimeRelayClient.stop()
            return
        }

        guard settingsManager.hermesRemoteRelayEnabled else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            for task in requestTasks.values {
                task.cancel()
            }
            requestTasks.removeAll()
            realtimeRelayClient.stop()
            await publishRelayOffline(uid: uid)
            return
        }

        await publishRelayConnection(uid: uid)
        ensureRequestListener(uid: uid)
    }

    private func publishRelayOffline(uid: String) async {
        let now = Self.iso8601.string(from: Date())
        let ref = db.collection("users").document(uid).collection("hermes_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            var data: [String: Any] = [
                "id": connectionID,
                "displayName": Host.current().localizedName.map { "\($0) Hermes Relay" } ?? "Mac Hermes Relay",
                "mode": HermesConnectionMode.relayLink.rawValue,
                "status": HermesConnectionStatus.offline.rawValue,
                "capabilities": ["remote_relay"],
                "advertisedModel": FieldValue.delete(),
                "realtimeRelayURL": FieldValue.delete(),
                "realtimeRelayStatus": "offline",
                "realtimeRelayLastSeenAt": FieldValue.delete(),
                "realtimeRelayProtocolVersion": FieldValue.delete(),
                "updatedAt": now,
                "schemaVersion": 2
            ]
            if let publicKey = try? relayKeyStore.existingPublicKeyBase64() {
                data["relayPublicKey"] = publicKey
                data["relayKeyVersion"] = HermesRelayCrypto.keyVersion
                data["relayEncryption"] = HermesRelayCrypto.algorithm
            }
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.silentFailure("hermes_relay_offline_publish_failed", error: error)
        }
    }

    private func publishRelayConnection(uid: String) async {
        let relayPrivateKey: HermesRelayPrivateKey
        do {
            relayPrivateKey = try relayKeyStore.privateKey()
        } catch {
            AppLogger.network.error(
                "hermes_relay_key_unavailable",
                metadata: ["error": error.localizedDescription]
            )
            await publishRelayOffline(uid: uid)
            return
        }
        let probe = await OpenAICompatibleModelProbe.probeWithModel(
            baseURL: burnBarGatewayBaseURLWithTrailingSlash(),
            bearerToken: settingsManager.gatewayAuthToken,
            timeout: 10
        )
        let now = Self.iso8601.string(from: Date())
        let cliAgentChatAvailable = cliChatDispatcher != nil
        let cliModelCatalogAvailable = cliModelCatalogDispatcher != nil
        let realtimeRegistered = await realtimeRelayClient.start(uid: uid, connectionID: connectionID)
        let realtimeReady = realtimeRegistered && realtimeRelayClient.isReady
        if realtimeRegistered && !realtimeReady {
            realtimeRelayClient.stop()
        }
        let relayAvailable = probe.available || cliAgentChatAvailable || cliModelCatalogAvailable || realtimeReady
        let realtimeRelayURL = realtimeReady ? realtimeRelayClient.publishableRelayURLString : nil
        AppLogger.network.info(
            "hermes_relay_connection_refresh relayAvailable=\(relayAvailable) chatGateway=\(probe.available) cliAgentChat=\(cliAgentChatAvailable) realtimeReady=\(realtimeReady) connectionID=\(connectionID)"
        )
        var capabilities = ["remote_relay"]
        if probe.available {
            capabilities.append("chat_completions")
        }
        if cliAgentChatAvailable {
            capabilities.append("cli_agent_chat")
        }
        if cliModelCatalogAvailable {
            capabilities.append("cli_agent_model_catalog")
        }
        if realtimeReady {
            capabilities.append(HermesRealtimeRelayProtocol.capability)
        }
        var data: [String: Any] = [
            "id": connectionID,
            "displayName": Host.current().localizedName.map { "\($0) Hermes Relay" } ?? "Mac Hermes Relay",
            "mode": HermesConnectionMode.relayLink.rawValue,
            "status": relayAvailable ? HermesConnectionStatus.online.rawValue : HermesConnectionStatus.offline.rawValue,
            "capabilities": capabilities,
            "relayPublicKey": relayPrivateKey.publicKeyBase64,
            "relayKeyVersion": HermesRelayCrypto.keyVersion,
            "relayEncryption": HermesRelayCrypto.algorithm,
            "realtimeRelayStatus": realtimeReady ? "online" : "offline",
            "updatedAt": now,
            "schemaVersion": 2
        ]
        if let relayURL = realtimeRelayURL {
            data["realtimeRelayURL"] = relayURL
        } else {
            data["realtimeRelayURL"] = FieldValue.delete()
        }
        if realtimeReady {
            data["realtimeRelayLastSeenAt"] = now
            data["realtimeRelayProtocolVersion"] = HermesRealtimeRelayProtocol.version
        } else {
            data["realtimeRelayLastSeenAt"] = FieldValue.delete()
            data["realtimeRelayProtocolVersion"] = FieldValue.delete()
        }
        if probe.available, let modelName = probe.modelName {
            data["advertisedModel"] = modelName
            data["lastSeenAt"] = now
        } else {
            data["advertisedModel"] = FieldValue.delete()
            if relayAvailable {
                data["lastSeenAt"] = now
            }
        }
        let ref = db.collection("users").document(uid).collection("hermes_connections").document(connectionID)
        do {
            let snap = try await ref.getDocument()
            if !snap.exists {
                data["createdAt"] = now
            }
            try await ref.setData(data, merge: true)
        } catch {
            AppLogger.network.error(
                "hermes_relay_connection_publish_failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func ensureRequestListener(uid: String) {
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = db.collection("users").document(uid)
            .collection("hermes_relay_requests")
            .whereField("connectionId", isEqualTo: connectionID)
            .whereField("status", isEqualTo: HermesRelayRequestStatus.pending.rawValue)
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    AppLogger.network.error(
                        "hermes_relay_listener_failed",
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
        var context: HermesRelayRequestContext?
        do {
            guard let claimedRequest = try await claimRelayRequest(reference: reference) else { return }
            let data = claimedRequest.data
            guard let operationText = data["operation"] as? String,
                  let operation = HermesRelayOperation(rawValue: operationText) else {
                try await failRelayRequest(reference: reference, requestID: reference.documentID, message: "Malformed relay request.")
                return
            }
            let requestID = (data["id"] as? String) ?? reference.documentID
            guard !isExpired(data["expiresAt"]) else {
                try await reference.setData([
                    "status": HermesRelayRequestStatus.expired.rawValue,
                    "updatedAt": Self.iso8601.string(from: Date())
                ], merge: true)
                return
            }
            let prepared = try decryptRelayRequest(data, uid: uid, requestID: requestID)
            context = prepared.context
            switch operation {
            case .chatCompletions:
                try await forwardStreamingRequest(
                    reference: reference,
                    context: prepared.context,
                    data: prepared.data
                )
            case .cliAgentChat:
                try await forwardCLIAgentChatRequest(
                    reference: reference,
                    context: prepared.context,
                    data: prepared.data
                )
            case .cliAgentModelCatalog:
                try await forwardCLIRuntimeModelCatalogRequest(
                    reference: reference,
                    context: prepared.context,
                    data: prepared.data
                )
            case .models, .sessions, .sessionDetail, .profiles, .jobs:
                try await forwardUnaryRequest(
                    reference: reference,
                    context: prepared.context,
                    operation: operation,
                    data: prepared.data
                )
            }
        } catch {
            try? await failRelayRequest(
                reference: reference,
                requestID: reference.documentID,
                message: error.localizedDescription,
                context: context
            )
        }
    }

    private func forwardCLIRuntimeModelCatalogRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        data: [String: Any]
    ) async throws {
        guard let cliModelCatalogDispatcher else {
            throw HermesRelayHostError.cliModelCatalogUnavailable
        }
        guard let body = data["body"] as? String,
              let bodyData = body.data(using: .utf8) else {
            throw HermesRelayHostError.missingBody
        }
        let request = try JSONDecoder().decode(CLIRuntimeModelCatalogRequest.self, from: bodyData)
        let response = try await cliModelCatalogDispatcher(request)
        let responseData = try JSONEncoder().encode(response)
        let bodyText = String(data: responseData, encoding: .utf8) ?? "{}"
        let chunkCount = try await writeRelayChunk(
            reference: reference,
            context: context,
            sequence: 0,
            kind: .data,
            data: bodyText
        )
        try await completeRelayRequest(reference: reference, chunkCount: chunkCount)
    }

    private func forwardCLIAgentChatRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        data: [String: Any]
    ) async throws {
        guard let cliChatDispatcher else {
            throw HermesRelayHostError.cliAgentChatUnavailable
        }
        guard let body = data["body"] as? String,
              let bodyData = body.data(using: .utf8) else {
            throw HermesRelayHostError.missingBody
        }
        let request = try JSONDecoder().decode(CLIAgentRelayChatRequest.self, from: bodyData)
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw HermesRelayHostError.requestNoLongerActive
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": HermesRelayRequestStatus.streaming.rawValue,
            "updatedAt": now
        ], merge: true)

        let sequencer = CLIAgentRelayChunkSequencer()
        try await cliChatDispatcher(request) { event in
            let payload = try JSONEncoder().encode(event)
            let sequence = await sequencer.next()
            _ = try await self.writeRelayChunk(
                reference: reference,
                context: context,
                sequence: sequence,
                kind: .sse,
                data: String(data: payload, encoding: .utf8) ?? "{}"
            )
        }
        try await completeRelayRequest(reference: reference, chunkCount: await sequencer.count())
    }

    private func decryptRelayRequest(
        _ data: [String: Any],
        uid: String,
        requestID: String
    ) throws -> (data: [String: Any], context: HermesRelayRequestContext) {
        guard uid.isEmpty == false,
              data["relayEncryption"] as? String == HermesRelayCrypto.algorithm,
              let wrappedKey = data["wrappedKey"] as? String,
              let payloadCiphertext = data["payloadCiphertext"] as? String else {
            throw HermesRelayHostError.encryptionRequired
        }
        let connectionID = (data["connectionId"] as? String) ?? self.connectionID
        let privateKey = try relayKeyStore.privateKey()
        let keyData = try HermesRelayCrypto.unwrapSymmetricKey(
            wrappedKey,
            privateKey: privateKey,
            aad: HermesRelayCrypto.keyAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.requestAAD(uid: uid, connectionID: connectionID, requestID: requestID)
        )
        let payload = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: plaintext)
        var decrypted = data
        decrypted["path"] = payload.path
        decrypted["sessionId"] = payload.sessionId
        decrypted["body"] = payload.body
        return (
            decrypted,
            HermesRelayRequestContext(
                uid: uid,
                requestID: requestID,
                connectionID: connectionID,
                keyData: keyData
            )
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
                      data["status"] as? String == HermesRelayRequestStatus.pending.rawValue else {
                    return NSNull()
                }
                let now = Self.iso8601.string(from: Date())
                transaction.setData([
                    "status": HermesRelayRequestStatus.claimed.rawValue,
                    "claimedAt": now,
                    "claimedBy": self.connectionID,
                    "updatedAt": now
                ], forDocument: reference, merge: true)
                data["status"] = HermesRelayRequestStatus.claimed.rawValue
                data["claimedBy"] = self.connectionID
                return data as NSDictionary
            }) { result, error in
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
            }
        }
    }

    private func forwardUnaryRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        operation: HermesRelayOperation,
        data: [String: Any]
    ) async throws {
        let request = try makeForwardRequest(operation: operation, data: data)
        let (body, response) = try await urlSession.data(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesRelayHostError.httpStatus(statusCode)
        }
        let responseBody: Data
        if operation == .models, !Self.usesBurnBarGateway(operation) {
            responseBody = await enrichedModelsBody(primaryBody: body)
        } else {
            responseBody = body
        }
        let bodyText = String(data: responseBody, encoding: .utf8) ?? ""
        let chunkCount = try await writeRelayChunk(
            reference: reference,
            context: context,
            sequence: 0,
            kind: .data,
            data: bodyText
        )
        try await completeRelayRequest(reference: reference, chunkCount: chunkCount)
    }

    private func forwardStreamingRequest(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        data: [String: Any]
    ) async throws {
        var request = try makeForwardRequest(operation: .chatCompletions, data: data)
        request.httpMethod = "POST"
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw HermesRelayHostError.requestNoLongerActive
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": HermesRelayRequestStatus.streaming.rawValue,
            "updatedAt": now
        ], merge: true)

        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw HermesRelayHostError.invalidResponse
        }
        guard (200..<300).contains(statusCode) else {
            throw HermesRelayHostError.httpStatus(statusCode)
        }

        var eventLines: [String] = []
        var sequence = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in Self.consumeSSELine(line, eventLines: &eventLines) {
                let writtenChunks = try await writeRelayChunk(
                    reference: reference,
                    context: context,
                    sequence: sequence,
                    kind: .sse,
                    data: event
                )
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

    private func makeForwardRequest(operation: HermesRelayOperation, data: [String: Any]) throws -> URLRequest {
        let path = try relayPath(operation: operation, data: data)
        let useBurnBarGateway = Self.usesBurnBarGateway(operation)
        let base = useBurnBarGateway
            ? burnBarGatewayBaseURLWithTrailingSlash()
            : hermesBaseURLWithTrailingSlash()
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw HermesRelayHostError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: operation == .chatCompletions ? 300 : 20)
        request.httpMethod = operation == .chatCompletions ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = useBurnBarGateway
            ? settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            : settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if operation == .chatCompletions {
            guard let body = data["body"] as? String,
                  let bodyData = body.data(using: .utf8) else {
                throw HermesRelayHostError.missingBody
            }
            request.httpBody = bodyData
        }
        return request
    }

    private static func usesBurnBarGateway(_ operation: HermesRelayOperation) -> Bool {
        switch operation {
        case .chatCompletions, .models:
            return true
        case .cliAgentChat, .cliAgentModelCatalog, .sessions, .profiles, .jobs, .sessionDetail:
            return false
        }
    }

    static func enrichedModelsBody(
        primaryBody: Data,
        settingsManager: SettingsManager,
        urlSession: URLSession
    ) async -> Data {
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return primaryBody
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let token = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (secondaryBody, response) = try await urlSession.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(statusCode) else {
                return primaryBody
            }
            return mergedModelsResponseBodies(primaryBody, secondaryBody) ?? primaryBody
        } catch {
            AppLogger.network.error("hermes_models_enrichment_failed", metadata: ["error": error.localizedDescription])
            return primaryBody
        }
    }

    private func enrichedModelsBody(primaryBody: Data) async -> Data {
        let port = settingsManager.gatewayPort > 0 ? settingsManager.gatewayPort : 8317
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return primaryBody
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        let token = settingsManager.gatewayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (secondaryBody, response) = try await urlSession.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(statusCode) else {
                return primaryBody
            }
            return Self.mergedModelsResponseBodies(primaryBody, secondaryBody) ?? primaryBody
        } catch {
            AppLogger.network.error("gateway_models_enrichment_failed", metadata: ["error": error.localizedDescription])
            return primaryBody
        }
    }

    private func relayPath(operation: HermesRelayOperation, data: [String: Any]) throws -> String {
        switch operation {
        case .chatCompletions:
            return "v1/chat/completions"
        case .cliAgentChat, .cliAgentModelCatalog:
            throw HermesRelayHostError.invalidPath
        case .models:
            return "v1/models"
        case .sessions:
            return "api/sessions"
        case .profiles:
            return "api/profiles"
        case .jobs:
            return "api/jobs"
        case .sessionDetail:
            guard let sessionID = data["sessionId"] as? String,
                  !sessionID.isEmpty else {
                throw HermesRelayHostError.invalidPath
            }
            let encoded = sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionID
            return "api/sessions/\(encoded)"
        }
    }

    @discardableResult
    private func writeRelayChunk(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        sequence: Int,
        kind: HermesRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws -> Int {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            throw HermesRelayHostError.requestNoLongerActive
        }

        if kind == .data, let data {
            let fragments = Self.relayDataFragments(data)
            for (offset, fragment) in fragments.enumerated() {
                try await writeRelayChunkDocument(
                    reference: reference,
                    context: context,
                    sequence: sequence + offset,
                    kind: kind,
                    data: fragment,
                    error: error
                )
            }
            return fragments.count
        }

        if let data, data.utf8.count > Self.maxRelayChunkDataBytes {
            throw HermesRelayHostError.payloadTooLarge
        }
        try await writeRelayChunkDocument(
            reference: reference,
            context: context,
            sequence: sequence,
            kind: kind,
            data: data,
            error: error.map { String($0.prefix(2_000)) }
        )
        return 1
    }

    private func writeRelayChunkDocument(
        reference: DocumentReference,
        context: HermesRelayRequestContext,
        sequence: Int,
        kind: HermesRelayChunkKind,
        data: String? = nil,
        error: String? = nil
    ) async throws {
        let now = Self.iso8601.string(from: Date())
        let chunkID = String(format: "%08d", sequence)
        var payload: [String: Any] = [
            "id": chunkID,
            "requestId": context.requestID,
            "sequence": sequence,
            "kind": kind.rawValue,
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 2
        ]
        let plaintext = error ?? data ?? ""
        payload["ciphertext"] = try HermesRelayCrypto.sealToBase64(
            plaintext: Data(plaintext.utf8),
            keyData: context.keyData,
            aad: HermesRelayCrypto.chunkAAD(
                uid: context.uid,
                connectionID: context.connectionID,
                requestID: context.requestID,
                sequence: sequence,
                kind: kind.rawValue
            )
        )
        try await reference.collection("chunks").document(chunkID).setData(payload, merge: false)
    }

    private func completeRelayRequest(reference: DocumentReference, chunkCount: Int) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            return
        }
        let now = Self.iso8601.string(from: Date())
        try await reference.setData([
            "status": HermesRelayRequestStatus.completed.rawValue,
            "chunkCount": chunkCount,
            "completedAt": now,
            "updatedAt": now
        ], merge: true)
    }

    private func failRelayRequest(
        reference: DocumentReference,
        requestID: String,
        message: String,
        context: HermesRelayRequestContext? = nil
    ) async throws {
        guard try await relayRequestCanReceiveOutput(reference: reference) else {
            return
        }
        let now = Self.iso8601.string(from: Date())
        var statusUpdate: [String: Any] = [
            "status": HermesRelayRequestStatus.failed.rawValue,
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
        } else {
            let snapshot = try? await reference.getDocument()
            let isEncrypted = (snapshot?.data()?["schemaVersion"] as? Int ?? 1) >= 2
            if !isEncrypted {
                statusUpdate["error"] = String(message.prefix(2_000))
            }
        }
        try await reference.setData(statusUpdate, merge: true)
    }

    private func relayRequestCanReceiveOutput(reference: DocumentReference) async throws -> Bool {
        let snapshot = try await reference.getDocument()
        guard let statusText = snapshot.data()?["status"] as? String,
              let status = HermesRelayRequestStatus(rawValue: statusText) else {
            return false
        }
        return status == .claimed || status == .streaming
    }

    private func hermesBaseURL() -> URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private func hermesBaseURLWithTrailingSlash() -> URL {
        let url = hermesBaseURL()
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
    }

    private func burnBarGatewayBaseURLWithTrailingSlash() -> URL {
        let rawHost = settingsManager.gatewayHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (rawHost.isEmpty || rawHost == "0.0.0.0" || rawHost == "::") ? "127.0.0.1" : rawHost
        let port = max(settingsManager.gatewayPort, 1)
        let url = URL(string: "http://\(host):\(port)") ?? URL(string: "http://127.0.0.1:8317")!
        if url.absoluteString.hasSuffix("/") { return url }
        return URL(string: "\(url.absoluteString)/") ?? url
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

    nonisolated static let maxRelayChunkDataBytes = 72_000

    nonisolated static func relayDataFragments(_ text: String) -> [String] {
        guard text.utf8.count > maxRelayChunkDataBytes else {
            return [text]
        }
        var fragments: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let bytes = String(character).utf8.count
            if currentBytes > 0, currentBytes + bytes > maxRelayChunkDataBytes {
                fragments.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += bytes
        }
        if !current.isEmpty {
            fragments.append(current)
        }
        return fragments
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

    nonisolated static func mergedModelsResponseBodies(_ primaryBody: Data, _ secondaryBody: Data) -> Data? {
        guard var primary = jsonObject(from: primaryBody),
              let secondary = jsonObject(from: secondaryBody) else {
            return nil
        }

        var seen = Set<String>()
        var merged: [[String: Any]] = []
        for item in (primary["data"] as? [[String: Any]] ?? []) + (secondary["data"] as? [[String: Any]] ?? []) {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            if seen.insert(id).inserted {
                merged.append(item)
            }
        }
        primary["data"] = merged
        primary["object"] = primary["object"] ?? "list"
        return try? JSONSerialization.data(withJSONObject: primary, options: [.sortedKeys])
    }

    private nonisolated static func jsonObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private enum HermesRelayHostError: LocalizedError {
    case invalidPath
    case missingBody
    case invalidResponse
    case httpStatus(Int)
    case requestNoLongerActive
    case payloadTooLarge
    case encryptionRequired
    case cliAgentChatUnavailable
    case cliModelCatalogUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Hermes relay request path is invalid."
        case .missingBody:
            return "Hermes relay chat request is missing a body."
        case .invalidResponse:
            return "Hermes returned an invalid relay response."
        case .httpStatus(let code):
            return "Hermes returned HTTP \(code)."
        case .requestNoLongerActive:
            return "Hermes relay request is no longer active."
        case .payloadTooLarge:
            return "Hermes relay response chunk is too large to relay safely."
        case .encryptionRequired:
            return "Hermes relay requests must be encrypted."
        case .cliAgentChatUnavailable:
            return "Codex and Claude chat relay is not available on this Mac yet."
        case .cliModelCatalogUnavailable:
            return "CLI model catalog discovery is not available on this Mac yet."
        }
    }
}

private struct HermesRelayRequestContext {
    let uid: String
    let requestID: String
    let connectionID: String
    let keyData: Data
}

struct HermesRelayKeyStore {
    private let keychain: KeychainStore
    private let account = "settings.chat.hermes.relay.p256.v1"
    private let fallbackCacheKey: String

    init(
        keychain: KeychainStore = KeychainStore(
            service: "com.openburnbar.hermes-relay",
            legacyServices: []
        ),
        fallbackCacheKey: String = "com.openburnbar.hermes-relay.p256.v1"
    ) {
        self.keychain = keychain
        self.fallbackCacheKey = fallbackCacheKey
    }

    func privateKey() throws -> HermesRelayPrivateKey {
        do {
            if let stored = try keychain.string(for: account),
               let data = Data(base64Encoded: stored),
               let key = try? HermesRelayPrivateKey(rawRepresentation: data) {
                return key
            }
            let key = HermesRelayCrypto.generatePrivateKey()
            do {
                try keychain.set(key.rawRepresentation.base64EncodedString(), for: account)
                return key
            } catch {
                AppLogger.network.notice(
                    "hermes_relay_keychain_ephemeral_fallback",
                    metadata: ["error": error.localizedDescription]
                )
                return try cachedFallbackPrivateKey()
            }
        } catch {
            AppLogger.network.notice(
                "hermes_relay_keychain_read_failed_using_ephemeral",
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
            return try HermesRelayPrivateKey(rawRepresentation: data).publicKeyBase64
        } catch {
            AppLogger.network.notice(
                "hermes_relay_keychain_public_key_failed_using_ephemeral",
                metadata: ["error": error.localizedDescription]
            )
            return try cachedFallbackPublicKeyBase64()
        }
    }

    private func cachedFallbackPrivateKey() throws -> HermesRelayPrivateKey {
        let data = RelayEphemeralKeyCache.shared.data(for: fallbackCacheKey) {
            HermesRelayCrypto.generatePrivateKey().rawRepresentation
        }
        return try HermesRelayPrivateKey(rawRepresentation: data)
    }

    private func cachedFallbackPublicKeyBase64() throws -> String? {
        guard let data = RelayEphemeralKeyCache.shared.existingData(for: fallbackCacheKey) else {
            return nil
        }
        return try HermesRelayPrivateKey(rawRepresentation: data).publicKeyBase64
    }
}
