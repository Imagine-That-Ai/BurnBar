import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Hermes Gateway API

/// Hermes Gateway domain slice of the Firebase callable surface, split out of
/// `FunctionsRepository` (tech-debt finding-67). Implements the existing
/// `HermesGatewayRepository` protocol (device-grant approval, client listing
/// and revocation, sealed event/model-switch/oversight/approval enqueueing).
/// Method bodies are verbatim moves from `FunctionsRepository`; the repository
/// remains a facade that forwards here, so existing call sites (including
/// everything typed against `any HermesGatewayRepository`) keep compiling
/// unchanged.
///
/// PRIVACY: phone→agent gateway event bodies must stay sealed end-to-end.
/// Never construct plaintext `payload["text"]` / `payload["senderDisplayName"]`
/// cloud payloads here — all content rides `relayEnvelope`/`ratchetEnvelope`
/// via `FunctionsRepository.sealGatewayEventPayload`. The privacy plaintext
/// scanner (scripts/privacy/scan-chat-cloud-plaintext.mjs) currently pins
/// these bans plus the seal entry points (`sealGatewayEventPayload(`,
/// `sealGatewayEventRatchetPayload(`) to FunctionsRepository.swift, which is
/// why those `nonisolated static` entry points stay defined there; migrating
/// the pins to this file must ride in its own scanner PR.
@MainActor
final class HermesGatewayAPI: HermesGatewayRepository {
    private let client: FunctionsClientProvider

    init(client: FunctionsClientProvider) {
        self.client = client
    }

    private func functionsClient() throws -> Functions {
        try client.client()
    }

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
        let callable = try functionsClient().httpsCallable("approveHermesGatewayDeviceGrant")
        var payload: [String: Any] = [
            "userCode": userCode,
            "destinationId": destinationId,
            "scopes": scopes
        ]
        if let displayName, !displayName.isEmpty {
            payload["displayName"] = displayName
        }
        // Publish the phone's relay pubkey so the agent can seal replies to it.
        if let phoneRelayPublicKey, !phoneRelayPublicKey.isEmpty {
            payload["phoneRelayPublicKey"] = phoneRelayPublicKey
            payload["supportsRelayEnvelopeVersions"] = [
                HermesRelayCrypto.gatewayRelayKeyVersion,
                HermesRelayCrypto.gatewayRelayKeyVersionV3
            ]
            payload["preferredRelayEnvelopeVersion"] = HermesRelayCrypto.gatewayRelayKeyVersionV3
            payload["supportsHpkeV3"] = true
            payload["clientPlatform"] = "ios"
            payload["clientAppBuild"] =
                (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
                ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                ?? "unknown"
        }
        if let phoneRelayKeyVersion {
            payload["phoneRelayKeyVersion"] = phoneRelayKeyVersion
        }
        if let phoneRelayEncryption, !phoneRelayEncryption.isEmpty {
            payload["phoneRelayEncryption"] = phoneRelayEncryption
        }
        if let phoneRatchetPrekeyBundle {
            payload["phoneRatchetIdentityPublicKey"] = phoneRatchetPrekeyBundle.identityPublicKeyBase64
            payload["phoneRatchetSigningPublicKey"] = phoneRatchetPrekeyBundle.signingPublicKeyBase64
            payload["phoneRatchetSignedPreKeyPublicKey"] = phoneRatchetPrekeyBundle.signedPreKeyPublicKeyBase64
            payload["phoneRatchetSignedPreKeyId"] = phoneRatchetPrekeyBundle.signedPreKeyID
            payload["phoneRatchetSignedPreKeySignature"] = phoneRatchetPrekeyBundle.signedPreKeySignatureBase64
            payload["phoneSupportsRatchetV1"] = true
        }

        try await prepareHermesGatewayApprovalContext()
        let executor = FirebaseCallableExecutor(callable)
        let callablePayload = FirebaseCallablePayload(payload)
        let result: HTTPSCallableResult
        do {
            result = try await executor.call(callablePayload)
        } catch {
            guard Self.isUnauthenticatedCallableError(error) else {
                throw Self.mappedHermesGatewayApprovalError(error)
            }
            // Firebase Auth can lag the SwiftUI signed-in state immediately after
            // a sign-out/sign-in cycle. Force one more token/App Check refresh
            // before surfacing the error to the user.
            try await prepareHermesGatewayApprovalContext()
            do {
                result = try await executor.call(callablePayload)
            } catch {
                throw Self.mappedHermesGatewayApprovalError(error)
            }
        }
        return try Self.decodeHermesGatewayValue(HermesGatewayApprovalResponse.self, from: result.data).client
    }

