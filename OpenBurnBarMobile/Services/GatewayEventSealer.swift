import CryptoKit
import Foundation
import OpenBurnBarCore

/// E2EE sealing core for phone→agent Hermes Gateway events, extracted
/// mechanically from `FunctionsRepository` (tech-debt finding-67) so the
/// sealing crypto no longer shares a compilation unit with the repository's
/// other backend domains. Implementations are byte-identical to their
/// previous home in FunctionsRepository.swift; only access levels needed for
/// the cross-file split were widened. The ratchet lane
/// (`FunctionsRepository.sealGatewayEventRatchetPayload`) intentionally stays
/// in FunctionsRepository.swift for now: the privacy plaintext scanner
/// (scripts/privacy/scan-chat-cloud-plaintext.mjs) pins that symbol to that
/// file, and gate changes must ride in their own PR.
@MainActor
enum GatewayEventSealer {
    nonisolated static func gatewayDestinationID(in payload: [String: Any]) -> String {
        if let value = payload["destinationId"] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = payload["destinationId"] as? NSString, value.length > 0 {
            return value as String
        }
        return "burnbar:home"
    }

    private nonisolated static let gatewayEventCounterLock = NSLock()
    private nonisolated static let gatewayEventCounterKeyPrefix = "openburnbar.hermesGateway.eventReplayCounter.v1"
    private nonisolated static let gatewaySealedPayloadReservedKeys: Set<String> = [
        "text",
        "destinationId",
        "replayCounter",
        "eventCounter",
        "senderDisplayName",
        "threadId",
        "modelId",
        "kind"
    ]

    private nonisolated static func gatewayEventCounterStorageKey(
        uid: String,
        clientId: String,
        phoneRelayPublicKey: String
    ) -> String {
        let material = [uid, clientId, phoneRelayPublicKey].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(gatewayEventCounterKeyPrefix).\(digest)"
    }

    nonisolated static func nextGatewayEventReplayCounter(
        uid: String,
        clientId: String,
        phoneRelayPublicKey: String,
        defaults: UserDefaults = .standard
    ) throws -> Int {
        let storageKey = gatewayEventCounterStorageKey(
            uid: uid,
            clientId: clientId,
            phoneRelayPublicKey: phoneRelayPublicKey
        )
        gatewayEventCounterLock.lock()
        defer { gatewayEventCounterLock.unlock() }

        let raw = defaults.object(forKey: storageKey)
        let current: Int
        if let value = raw as? Int {
            current = max(0, value)
        } else if let value = raw as? NSNumber {
            current = max(0, value.intValue)
        } else {
            current = 0
        }
        guard current < Int.max else {
            throw FunctionsError.gatewayReplayCounterExhausted
        }
        let next = current + 1
        defaults.set(next, forKey: storageKey)
        return next
    }

    nonisolated static func applyExtraSealedFields(
        _ fields: [String: Any],
        to sealedPayload: inout [String: Any]
    ) throws {
        try validateExtraSealedFields(fields)
        for (rawKey, value) in fields {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            sealedPayload[key] = value
        }
    }

    private nonisolated static func validateExtraSealedFields(_ fields: [String: Any]) throws {
        for rawKey in fields.keys {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !gatewaySealedPayloadReservedKeys.contains(key) else {
                throw FunctionsError.gatewayInvalidSealedControlPayload
            }
        }
    }

    /// Pure, `uid`-injected seal core shared by the live path and tests. Refuses
    /// to seal unless the target can seal AND its advertised relay pubkey passes
    /// the phone's TOFU pin check. Fails closed on every gap.
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
        guard let targetClient, !uid.isEmpty else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }
        try validateExtraSealedFields(extraSealedFields)

        if targetClient.canRatchetToAgent {
            try FunctionsRepository.sealGatewayEventRatchetPayload(
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
            return
        }

        let keypair = try HermesGatewayRelayKeypair.loadOrCreate()
        guard targetClient.isPairedWithThisDevice(relayPublicKeyBase64: keypair.relayPublicKeyBase64) else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        guard targetClient.canSealToAgent,
              let relayPublicKey = targetClient.relayPublicKey
        else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }

        // Phone-side TOFU pin (defense-in-depth alongside the server immutability
        // fix): refuse to seal to a key that differs from the one we pinned at
        // first pairing. A mismatch — or a Keychain read failure we can't verify
        // against — fails closed: the encrypted payload is never built, so no
        // plaintext or attacker-readable ciphertext leaves the device.
        guard pinStore
            .verifyOrPin(agentPublicKeyBase64: relayPublicKey, uid: uid, clientId: targetClient.id)
            .allowsSeal
        else {
            throw FunctionsError.gatewayRelayKeyChanged
        }

        // v2 authenticated seal: the phone's own persistent gateway relay key is
        // the SENDER. The agent opens the event binding this phone key (which it
        // pinned at pairing), so a relay that cannot produce the phone's private
        // key cannot forge an event to the agent.
        let destinationId = gatewayDestinationID(in: payload)
        let eventId = "evt_\(UUID().uuidString.lowercased())"
        let replayCounter = try nextGatewayEventReplayCounter(
            uid: uid,
            clientId: targetClient.id,
            phoneRelayPublicKey: keypair.relayPublicKeyBase64
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
        try applyExtraSealedFields(extraSealedFields, to: &sealedPayload)
        let plaintext = try JSONSerialization.data(withJSONObject: sealedPayload)
        let key = try HermesRelayCrypto.generateSymmetricKeyData()
        let payloadCiphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: plaintext,
            keyData: key,
            aad: HermesRelayCrypto.gatewayEventAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        )
        let keyAAD = HermesRelayCrypto.gatewayEventKeyAAD(uid: uid, clientId: targetClient.id, eventId: eventId)
        var relayEnvelope: [String: Any] = [
            "payloadCiphertext": payloadCiphertext,
            "senderPublicKey": keypair.relayPublicKeyBase64
        ]
        if targetClient.preferredRelayEnvelopeVersionForSeal == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
            let wrap = try HermesRelayCrypto.sealKeyV3(
                key,
                recipientPublicKeyBase64: relayPublicKey,
                senderPrivateKey: keypair.privateKey,
                aad: keyAAD
            )
            relayEnvelope["wrappedKey"] = wrap.wrappedKey.base64EncodedString()
            relayEnvelope["enc"] = wrap.enc.base64EncodedString()
            relayEnvelope["relayEncryption"] = HermesRelayCrypto.relayEncryptionV3
            relayEnvelope["relayKeyVersion"] = HermesRelayCrypto.gatewayRelayKeyVersionV3
        } else {
            relayEnvelope["wrappedKey"] = try HermesRelayCrypto.wrapSymmetricKey(
                key,
                recipientPublicKeyBase64: relayPublicKey,
                aad: keyAAD,
                senderPrivateKey: keypair.privateKey
            )
            relayEnvelope["relayEncryption"] = HermesRelayCrypto.algorithm
            relayEnvelope["relayKeyVersion"] = HermesRelayCrypto.gatewayRelayKeyVersion
        }
        // Drop plaintext text/senderDisplayName/threadId from the top level — they
        // now live only inside `payloadCiphertext`. Keep routing fields. The
        // `relayKeyVersion` is the gateway wrap-protocol version the phone
        // authoritatively stamped for what it actually sealed. `senderPublicKey` is
        // a lookup hint; the agent authenticates against its pinned copy, never
        // this wire field.
        payload["eventId"] = eventId
        payload["relayEnvelope"] = relayEnvelope
    }
}
