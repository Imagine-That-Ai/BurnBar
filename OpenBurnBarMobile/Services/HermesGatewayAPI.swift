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

    // MARK: Hermes host pairing

    func createHermesPairing(
        deviceId: String? = nil,
        platform: String? = nil,
        displayName: String? = nil
    ) async throws -> HermesPairingSessionRecord {
        let callable = try functionsClient().httpsCallable("createHermesPairing")
        var payload: [String: Any] = [:]
        if let deviceId, !deviceId.isEmpty { payload["deviceId"] = deviceId }
        if let platform, !platform.isEmpty { payload["platform"] = platform }
        if let displayName, !displayName.isEmpty { payload["displayName"] = displayName }

        let result = try await callable.call(payload)
        return try decodeHermesValue(HermesPairingSessionRecord.self, from: result.data)
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
        let callable = try functionsClient().httpsCallable("completeHermesPairing")
        var payload: [String: Any] = [
            "pairingId": pairingId,
            "code": code,
            "displayName": displayName,
            "mode": HermesConnectionMode.directURL.rawValue,
            "endpointURL": endpointURL,
            "capabilities": capabilities
        ]
        if let connectionId, !connectionId.isEmpty {
            payload["connectionId"] = connectionId
        }
        if let advertisedModel, !advertisedModel.isEmpty {
            payload["advertisedModel"] = advertisedModel
        }

        let result = try await callable.call(payload)
        return try decodeHermesValue(HermesConnectionRecord.self, from: result.data)
    }

    func listHermesConnections() async throws -> [HermesConnectionRecord] {
        let callable = try functionsClient().httpsCallable("listHermesConnections")
        let result = try await callable.call([:])
        guard
            let dict = result.data as? [String: Any],
            let connections = dict["connections"]
        else {
            throw FunctionsError.decodingFailed
        }
        return try decodeHermesValue([HermesConnectionRecord].self, from: connections)
    }

    func revokeHermesConnection(connectionId: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeHermesConnection")
        _ = try await callable.call(["connectionId": connectionId])
    }

    func revokeRemoteMcpClient(clientID: String) async throws {
        let callable = try functionsClient().httpsCallable("revokeRemoteMcpClient")
        _ = try await callable.call(["clientId": clientID])
    }

    private func decodeHermesValue<T: Decodable>(_ type: T.Type, from raw: Any) throws -> T {
        let sanitized = FirestoreRepository.shared.sanitizeForJSON(raw)
        let data = try JSONSerialization.data(withJSONObject: sanitized)
        return try JSONDecoder().decode(type, from: data)
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

// MARK: - Hermes Gateway Repository

@MainActor
protocol HermesGatewayRepository: AnyObject {
    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String?,
        destinationId: String,
        scopes: [String],
        phoneRelayPublicKey: String?,
        phoneRelayKeyVersion: Int?,
        phoneRelayEncryption: String?,
        phoneRatchetPrekeyBundle: HermesGatewayRatchetPrekeyBundle?
    ) async throws -> HermesGatewayClientRecord

    func listHermesGatewayClients(includeRevoked: Bool) async throws -> [HermesGatewayClientRecord]
    func revokeHermesGatewayClient(clientId: String) async throws

    func enqueueHermesGatewayEvent(
        text: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        destinationId: String,
        threadId: String,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?,
        senderDisplayName: String
    ) async throws -> HermesGatewayQueuedEvent

    func setHermesGatewayOversightMode(clientId: String, mode: String, targetClient: HermesGatewayClientRecord?) async throws

    func respondHermesGatewayApproval(approvalId: String, approve: Bool, deviceId: String) async throws

    /// After a native approval callable succeeds, enqueue a sealed
    /// ``approval_decision`` event so the Hermes agent applies the choice without
    /// trusting relay-visible ``/approvals`` poll state.
    func enqueueHermesGatewayApprovalDecision(
        approvalId: String,
        approve: Bool,
        targetClient: HermesGatewayClientRecord?,
        targetClientId: String?
    ) async throws
}

extension HermesGatewayRepository {
    func approveHermesGatewayDeviceGrant(
        userCode: String,
        displayName: String? = nil
    ) async throws -> HermesGatewayClientRecord {
        // Publish this phone's persistent relay pubkey at pairing so the agent can
        // seal `hermes_gateway_messages` replies back to this device.
        let keypair = try HermesGatewayRelayKeypair.loadOrCreate()
        let ratchetBundle = try HermesGatewayRatchetPrekeyStore.loadOrCreateBundle()
        return try await approveHermesGatewayDeviceGrant(
            userCode: userCode,
            displayName: displayName,
            destinationId: "burnbar:home",
            scopes: [
                "hermes.gateway.read",
                "hermes.gateway.write",
                "hermes.gateway.manage"
            ],
            phoneRelayPublicKey: keypair.relayPublicKeyBase64,
            phoneRelayKeyVersion: keypair.keyVersion,
            phoneRelayEncryption: keypair.relayEncryption,
            phoneRatchetPrekeyBundle: ratchetBundle
        )
    }

