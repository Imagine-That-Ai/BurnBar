import CryptoKit
import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

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
        isRelaySealed || isRatchetSealed
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
            let keyAAD = HermesRelayCrypto.gatewayMessageKeyAAD(uid: uid, clientId: clientId, messageId: id)
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
                aad: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
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
                associatedData: HermesRelayCrypto.gatewayMessageAAD(uid: uid, clientId: clientId, messageId: id)
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) call it from their own files.
struct FirebaseCallablePayload: @unchecked Sendable {
    let rawValue: NSDictionary

    init(_ payload: [String: Any]) {
        self.rawValue = Self.bridgeDictionary(payload)
    }

    private static func bridgeDictionary(_ dictionary: [String: Any]) -> NSDictionary {
        var bridged: [String: Any] = [:]
        for (key, value) in dictionary {
            bridged[key] = bridgeValue(value)
        }
        return NSDictionary(dictionary: bridged)
    }

    private static func bridgeArray(_ array: [Any]) -> NSArray {
        NSArray(array: array.map(bridgeValue))
    }

    private static func bridgeValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return bridgeDictionary(dictionary)
        }
        if let array = value as? [Any] {
            return bridgeArray(array)
        }
        if let string = value as? String {
            return string as NSString
        }
        if let number = value as? NSNumber {
            return number
        }
        if let bool = value as? Bool {
            return NSNumber(value: bool)
        }
        if let int = value as? Int {
            return NSNumber(value: int)
        }
        if let double = value as? Double {
            return NSNumber(value: double)
        }
        if let float = value as? Float {
            return NSNumber(value: float)
        }
        return value
    }
}

/// Single source of truth for the primitive coercions that the untyped
/// `[String: Any]` Firebase boundary needs all over this file.
///
/// Before this existed the same `string(_:)` switch was hand-copied into four
/// model parsers and the `gatewayDate(from:)` ISO-8601 decode was copied into
/// three more — each `gatewayDate` call also allocated two fresh
/// `ISO8601DateFormatter`s. The formatters are expensive to build, so they are
/// cached here once. The per-type `string`/`gatewayDate` helpers now forward to
/// these so there is one behaviour to reason about and one place to fix.
///
/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) parse with it from their
/// own files.
enum ParsePrimitives {
    /// Reused across every gateway-date parse. `ISO8601DateFormatter` is
    /// thread-safe for `date(from:)`, so a single shared instance is safe even
    /// though this file spans `@MainActor` and `Sendable` types.
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601 = ISO8601DateFormatter()

    /// Coerce a JSON-bridged value into a non-empty `String`, tolerating the
    /// `NSString`/`NSNumber` forms that Firebase callable payloads surface.
    static func string(_ raw: Any?) -> String? {
        switch raw {
        case let value as String where !value.isEmpty:
            return value
        case let value as NSString where value.length > 0:
            return value as String
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    /// Decode a gateway ISO-8601 timestamp, preferring fractional seconds and
    /// falling back to whole-second form.
    static func gatewayDate(from raw: String) -> Date? {
        if let date = fractionalISO8601.date(from: raw) { return date }
        return plainISO8601.date(from: raw)
    }
}

/// Internal (not `private`) since the per-domain API splits of
/// `FunctionsRepository` (tech-debt finding-67) call it from their own files.
final class FirebaseCallableExecutor: @unchecked Sendable {
    private let callable: HTTPSCallable

    init(_ callable: HTTPSCallable) {
        self.callable = callable
    }

    func call(_ payload: FirebaseCallablePayload) async throws -> HTTPSCallableResult {
        try await callable.call(payload.rawValue)
    }

    /// Typed callable invocation that keeps the request `Encodable` and decodes
    /// the response `Decodable` while preserving the failure context that a bare
    /// `try? JSONDecoder().decode(...)` throws away.
    ///
    /// On a malformed response this surfaces the underlying `DecodingError`
    /// (key path, type mismatch) through ``FunctionsError/responseDecodingFailed``
    /// instead of collapsing it into an opaque ``FunctionsError/decodingFailed``.
    func call<Req: Encodable, Res: Decodable>(_ request: Req) async throws -> Res {
        let requestObject = try Self.encodeToJSONObject(request)
        let result = try await call(FirebaseCallablePayload(requestObject))
        return try Self.decodeResponse(Res.self, from: result.data)
    }

    /// Build the callable for `name`, then make the typed request above. Mirrors
    /// the `functionsClient().httpsCallable(name)` + `.call(...)` boilerplate that
    /// is repeated for every endpoint in this file.
    static func call<Req: Encodable, Res: Decodable>(
        _ name: String,
        _ request: Req,
        using functions: Functions
    ) async throws -> Res {
        try await FirebaseCallableExecutor(functions.httpsCallable(name)).call(request)
    }

    /// Encode an `Encodable` request into the JSON-object dictionary that the
    /// callable payload bridge expects.
    static func encodeToJSONObject<Req: Encodable>(_ request: Req) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FunctionsError.responseDecodingFailed(
                "Request \(Req.self) did not encode to a JSON object."
            )
        }
        return object
    }

