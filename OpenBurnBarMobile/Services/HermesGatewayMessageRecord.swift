import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

// MARK: - Hermes Gateway message records
//
// Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural
// decomposition). Pure move — no behavior change.

// MARK: - Hermes Gateway Records
// Moved verbatim from `FunctionsRepository.swift` (tech-debt finding-67) so
// the gateway domain owns its wire records — including
// `HermesGatewayMessageRecord` and its ratchet reply open path
// (`decodedRatchetText(`), which the privacy plaintext scanner pins to this
// file.

/// The sealed gateway message payload schema (MP-27): the agent seals JSON
/// `{text, actionId?, kind?}`; the phone decodes it (never renders the raw bytes)
/// and uses `actionId` to bind an approval detail to the right oversight gate
/// (MP-6). A payload missing `text` is rejected (decode throws → treated as
/// unopenable) so a malformed sealed body never surfaces as a reply.
private struct SealedGatewayPayload: Decodable {
    let text: String
    let actionId: String?
    let kind: String?
}

struct HermesGatewayMessageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let kind: String
    let destinationId: String
    let threadId: String?
    let replyToEventId: String?
    /// Legacy plaintext reply body. Present only on pre-seal (schemaVersion < 2)
    /// docs; sealed docs carry the body in `relayEnvelope.payloadCiphertext`
    /// instead.
    let text: String?
    let attachmentIds: [String]
    let createdAt: String
    let schemaVersion: Int
    /// Sealed reply body (agent→phone). The agent wraps the per-message key to
    /// this phone's relay pubkey; only this device can open it.
    let payloadCiphertext: String?
    let wrappedKey: String?
    let enc: String?
    let relayEncryption: String?
    let relayKeyVersion: Int?
    let signalEnvelopeData: Data?
    let ratchetEnvelope: HermesRatchetEnvelope?
    let ratchetEnvelopeCiphertextBase64: String?
    let ratchetEnvelopeAlgorithm: String?
    /// Plaintext recovered by opening `payloadCiphertext` in the snapshot handler.
    /// Held in-memory only; never persisted. `nil` until opened.
    var resolvedText: String?
    /// The `actionId` carried inside a sealed approval-detail payload (MP-27), used
    /// to bind the decrypted detail to the matching server approval gate (MP-6).
    /// `nil` for ordinary replies. In-memory only; never persisted.
    var resolvedActionId: String?
    /// The optional `kind` discriminator carried inside the sealed payload (e.g.
    /// "approval"). In-memory only; never persisted.
    var resolvedKind: String?
    /// Files recovered from `hermes_gateway_attachments`, downloaded from
    /// Storage, opened on this device, and written into the normal chat
    /// attachment workspace. Held in-memory until the chat service persists the
    /// rendered message.
    var openedAttachments: [HermesAttachment]
    /// Referenced gateway attachments that this device could not open during the
    /// latest hydration attempt. Held in-memory only so the UI can show a truthful
    /// recovery state instead of an empty attachment strip.
    var failedAttachmentIds: [String]
    /// True when this device has PINNED the agent's relay public key for this
    /// client (set in `decodedText` from the device Keychain). Once an agent key is
    /// pinned the pairing is relay-capable, so EVERY reply must arrive sealed — an
    /// unsealed reply is a server downgrade/forgery and its server-supplied
    /// plaintext is never rendered. The pin lives in this device's Keychain, so a
    /// hostile server cannot clear it to re-open a plaintext channel. Defaults to
    /// `false` (no pin → genuine legacy client; the plaintext read fallback stays
    /// allowed for pre-cutoff migration). Held in-memory only; never persisted.
    var requiresSealedReply: Bool

    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let clientId = Self.string(data["clientId"]),
            let kind = Self.string(data["kind"]),
            let destinationId = Self.string(data["destinationId"]),
            let createdAt = Self.string(data["createdAt"])
        else { return nil }
        self.id = id
        self.clientId = clientId
        self.kind = kind
        self.destinationId = destinationId
        self.threadId = Self.string(data["threadId"])
        self.replyToEventId = Self.string(data["replyToEventId"])
        self.text = Self.string(data["text"])
        self.attachmentIds = (data["attachmentIds"] as? [Any])?.compactMap(Self.string) ?? []
        self.createdAt = createdAt
        self.schemaVersion = (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1
        let relayEnvelope = Self.dictionary(data["relayEnvelope"])
        self.payloadCiphertext = Self.string(relayEnvelope?["payloadCiphertext"]) ?? Self.string(data["payloadCiphertext"])
        self.wrappedKey = Self.string(relayEnvelope?["wrappedKey"]) ?? Self.string(data["wrappedKey"])
        self.enc = Self.string(relayEnvelope?["enc"]) ?? Self.string(data["enc"])
        self.relayEncryption = Self.string(relayEnvelope?["relayEncryption"]) ?? Self.string(data["relayEncryption"])
        self.relayKeyVersion =
            (relayEnvelope?["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (relayEnvelope?["relayKeyVersion"] as? Int)
            ?? (data["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (data["relayKeyVersion"] as? Int)
        self.signalEnvelopeData = Self.encodeSignalEnvelope(
            Self.dictionary(data["signalEnvelope"]).map { $0 as NSDictionary }
        )
        let ratchetEnvelope = Self.dictionary(data["ratchetEnvelope"])
        let ratchetHeader = Self.dictionary(ratchetEnvelope?["header"])
        self.ratchetEnvelope = Self.decodeRatchetEnvelope(ratchetEnvelope)
        self.ratchetEnvelopeCiphertextBase64 = Self.string(ratchetEnvelope?["ciphertextBase64"])
        self.ratchetEnvelopeAlgorithm = Self.string(ratchetHeader?["algorithm"])
        self.resolvedText = nil
        self.resolvedActionId = nil
        self.resolvedKind = nil
        self.openedAttachments = []
        self.failedAttachmentIds = []
        self.requiresSealedReply = false
    }

    /// True when the reply carries a sealed body that must be opened with the
    /// phone's relay key (vs. a legacy plaintext doc).
    var isSealed: Bool {
        isSignalSealed || isRelaySealed || isRatchetSealed
    }

    private var isSignalSealed: Bool {
        signalEnvelope?.mode == "transport"
            && signalEnvelope?.binding.scope == "gateway"
            && signalEnvelope?.keyDelivery.signalMessageB64?.isEmpty == false
    }

    private var signalEnvelope: FirestoreGatewaySignalEnvelopeDoc? {
        guard let signalEnvelopeData else { return nil }
        return try? JSONDecoder().decode(FirestoreGatewaySignalEnvelopeDoc.self, from: signalEnvelopeData)
    }

    private var isRelaySealed: Bool {
        (relayEncryption == HermesRelayCrypto.algorithm || relayEncryption == HermesRelayCrypto.relayEncryptionV3)
            && (payloadCiphertext?.isEmpty == false)
            && (wrappedKey?.isEmpty == false)
    }

    private var isRatchetSealed: Bool {
        ratchetEnvelopeAlgorithm == HermesRatchetCrypto.algorithm
            && (ratchetEnvelopeCiphertextBase64?.isEmpty == false)
    }

    /// The body to render: the opened plaintext for sealed docs, otherwise the
    /// legacy plaintext `text` field. `nil` when a sealed doc has not yet been
    /// opened (or could not be opened on this device).
    var displayText: String? {
        if isSealed { return resolvedText }
        // Downgrade protection: once this device pinned the agent's relay key the
        // pairing is relay-capable, so a reply that is NOT sealed is a server
        // downgrade/forgery. Never surface the server-supplied plaintext `text`.
        if requiresSealedReply { return nil }
        return text
    }

    /// True when a reply that MUST be sealed (this device pinned the agent's relay
    /// key) instead arrived unsealed — a server downgrade/forgery this device
    /// refuses to render. Distinct from `isUndecryptableHere`'s sealed-for-another-
    /// device case so the chat surface can show honest, case-specific copy.
    var isRefusedUnsealedReply: Bool {
        requiresSealedReply && !isSealed
    }

    /// True when this reply is sealed for a different paired device (or otherwise
    /// could not be opened on this device): a sealed doc whose `resolvedText`
    /// stayed `nil` after `decodedText`. The chat surface renders a calm,
    /// jargon-free re-pair state for this instead of an empty/"no text" bubble.
    var isUndecryptableHere: Bool {
        (isSealed && resolvedText == nil) || isRefusedUnsealedReply
    }

    /// Calm, jargon-free copy shown when a reply was encrypted for another
    /// device this account paired. Deliberately avoids transport/crypto terms
    /// (no "relay key", "E2EE", "man-in-the-middle") per the copy policy, and
    /// names the recoverable action — re-pair on this device.
    static let sealedForAnotherDeviceText =
        "This reply was sent privately to another of your devices. Reconnect Hermes on this device to read replies here."

    /// Calm, jargon-free copy shown when a reply that should have been private
    /// instead arrived unprotected (a server downgrade this device refuses to
    /// trust). Avoids transport/crypto terms per the copy policy and names the
    /// recoverable action — reconnect to restore a trusted connection.
    static let unverifiedReplyText =
        "This reply couldn't be verified as coming from your agent, so it's hidden. Reconnect Hermes on this device to restore a trusted connection."

    static func attachmentOpenFailureText(count: Int) -> String {
        if count == 1 {
            return "One attachment could not open on this device. Reconnect Hermes here, then try again."
        }
        return "\(count) attachments could not open on this device. Reconnect Hermes here, then try again."
    }

    /// The single source of truth for what the conversation thread should show
    /// for a gateway reply: the opened body, the legacy plaintext, the
    /// re-pair state for a reply this device cannot open, or a benign fallback
    /// for an attachment-only / empty reply. Used by the live chat path and the
    /// Settings hero so the copy never diverges.
    func chatRenderText(
        emptyFallback: String = "Hermes sent a reply through BurnBar Cloud."
    ) -> String {
        // A reply that should have been sealed but arrived unsealed is a server
        // downgrade/forgery: refuse the ENTIRE reply (body and attachments) and
        // show the calm reconnect state — never render any server-supplied content
        // for a client whose agent key this device has pinned.
        if isRefusedUnsealedReply {
            return Self.unverifiedReplyText
        }
        let failedAttachmentText = failedAttachmentIds.isEmpty ? nil : Self.attachmentOpenFailureText(count: failedAttachmentIds.count)
        if let body = displayText?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            if let failedAttachmentText {
                return "\(body)\n\n\(failedAttachmentText)"
            }
            return body
        }
        // Files that already opened on this device render in the bubble; the
        // caption stays neutral rather than implying a re-pair is needed.
        if !openedAttachments.isEmpty {
            let count = openedAttachments.count
            if let failedAttachmentText {
                return "Hermes sent \(count) attachment\(count == 1 ? "" : "s"). \(failedAttachmentText)"
            }
            return "Hermes sent \(count) attachment\(count == 1 ? "" : "s")."
        }
        // A sealed reply this device cannot open (and with no opened files) shows
        // the calm re-pair state, never a blank/"no text" bubble or crypto jargon.
        if isUndecryptableHere {
            if let failedAttachmentText {
                return "\(Self.sealedForAnotherDeviceText)\n\n\(failedAttachmentText)"
            }
            return Self.sealedForAnotherDeviceText
        }
        if let failedAttachmentText {
            return failedAttachmentText
        }
        if !attachmentIds.isEmpty {
            let count = attachmentIds.count
            return "Hermes sent \(count) attachment\(count == 1 ? "" : "s")."
        }
        return emptyFallback
    }

    /// Open the sealed reply body with this phone's relay key, returning a copy of
    /// the record with `resolvedText` populated. Legacy plaintext docs are
    /// returned unchanged. A sealed doc this device cannot open (key mismatch /
    /// envelope sealed for another device) is returned with `resolvedText == nil`
    /// so the caller can show a graceful "sealed for another device" state rather
    /// than crash or render ciphertext.
    func decodedText(
        using keypair: HermesGatewayRelayKeypair,
        uid: String,
        targetClient: HermesGatewayClientRecord? = nil,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore()
    ) -> HermesGatewayMessageRecord {
        var resolved = self
        // Downgrade protection (evaluated for BOTH sealed and unsealed docs): if
        // this device has pinned the agent's relay key for this client, every reply
        // must arrive sealed. The render path then refuses an unsealed reply's
        // server-supplied plaintext (see `requiresSealedReply`). The pin is read
        // from the device Keychain, so a hostile server cannot suppress this gate;
        // `requiresSealedReplies` is fail-CLOSED on a Keychain read error (it treats
        // an unreadable pin as "must seal") so a transient Keychain failure can never
        // re-open the plaintext path.
        //
        // v2 closes the anonymous-sender residual: the wrap is now an authenticated
        // 2-DH KEM, and the open below binds the AGENT's PINNED relay key as the
        // sender. A swapped/forged sender key fails the GCM tag, so a compromised
        // relay can no longer seal a forged reply to this phone's public key.
        resolved.requiresSealedReply = pinStore.requiresSealedReplies(uid: uid, clientId: clientId)
        // Gateway v4 is opened asynchronously by `decodedSignalText`; keep the
        // record sealed (and therefore non-renderable) until that official
        // libsignal session has recovered the private payload.
        if isSignalSealed {
            return resolved
        }
        if isRatchetSealed {
            return decodedRatchetText(uid: uid, targetClient: targetClient, resolved: resolved)
        }
        guard isRelaySealed,
              let payloadCiphertext,
              let wrappedKey else {
            return resolved
        }
        guard let pinnedAgentKey = pinStore.pinnedKey(uid: uid, clientId: clientId) else {
            resolved.resolvedText = nil
            return resolved
        }
        do {
            let keyAAD = try HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: id)
            let keyData: Data
            if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersion {
                guard relayEncryption == HermesRelayCrypto.algorithm else { return resolved }
                keyData = try HermesRelayCrypto.unwrapSymmetricKey(
                    wrappedKey,
                    privateKey: keypair.privateKey,
                    aad: keyAAD,
                    senderPublicKeyBase64: pinnedAgentKey
                )
            } else if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
                guard relayEncryption == HermesRelayCrypto.relayEncryptionV3,
                      let enc,
                      !enc.isEmpty else { return resolved }
                keyData = try HermesRelayCrypto.openKeyV3(
                    encBase64: enc,
                    wrappedKeyBase64: wrappedKey,
                    privateKey: keypair.privateKey,
                    pinnedSenderPublicKeyBase64: pinnedAgentKey,
                    aad: keyAAD
                )
            } else {
                return resolved
            }
            let plaintext = try HermesRelayCrypto.openBase64(
                ciphertext: payloadCiphertext,
                keyData: keyData,
                aad: try HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
            )
            // MP-27: the agent seals JSON {text, actionId?, kind?}; decode it (never
            // render the raw bytes, which would show literal `{"text":...}`). A
            // payload without `text` fails to decode and is treated as unopenable.
            if let payload = try? JSONDecoder().decode(SealedGatewayPayload.self, from: plaintext) {
                resolved.resolvedText = payload.text
                resolved.resolvedActionId = payload.actionId
                resolved.resolvedKind = payload.kind
            } else {
                resolved.resolvedText = nil
            }
        } catch {
            resolved.resolvedText = nil
        }
        return resolved
    }

    /// Open a Gateway v4 reply with the durable official libsignal session. This
    /// remains separate from the synchronous legacy decoder because the session
    /// actor serializes libsignal store access across snapshot callbacks.
    func decodedSignalText(
        uid: String,
        targetClient: HermesGatewayClientRecord?
    ) async -> HermesGatewayMessageRecord {
        guard
            isSignalSealed,
            let targetClient,
            targetClient.canSignalToAgent,
            let signalEnvelope,
            let slotId = signalEnvelope.binding.slotId,
            let envelopeData = try? JSONEncoder().encode(signalEnvelope)
        else { return self }
        var resolved = self
        do {
            let deviceId = await MainActor.run { MobileDeviceIdentity.loadOrCreateDeviceId() }
            let session = try HermesGatewaySignalRuntime.session(
                uid: uid,
                targetClient: targetClient,
                deviceId: deviceId
            )
            let plaintext = try await session.provider.open(
                envelopeData: envelopeData,
                uid: uid,
                clientId: clientId,
                slotId: slotId
            )
            let payload = try JSONDecoder().decode(SealedGatewayPayload.self, from: plaintext)
            resolved.resolvedText = payload.text
            resolved.resolvedActionId = payload.actionId
            resolved.resolvedKind = payload.kind
        } catch {
            resolved.resolvedText = nil
            resolved.resolvedActionId = nil
            resolved.resolvedKind = nil
        }
        return resolved
    }

    private func decodedRatchetText(
        uid: String,
        targetClient: HermesGatewayClientRecord?,
        resolved initial: HermesGatewayMessageRecord
    ) -> HermesGatewayMessageRecord {
        var resolved = initial
        guard let envelope = ratchetEnvelope,
              let targetClient,
              targetClient.canRatchetToAgent,
              let agentIdentity = targetClient.agentRatchetIdentityPublicKey,
              let agentSigning = targetClient.agentRatchetSigningPublicKey,
              let agentSignedPreKey = targetClient.agentRatchetSignedPreKeyPublicKey,
              let agentSignedPreKeyID = targetClient.agentRatchetSignedPreKeyId,
              let agentSignature = targetClient.agentRatchetSignedPreKeySignature,
              HermesGatewayRatchetChatLane.verifySignedPreKey(
                signingPublicKeyBase64: agentSigning,
                identityPublicKeyBase64: agentIdentity,
                signedPreKeyPublicKeyBase64: agentSignedPreKey,
                signedPreKeyID: agentSignedPreKeyID,
                signatureBase64: agentSignature
              )
        else {
            resolved.resolvedText = nil
            return resolved
        }
        do {
            let local = try HermesGatewayRatchetPrekeyStore.loadOrCreatePrivateBundle()
            guard local.identityPublicKeyBase64 == targetClient.phoneRatchetIdentityPublicKey,
                  local.signedPreKeyPublicKeyBase64 == targetClient.phoneRatchetSignedPreKeyPublicKey else {
                resolved.resolvedText = nil
                return resolved
            }
            var state: HermesRatchetSessionState
            if let existing = try HermesGatewayRatchetSessionStore.load(sessionID: envelope.header.sessionID) {
                state = existing
            } else {
                guard envelope.header.senderDeviceID.hasPrefix("agent:") else {
                    resolved.resolvedText = nil
                    return resolved
                }
                let sharedSecret = try HermesGatewayRatchetChatLane.responderSharedSecret(
                    uid: uid,
                    clientId: clientId,
                    initiatorRole: .agent,
                    localIdentityPrivateKeyBase64: local.identityPrivateKeyBase64,
                    localSignedPreKeyPrivateKeyBase64: local.signedPreKeyPrivateKeyBase64,
                    localIdentityPublicKeyBase64: local.identityPublicKeyBase64,
                    localSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                    remoteIdentityPublicKeyBase64: agentIdentity,
                    remoteSignedPreKeyPublicKeyBase64: agentSignedPreKey,
                    remoteInitialRatchetPublicKeyBase64: envelope.header.ratchetPublicKeyBase64
                )
                state = try HermesRatchetCrypto.responderState(
                    sessionID: envelope.header.sessionID,
                    localDeviceID: envelope.header.receiverDeviceID,
                    remoteDeviceID: envelope.header.senderDeviceID,
                    sharedSecret: sharedSecret,
                    localInitialRatchetKeyPair: local.signedPreKeyPair
                )
            }
            let plaintext = try HermesRatchetCrypto.decrypt(
                envelope,
                state: &state,
                associatedData: try HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
            )
            try HermesGatewayRatchetSessionStore.save(state)
            try HermesGatewayRatchetSessionStore.saveCurrentChatSessionID(state.sessionID, uid: uid, clientId: clientId)
            if let payload = try? JSONDecoder().decode(SealedGatewayPayload.self, from: plaintext) {
                resolved.resolvedText = payload.text
                resolved.resolvedActionId = payload.actionId
                resolved.resolvedKind = payload.kind
            } else {
                resolved.resolvedText = nil
            }
        } catch {
            resolved.resolvedText = nil
        }
        return resolved
    }

    func withOpenedAttachments(_ attachments: [HermesAttachment]) -> HermesGatewayMessageRecord {
        var copy = self
        copy.openedAttachments = attachments
        copy.failedAttachmentIds = []
        return copy
    }

    func withAttachmentHydration(opened attachments: [HermesAttachment], failedAttachmentIds: [String]) -> HermesGatewayMessageRecord {
        var copy = self
        copy.openedAttachments = attachments
        copy.failedAttachmentIds = failedAttachmentIds
        return copy
    }

    static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }

    static func dictionary(_ raw: Any?) -> [String: Any]? {
        switch raw {
        case let dict as [String: Any]:
            return dict
        case let dict as NSDictionary:
            return dict as? [String: Any]
        default:
            return nil
        }
    }

    static func decodeRatchetEnvelope(_ raw: [String: Any]?) -> HermesRatchetEnvelope? {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(HermesRatchetEnvelope.self, from: data)
    }

    static func decodeSignalEnvelope(_ raw: NSDictionary?) -> FirestoreGatewaySignalEnvelopeDoc? {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw)
        else { return nil }
        return try? JSONDecoder().decode(FirestoreGatewaySignalEnvelopeDoc.self, from: data)
    }

    static func encodeSignalEnvelope(_ raw: NSDictionary?) -> Data? {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw)
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: raw)
    }
}