    func listHermesGatewayClients() async throws -> [HermesGatewayClientRecord] {
        try await listHermesGatewayClients(includeRevoked: false)
    }

    func enqueueHermesGatewayEvent(
        text: String,
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayEvent(
            text: text,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId ?? targetClient?.id,
            senderDisplayName: senderDisplayName
        )
    }

    func enqueueHermesGatewayModelSwitch(
        modelId: String,
        threadId: String = "burnbar-ios-e2e",
        targetClient: HermesGatewayClientRecord? = nil,
        targetClientId: String? = nil,
        senderDisplayName: String = "OpenBurnBar iPhone"
    ) async throws -> HermesGatewayQueuedEvent {
        try await enqueueHermesGatewayModelSwitch(
            modelId: modelId,
            destinationId: "burnbar:home",
            threadId: threadId,
            targetClient: targetClient,
            targetClientId: targetClientId ?? targetClient?.id,
            senderDisplayName: senderDisplayName
        )
    }
}

// MARK: - Hermes Gateway Records
// Moved verbatim from `FunctionsRepository.swift` (tech-debt finding-67) so
// the gateway domain owns its wire records. `HermesGatewayMessageRecord`
// stays in the facade file while the privacy plaintext scanner pins
// `decodedRatchetText(` there.

