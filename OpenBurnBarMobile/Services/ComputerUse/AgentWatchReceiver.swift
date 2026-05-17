#if canImport(UIKit)
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia

/// iOS-side reducer for Computer Use `control.*` frames.
///
/// The transport layer owns bytes and streams; this receiver owns the
/// product state the SwiftUI watch surface renders. It is intentionally
/// deterministic and side-effect-light so tests can feed raw relay
/// frames without starting iroh.
@MainActor
public final class AgentWatchReceiver: ObservableObject {
    public let state: AgentWatchState
    private let approvalFrameSink: PhoneControlSender.FrameSink
    private let phoneControlSender: PhoneControlSender?
    private let uid: String
    private let connectionId: String

    public init(
        state: AgentWatchState = AgentWatchState(),
        uid: String,
        connectionId: String,
        approvalFrameSink: @escaping PhoneControlSender.FrameSink,
        phoneControlSender: PhoneControlSender? = nil
    ) {
        self.state = state
        self.uid = uid
        self.connectionId = connectionId
        self.approvalFrameSink = approvalFrameSink
        self.phoneControlSender = phoneControlSender
    }

    public func ingest(_ frame: HermesRealtimeRelayFrame) {
        guard frame.uid == uid, frame.connectionId == connectionId else { return }
        switch frame.type {
        case .controlClassify:
            if let sessionId = frame.control?.sessionId {
                state.setSession(id: ComputerUseSessionID(sessionId), startedAt: Date())
            }
        case .controlActionLogEntry:
            guard let entry = frame.control?.actionLogEntry else { return }
            state.ingestActionLog(entry)
        case .controlApprovalRequest:
            guard let request = frame.control?.approvalRequest else { return }
            state.setSession(id: ComputerUseSessionID(request.sessionId), startedAt: state.sessionStartedAt ?? request.requestedAt)
            state.setPendingApproval(request)
        case .controlApprovalResponse:
            if let response = frame.control?.approvalResponse,
               state.pendingApproval?.approvalId == response.approvalId {
                state.setPendingApproval(nil)
            }
        case .controlDenied:
            state.setDeniedReason(denyReason(from: frame.control?.denied?.reason))
        default:
            break
        }
    }

    public func ingestSurfaceFrame(_ frame: MediaFrame) {
        state.ingestSurfaceFrame(frame)
    }

    public func approve(_ request: HermesRealtimeRelayApprovalRequest) async throws {
        try await sendApproval(request, decision: .approve, note: nil)
    }

    public func reject(_ request: HermesRealtimeRelayApprovalRequest, halt: Bool) async throws {
        try await sendApproval(
            request,
            decision: halt ? .rejectAndHalt : .reject,
            note: halt ? "Rejected from phone and halted" : "Rejected from phone"
        )
    }

    public func downgradeTrustMode(_ mode: ComputerUseTrustMode) {
        state.setTrustMode(mode)
    }

    public func panicHalt() async throws {
        guard let phoneControlSender else { throw PhoneControlSender.SendError.streamClosed }
        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: .panic,
            authority: emptyAuthority
        )
        _ = try await phoneControlSender.send(intent: intent)
        state.clear()
    }

    private func sendApproval(
        _ request: HermesRealtimeRelayApprovalRequest,
        decision: HermesRealtimeRelayApprovalResponse.Decision,
        note: String?
    ) async throws {
        let response = HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: decision,
            respondedBy: "phone",
            respondedAt: Date(),
            note: note
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlApprovalResponse,
            uid: uid,
            connectionId: connectionId,
            control: HermesRealtimeRelayControlPayload(
                streamClass: "control.approval",
                sessionId: request.sessionId,
                approvalResponse: response
            )
        )
        try await approvalFrameSink(frame)
        state.setPendingApproval(nil)
    }

    private func denyReason(from reason: HermesRealtimeRelayControlDenied.Reason?) -> ComputerUseDenyReason {
        switch reason {
        case .entitlement: return .entitlement
        case .sessionLimit: return .sessionLimit
        case .dailyLimit: return .dailyLimit
        case .softCap: return .softCap
        case .hardCap: return .hardCap
        case .scope: return .scopeDenied
        case .denyRegion: return .denyRegion
        case .killSwitch: return .killSwitch
        case .signatureFailure: return .signatureFailure
        case .counterReplay: return .counterReplay
        case .staleTimestamp: return .staleTimestamp
        case .unknown, .none: return .scopeNotMatched
        }
    }
}
#endif
