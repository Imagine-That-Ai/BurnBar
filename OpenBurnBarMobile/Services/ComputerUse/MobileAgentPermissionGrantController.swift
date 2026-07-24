#if canImport(UIKit)
import CryptoKit
import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import Foundation
import LocalAuthentication
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

@MainActor
final class MobileAgentPermissionGrantController {
    static let shared = MobileAgentPermissionGrantController()

    enum GrantError: LocalizedError {
        case notSignedIn
        case deviceNotTrusted
        case localAuthenticationFailed
        case liveDeliveryUnavailable
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in before granting desktop permissions."
            case .deviceNotTrusted:
                return "Approve this iPhone or iPad in Devices & Sync before granting Mac permissions."
            case .localAuthenticationFailed:
                return "Device authentication did not complete."
            case .liveDeliveryUnavailable:
                return "The live connection to your desktop is unavailable."
            case .signingFailed(let message):
                return "Could not sign the permission request: \(message)"
            }
        }
    }

    typealias LiveGrantDelivery = (AgentCapabilityGrantRequest) async throws -> Bool
    typealias QueuedGrantDelivery = (AgentCapabilityGrantRequest) async throws -> Void
    typealias DeviceOwnerAuthenticator = (_ reason: String) async throws -> Bool

    private let signer = ComputerUsePhoneControlSigner()
    private let keyStore: PhoneControlSigningKeyStore
    private let userDefaults: UserDefaults
    private let firestoreProvider: @Sendable () -> Firestore
    private let liveGrantDelivery: LiveGrantDelivery
    private let queuedGrantDelivery: QueuedGrantDelivery?
    private let deviceOwnerAuthenticator: DeviceOwnerAuthenticator
    private var optimisticReceipts: [String: AgentCapabilityGrantReceipt] = [:]

    init(
        keyStore: PhoneControlSigningKeyStore = .shared,
        userDefaults: UserDefaults = .standard,
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        liveGrantDelivery: LiveGrantDelivery? = nil,
        queuedGrantDelivery: QueuedGrantDelivery? = nil,
        deviceOwnerAuthenticator: DeviceOwnerAuthenticator? = nil
    ) {
        self.keyStore = keyStore
        self.userDefaults = userDefaults
        self.firestoreProvider = firestoreProvider
        self.liveGrantDelivery = liveGrantDelivery ?? { request in
            guard let sender = AgentWatchOverlaySingleton.shared.coordinator.phoneControlSender else {
                return false
            }
            _ = try await sender.send(agentGrant: request)
            return true
        }
        self.queuedGrantDelivery = queuedGrantDelivery
        self.deviceOwnerAuthenticator = deviceOwnerAuthenticator ?? Self.evaluateDeviceOwnerAuthentication(reason:)
    }

    private var currentUID: String? {
        guard FirebaseApp.app() != nil else { return nil }
        return Auth.auth().currentUser?.uid
    }

    func grant(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        preset: AgentPermissionPreset,
        deliveryMode: AgentGrantDeliveryMode = .liveThenQueued
    ) async throws -> AgentCapabilityGrantReceipt {
        guard let uid = currentUID else { throw GrantError.notSignedIn }
        let deviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
        try await ensureTrustedDevice(uid: uid, sourceDeviceID: deviceID)
        let authenticated = try await authenticateIfNeeded(for: preset)
        let request = AgentCapabilityGrantRequest(
            runtimeID: runtimeID,
            threadID: threadID,
            preset: preset,
            deliveryMode: deliveryMode,
            sourceDeviceID: deviceID,
            localAuthenticationSatisfied: authenticated
        )

        return try await deliver(uid: uid, request: request)
    }

    /// Issues a grant for one exact Linux Computer Use session. Validation is
    /// completed before device-owner authentication, and the generic grant API
    /// remains available for non-challenge permission changes.
    func grant(
        sessionChallenge: HermesRealtimeRelaySessionGrantChallenge,
        liveGrantDelivery: @escaping LiveGrantDelivery,
        authenticationWillBegin: @MainActor @Sendable () -> Void = {}
    ) async throws -> AgentCapabilityGrantReceipt {
        guard let uid = currentUID else { throw GrantError.notSignedIn }
        let deviceID = MobileDeviceIdentity.loadOrCreateDeviceId()
        var request = try AgentCapabilityGrantRequest(
            validatedSessionChallenge: sessionChallenge,
            sourceDeviceID: deviceID,
            deliveryMode: .live,
            now: Date(),
            signer: signer
        )
        try await ensureTrustedDevice(uid: uid, sourceDeviceID: deviceID)
        authenticationWillBegin()
        request.localAuthenticationSatisfied = try await authenticateSessionGrant(for: request.preset)
        return try await deliver(
            uid: uid,
            request: request,
            liveGrantDelivery: liveGrantDelivery
        )
    }

    func deliver(
        uid: String,
        request: AgentCapabilityGrantRequest,
        liveGrantDelivery routeBoundLiveGrantDelivery: LiveGrantDelivery? = nil
    ) async throws -> AgentCapabilityGrantReceipt {
        if request.deliveryMode != .queued {
            do {
                let delivery = routeBoundLiveGrantDelivery ?? liveGrantDelivery
                if try await delivery(request) {
                    return remember(pendingReceipt(for: request, message: "Sent to your Mac."))
                }
                if request.deliveryMode == .live {
                    throw GrantError.liveDeliveryUnavailable
                }
            } catch {
                if request.deliveryMode == .live {
                    throw error
                }
                try await enqueue(request)
                return remember(pendingReceipt(for: request, message: "Mac was unreachable, so this was queued for 5 minutes."))
            }
        }

        try await enqueue(request)
        return remember(pendingReceipt(for: request, message: "Queued for your Mac for 5 minutes."))
    }

    private func enqueue(_ request: AgentCapabilityGrantRequest) async throws {
        if let queuedGrantDelivery {
            try await queuedGrantDelivery(request)
        } else {
            try await queue(request)
        }
    }

    func optimisticGrant(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        now: Date = Date()
    ) -> AgentCapabilityGrantReceipt? {
        let key = receiptKey(runtimeID: runtimeID, threadID: threadID)
        guard let receipt = optimisticReceipts[key],
              receipt.status != .denied,
              !receipt.capabilities.isEmpty,
              (receipt.grantExpiresAt ?? .distantPast) > now else {
            return nil
        }
        return receipt
    }

    func apply(receipt: AgentCapabilityGrantReceipt) {
        optimisticReceipts[receiptKey(runtimeID: receipt.runtimeID, threadID: receipt.threadID)] = receipt
    }

    private func authenticateIfNeeded(for preset: AgentPermissionPreset) async throws -> Bool {
        guard preset.requiresLocalAuthentication else { return false }
        return try await authenticateDeviceOwner(
            reason: "Allow \(preset.title) desktop permissions for this agent thread."
        )
    }

    func authenticateSessionGrant(for preset: AgentPermissionPreset) async throws -> Bool {
        try await authenticateDeviceOwner(
            reason: "Approve this \(preset.title) Computer Use session."
        )
    }

    private func authenticateDeviceOwner(reason: String) async throws -> Bool {
        try await deviceOwnerAuthenticator(reason)
    }

    private static func evaluateDeviceOwnerAuthentication(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw GrantError.localAuthenticationFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                if success {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(throwing: GrantError.localAuthenticationFailed)
                }
            }
        }
    }

    private func pendingReceipt(
        for request: AgentCapabilityGrantRequest,
        message: String
    ) -> AgentCapabilityGrantReceipt {
        AgentCapabilityGrantReceipt(
            requestID: request.requestID,
            runtimeID: request.runtimeID,
            threadID: request.threadID,
            status: .queued,
            capabilities: request.capabilities,
            trustMode: request.trustMode,
            receivedAt: Date(),
            grantExpiresAt: request.grantExpiresAt(),
            sourceDeviceID: request.sourceDeviceID,
            message: message
        )
    }

    private func remember(_ receipt: AgentCapabilityGrantReceipt) -> AgentCapabilityGrantReceipt {
        optimisticReceipts[receiptKey(runtimeID: receipt.runtimeID, threadID: receipt.threadID)] = receipt
        return receipt
    }

    private func receiptKey(runtimeID: AssistantRuntimeID, threadID: String) -> String {
        "\(runtimeID.rawValue)|\(threadID)"
    }

    private func ensureTrustedDevice(uid: String, sourceDeviceID: String) async throws {
        await LiveDeviceTrustGateway().registerSelfIfNeeded()
        let snapshot = try await firestoreProvider()
            .collection("users")
            .document(uid)
            .collection("escrow_devices")
            .document(sourceDeviceID)
            .getDocument()
        guard (snapshot.data()?["trustState"] as? String) == EscrowDeviceTrustState.trusted.rawValue else {
            throw GrantError.deviceNotTrusted
        }
    }

    private func queue(_ request: AgentCapabilityGrantRequest) async throws {
        let identity = try keyStore.signingIdentity()
        let peerNodeId = keyStore.peerNodeId(for: identity)
        try await PhoneControlSendSequencer.shared.enqueue(peerNodeId: peerNodeId) { [self] in
            let signedWire = try await signedWireRequest(
                for: request,
                identity: identity,
                peerNodeId: peerNodeId
            )
            try await publishAuthority(
                sourceDeviceID: request.sourceDeviceID,
                identity: identity,
                peerNodeId: peerNodeId
            )
            try await ComputerUseSecurityCallableClient.queueAgentCapabilityGrantRequest(
                signedWire
            )
        }
    }

    private func publishAuthority(
        sourceDeviceID: String,
        identity: PhoneControlAuthoritySigningKey,
        peerNodeId: String
    ) async throws {
        try await ComputerUseSecurityCallableClient.publishAgentGrantAuthority(
            deviceId: sourceDeviceID,
            peerNodeId: peerNodeId,
            publicKeyBase64: identity.publicKeyRepresentation.base64EncodedString(),
            keyKind: identity.kind
        )
    }

    private func signedWireRequest(
        for request: AgentCapabilityGrantRequest,
        identity: PhoneControlAuthoritySigningKey,
        peerNodeId: String
    ) throws -> HermesRealtimeRelayAgentGrantRequest {
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: request.requestedAt,
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let unsignedWire = request.wire(authority: placeholder)
        let counter = nextCounter(peerNodeId: peerNodeId)
        let timestamp = Date()
        let signed: ComputerUsePhoneControlSigner.SignedAuthority
        do {
            signed = try signer.signAuthority(
                intentHashHex: signer.canonicalAgentGrantRequestHashHex(request: unsignedWire),
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                key: identity
            )
        } catch {
            throw GrantError.signingFailed(error.localizedDescription)
        }
        var signedRequest = request
        if request.localAuthenticationSatisfied {
            signedRequest.localAuthProof = try signer.signLocalAuthProof(
                deviceId: request.sourceDeviceID,
                signedIntentHash: signed.intentHashHex,
                authenticatedAt: signed.timestamp,
                expiresAt: request.expiresAt,
                key: identity
            )
        }
        return signedRequest.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64,
            keyKind: identity.wireKeyKind
        ))
    }

    private func nextCounter(peerNodeId: String) -> UInt64 {
        PhoneControlSender.nextCounter(peerNodeId: peerNodeId, userDefaults: userDefaults)
    }

}
#endif
