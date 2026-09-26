#if os(Linux)
import Foundation
import OpenBurnBarEngine
import OpenBurnBarMedia

extension MercuryLinuxMediaSessionController {
    func sendDecision(
        for pending: PendingSession,
        accepted: Bool,
        sessionID: String?,
        detail: String?
    ) async {
        guard let replySender = pending.replySender else { return }
        let frame: HermesRealtimeRelayFrame
        switch pending.kind {
        case .mirror:
            frame = HermesRealtimeRelayFrame(
                type: .mediaMirrorAck,
                uid: pending.uid,
                connectionId: pending.connectionID,
                requestId: pending.requestID,
                media: HermesRealtimeRelayMediaPayload(
                    mirrorAck: HermesRealtimeRelayMirrorAck(
                        requestId: pending.requestID,
                        decision: accepted ? .accepted : .denied,
                        detail: detail,
                        sessionId: sessionID,
                        streamingCapabilities: nil,
                        mediaFrameSealEstablished: mediaFrameSealKey != nil
                    )
                )
            )
        case .call:
            frame = HermesRealtimeRelayFrame(
                type: .mediaCallAck,
                uid: pending.uid,
                connectionId: pending.connectionID,
                requestId: pending.requestID,
                media: HermesRealtimeRelayMediaPayload(
                    callAck: HermesRealtimeRelayCallAck(
                        requestId: pending.requestID,
                        decision: accepted ? .accepted : .denied,
                        detail: detail
                    )
                )
            )
        }
        do {
            try await replySender(frame)
        } catch {
            logger.warning("linux_media_reply_failed", metadata: ["error": "\(error)"])
        }
    }

    func sendBusyMirrorAck(
        frame: HermesRealtimeRelayFrame,
        request: HermesRealtimeRelayMirrorRequest,
        replySender: MercuryLinuxMediaReplySender?
    ) async {
        guard let replySender else { return }
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaMirrorAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: request.requestId,
            media: HermesRealtimeRelayMediaPayload(
                mirrorAck: HermesRealtimeRelayMirrorAck(
                    requestId: request.requestId,
                    decision: .busy,
                    detail: "Linux Mercury media is already streaming."
                )
            )
        )
        try? await replySender(outbound)
    }

    func sendBusyCallAck(
        frame: HermesRealtimeRelayFrame,
        invite: HermesRealtimeRelayCallInvite,
        replySender: MercuryLinuxMediaReplySender?
    ) async {
        guard let replySender else { return }
        let outbound = HermesRealtimeRelayFrame(
            type: .mediaCallAck,
            uid: frame.uid,
            connectionId: frame.connectionId,
            requestId: invite.requestId,
            media: HermesRealtimeRelayMediaPayload(
                callAck: HermesRealtimeRelayCallAck(
                    requestId: invite.requestId,
                    decision: .busy,
                    detail: "Linux Mercury media is already streaming."
                )
            )
        )
        try? await replySender(outbound)
    }
}
#endif