    /// Decode a callable's `result.data` into `Res`, surfacing `DecodingError`
    /// context (rather than swallowing it) when the cloud response is malformed.
    static func decodeResponse<Res: Decodable>(_ type: Res.Type, from raw: Any?) throws -> Res {
        guard let object = raw as? [String: Any],
              let sanitized = FirestoreRepository.shared.sanitizeForJSON(object) as? [String: Any] else {
            throw FunctionsError.responseDecodingFailed(
                "Cloud response for \(Res.self) was not a JSON object."
            )
        }
        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: sanitized)
        } catch {
            throw FunctionsError.responseDecodingFailed(
                "Cloud response for \(Res.self) was not serializable: \(error)"
            )
        }
        do {
            return try JSONDecoder().decode(Res.self, from: jsonData)
        } catch let decodingError as DecodingError {
            throw FunctionsError.responseDecodingFailed(
                Self.describe(decodingError, for: Res.self)
            )
        } catch {
            throw FunctionsError.responseDecodingFailed(
                "Failed to decode \(Res.self): \(error)"
            )
        }
    }

    /// Render a `DecodingError` into a stable, log-safe sentence that names the
    /// failing key path and reason without leaking the decoded payload.
    private static func describe<Res>(_ error: DecodingError, for type: Res.Type) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue)
            return keys.isEmpty ? "<root>" : keys.joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "Decoding \(Res.self) failed: missing key '\(key.stringValue)' at \(path(context))."
        case let .typeMismatch(expected, context):
            return "Decoding \(Res.self) failed: type mismatch (expected \(expected)) at \(path(context))."
        case let .valueNotFound(expected, context):
            return "Decoding \(Res.self) failed: missing value (expected \(expected)) at \(path(context))."
        case let .dataCorrupted(context):
            return "Decoding \(Res.self) failed: corrupted data at \(path(context)) — \(context.debugDescription)"
        @unknown default:
            return "Decoding \(Res.self) failed: \(error)"
        }
    }
}

// MARK: - Functions Client Provider

/// Lazily builds and caches the shared `Functions` client exactly the way
/// `FunctionsRepository.functionsClient()` always did, so every per-domain
/// API split out of the repository (tech-debt finding-67) keeps the same
/// single-lazy-client + fail-before-Firebase-configures behavior.
@MainActor
final class FunctionsClientProvider {
    private var cachedFunctions: Functions?

    func client() throws -> Functions {
        if let cachedFunctions {
            return cachedFunctions
        }
        guard FirebaseApp.app() != nil else {
            throw FunctionsError.firebaseUnavailable
        }
        let functions = Functions.functions()
        cachedFunctions = functions
        return functions
    }
}

