import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

// MARK: - HermesGatewayRepository protocol
//
// Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural
// decomposition). Pure move — no behavior change.

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
        phoneRatchetPrekeyBundle: HermesGatewayRatchetPrekeyBundle?,
        phoneSignalPrekeyBundle: FirestoreHermesGatewaySignalPrekeyBundleDoc?
    ) async throws -> HermesGatewayClientRecord

    func listHermesGatewayClients(includeRevoked: Bool) async throws -> [HermesGatewayClientRecord]
    func revokeHermesGatewayClient(clientId: String) async throws

    func hermesGatewayAttachmentDownloadURL(
        attachmentId: String,
        clientId: String,
        destinationId: String?
    ) async throws -> URL

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
            phoneRatchetPrekeyBundle: ratchetBundle,
            phoneSignalPrekeyBundle: nil
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