struct HermesGatewayClientRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let status: String
    let tokenPreview: String
    let scopes: [String]
    let homeDestinationId: String
    let lastSeenAt: String?
    let runtimeModelId: String?
    let runtimeProviderId: String?
    let runtimeModelOptions: [HermesGatewayModelOptionRecord]
    let runtimeUpdatedAt: String?
    let agentVersion: String?
    let pendingModelId: String?
    let pendingModelRequestedAt: String?
    let oversightMode: String?
    /// The agent's published P-256 relay public key (X9.63 base64). The phone
    /// wraps per-event symmetric keys to this so only the paired agent can open
    /// `hermes_gateway_events`.
    let relayPublicKey: String?
    let relayKeyVersion: Int?
    let relayEncryption: String?
    let phoneRelayPublicKey: String?
    let phoneRelayKeyVersion: Int?
    let phoneRelayEncryption: String?
    let supportsRelayEnvelopeVersions: [Int]
    let preferredRelayEnvelopeVersion: Int
    let supportsHpkeV3: Bool
    let agentRatchetIdentityPublicKey: String?
    let agentRatchetSigningPublicKey: String?
    let agentRatchetSignedPreKeyPublicKey: String?
    let agentRatchetSignedPreKeyId: String?
    let agentRatchetSignedPreKeySignature: String?
    let agentSupportsRatchetV1: Bool?
    let phoneRatchetIdentityPublicKey: String?
    let phoneRatchetSigningPublicKey: String?
    let phoneRatchetSignedPreKeyPublicKey: String?
    let phoneRatchetSignedPreKeyId: String?
    let phoneRatchetSignedPreKeySignature: String?
    let phoneSupportsRatchetV1: Bool?
    let supportsRatchetV1: Bool
    let revokedAt: String?
    let createdAt: String
    let updatedAt: String
    let schemaVersion: Int

    var isActive: Bool { status == "active" }

    /// True once the agent has published a usable relay pubkey, so the phone can
    /// seal event text end-to-end instead of sending plaintext. Mirrors the
    /// realtime-relay `canSealToHost` guard in `HermesService`.
    var canSealToAgent: Bool {
        relayEncryption == HermesRelayCrypto.algorithm && (relayPublicKey?.isEmpty == false)
    }

    func isPairedWithThisDevice(relayPublicKeyBase64 localRelayPublicKey: String) -> Bool {
        guard
            let phoneRelayPublicKey = phoneRelayPublicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
            !phoneRelayPublicKey.isEmpty
        else { return false }
        return phoneRelayPublicKey == localRelayPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var preferredRelayEnvelopeVersionForSeal: Int {
        supportsRelayEnvelopeVersions.contains(preferredRelayEnvelopeVersion)
            ? preferredRelayEnvelopeVersion
            : HermesRelayCrypto.gatewayRelayKeyVersion
    }

    /// True only when both peers have published complete, echoed Phase 6 ratchet
    /// public material. The UI may show this as ratchet-capable, but transport
    /// still binds the identities through the safety-code path before trust.
    var canRatchetToAgent: Bool {
        supportsRatchetV1
            && agentSupportsRatchetV1 != false
            && phoneSupportsRatchetV1 != false
            && Self.nonEmpty(agentRatchetIdentityPublicKey)
            && Self.nonEmpty(agentRatchetSigningPublicKey)
            && Self.nonEmpty(agentRatchetSignedPreKeyPublicKey)
            && Self.nonEmpty(agentRatchetSignedPreKeyId)
            && Self.nonEmpty(agentRatchetSignedPreKeySignature)
            && Self.nonEmpty(phoneRatchetIdentityPublicKey)
            && Self.nonEmpty(phoneRatchetSigningPublicKey)
            && Self.nonEmpty(phoneRatchetSignedPreKeyPublicKey)
            && Self.nonEmpty(phoneRatchetSignedPreKeyId)
            && Self.nonEmpty(phoneRatchetSignedPreKeySignature)
    }

    /// Treat an unset `oversightMode` as the safe `supervised` default so the
    /// phone never implies a gateway is running autonomously when the server
    /// hasn't explicitly opted into it.
    var isOversightSupervised: Bool { oversightMode != "autonomous" }

    /// True while the gateway has accepted a model-switch request but is not yet
    /// reporting that model as its live runtime model.
    var isSwitchingModel: Bool {
        guard let pendingModelId, !pendingModelId.isEmpty else { return false }
        return pendingModelId != runtimeModelId
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case status
        case tokenPreview
        case scopes
        case homeDestinationId
        case lastSeenAt
        case runtimeModelId
        case runtimeProviderId
        case runtimeModelOptions
        case runtimeUpdatedAt
        case agentVersion
        case pendingModelId
        case pendingModelRequestedAt
        case oversightMode
        case relayPublicKey
        case relayKeyVersion
        case relayEncryption
        case supportsRelayEnvelopeVersions
        case preferredRelayEnvelopeVersion
        case supportsHpkeV3
        case agentRelayPublicKey
        case agentRelayKeyVersion
        case agentRelayEncryption
        case phoneRelayPublicKey
        case phoneRelayKeyVersion
        case phoneRelayEncryption
        case agentRatchetIdentityPublicKey
        case agentRatchetSigningPublicKey
        case agentRatchetSignedPreKeyPublicKey
        case agentRatchetSignedPreKeyId
        case agentRatchetSignedPreKeySignature
        case agentSupportsRatchetV1
        case phoneRatchetIdentityPublicKey
        case phoneRatchetSigningPublicKey
        case phoneRatchetSignedPreKeyPublicKey
        case phoneRatchetSignedPreKeyId
        case phoneRatchetSignedPreKeySignature
        case phoneSupportsRatchetV1
        case supportsRatchetV1
        case revokedAt
        case createdAt
        case updatedAt
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            status: try container.decode(String.self, forKey: .status),
            tokenPreview: try container.decode(String.self, forKey: .tokenPreview),
            scopes: try container.decodeIfPresent([String].self, forKey: .scopes) ?? [],
            homeDestinationId: try container.decode(String.self, forKey: .homeDestinationId),
            lastSeenAt: try container.decodeIfPresent(String.self, forKey: .lastSeenAt),
            revokedAt: try container.decodeIfPresent(String.self, forKey: .revokedAt),
            createdAt: try container.decode(String.self, forKey: .createdAt),
            updatedAt: try container.decode(String.self, forKey: .updatedAt),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            runtimeModelId: try container.decodeIfPresent(String.self, forKey: .runtimeModelId),
            runtimeProviderId: try container.decodeIfPresent(String.self, forKey: .runtimeProviderId),
            runtimeModelOptions: try container.decodeIfPresent([HermesGatewayModelOptionRecord].self, forKey: .runtimeModelOptions) ?? [],
            runtimeUpdatedAt: try container.decodeIfPresent(String.self, forKey: .runtimeUpdatedAt),
            agentVersion: try container.decodeIfPresent(String.self, forKey: .agentVersion),
            pendingModelId: try container.decodeIfPresent(String.self, forKey: .pendingModelId),
            pendingModelRequestedAt: try container.decodeIfPresent(String.self, forKey: .pendingModelRequestedAt),
            oversightMode: try container.decodeIfPresent(String.self, forKey: .oversightMode),
            relayPublicKey: try container.decodeIfPresent(String.self, forKey: .relayPublicKey)
                ?? container.decodeIfPresent(String.self, forKey: .agentRelayPublicKey),
            relayKeyVersion: try container.decodeIfPresent(Int.self, forKey: .relayKeyVersion)
                ?? container.decodeIfPresent(Int.self, forKey: .agentRelayKeyVersion),
            relayEncryption: try container.decodeIfPresent(String.self, forKey: .relayEncryption)
                ?? container.decodeIfPresent(String.self, forKey: .agentRelayEncryption),
            phoneRelayPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRelayPublicKey),
            phoneRelayKeyVersion: try container.decodeIfPresent(Int.self, forKey: .phoneRelayKeyVersion),
            phoneRelayEncryption: try container.decodeIfPresent(String.self, forKey: .phoneRelayEncryption),
            supportsRelayEnvelopeVersions: try container.decodeIfPresent([Int].self, forKey: .supportsRelayEnvelopeVersions) ?? [HermesRelayCrypto.gatewayRelayKeyVersion],
            preferredRelayEnvelopeVersion: try container.decodeIfPresent(Int.self, forKey: .preferredRelayEnvelopeVersion) ?? HermesRelayCrypto.gatewayRelayKeyVersion,
            supportsHpkeV3: try container.decodeIfPresent(Bool.self, forKey: .supportsHpkeV3) ?? false,
            agentRatchetIdentityPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetIdentityPublicKey),
            agentRatchetSigningPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetSigningPublicKey),
            agentRatchetSignedPreKeyPublicKey: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeyPublicKey),
            agentRatchetSignedPreKeyId: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeyId),
            agentRatchetSignedPreKeySignature: try container.decodeIfPresent(String.self, forKey: .agentRatchetSignedPreKeySignature),
            agentSupportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .agentSupportsRatchetV1),
            phoneRatchetIdentityPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetIdentityPublicKey),
            phoneRatchetSigningPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSigningPublicKey),
            phoneRatchetSignedPreKeyPublicKey: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyPublicKey),
            phoneRatchetSignedPreKeyId: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeyId),
            phoneRatchetSignedPreKeySignature: try container.decodeIfPresent(String.self, forKey: .phoneRatchetSignedPreKeySignature),
            phoneSupportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .phoneSupportsRatchetV1),
            supportsRatchetV1: try container.decodeIfPresent(Bool.self, forKey: .supportsRatchetV1) ?? false
        )
    }

    init(
        id: String,
        displayName: String,
        status: String,
        tokenPreview: String,
        scopes: [String],
        homeDestinationId: String,
        lastSeenAt: String?,
        revokedAt: String?,
        createdAt: String,
        updatedAt: String,
        schemaVersion: Int,
        runtimeModelId: String? = nil,
        runtimeProviderId: String? = nil,
        runtimeModelOptions: [HermesGatewayModelOptionRecord] = [],
        runtimeUpdatedAt: String? = nil,
        agentVersion: String? = nil,
        pendingModelId: String? = nil,
        pendingModelRequestedAt: String? = nil,
        oversightMode: String? = nil,
        relayPublicKey: String? = nil,
        relayKeyVersion: Int? = nil,
        relayEncryption: String? = nil,
        phoneRelayPublicKey: String? = nil,
        phoneRelayKeyVersion: Int? = nil,
        phoneRelayEncryption: String? = nil,
        supportsRelayEnvelopeVersions: [Int] = [HermesRelayCrypto.gatewayRelayKeyVersion],
        preferredRelayEnvelopeVersion: Int = HermesRelayCrypto.gatewayRelayKeyVersion,
        supportsHpkeV3: Bool = false,
        agentRatchetIdentityPublicKey: String? = nil,
        agentRatchetSigningPublicKey: String? = nil,
        agentRatchetSignedPreKeyPublicKey: String? = nil,
        agentRatchetSignedPreKeyId: String? = nil,
        agentRatchetSignedPreKeySignature: String? = nil,
        agentSupportsRatchetV1: Bool? = nil,
        phoneRatchetIdentityPublicKey: String? = nil,
        phoneRatchetSigningPublicKey: String? = nil,
        phoneRatchetSignedPreKeyPublicKey: String? = nil,
        phoneRatchetSignedPreKeyId: String? = nil,
        phoneRatchetSignedPreKeySignature: String? = nil,
        phoneSupportsRatchetV1: Bool? = nil,
        supportsRatchetV1: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.tokenPreview = tokenPreview
        self.scopes = scopes
        self.homeDestinationId = homeDestinationId
        self.lastSeenAt = lastSeenAt
        self.runtimeModelId = runtimeModelId
        self.runtimeProviderId = runtimeProviderId
        self.runtimeModelOptions = runtimeModelOptions
        self.runtimeUpdatedAt = runtimeUpdatedAt
        self.agentVersion = agentVersion
        self.pendingModelId = pendingModelId
        self.pendingModelRequestedAt = pendingModelRequestedAt
        self.oversightMode = oversightMode
        self.relayPublicKey = relayPublicKey
        self.relayKeyVersion = relayKeyVersion
        self.relayEncryption = relayEncryption
        self.phoneRelayPublicKey = phoneRelayPublicKey
        self.phoneRelayKeyVersion = phoneRelayKeyVersion
        self.phoneRelayEncryption = phoneRelayEncryption
        self.supportsRelayEnvelopeVersions = supportsRelayEnvelopeVersions
        self.preferredRelayEnvelopeVersion = preferredRelayEnvelopeVersion
        self.supportsHpkeV3 = supportsHpkeV3
        self.agentRatchetIdentityPublicKey = agentRatchetIdentityPublicKey
        self.agentRatchetSigningPublicKey = agentRatchetSigningPublicKey
        self.agentRatchetSignedPreKeyPublicKey = agentRatchetSignedPreKeyPublicKey
        self.agentRatchetSignedPreKeyId = agentRatchetSignedPreKeyId
        self.agentRatchetSignedPreKeySignature = agentRatchetSignedPreKeySignature
        self.agentSupportsRatchetV1 = agentSupportsRatchetV1
        self.phoneRatchetIdentityPublicKey = phoneRatchetIdentityPublicKey
        self.phoneRatchetSigningPublicKey = phoneRatchetSigningPublicKey
        self.phoneRatchetSignedPreKeyPublicKey = phoneRatchetSignedPreKeyPublicKey
        self.phoneRatchetSignedPreKeyId = phoneRatchetSignedPreKeyId
        self.phoneRatchetSignedPreKeySignature = phoneRatchetSignedPreKeySignature
        self.phoneSupportsRatchetV1 = phoneSupportsRatchetV1
        self.supportsRatchetV1 = supportsRatchetV1
        self.revokedAt = revokedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension HermesGatewayClientRecord {
    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let displayName = Self.string(data["displayName"]),
            let status = Self.string(data["status"]),
            let tokenPreview = Self.string(data["tokenPreview"]),
            let homeDestinationId = Self.string(data["homeDestinationId"]),
            let createdAt = Self.string(data["createdAt"]),
            let updatedAt = Self.string(data["updatedAt"])
        else { return nil }
        self.init(
            id: id,
            displayName: displayName,
            status: status,
            tokenPreview: tokenPreview,
            scopes: (data["scopes"] as? [Any])?.compactMap(Self.string) ?? [],
            homeDestinationId: homeDestinationId,
            lastSeenAt: Self.string(data["lastSeenAt"]),
            revokedAt: Self.string(data["revokedAt"]),
            createdAt: createdAt,
            updatedAt: updatedAt,
            schemaVersion: (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1,
            runtimeModelId: Self.string(data["runtimeModelId"]),
            runtimeProviderId: Self.string(data["runtimeProviderId"]),
            runtimeModelOptions: Self.modelOptions(data["runtimeModelOptions"]),
            runtimeUpdatedAt: Self.string(data["runtimeUpdatedAt"]),
            agentVersion: Self.string(data["agentVersion"]),
            pendingModelId: Self.string(data["pendingModelId"]),
            pendingModelRequestedAt: Self.string(data["pendingModelRequestedAt"]),
            oversightMode: Self.string(data["oversightMode"]),
            relayPublicKey: Self.string(data["relayPublicKey"]) ?? Self.string(data["agentRelayPublicKey"]),
            relayKeyVersion: (data["relayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["relayKeyVersion"] as? Int)
                ?? (data["agentRelayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["agentRelayKeyVersion"] as? Int),
            relayEncryption: Self.string(data["relayEncryption"]) ?? Self.string(data["agentRelayEncryption"]),
            phoneRelayPublicKey: Self.string(data["phoneRelayPublicKey"]),
            phoneRelayKeyVersion: (data["phoneRelayKeyVersion"] as? NSNumber)?.intValue
                ?? (data["phoneRelayKeyVersion"] as? Int),
            phoneRelayEncryption: Self.string(data["phoneRelayEncryption"]),
            supportsRelayEnvelopeVersions: Self.intArray(data["supportsRelayEnvelopeVersions"], fallback: [HermesRelayCrypto.gatewayRelayKeyVersion]),
            preferredRelayEnvelopeVersion: (data["preferredRelayEnvelopeVersion"] as? NSNumber)?.intValue
                ?? (data["preferredRelayEnvelopeVersion"] as? Int)
                ?? HermesRelayCrypto.gatewayRelayKeyVersion,
            supportsHpkeV3: (data["supportsHpkeV3"] as? Bool) ?? false,
            agentRatchetIdentityPublicKey: Self.string(data["agentRatchetIdentityPublicKey"]),
            agentRatchetSigningPublicKey: Self.string(data["agentRatchetSigningPublicKey"]),
            agentRatchetSignedPreKeyPublicKey: Self.string(data["agentRatchetSignedPreKeyPublicKey"]),
            agentRatchetSignedPreKeyId: Self.string(data["agentRatchetSignedPreKeyId"]),
            agentRatchetSignedPreKeySignature: Self.string(data["agentRatchetSignedPreKeySignature"]),
            agentSupportsRatchetV1: data["agentSupportsRatchetV1"] as? Bool,
            phoneRatchetIdentityPublicKey: Self.string(data["phoneRatchetIdentityPublicKey"]),
            phoneRatchetSigningPublicKey: Self.string(data["phoneRatchetSigningPublicKey"]),
            phoneRatchetSignedPreKeyPublicKey: Self.string(data["phoneRatchetSignedPreKeyPublicKey"]),
            phoneRatchetSignedPreKeyId: Self.string(data["phoneRatchetSignedPreKeyId"]),
            phoneRatchetSignedPreKeySignature: Self.string(data["phoneRatchetSignedPreKeySignature"]),
            phoneSupportsRatchetV1: data["phoneSupportsRatchetV1"] as? Bool,
            supportsRatchetV1: (data["supportsRatchetV1"] as? Bool) ?? false
        )
    }

    var lastSeenDate: Date? {
        guard let lastSeenAt else { return nil }
        return Self.gatewayDate(from: lastSeenAt)
    }

    func isOnline(relativeTo now: Date = Date(), staleAfter interval: TimeInterval = 90) -> Bool {
        guard isActive, let lastSeenDate else { return false }
        return now.timeIntervalSince(lastSeenDate) <= interval
    }

    private static func gatewayDate(from raw: String) -> Date? {
        ParsePrimitives.gatewayDate(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }

    private static func intArray(_ raw: Any?, fallback: [Int]) -> [Int] {
        guard let values = raw as? [Any] else { return fallback }
        let parsed = values.compactMap { item -> Int? in
            if let number = item as? NSNumber { return number.intValue }
            if let int = item as? Int { return int }
            if let string = item as? String { return Int(string) }
            return nil
        }
        return parsed.isEmpty ? fallback : parsed
    }

    private static func modelOptions(_ raw: Any?) -> [HermesGatewayModelOptionRecord] {
        (raw as? [Any])?.compactMap { item in
            guard let data = item as? [String: Any] else { return nil }
            return HermesGatewayModelOptionRecord(data: data)
        } ?? []
    }
}

struct HermesGatewayModelOptionRecord: Decodable, Hashable, Sendable {
    let providerId: String
    let providerName: String
    let modelId: String
    let displayName: String

    private enum CodingKeys: String, CodingKey {
        case providerId
        case providerName
        case modelId
        case displayName
    }

    init(providerId: String, providerName: String, modelId: String, displayName: String) {
        self.providerId = providerId
        self.providerName = providerName
        self.modelId = modelId
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modelId = try container.decode(String.self, forKey: .modelId)
        let providerId = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .providerId)) ?? "hermes"
        self.init(
            providerId: providerId,
            providerName: Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .providerName)) ?? providerId,
            modelId: modelId,
            displayName: Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .displayName)) ?? modelId
        )
    }

    init?(data: [String: Any]) {
        guard let modelId = Self.string(data["modelId"]) else { return nil }
        let providerId = Self.string(data["providerId"]) ?? "hermes"
        self.init(
            providerId: providerId,
            providerName: Self.string(data["providerName"]) ?? providerId,
            modelId: modelId,
            displayName: Self.string(data["displayName"]) ?? modelId
        )
    }

    var hermesRuntimeOption: HermesRuntimeModelOption {
        HermesRuntimeModelOption(
            providerID: providerId,
            providerName: providerName,
            modelID: modelId,
            displayName: displayName,
            sourceKind: "burnbar-cloud-gateway",
            routeEligible: true
        )
    }

    private static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct HermesGatewayQueuedEvent: Decodable, Hashable, Sendable {
    let id: String
    let sequence: Int
    let targetClientId: String?
}

/// Owner-read view of a server-armed oversight gate at
/// `users/{uid}/hermes_gateway_approvals/{approvalId}`. The agent blocks on this
/// gate until a trusted native device approves or rejects via
/// `respondHermesGatewayApproval`.
struct HermesGatewayApprovalRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String
    let actionId: String
    let toolName: String?
    let summary: String
    let status: String
    let requestedAt: String
    let expiresAt: String
    let respondedAt: String?
    let approvedByDeviceId: String?
    let schemaVersion: Int

    var isWaiting: Bool { status == "waiting_for_approval" }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case destinationId
        case actionId
        case toolName
        case summary
        case status
        case requestedAt
        case expiresAt
        case respondedAt
        case approvedByDeviceId
        case schemaVersion
    }

    init(
        id: String,
        clientId: String,
        destinationId: String,
        actionId: String,
        toolName: String?,
        summary: String,
        status: String,
        requestedAt: String,
        expiresAt: String,
        respondedAt: String? = nil,
        approvedByDeviceId: String? = nil,
        schemaVersion: Int
    ) {
        self.id = id
        self.clientId = clientId
        self.destinationId = destinationId
        self.actionId = actionId
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.respondedAt = respondedAt
        self.approvedByDeviceId = approvedByDeviceId
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            clientId: try container.decode(String.self, forKey: .clientId),
            destinationId: try container.decode(String.self, forKey: .destinationId),
            actionId: try container.decode(String.self, forKey: .actionId),
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName),
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            status: try container.decode(String.self, forKey: .status),
            requestedAt: try container.decode(String.self, forKey: .requestedAt),
            expiresAt: try container.decode(String.self, forKey: .expiresAt),
            respondedAt: try container.decodeIfPresent(String.self, forKey: .respondedAt),
            approvedByDeviceId: try container.decodeIfPresent(String.self, forKey: .approvedByDeviceId),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }
}