// MARK: - Functions Repository

/// Facade over the Firebase callable surface. The provider-account,
/// StoreKit-entitlement, Pi-pairing, conversation-search, and Hermes Gateway
/// domains live in their own API objects (`ProviderAccountsAPI`,
/// `EntitlementsAPI`, `PiPairingAPI`, `ConversationSearchAPI`,
/// `HermesGatewayAPI` — tech-debt finding-67); this type forwards to them so
/// every existing call site keeps compiling unchanged. The privacy plaintext
/// scanner (scripts/privacy/scan-chat-cloud-plaintext.mjs) still pins symbols
/// to this file: keep the conversation-query forwarder and its static decode
/// forwarder below in that order (the scanner anchors a no-projectName rule
/// between their signatures, matched by first occurrence — never repeat those
/// signature strings above the forwarders), and keep the gateway seal entry
/// points (the sealGatewayEvent* statics) defined on this type, until the
/// scanner pins migrate to the per-domain files in their own PR. The Hermes
/// host-pairing callables delegate to `HermesGatewayAPI` with the rest of
/// the Hermes domain.
@MainActor
final class FunctionsRepository: HermesGatewayRepository {
    static let shared = FunctionsRepository()

    private let clientProvider: FunctionsClientProvider

    /// Per-domain callable APIs. New call sites may depend on these (or their
    /// protocols) directly instead of the whole repository.
    let providerAccounts: ProviderAccountsAPI
    let entitlements: EntitlementsAPI
    let piPairing: PiPairingAPI
    let conversationSearch: ConversationSearchAPI
    let hermesGateway: HermesGatewayAPI

    init() {
        let clientProvider = FunctionsClientProvider()
        self.clientProvider = clientProvider
        self.providerAccounts = ProviderAccountsAPI(client: clientProvider)
        self.entitlements = EntitlementsAPI(client: clientProvider)
        self.piPairing = PiPairingAPI(client: clientProvider)
        self.conversationSearch = ConversationSearchAPI(client: clientProvider)
        self.hermesGateway = HermesGatewayAPI(client: clientProvider)
    }

    // MARK: Provider accounts (delegates to ProviderAccountsAPI)

    func connectProviderCredential(provider: String, credential: String, kind: CredentialKind) async throws -> ProviderConnectionDoc {
        try await providerAccounts.connectProviderCredential(provider: provider, credential: credential, kind: kind)
    }