    private func prepareHermesGatewayApprovalContext() async throws {
        guard FirebaseApp.app() != nil,
              let user = Auth.auth().currentUser,
              !user.isAnonymous else {
            throw FunctionsError.gatewayApprovalNotAuthenticated
        }
        do {
            _ = try await user.getIDTokenResult(forcingRefresh: true)
        } catch {
            throw FunctionsError.gatewayApprovalNotAuthenticated
        }
        do {
            let token = try await AppCheck.appCheck().token(forcingRefresh: true)
            guard !token.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FunctionsError.gatewayApprovalAppCheckBlocked
            }
        } catch let error as FunctionsError {
            throw error
        } catch {
            throw FunctionsError.gatewayApprovalAppCheckBlocked
        }
    }

    private static func mappedHermesGatewayApprovalError(_ error: Error) -> Error {
        guard isUnauthenticatedCallableError(error) else { return error }
        let message = (error as NSError).localizedDescription
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        if message.contains("appcheck") || message.contains("attestation") {
            return FunctionsError.gatewayApprovalAppCheckBlocked
        }
        return FunctionsError.gatewayApprovalNotAuthenticated
    }

    private static func isUnauthenticatedCallableError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == FunctionsErrorDomain
            && nsError.code == FunctionsErrorCode.unauthenticated.rawValue
    }

    func listHermesGatewayClients(includeRevoked: Bool = false) async throws -> [HermesGatewayClientRecord] {
        let callable = try functionsClient().httpsCallable("listHermesGatewayClients")
        let result = try await callable.call(["includeRevoked": includeRevoked])
        return try Self.decodeHermesGatewayValue(HermesGatewayClientsResponse.self, from: result.data).clients
    }

    func revokeHermesGatewayClient(clientId: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeHermesGatewayClient")
        _ = try await callable.call(["clientId": clientId])
    }

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "threadId": threadId,
            "senderId": "burnbar-ios"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        try Self.applyGatewayEventSeal(
            into: &payload,
            text: text,
            senderDisplayName: senderDisplayName,
            threadId: threadId,
            modelId: nil,
            targetClient: targetClient
        )
        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String = "burnbar:home",
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        let callable = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
        var payload: [String: Any] = [
            "destinationId": destinationId,
            "senderId": "burnbar-ios",
            "eventKind": "model_switch"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        if targetClient?.canSealToAgent == true {
            // E2E link: seal the model id into `relayEnvelope.payloadCiphertext`
            // (alongside text/senderDisplayName/threadId) like every other event,
            // so the model command never leaves the device in cleartext. The
            // agent opens `modelId` from inside the sealed payload after polling.
            // We now also stamp top-level `kind` inside the sealed payload so the
            // receiving agent dispatches it as a control (not chat text) per the
            // E2EE remediation requirement.
            try Self.applyGatewayEventSeal(
                into: &payload,
                text: "",
                senderDisplayName: senderDisplayName,
                threadId: threadId,
                modelId: modelId,
                targetClient: targetClient,
                kind: "model_switch"
            )
        } else {
            // Legacy (non-canSealToAgent) link during the grace window: the agent
            // has no relay key to wrap to, so the routing-only model id stays
            // cleartext per the gateway wire contract until that Mac re-pairs.
            // Wire stays identical to the pre-seal model_switch (no threadId).
            payload["modelId"] = modelId
        }
        let result = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
        return try Self.decodeHermesGatewayValue(HermesGatewayQueuedEvent.self, from: result.data)
    }

    private static func trimmedClientID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Seal the phone→agent event payload into `payload`, reusing the existing
    /// `HermesRelayCrypto` envelope. When the target agent has published a usable
    /// relay pubkey (`canSealToAgent`), the cleartext body never leaves the
    /// device: a per-event symmetric key seals `{text, destinationId,
    /// replayCounter, senderDisplayName, threadId[, modelId]}` and is wrapped to
    /// the agent's pubkey. The phone generates the `eventId` so it binds the AAD;
    /// the server honors it as the doc id. If the target cannot seal, the call
    /// fails before constructing any plaintext cloud payload.
    private static func applyGatewayEventSeal(
        into payload: inout [String: Any],
        text: String,
        senderDisplayName: String,
        threadId: String,
        modelId: String?,
        targetClient: HermesGatewayClientRecord?,
        pinStore: HermesGatewayAgentKeyPinStore = HermesGatewayAgentKeyPinStore(),
        kind: String? = nil,
        extraSealedFields: [String: Any] = [:]
    ) throws {
        guard FirebaseApp.app() != nil,
              let uid = Auth.auth().currentUser?.uid,
              !uid.isEmpty else {
            throw FunctionsError.gatewayTargetMissingRelayKey
        }
        try FunctionsRepository.sealGatewayEventPayload(
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

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws {
        // On E2E-paired links, also emit a sealed oversight_mode control event.
        // The agent on E2E links ignores the relay-visible client doc state for
        // oversight (to avoid relay-controlled flips) and only applies changes
        // delivered via pinned-sender sealed events. Build the envelope before
        // mutating the relay-visible doc so local key/pin failures fail cleanly.
        var sealedOversightPayload: [String: Any]?
        if let tc = targetClient, tc.canSealToAgent {
            var payload: [String: Any] = [
                "destinationId": "burnbar:home",
                "senderId": "burnbar-ios",
                "threadId": "burnbar-ios-oversight"
            ]
            if let rid = Self.trimmedClientID(tc.id) {
                payload["targetClientId"] = rid
            }
            let extra: [String: Any] = [
                "mode": mode,
                "senderId": "burnbar-ios"
            ]
            try Self.applyGatewayEventSeal(
                into: &payload,
                text: "",
                senderDisplayName: "OpenBurnBar iPhone",
                threadId: "burnbar-ios-oversight",
                modelId: nil,
                targetClient: tc,
                kind: "oversight_mode",
                extraSealedFields: extra
            )
            sealedOversightPayload = payload
        }

        let callable = try functionsClient().httpsCallable("setHermesGatewayOversightMode")
        _ = try await callable.call([
            "clientId": clientId,
            "mode": mode
        ])

        if let sealedOversightPayload {
            let ev = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
            _ = try await FirebaseCallableExecutor(ev).call(FirebaseCallablePayload(sealedOversightPayload))
        }
    }

    /// Bind a gateway oversight approve/reject decision to this trusted native
    /// escrow device, reusing the same App-Check-enforced device-trust path as
    /// the CLI-mission `respondMissionApproval` flow.
    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws {
        try await ComputerUseSecurityCallableClient.respondHermesGatewayApproval(
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
        let choice = approve ? "approve" : "reject"
        // For E2E links we must emit the control fields (including "kind") at the
        // root of the sealed payload so the agent can dispatch to the special
        // _handle_sealed_approval_decision path (rather than treating it as chat
        // text). The legacy json-in-text path is retired for correctness.
        var payload: [String: Any] = [
            "destinationId": "burnbar:home",
            "senderId": "burnbar-ios",
            "threadId": "burnbar-ios-approval"
        ]
        if let resolvedTargetClientId = Self.trimmedClientID(targetClientId) ?? Self.trimmedClientID(targetClient?.id) {
            payload["targetClientId"] = resolvedTargetClientId
        }
        let extra: [String: Any] = [
            "actionId": approvalId,
            "choice": choice,
            "senderId": "burnbar-ios"
        ]
        try Self.applyGatewayEventSeal(
            into: &payload,
            text: "",
            senderDisplayName: "OpenBurnBar iPhone",
            threadId: "burnbar-ios-approval",
            modelId: nil,
            targetClient: targetClient,
            kind: "approval_decision",
            extraSealedFields: extra
        )
        let callable = try functionsClient().httpsCallable("enqueueHermesGatewayEvent")
        _ = try await FirebaseCallableExecutor(callable).call(FirebaseCallablePayload(payload))
    }

    // MARK: Response decoding

    nonisolated private static func decodeHermesGatewayValue<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let sanitized = sanitizeHermesGatewayJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func sanitizeHermesGatewayJSON(_ value: Any) -> Any {
        switch value {
        case let ts as Timestamp:
            return ISO8601DateFormatter().string(from: ts.dateValue())
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = sanitizeHermesGatewayJSON(entry.value)
            }
        case let dict as NSDictionary:
            return dict.reduce(into: [String: Any]()) { result, entry in
                guard let key = entry.key as? String else { return }
                result[key] = sanitizeHermesGatewayJSON(entry.value)
            }
        case let arr as [Any]:
            return arr.map { sanitizeHermesGatewayJSON($0) }
        case let arr as NSArray:
            return arr.map { sanitizeHermesGatewayJSON($0) }
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    #if DEBUG
    nonisolated static func decodeHermesGatewayApprovalClientForTesting(_ raw: Any) throws -> HermesGatewayClientRecord {
        try decodeHermesGatewayValue(HermesGatewayApprovalResponse.self, from: raw).client
    }
    #endif
}

// MARK: - Callable response envelopes

private struct HermesGatewayApprovalResponse: Decodable, Sendable {
    let client: HermesGatewayClientRecord
    let homeDestinationId: String
}

private struct HermesGatewayClientsResponse: Decodable, Sendable {
    let clients: [HermesGatewayClientRecord]
}
