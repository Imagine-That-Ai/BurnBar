import Foundation

public enum HermesRelayAuthenticatedRequestDenyReason: String, Codable, Sendable, Equatable {
    case senderAuthRequired = "sender_auth_required"
    case senderKeyUntrusted = "sender_key_untrusted"
    case senderReplay = "sender_replay"
    case signalIdentityUnverified = "signal_identity_unverified"
}

public enum HermesRelayAuthenticatedRequestError: LocalizedError, Sendable, Equatable {
    case rejected(HermesRelayAuthenticatedRequestDenyReason)

    public var errorDescription: String? {
        switch self {
        case .rejected(let reason):
            return reason.rawValue
        }
    }
}

public struct HermesRelayAuthenticatedSender: Codable, Sendable, Equatable {
    public var publicKeyBase64: String
    public var deviceID: String
    public var peerNodeID: String
    public var counter: Int64
    public var keyID: String

    public init(
        publicKeyBase64: String,
        deviceID: String,
        peerNodeID: String,
        counter: Int64,
        keyID: String
    ) {
        self.publicKeyBase64 = publicKeyBase64
        self.deviceID = deviceID
        self.peerNodeID = peerNodeID
        self.counter = counter
        self.keyID = keyID
    }
}

public struct HermesRelayAuthenticatedRequestTrustContext: Sendable, Equatable {
    public var uid: String
    public var connectionID: String
    public var requestID: String
    public var operation: HermesRelayOperation
    public var sender: HermesRelayAuthenticatedSender

    public init(
        uid: String,
        connectionID: String,
        requestID: String,
        operation: HermesRelayOperation,
        sender: HermesRelayAuthenticatedSender
    ) {
        self.uid = uid
        self.connectionID = connectionID
        self.requestID = requestID
        self.operation = operation
        self.sender = sender
    }
}

public protocol HermesRelaySenderTrustResolving: Sendable {
    func pinnedRelaySenderPublicKeyBase64(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws -> String

    func requireVerifiedSignalIdentity(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws
}

public struct HermesRelayOpenedAuthenticatedRequest: Sendable, Equatable {
    public var encryptedPayload: HermesRelayEncryptedRequestPayload
    public var keyData: Data
    public var sender: HermesRelayAuthenticatedSender

    public init(
        encryptedPayload: HermesRelayEncryptedRequestPayload,
        keyData: Data,
        sender: HermesRelayAuthenticatedSender
    ) {
        self.encryptedPayload = encryptedPayload
        self.keyData = keyData
        self.sender = sender
    }
}

public actor HermesRelayReplayCache {
    private struct SenderReplayState: Codable, Sendable, Equatable {
        var maxCounter: Int64
        var requestIDs: [String: Date]
    }

    private struct PersistentState: Codable, Sendable, Equatable {
        var senders: [String: SenderReplayState]
    }

    private let persistenceURL: URL?
    private let requestIDTTL: TimeInterval
    private let now: @Sendable () -> Date
    private var senders: [String: SenderReplayState]

    public init(
        persistenceURL: URL? = nil,
        requestIDTTL: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.persistenceURL = persistenceURL
        self.requestIDTTL = requestIDTTL
        self.now = now
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let state = try? JSONDecoder().decode(PersistentState.self, from: data) {
            self.senders = state.senders
        } else {
            self.senders = [:]
        }
    }

    public func recordFresh(
        uid: String,
        connectionID: String,
        requestID: String,
        sender: HermesRelayAuthenticatedSender
    ) throws {
        let key = scopeKey(uid: uid, connectionID: connectionID, sender: sender)
        let cutoff = now().addingTimeInterval(-requestIDTTL)
        var state = senders[key] ?? SenderReplayState(maxCounter: -1, requestIDs: [:])
        state.requestIDs = state.requestIDs.filter { $0.value >= cutoff }
        guard sender.counter > state.maxCounter,
              state.requestIDs[requestID] == nil else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderReplay)
        }
        state.maxCounter = sender.counter
        state.requestIDs[requestID] = now()
        senders[key] = state
        try persist()
    }

    public func reset() throws {
        senders.removeAll()
        try persist()
    }

    private func persist() throws {
        guard let persistenceURL else { return }
        let data = try JSONEncoder().encode(PersistentState(senders: senders))
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: persistenceURL, options: [.atomic])
    }

    private func scopeKey(
        uid: String,
        connectionID: String,
        sender: HermesRelayAuthenticatedSender
    ) -> String {
        [
            uid,
            connectionID,
            sender.deviceID,
            sender.peerNodeID,
            sender.keyID
        ]
            .map { Data($0.utf8).base64EncodedString() }
            .joined(separator: ".")
    }
}