extension HermesGatewayApprovalRecord {
    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let clientId = Self.string(data["clientId"]),
            let destinationId = Self.string(data["destinationId"]),
            let actionId = Self.string(data["actionId"]),
            let status = Self.string(data["status"]),
            let requestedAt = Self.string(data["requestedAt"]),
            let expiresAt = Self.string(data["expiresAt"])
        else { return nil }
        self.init(
            id: id,
            clientId: clientId,
            destinationId: destinationId,
            actionId: actionId,
            toolName: Self.string(data["toolName"]),
            summary: Self.string(data["summary"]) ?? "",
            status: status,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            respondedAt: Self.string(data["respondedAt"]),
            approvedByDeviceId: Self.string(data["approvedByDeviceId"]),
            schemaVersion: (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1
        )
    }

    var expiresAtDate: Date? { Self.gatewayDate(from: expiresAt) }

    /// A gate is actionable only while it is still waiting and has not passed its
    /// server-stamped expiry.
    func isActionable(relativeTo now: Date = Date()) -> Bool {
        guard isWaiting else { return false }
        guard let expiresAtDate else { return true }
        return now < expiresAtDate
    }

    private static func gatewayDate(from raw: String) -> Date? {
        ParsePrimitives.gatewayDate(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }
}

/// The opened content of an agent→phone sealed gateway attachment: the manifest
/// (filename / size / content type) plus the decrypted file bytes.
struct HermesGatewayOpenedAttachment: Hashable, Sendable {
    let attachmentId: String
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let data: Data
}

/// An agent→phone sealed gateway attachment as stored in
/// `hermes_gateway_attachments`. The agent seals the file with a per-attachment
/// symmetric key wrapped to this phone's relay pubkey, stores the sealed
/// *manifest* (`{fileName, byteCount, contentType, destinationId}`) in `payloadCiphertext`, and
/// uploads the sealed *body* bytes to Cloud Storage at `bodyStoragePath`. The
/// phone unwraps the body key once and opens both the manifest and the body,
/// each bound to a distinct AAD label so a relay cannot swap one slot for the
/// other. Mirrors the Python adapter `seal_attachment` wire format.
///
/// The gateway settings store fetches only the attachment ids referenced by the
/// selected reply, downloads their sealed body blobs, calls these open
/// primitives, and renders the resulting `HermesAttachment` records through the
/// normal chat bubble strip. No bulk attachment download is needed.
struct HermesGatewayAttachmentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String?
    let bodyStoragePath: String?
    let payloadCiphertext: String?
    let wrappedKey: String?
    let enc: String?
    let relayEncryption: String?
    let relayKeyVersion: Int?
    let ratchetEnvelopeCiphertextBase64: String?
    let ratchetEnvelopeAlgorithm: String?
    let createdAt: String?

