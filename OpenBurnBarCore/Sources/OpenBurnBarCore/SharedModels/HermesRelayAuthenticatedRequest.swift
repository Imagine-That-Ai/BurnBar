import Foundation
#if canImport(Security)
import Security
#endif

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

/// Tamper-resistant anchor for the per-sender replay high-water-mark.
///
/// **Threat closed (T-CRY-03).** The replay cache persists `maxCounter` in a
/// plaintext JSON file. Deleting that file resets every sender's high-water-mark
/// to `-1`, so an attacker who can remove it re-opens the monotonic-counter
/// replay window (already-seen `(counter, requestID)` pairs become acceptable
/// again). The end-to-end signature layer does not stop this — the freshness
/// decision is anchored only in deletable filesystem state.
///
/// **Fix.** Mirror the monotonic `maxCounter` into a second, harder-to-delete
/// store (the Keychain, `WhenUnlockedThisDeviceOnly`, never synced). On load the
/// cache takes the **MAX** of the file value and the anchor and refuses to go
/// backwards, so deleting the JSON file alone cannot lower a sender's
/// high-water-mark. This mirrors ``ControllerKeyPinBacking``: a pure seam over an
/// injectable backing, unit-testable with an in-memory backing on CI runners
/// without a Keychain entitlement; the shipping app always uses the Keychain.
public protocol HermesReplayCounterAnchorBacking: Sendable {
    /// The anchored high-water-mark for `scopeKey`, or `nil` if none / unreadable.
    /// `nil` is treated as "no anchor" (the file value stands) — a missing anchor
    /// must never *lower* a counter, only the MAX with a present anchor can raise it.
    func loadMaxCounter(scopeKey: String) -> Int64?
    /// Persist `maxCounter` for `scopeKey`, monotonically (never lower an existing
    /// anchored value). Best-effort: a failure leaves the file value as the source
    /// of truth and is not fatal to admitting a genuinely fresh request.
    func storeMaxCounter(_ maxCounter: Int64, scopeKey: String)
    /// Drop the anchor for `scopeKey` (used by `reset()` for a deliberate clear).
    func clear(scopeKey: String)
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
    private let counterAnchor: HermesReplayCounterAnchorBacking?
    private var senders: [String: SenderReplayState]

    public init(
        persistenceURL: URL? = nil,
        requestIDTTL: TimeInterval = 24 * 60 * 60,
        counterAnchor: HermesReplayCounterAnchorBacking? = HermesRelayReplayCache.defaultCounterAnchor(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistenceURL = persistenceURL
        self.requestIDTTL = requestIDTTL
        self.counterAnchor = counterAnchor
        self.now = now
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let state = try? JSONDecoder().decode(PersistentState.self, from: data) {
            self.senders = state.senders
        } else {
            self.senders = [:]
        }
        // Fold the Keychain anchor into every known scope: if the file was deleted
        // or rolled back, the anchored high-water-mark wins. We never lower a
        // file value with a missing/lower anchor — only raise it.
        if let counterAnchor {
            for (key, var state) in senders {
                if let anchored = counterAnchor.loadMaxCounter(scopeKey: key),
                   anchored > state.maxCounter {
                    state.maxCounter = anchored
                    senders[key] = state
                }
            }
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
        // Anchor wins even for a scope absent from the (possibly deleted) file:
        // a fresh in-memory `-1` must not silently re-admit counters already seen.
        if let anchored = counterAnchor?.loadMaxCounter(scopeKey: key),
           anchored > state.maxCounter {
            state.maxCounter = anchored
        }
        state.requestIDs = state.requestIDs.filter { $0.value >= cutoff }
        guard sender.counter > state.maxCounter,
              state.requestIDs[requestID] == nil else {
            throw HermesRelayAuthenticatedRequestError.rejected(.senderReplay)
        }
        state.maxCounter = sender.counter
        state.requestIDs[requestID] = now()
        senders[key] = state
        try persist()
        // Mirror the new high-water-mark to the deletion-resistant anchor so a
        // later file deletion cannot silently reset it.
        counterAnchor?.storeMaxCounter(sender.counter, scopeKey: key)
    }

    public func reset() throws {
        let clearedKeys = Array(senders.keys)
        senders.removeAll()
        try persist()
        for key in clearedKeys {
            counterAnchor?.clear(scopeKey: key)
        }
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

extension HermesRelayReplayCache {
    /// Production default: the device Keychain anchor. On platforms without the
    /// Security framework (Linux CI) there is no Keychain, so the anchor is
    /// `nil` and the file value stands alone — the shipping macOS/iOS app always
    /// resolves to the Keychain-backed anchor.
    public static func defaultCounterAnchor() -> HermesReplayCounterAnchorBacking? {
        #if canImport(Security)
        return HermesReplayCounterKeychainAnchorBacking()
        #else
        return nil
        #endif
    }
}

#if canImport(Security)
/// Keychain-backed replay high-water-mark anchor: one
/// `kSecClassGenericPassword` item per `scopeKey`, accessible only
/// `WhenUnlockedThisDeviceOnly` and never synced off device. Stores the raw
/// decimal `maxCounter` so a deleted JSON replay file cannot silently reset it.
public struct HermesReplayCounterKeychainAnchorBacking: HermesReplayCounterAnchorBacking {
    public static let service = "com.openburnbar.hermes.relay-replay-counter-anchor"

    public init() {}

    public func loadMaxCounter(scopeKey: String) -> Int64? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: scopeKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              let value = Int64(text) else {
            // Absent or unreadable: no anchor to apply. A present-but-undecodable
            // item is treated as "no anchor" so a corrupted record can never lower
            // a legitimately higher file value; the file remains the source of truth.
            return nil
        }
        return value
    }

    public func storeMaxCounter(_ maxCounter: Int64, scopeKey: String) {
        // Monotonic: never lower an already-anchored value.
        if let existing = loadMaxCounter(scopeKey: scopeKey), existing >= maxCounter {
            return
        }
        let data = Data(String(maxCounter).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: scopeKey
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(create as CFDictionary, nil)
        }
    }

    public func clear(scopeKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: scopeKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif

/// In-memory replay high-water-mark anchor for tests and non-Keychain platforms.
/// Thread-safe and monotonic — a `store` never lowers an existing value, mirroring
/// the Keychain backing's contract so the fail-closed anchor logic is verifiable
/// without a Keychain entitlement.
public final class InMemoryHermesReplayCounterAnchorBacking: HermesReplayCounterAnchorBacking, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Int64] = [:]

    public init() {}

    public func loadMaxCounter(scopeKey: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return store[scopeKey]
    }

    public func storeMaxCounter(_ maxCounter: Int64, scopeKey: String) {
        lock.lock(); defer { lock.unlock() }
        if let existing = store[scopeKey], existing >= maxCounter { return }
        store[scopeKey] = maxCounter
    }

    public func clear(scopeKey: String) {
        lock.lock(); defer { lock.unlock() }
        store[scopeKey] = nil
    }
}