public struct HermesRelayAuthenticatedRequestOpener: Sendable {
    private let replayCache: HermesRelayReplayCache
    private let trustResolver: any HermesRelaySenderTrustResolving

    public init(
        replayCache: HermesRelayReplayCache,
        trustResolver: any HermesRelaySenderTrustResolving
    ) {
        self.replayCache = replayCache
        self.trustResolver = trustResolver
    }

    public func open(
        payload: HermesRealtimeRelayPayload,
        uid: String,
        connectionID: String,
        requestID: String,
        operation: HermesRelayOperation,
        recipientPrivateKey: HermesRelayPrivateKey
    ) async throws -> HermesRelayOpenedAuthenticatedRequest {
        guard payload.operation == nil || payload.operation == operation,
              payload.relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3,
              payload.relayEncryption == HermesRelayCrypto.relayEncryptionV3,
              let enc = nonEmpty(payload.enc),
              let wrappedKey = nonEmpty(payload.wrappedKey),
              let payloadCiphertext = nonEmpty(payload.payloadCiphertext),
              let senderPublicKey = nonEmpty(payload.senderPublicKey),
              let senderDeviceID = nonEmpty(payload.senderDeviceId),
              let senderPeerNodeID = nonEmpty(payload.senderPeerNodeId),
              let senderCounter = payload.senderCounter,
              let keyID = nonEmpty(payload.keyId),
              senderCounter >= 0 else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderAuthRequired)
        }

        let sender = HermesRelayAuthenticatedSender(
            publicKeyBase64: senderPublicKey,
            deviceID: senderDeviceID,
            peerNodeID: senderPeerNodeID,
            counter: senderCounter,
            keyID: keyID
        )
        let trustContext = HermesRelayAuthenticatedRequestTrustContext(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            operation: operation,
            sender: sender
        )
        let pinnedPublicKey = try await pinnedSenderPublicKey(for: trustContext)
        guard Self.samePublicKey(senderPublicKey, pinnedPublicKey) else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
        try await verifiedSignalIdentity(for: trustContext)

        let keyAAD = HermesRelayCrypto.authenticatedKeyAAD(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            operation: operation,
            senderDeviceID: senderDeviceID,
            senderPeerNodeID: senderPeerNodeID,
            senderCounter: senderCounter,
            keyID: keyID
        )
        let keyData = try HermesRelayCrypto.openKeyV3(
            encBase64: enc,
            wrappedKeyBase64: wrappedKey,
            privateKey: recipientPrivateKey,
            pinnedSenderPublicKeyBase64: pinnedPublicKey,
            aad: keyAAD
        )

        try await replayCache.recordFresh(
            uid: uid,
            connectionID: connectionID,
            requestID: requestID,
            sender: sender
        )

        let plaintext = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: keyData,
            aad: HermesRelayCrypto.authenticatedRequestAAD(
                uid: uid,
                connectionID: connectionID,
                requestID: requestID,
                operation: operation,
                senderDeviceID: senderDeviceID,
                senderPeerNodeID: senderPeerNodeID,
                senderCounter: senderCounter,
                keyID: keyID
            )
        )
        let encryptedPayload = try JSONDecoder().decode(HermesRelayEncryptedRequestPayload.self, from: plaintext)
        return HermesRelayOpenedAuthenticatedRequest(
            encryptedPayload: encryptedPayload,
            keyData: keyData,
            sender: sender
        )
    }

    private func pinnedSenderPublicKey(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws -> String {
        do {
            return try await trustResolver.pinnedRelaySenderPublicKeyBase64(for: context)
        } catch let error as HermesRelayAuthenticatedRequestError {
            throw error
        } catch {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderKeyUntrusted)
        }
    }

    private func verifiedSignalIdentity(
        for context: HermesRelayAuthenticatedRequestTrustContext
    ) async throws {
        do {
            try await trustResolver.requireVerifiedSignalIdentity(for: context)
        } catch let error as HermesRelayAuthenticatedRequestError {
            throw error
        } catch {
            throw HermesRelayAuthenticatedRequestError.rejected(.signalIdentityUnverified)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else {
            return nil
        }
        return value
    }

    private static func samePublicKey(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsData = Data(base64Encoded: lhs),
              let rhsData = Data(base64Encoded: rhs) else {
            return false
        }
        return lhsData == rhsData
    }
}