    func connectProviderAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil,
        metadata: ProviderAccountConnectMetadata? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectProviderAccount(
            providerID: providerID,
            credential: credential,
            kind: kind,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName,
            metadata: metadata
        )
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectHostedQuotaAccount(
            providerID: providerID,
            credential: credential,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func connectSelfHostedQuotaAccount(
        providerID: ProviderID,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectSelfHostedQuotaAccount(
            providerID: providerID,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func deleteProviderCredential(provider: String) async throws {
        try await providerAccounts.deleteProviderCredential(provider: provider)
    }

    func refreshProviderQuota(provider: String) async throws {
        try await providerAccounts.refreshProviderQuota(provider: provider)
    }

    func refreshProviderAccountQuota(accountID: String) async throws -> ProviderQuotaSnapshot {
        try await providerAccounts.refreshProviderAccountQuota(accountID: accountID)
    }

    func connectHostedQuotaAccount(
        providerID: ProviderID,
        credential: String,
        kind: CredentialKind,
        label: String?,
        accountID: String? = nil,
        sourceDeviceID: String? = nil,
        deviceDisplayName: String? = nil
    ) async throws -> ProviderAccountDoc {
        try await providerAccounts.connectHostedQuotaAccount(
            providerID: providerID,
            credential: credential,
            kind: kind,
            label: label,
            accountID: accountID,
            sourceDeviceID: sourceDeviceID,
            deviceDisplayName: deviceDisplayName
        )
    }

    func deleteHostedQuotaCredentials(accountID: String = "codex_default") async throws {
        try await providerAccounts.deleteHostedQuotaCredentials(accountID: accountID)
    }

    func updateProviderAccount(accountID: String, label: String? = nil, isDefault: Bool? = nil, disabled: Bool? = nil) async throws -> ProviderAccountDoc {
        try await providerAccounts.updateProviderAccount(accountID: accountID, label: label, isDefault: isDefault, disabled: disabled)
    }

    func deleteProviderAccount(accountID: String) async throws {
        try await providerAccounts.deleteProviderAccount(accountID: accountID)
    }

    func rebuildUsageRollups(force: Bool = false) async throws {
        try await providerAccounts.rebuildUsageRollups(force: force)
    }

    // MARK: Conversation search (delegates to ConversationSearchAPI)

    func searchStreams(query: String, limit: Int = 25) async throws -> [StreamSearchHit] {
        try await conversationSearch.searchStreams(query: query, limit: limit)
    }

    func searchEncryptedConversationIndex(
        tokenHashes: [String],
        semanticHashes: [String] = [],
        limit: Int = 25
    ) async throws -> [CloudConversationSearchHit] {
        try await conversationSearch.searchEncryptedConversationIndex(
            tokenHashes: tokenHashes,
            semanticHashes: semanticHashes,
            limit: limit
        )
    }

    /// Forwards to `ConversationSearchAPI.queryConversations`. PRIVACY: this
    /// forwarder is the chokepoint the privacy plaintext scanner pins for the
    /// "no `projectName` filter" rule — server-side filters stay operational
    /// facets only; project/path/title/body search must use
    /// `searchEncryptedConversationIndex` with client-keyed hashes.
    func queryConversations(
        providers: [String] = [],
        models: [String] = [],
        deviceId: String? = nil,
        sourceType: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        sort: String = "updatedAt",
        direction: String = "desc",
        limit: Int = 30,
        cursorDocId: String? = nil,
        includeAggregates: Bool = true
    ) async throws -> ConversationQueryResponse {
        try await conversationSearch.queryConversations(
            providers: providers,
            models: models,
            deviceId: deviceId,
            sourceType: sourceType,
            dateFrom: dateFrom,
            dateTo: dateTo,
            sort: sort,
            direction: direction,
            limit: limit,
            cursorDocId: cursorDocId,
            includeAggregates: includeAggregates
        )
    }

    static func decodeConversationQueryResponse(_ raw: Any?) throws -> ConversationQueryResponse {
        try ConversationSearchAPI.decodeConversationQueryResponse(raw)
    }

    func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL {
        try await conversationSearch.encryptedSessionBlobDownloadURL(storagePath: storagePath)
    }

    func uploadProviderQuotaSnapshot(_ snapshot: ProviderQuotaSnapshot) async throws -> ProviderQuotaSnapshot {
        try await providerAccounts.uploadProviderQuotaSnapshot(snapshot)
    }

    // MARK: Hermes host pairing (delegates to HermesGatewayAPI)

    func createHermesPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> HermesPairingSessionRecord {
        try await hermesGateway.createHermesPairing(
            deviceId: deviceId,
            platform: platform,
            displayName: displayName
        )
    }

    func completeHermesPairing(
        pairingId: String,
        code: String,
        connectionId: String? = nil,
        displayName: String,
        endpointURL: String,
        advertisedModel: String? = nil,
        capabilities: [String] = ["chat_completions"]
    ) async throws -> HermesConnectionRecord {
        try await hermesGateway.completeHermesPairing(
            pairingId: pairingId,
            code: code,
            connectionId: connectionId,
            displayName: displayName,
            endpointURL: endpointURL,
            advertisedModel: advertisedModel,
            capabilities: capabilities
        )
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        try await hermesGateway.listHermesConnections()
    }

    func revokeHermesConnection(connectionId: String) async throws {
        try await hermesGateway.revokeHermesConnection(connectionId: connectionId)
    }

    func revokeRemoteMcpClient(clientID: String) async throws {
        try await hermesGateway.revokeRemoteMcpClient(clientID: clientID)
    }

    // MARK: Hermes Gateway platform adapter (delegates to HermesGatewayAPI)

    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = nil,
        destinationId: String = "burnbar:home",
        scopes: [String] = [
            "hermes.gateway.read",
            "hermes.gateway.write",
            "hermes.gateway.manage"
        ],
        phoneRelayPublicKey: String? = nil,
        phoneRelayKeyVersion: Int? = nil,
        phoneRelayEncryption: String? = nil,
        phoneRatchetPrekeyBundle: HermesGatewayRatchetPrekeyBundle? = nil
    ) async throws -> HermesGatewayClientRecord {
        try await hermesGateway.approveHermesGatewayDeviceGrant(
            userCode: userCode,
            displayName: displayName,
            destinationId: destinationId,
            scopes: scopes,
            phoneRelayPublicKey: phoneRelayPublicKey,
            phoneRelayKeyVersion: phoneRelayKeyVersion,
            phoneRelayEncryption: phoneRelayEncryption,
            phoneRatchetPrekeyBundle: phoneRatchetPrekeyBundle
        )
    }

    func listHermesGatewayClients(includeRevoked: Bool = false) async throws -> [HermesGatewayClientRecord] {
        try await hermesGateway.listHermesGatewayClients(includeRevoked: includeRevoked)
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        try await hermesGateway.revokeHermesGatewayClient(clientId: clientId)
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await hermesGateway.enqueueHermesGatewayEvent(
            text: text,
            destinationId: destinationId,
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await hermesGateway.enqueueHermesGatewayModelSwitch(
            modelId: modelId,
            destinationId: destinationId,
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId,
            senderDisplayName: senderDisplayName
        )
    }

    /// Test-visible entry point preserved in place; the implementation moved
    /// to `GatewayEventSealer.sealGatewayEventPayload` (mechanical extraction,
    /// tech-debt finding-67). Signature, defaults, and behavior are unchanged.
    nonisolated static func sealGatewayEventPayload(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord?,
        uid: String,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore(),
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        try GatewayEventSealer.sealGatewayEventPayload(
            into: &payload,
            text: text,
            senderDisplayName: senderDisplayName,
            threadId: threadId,
            modelId: modelId,
            targetClient: targetClient,
            uid: uid,
            pinStore: pinStore,
            kind: kind,
            extraSealedFields: extraSealedFields
        )
    }

    nonisolated static func sealGatewayEventRatchetPayload(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord,
        uid: String,
        pinStore: HermesGatewayAgentKeyPinStore,
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        let localRelayKeypair = try HermesGatewayRelayKeypair.loadOrCreate()
        guard targetClient.isPairedWithThisDevice(relayPublicKeyBase64: localRelayKeypair.relayPublicKeyBase64) else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        guard targetClient.canSealToAgent,
              let relayPublicKey = targetClient.relayPublicKey,
              pinStore.verifyOrPin(agentPublicKeyBase64: relayPublicKey, uid: uid, clientId: targetClient.id).allowsSeal,
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
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        let local = try HermesGatewayRatchetPrekeyStore.loadOrCreatePrivateBundle()
        guard local.identityPublicKeyBase64 == targetClient.phoneRatchetIdentityPublicKey,
              local.signedPreKeyPublicKeyBase64 == targetClient.phoneRatchetSignedPreKeyPublicKey else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        let destinationId = GatewayEventSealer.gatewayDestinationID(in: payload)
        let eventId = "evt_\(UUID().uuidString.lowercased())"
        let replayCounter = try GatewayEventSealer.nextGatewayEventReplayCounter(
            uid: uid,
            clientId: targetClient.id,
            phoneRelayPublicKey: localRelayKeypair.relayPublicKeyBase64
        )
        var sealedPayload: [String: Any] = [
            "text": text,
            "destinationId": destinationId,
            "replayCounter": replayCounter,
            "senderDisplayName": senderDisplayName,
            "threadId": threadId
        ]
        if let modelId, !modelId.isEmpty {
            sealedPayload["modelId"] = modelId
        }
        if let k = kind, !k.isEmpty {
            sealedPayload["kind"] = k
        }
        try GatewayEventSealer.applyExtraSealedFields(extraSealedFields, to: &sealedPayload)
        let plaintext = try JSONSerialization.data(withJSONObject: sealedPayload)
        let phoneDeviceID = try HermesGatewayRatchetChatLane.deviceID(prefix: "phone", identityPublicKeyBase64: local.identityPublicKeyBase64)
        let agentDeviceID = try HermesGatewayRatchetChatLane.deviceID(prefix: "agent", identityPublicKeyBase64: agentIdentity)
        var state: HermesRatchetSessionState
        if let sessionID = try HermesGatewayRatchetSessionStore.loadCurrentChatSessionID(uid: uid, clientId: targetClient.id),
           let existing = try HermesGatewayRatchetSessionStore.load(sessionID: sessionID) {
            state = existing
        } else {
            let initialRatchet = HermesRatchetCrypto.generateKeyPair()
            let sessionID = try HermesGatewayRatchetChatLane.sessionID(
                uid: uid,
                clientId: targetClient.id,
                initiatorRole: .phone,
                initiatorIdentityPublicKeyBase64: local.identityPublicKeyBase64,
                responderIdentityPublicKeyBase64: agentIdentity,
                initiatorSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                responderSignedPreKeyPublicKeyBase64: agentSignedPreKey,
                initiatorInitialRatchetPublicKeyBase64: initialRatchet.publicKeyBase64
            )
            let sharedSecret = try HermesGatewayRatchetChatLane.initiatorSharedSecret(
                uid: uid,
                clientId: targetClient.id,
                initiatorRole: .phone,
                localIdentityPrivateKeyBase64: local.identityPrivateKeyBase64,
                localSignedPreKeyPublicKeyBase64: local.signedPreKeyPublicKeyBase64,
                localInitialRatchetKeyPair: initialRatchet,
                remoteIdentityPublicKeyBase64: agentIdentity,
                remoteSignedPreKeyPublicKeyBase64: agentSignedPreKey
            )
            state = try HermesRatchetCrypto.initiatorState(
                sessionID: sessionID,
                localDeviceID: phoneDeviceID,
                remoteDeviceID: agentDeviceID,
                sharedSecret: sharedSecret,
                remoteInitialRatchetPublicKeyBase64: agentSignedPreKey,
                localInitialRatchetKeyPair: initialRatchet
            )
        }
        let envelope = try HermesRatchetCrypto.encrypt(
            plaintext: plaintext,
            state: &state,
            associatedData: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        )
        try HermesGatewayRatchetSessionStore.save(state)
        try HermesGatewayRatchetSessionStore.saveCurrentChatSessionID(state.sessionID, uid: uid, clientId: targetClient.id)
        let envelopeData = try JSONEncoder().encode(envelope)
        guard let envelopeJSON = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any] else {
            throw HermesRatchetError.invalidEnvelope
        }
        payload["eventId"] = eventId
        payload["ratchetEnvelope"] = envelopeJSON
    }

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws {
        try await hermesGateway.setHermesGatewayOversightMode(
            clientId: clientId,
            mode: mode,
            targetClient: targetClient
        )
    }

    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        try await hermesGateway.respondHermesGatewayApproval(
            approvalId: approvalId,
            approve: approve,
            deviceId: deviceId
        )
    }

    func enqueueHermesGatewayApprovalDecision(
        approvalId: String,
        approve: Bool,
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil
    ) async throws {
        try await hermesGateway.enqueueHermesGatewayApprovalDecision(
            approvalId: approvalId,
            approve: approve,
            targetClient: targetClient,
            targetClientId: targetClientId
        )
    }

    // MARK: Pi Agent host pairing (delegates to PiPairingAPI)

    func createPiAgentPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> PiPairingSessionRecord {
        try await piPairing.createPiAgentPairing(
            deviceId: deviceId,
            platform: platform,
            displayName: displayName
        )
    }

    func completePiAgentPairing(
        pairingId: String,
        code: String,
        connectionId: String? = nil,
        displayName: String,
        mode: PiConnectionMode = .directURL,
        endpointURL: String,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        redisURL: String? = nil,
        capabilities: [String] = ["chat_completions"],
        instances: [PiAgentInstanceRecord] = [],
        models: [PiAgentRuntimeModelOption] = [],
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        realtimeRelayURL: String? = nil,
        realtimeRelayStatus: String? = nil,
        deviceId: String? = nil
    ) async throws -> PiConnectionRecord {
        try await piPairing.completePiAgentPairing(
            pairingId: pairingId,
            code: code,
            connectionId: connectionId,
            displayName: displayName,
            mode: mode,
            endpointURL: endpointURL,
            advertisedModel: advertisedModel,
            selectedInstanceID: selectedInstanceID,
            redisURL: redisURL,
            capabilities: capabilities,
            instances: instances,
            models: models,
            relayPublicKey: relayPublicKey,
            relayKeyVersion: relayKeyVersion,
            relayEncryption: relayEncryption,
            realtimeRelayURL: realtimeRelayURL,
            realtimeRelayStatus: realtimeRelayStatus,
            deviceId: deviceId
        )
    }

    func listPiAgentConnections(includeRevoked: Bool = false) async throws -> [PiConnectionRecord] {
        try await piPairing.listPiAgentConnections(includeRevoked: includeRevoked)
    }

    func revokePiAgentConnection(connectionId: String, deviceId: String? = nil) async throws {
        try await piPairing.revokePiAgentConnection(connectionId: connectionId, deviceId: deviceId)
    }

    func updatePiAgentConnectionStatus(
        connectionId: String,
        status: PiConnectionStatus,
        advertisedModel: String? = nil,
        selectedInstanceID: String? = nil,
        capabilities: [String]? = nil,
        instances: [PiAgentInstanceRecord]? = nil,
        models: [PiAgentRuntimeModelOption]? = nil,
        deviceId: String? = nil
    ) async throws {
        try await piPairing.updatePiAgentConnectionStatus(
            connectionId: connectionId,
            status: status,
            advertisedModel: advertisedModel,
            selectedInstanceID: selectedInstanceID,
            capabilities: capabilities,
            instances: instances,
            models: models,
            deviceId: deviceId
        )
    }

    #if DEBUG
    /// Test-visible entry point preserved in place; the implementation moved
    /// to `HermesGatewayAPI` with the rest of the gateway domain (tech-debt
    /// finding-67). Behavior is unchanged.
    nonisolated static func decodeHermesGatewayApprovalClientForTesting(_ raw: Any) throws -> HermesGatewayClientRecord {
        try HermesGatewayAPI.decodeHermesGatewayApprovalClientForTesting(raw)
    }
    #endif

    // MARK: Apple-verified hosted quota entitlement (delegates to EntitlementsAPI)

    func beginEntitlementBinding(
        productID: String,
        clientPlatform: String? = nil
    ) async throws -> String {
        try await entitlements.beginEntitlementBinding(
            productID: productID,
            clientPlatform: clientPlatform
        )
    }

    @discardableResult
    func verifyHostedQuotaEntitlement(
        signedTransactionJWS: String,
        signedRenewalInfoJWS: String? = nil,
        productID: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        try await entitlements.verifyHostedQuotaEntitlement(
            signedTransactionJWS: signedTransactionJWS,
            signedRenewalInfoJWS: signedRenewalInfoJWS,
            productID: productID
        )
    }

    @discardableResult
    func restoreHostedQuotaEntitlement(
        productID: String? = nil,
        signedTransactionJWS: String? = nil
    ) async throws -> HostedQuotaEntitlementResponse {
        try await entitlements.restoreHostedQuotaEntitlement(
            productID: productID,
            signedTransactionJWS: signedTransactionJWS
        )
    }

    @discardableResult
    func verifyCloudProTopUp(
        signedTransactionJWS: String,
        productID: String
    ) async throws -> CloudProTopUpCreditResponse {
        try await entitlements.verifyCloudProTopUp(
            signedTransactionJWS: signedTransactionJWS,
            productID: productID
        )
    }
}

// MARK: - Functions Error

enum FunctionsError: Error, LocalizedError, Equatable {
    case decodingFailed
    /// A typed callable response could not be decoded. The associated string
    /// carries the underlying `DecodingError` context (failing key path / type)
    /// so failures are diagnosable instead of being collapsed by `try?`.
    case responseDecodingFailed(String)
    case firebaseUnavailable
    case gatewayTargetMissingRelayKey
    case gatewayRelayKeyChanged
    case gatewayAttachmentUnreadable
    case gatewayApprovalNotAuthenticated
    case gatewayApprovalAppCheckBlocked
    case gatewayReplayCounterExhausted
    case gatewayInvalidSealedControlPayload

