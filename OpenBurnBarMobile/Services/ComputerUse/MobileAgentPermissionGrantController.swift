#if canImport(UIKit)
import CryptoKit
import FirebaseAuth
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
        case signingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in before granting desktop permissions."
            case .deviceNotTrusted:
                return "Approve this iPhone or iPad in Devices & Sync before granting Mac permissions."
            case .localAuthenticationFailed:
                return "Device authentication did not complete."
            case .signingFailed(let message):
                return "Could not sign the permission request: \(message)"
            }
        }
    }

    private let signer = ComputerUsePhoneControlSigner()
    private let keyStore: PhoneControlSigningKeyStore
    private let userDefaults: UserDefaults
    private let firestoreProvider: @Sendable () -> Firestore
    private var optimisticReceipts: [String: AgentCapabilityGrantReceipt] = [:]

    init(
        keyStore: PhoneControlSigningKeyStore = .shared,
        userDefaults: UserDefaults = .standard,
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }
    ) {
        self.keyStore = keyStore
        self.userDefaults = userDefaults
        self.firestoreProvider = firestoreProvider
    }

    func grant(
        runtimeID: AssistantRuntimeID,
        threadID: String,
        preset: AgentPermissionPreset,
        deliveryMode: AgentGrantDeliveryMode = .liveThenQueued
    ) async throws -> AgentCapabilityGrantReceipt {
        guard let uid = Auth.auth().currentUser?.uid else { throw GrantError.notSignedIn }
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

        if deliveryMode != .queued,
           let sender = AgentWatchOverlaySingleton.shared.coordinator.phoneControlSender {
            do {
                _ = try await sender.send(agentGrant: request)
                return remember(pendingReceipt(for: request, message: "Sent to your Mac."))
            } catch where deliveryMode == .live {
                throw error
            } catch {
                try await queue(request)
                return remember(pendingReceipt(for: request, message: "Mac was unreachable, so this was queued for 5 minutes."))
            }
        }

        try await queue(request)
        return remember(pendingReceipt(for: request, message: "Queued for your Mac for 5 minutes."))
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
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw GrantError.localAuthenticationFailed
        }
        let reason = "Allow \(preset.title) desktop permissions for this agent thread."
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
        let signedWire = try signedWireRequest(for: request)
        try await publishAuthority(sourceDeviceID: request.sourceDeviceID)
        try await ComputerUseSecurityCallableClient.queueAgentCapabilityGrantRequest(try jsonObject(from: signedWire))
    }

    private func publishAuthority(sourceDeviceID: String) async throws {
        let key = try keyStore.signingKey()
        let peerNodeId = keyStore.peerNodeId(for: key)
        try await ComputerUseSecurityCallableClient.publishAgentGrantAuthority(
            deviceId: sourceDeviceID,
            peerNodeId: peerNodeId,
            publicKeyBase64: key.privateKey.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    private func signedWireRequest(
        for request: AgentCapabilityGrantRequest
    ) throws -> HermesRealtimeRelayAgentGrantRequest {
        let key = try keyStore.signingKey()
        let peerNodeId = keyStore.peerNodeId(for: key)
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
            signed = try signer.sign(
                request: unsignedWire,
                peerNodeId: peerNodeId,
                counter: counter,
                timestamp: timestamp,
                privateKey: key.privateKey
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
                privateKey: key.privateKey
            )
        }
        return signedRequest.wire(authority: HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: signed.peerNodeId,
            counter: signed.counter,
            timestamp: signed.timestamp,
            intentHashBlake3: signed.intentHashHex,
            signatureEd25519: signed.signatureBase64
        ))
    }

    private func nextCounter(peerNodeId: String) -> UInt64 {
        PhoneControlSender.nextCounter(peerNodeId: peerNodeId, userDefaults: userDefaults)
    }

    private func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
#endif
