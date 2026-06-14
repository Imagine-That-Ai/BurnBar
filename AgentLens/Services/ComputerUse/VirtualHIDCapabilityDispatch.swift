#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore

struct VirtualHIDCapabilityDispatch: Sendable {
    var token: CapabilityToken
    var presentingEscrowDeviceId: String?
    var requiredAttestationHashBlake3: String?
}

func mintRemoteUnlockVirtualHIDCapabilityDispatch(
    actionKind: String,
    sessionId: String?,
    peerNodeId: String?
) async throws -> VirtualHIDCapabilityDispatch {
    let scopeHash = SHA256.hash(data: Data("remote_unlock:\(sessionId ?? "none")".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let binding = await MacRemoteUnlockReadinessService.shared.activeRemoteUnlockBinding(
        sessionId: sessionId,
        peerNodeId: peerNodeId
    )
    guard let token = try await RemoteUnlockCapabilityTokenBroker.shared.mintInputToken(
        actionKind: actionKind,
        scopeHash: scopeHash,
        attestationHashBlake3: binding?.attestationHashBlake3,
        boundEscrowDeviceId: binding?.viewerDeviceId,
        sessionId: sessionId,
        peerNodeId: peerNodeId
    ) else {
        throw ComputerUseSessionCoordinator.CoordinatorError.noActiveSession
    }
    return VirtualHIDCapabilityDispatch(
        token: token,
        presentingEscrowDeviceId: binding?.viewerDeviceId,
        requiredAttestationHashBlake3: binding?.attestationHashBlake3
    )
}
#endif