    var errorDescription: String? {
        switch self {
        case .decodingFailed: return "Failed to decode cloud function response."
        case .responseDecodingFailed: return "Failed to decode cloud function response."
        case .firebaseUnavailable:
            return "BurnBar Cloud is still starting. Try again after sign-in finishes."
        case .gatewayTargetMissingRelayKey:
            // Benefit-first, jargon-free per the copy policy: messages stay
            // private, so they can only send once the Mac is ready.
            return "Update OpenBurnBar on your Mac, then reconnect Hermes. Messages here stay private to your devices, so they can only be sent once that Mac is ready."
        case .gatewayRelayKeyChanged:
            // No transport/security jargon ("relay key", "man-in-the-middle"):
            // calm, action-first copy that protects the user and names the fix.
            return "This Hermes connection looks different from when you set it up, so your message was kept on this device for your safety. Reconnect Hermes on your Mac to keep sending privately."
        case .gatewayAttachmentUnreadable:
            return "This file was shared privately with another of your devices. Reconnect Hermes on this device to open files here."
        case .gatewayApprovalNotAuthenticated:
            return "Sign in to BurnBar Cloud, then reopen Hermes Gateway and tap Connect Hermes again."
        case .gatewayApprovalAppCheckBlocked:
            return "App Check rejected this build. Reinstall from the official channel, or register and stamp the local debug token before trying Connect Hermes."
        case .gatewayReplayCounterExhausted:
            return "Reconnect Hermes on your Mac before sending more private gateway messages."
        case .gatewayInvalidSealedControlPayload:
            return "Could not prepare this private Hermes control message. Reconnect Hermes on your Mac, then try again."
        }
    }
}

// MARK: - Provider Account Device Links (delegates to ProviderAccountsAPI)

extension FunctionsRepository {
    func adoptProviderAccountForDevice(
        accountID: String,
        deviceID: String,
        deviceDisplayName: String,
        capability: DeviceLinkCapability
    ) async throws {
        try await providerAccounts.adoptProviderAccountForDevice(
            accountID: accountID,
            deviceID: deviceID,
            deviceDisplayName: deviceDisplayName,
            capability: capability
        )
    }

    func revokeProviderAccountDeviceLink(accountID: String, deviceID: String) async throws {
        try await providerAccounts.revokeProviderAccountDeviceLink(accountID: accountID, deviceID: deviceID)
    }

    func backfillProviderAccountDeviceLinks() async throws {
        try await providerAccounts.backfillProviderAccountDeviceLinks()
    }
}