enum HermesGatewayMessageResolver {
    static let defaultThreadID = "burnbar-ios-e2e"

    static func newestReply(
        for event: HermesGatewayQueuedEvent,
        in messages: [HermesGatewayMessageRecord],
        threadID: String = defaultThreadID,
        targetClientId: String? = nil,
        pendingEventSentAt: Date? = nil
    ) -> HermesGatewayMessageRecord? {
        let resolvedTargetClientId = nonEmpty(targetClientId) ?? nonEmpty(event.targetClientId)
        if let exactReply = messages.first(where: {
            $0.replyToEventId == event.id && matchesTarget($0, targetClientId: resolvedTargetClientId)
        }) {
            return exactReply
        }

        return messages.first { message in
            let hasThreadMatch = message.threadId == threadID
            let canUseSealedTimeFallback = message.isSealed && message.threadId == nil && pendingEventSentAt != nil
            guard hasThreadMatch || canUseSealedTimeFallback else { return false }
            guard matchesTarget(message, targetClientId: resolvedTargetClientId) else { return false }
            guard let pendingEventSentAt else { return true }
            guard let createdAt = gatewayDate(from: message.createdAt) else { return false }
            return createdAt >= pendingEventSentAt
        }
    }

    static func newestThreadReply(
        in messages: [HermesGatewayMessageRecord],
        threadID: String = defaultThreadID,
        targetClientId: String? = nil
    ) -> HermesGatewayMessageRecord? {
        messages.first { message in
            guard message.threadId == threadID || (message.isSealed && message.threadId == nil) else { return false }
            guard matchesTarget(message, targetClientId: nonEmpty(targetClientId)) else { return false }
            // A sealed reply is selectable even before it is opened — the snapshot
            // handler opens it and renders `displayText`. Legacy docs gate on the
            // plaintext `text`. Both directions still honor attachment-only replies.
            return message.isSealed
                || message.isRefusedUnsealedReply
                || message.displayText?.isEmpty == false
                || !message.attachmentIds.isEmpty
        }
    }

    static func wasCreatedWhileListening(
        _ reply: HermesGatewayMessageRecord,
        listenerStartedAt: Date?,
        clockSkewGraceInterval: TimeInterval = 30
    ) -> Bool {
        guard let listenerStartedAt,
              let createdAt = gatewayDate(from: reply.createdAt)
        else { return false }
        return createdAt >= listenerStartedAt.addingTimeInterval(-clockSkewGraceInterval)
    }

    private static func gatewayDate(from raw: String) -> Date? {
        ParsePrimitives.gatewayDate(from: raw)
    }

    private static func matchesTarget(_ message: HermesGatewayMessageRecord, targetClientId: String?) -> Bool {
        guard let targetClientId else { return true }
        return message.clientId == targetClientId
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

