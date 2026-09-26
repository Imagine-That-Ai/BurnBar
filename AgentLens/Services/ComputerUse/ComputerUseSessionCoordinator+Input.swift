#if canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarQuota
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

// Input handling forwards onto ComputerUseInputPipeline.

extension ComputerUseSessionCoordinator {
    func shouldUseVirtualHIDForLockedInput() -> Bool {
        return inputPipeline.shouldUseVirtualHIDForLockedInput()
    }

    func mintVirtualHIDCapabilityDispatch(actionKind: String) async throws -> VirtualHIDCapabilityDispatch {
        return try await inputPipeline.mintVirtualHIDCapabilityDispatch(actionKind: actionKind)
    }

    func emitControlSealDenied(detail: String, frame: HermesRealtimeRelayFrame) {
        inputPipeline.emitControlSealDenied(detail: detail, frame: frame)
    }

    func establishControlSealSession(
        envelope: HermesRealtimeRelayControlSealKeyEnvelope,
        uid: String,
        connectionId: String,
        peerNodeId: String
    ) async throws -> SymmetricKey {
        return try await inputPipeline.establishControlSealSession(envelope: envelope, uid: uid, connectionId: connectionId, peerNodeId: peerNodeId)
    }

    func handleControlFrame(
        _ rawFrame: HermesRealtimeRelayFrame,
        replySender: @escaping @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    ) async {
        await inputPipeline.handleControlFrame(rawFrame, replySender: replySender)
    }

    #if DEBUG
    func startE2EApprovalProbeIfRequested() {
        inputPipeline.startE2EApprovalProbeIfRequested()
    }
    #endif

    func handlePhoneAction(_ action: ComputerUseAction, sessionId: ComputerUseSessionID, counter: UInt64) async {
        await inputPipeline.handlePhoneAction(action, sessionId: sessionId, counter: counter)
    }

    func refocusPhoneKeyboardTargetIfNeeded(for action: ComputerUseAction) {
        inputPipeline.refocusPhoneKeyboardTargetIfNeeded(for: action)
    }

    func emitPhoneControlDeniedFrameIfNeeded(_ response: ComputerUseInvokeResponse) {
        inputPipeline.emitPhoneControlDeniedFrameIfNeeded(response)
    }

    func applyRemoteClipboardResult(_ result: RemoteClipboardController.Result) {
        inputPipeline.applyRemoteClipboardResult(result)
    }

}

#endif