    init?(documentID: String, data: [String: Any]) {
        guard
            let id = HermesGatewayMessageRecord.string(data["id"]) ?? HermesGatewayMessageRecord.string(data["attachmentId"]) ?? documentID.nilIfEmpty,
            let clientId = HermesGatewayMessageRecord.string(data["clientId"])
        else { return nil }
        self.id = id
        self.clientId = clientId
        self.destinationId = HermesGatewayMessageRecord.string(data["destinationId"])
        self.bodyStoragePath =
            HermesGatewayMessageRecord.string(data["bodyStoragePath"])
            ?? HermesGatewayMessageRecord.string(data["storagePath"])
        let relayEnvelope = HermesGatewayMessageRecord.dictionary(data["relayEnvelope"])
        self.payloadCiphertext =
            HermesGatewayMessageRecord.string(relayEnvelope?["payloadCiphertext"])
            ?? HermesGatewayMessageRecord.string(data["payloadCiphertext"])
        self.wrappedKey =
            HermesGatewayMessageRecord.string(relayEnvelope?["wrappedKey"])
            ?? HermesGatewayMessageRecord.string(data["wrappedKey"])
        self.enc =
            HermesGatewayMessageRecord.string(relayEnvelope?["enc"])
            ?? HermesGatewayMessageRecord.string(data["enc"])
        self.relayEncryption =
            HermesGatewayMessageRecord.string(relayEnvelope?["relayEncryption"])
            ?? HermesGatewayMessageRecord.string(data["relayEncryption"])
        self.relayKeyVersion =
            (relayEnvelope?["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (relayEnvelope?["relayKeyVersion"] as? Int)
            ?? (data["relayKeyVersion"] as? NSNumber)?.intValue
            ?? (data["relayKeyVersion"] as? Int)
        let ratchetEnvelope = HermesGatewayMessageRecord.dictionary(data["ratchetEnvelope"])
        let ratchetHeader = HermesGatewayMessageRecord.dictionary(ratchetEnvelope?["header"])
        self.ratchetEnvelopeCiphertextBase64 = HermesGatewayMessageRecord.string(ratchetEnvelope?["ciphertextBase64"])
        self.ratchetEnvelopeAlgorithm = HermesGatewayMessageRecord.string(ratchetHeader?["algorithm"])
        self.createdAt = HermesGatewayMessageRecord.string(data["createdAt"])
    }

    /// True when this attachment carries a sealed body the phone must open with
    /// its relay key (vs. a legacy plaintext attachment).
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

    /// Unwrap the per-attachment body key with this phone's relay key, binding
    /// the *key* AAD (`gatewayAttachmentKey`). Returns `nil` when the attachment
    /// is unsealed or the wrap was sealed for another device. This is the open
    /// primitive shared by the manifest-only and full-body paths.
    func unwrapBodyKey(using keypair: HermesGatewayRelayKeypair, uid: String, pinnedSenderKey: String?) -> Data? {
        guard isRelaySealed, let wrappedKey, let pinnedSenderKey else { return nil }
        let keyAAD = HermesRelayCrypto.gatewayAttachmentKeyAAD(uid: uid, clientId: clientId, attachmentId: id)
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersion {
            guard relayEncryption == HermesRelayCrypto.algorithm else { return nil }
            return try? HermesRelayCrypto.unwrapSymmetricKey(
                wrappedKey,
                privateKey: keypair.privateKey,
                aad: keyAAD,
                senderPublicKeyBase64: pinnedSenderKey
            )
        }
        if relayKeyVersion == HermesRelayCrypto.gatewayRelayKeyVersionV3 {
            guard relayEncryption == HermesRelayCrypto.relayEncryptionV3,
                  let enc,
                  !enc.isEmpty else { return nil }
            return try? HermesRelayCrypto.openKeyV3(
                encBase64: enc,
                wrappedKeyBase64: wrappedKey,
                privateKey: keypair.privateKey,
                pinnedSenderPublicKeyBase64: pinnedSenderKey,
                aad: keyAAD
            )
        }
        return nil
    }

    /// Open the sealed manifest (`{fileName, byteCount, contentType, destinationId}`) with the
    /// already-unwrapped body key, binding the *manifest* AAD. Throws on a
    /// cross-slot swap (the body ciphertext fails the manifest tag) or malformed
    /// manifest JSON.
    func openManifest(bodyKey: Data, uid: String) throws -> HermesGatewayAttachmentManifest {
        guard let payloadCiphertext else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        let manifestData = try HermesRelayCrypto.openBase64(
            ciphertext: payloadCiphertext,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentManifestAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
        guard let manifest = HermesGatewayAttachmentManifest(jsonData: manifestData) else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        if let destinationId, !destinationId.isEmpty, manifest.destinationId != destinationId {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return manifest
    }

    /// Open the sealed body bytes with the already-unwrapped body key, binding
    /// the *body* AAD. `downloadedBody` is the raw blob fetched from
    /// `bodyStoragePath`; the agent uploads the base64 of the sealed body, so the
    /// blob is the ASCII base64 string of the ciphertext (matching the Python
    /// `seal_attachment` wire). Throws on a wrong-device key or a tampered body.
    func openBody(downloadedBody: Data, bodyKey: Data, uid: String) throws -> Data {
        guard let ciphertextBase64 = String(data: downloadedBody, encoding: .utf8),
              !ciphertextBase64.isEmpty else {
            throw FunctionsError.gatewayAttachmentUnreadable
        }
        return try HermesRelayCrypto.openBase64(
            ciphertext: ciphertextBase64,
            keyData: bodyKey,
            aad: HermesRelayCrypto.gatewayAttachmentBodyAAD(uid: uid, clientId: clientId, attachmentId: id)
        )
    }

    /// Full open: unwrap the body key, open the manifest for the filename, and
    /// open the body bytes — returning the rendered attachment. `downloadedBody`
    /// is the blob fetched from `bodyStoragePath` by the caller (the network
    /// download is the caller's responsibility so this stays pure/testable).
    /// Returns `nil` when this device cannot open the attachment (sealed for
    /// another device), so the caller can show the same calm re-pair state as a
    /// sealed reply.
    func opened(
        downloadedBody: Data,
        using keypair: HermesGatewayRelayKeypair,
        uid: String,
        pinnedSenderKey: String?
    ) -> HermesGatewayOpenedAttachment? {
        guard let bodyKey = unwrapBodyKey(using: keypair, uid: uid, pinnedSenderKey: pinnedSenderKey) else { return nil }
        do {
            let manifest = try openManifest(bodyKey: bodyKey, uid: uid)
            let body = try openBody(downloadedBody: downloadedBody, bodyKey: bodyKey, uid: uid)
            return HermesGatewayOpenedAttachment(
                attachmentId: id,
                fileName: manifest.fileName,
                byteCount: manifest.byteCount,
                contentType: manifest.contentType,
                data: body
            )
        } catch {
            return nil
        }
    }
}

/// Decoded gateway-attachment manifest. The agent seals exactly
/// `{fileName, byteCount, contentType, destinationId}` so the phone can name,
/// size, and route the file without ever exposing that to the server.
struct HermesGatewayAttachmentManifest: Hashable, Sendable {
    let fileName: String
    let byteCount: Int
    let contentType: String?
    let destinationId: String

    init?(jsonData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let fileName = HermesGatewayMessageRecord.string(object["fileName"]),
              let destinationId = HermesGatewayMessageRecord.string(object["destinationId"])
        else { return nil }
        self.fileName = fileName
        self.byteCount =
            (object["byteCount"] as? NSNumber)?.intValue
            ?? (object["byteCount"] as? Int)
            ?? 0
        self.contentType = HermesGatewayMessageRecord.string(object["contentType"])
        self.destinationId = destinationId
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
