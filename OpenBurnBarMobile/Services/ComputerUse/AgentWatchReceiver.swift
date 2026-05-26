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
        if let focus = frame.media?.focusContext {
            state.ingestFocusContext(focus)
        }
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
        case .controlAgentGrantReceipt:
            guard let wireReceipt = frame.control?.agentGrantReceipt,
                  let receipt = try? AgentCapabilityGrantReceipt(wire: wireReceipt) else { return }
            MobileAgentPermissionGrantController.shared.apply(receipt: receipt)
        case .controlSystemPermissionStatus:
            guard let wireStatus = frame.control?.systemPermissionStatus else { return }
            let threadID = HermesService.shared.selectedSessionID ?? frame.control?.sessionId ?? "unknown"
            SystemPermissionInboxStore.shared.ingest(wireStatus: wireStatus, threadID: threadID)
            if wireStatus.status == .granted,
               let item = SystemPermissionInboxStore.shared.latestItem(forThread: threadID),
               item.status == .granted,
               item.originatingToolCallId != nil {
                Task { @MainActor in
                    if let handler = SystemPermissionInboxStore.shared.retryHandler {
                        await handler(item)
                    }
                }
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

    public func tap(normalizedX: Double, normalizedY: Double, displayId: String? = nil, mouseButton: Int = 0) async throws {
        try await sendInputIntent(
            kind: .tap,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            mouseButton: mouseButton
        )
    }

    public func scrollDrag(
        startNormalizedX: Double,
        startNormalizedY: Double,
        endNormalizedX: Double,
        endNormalizedY: Double,
        displayId: String? = nil
    ) async throws {
        try await sendInputIntent(
            kind: .scroll,
            displayId: displayId,
            normalizedX: startNormalizedX,
            normalizedY: startNormalizedY,
            normalizedX2: endNormalizedX,
            normalizedY2: endNormalizedY
        )
    }

    public func type(_ text: String) async throws {
        guard text.isEmpty == false else { return }
        try await sendInputIntent(kind: .type, text: text)
    }

    public func shortcut(key: String, modifiers: [String] = []) async throws {
        try await sendInputIntent(kind: .shortcut, key: key, modifiers: modifiers)
    }

    public func pointerMove(deltaX: Double, deltaY: Double) async throws {
        try await sendInputIntent(kind: .pointerMove, normalizedX2: deltaX, normalizedY2: deltaY)
    }

    public func pointerClick(mouseButton: Int = 0) async throws {
        try await sendInputIntent(kind: .pointerClick, mouseButton: mouseButton)
    }

    public func panicHalt() async throws {
        try await sendInputIntent(kind: .panic)
        state.clear()
    }

    private func sendInputIntent(
        kind: HermesRealtimeRelayInputIntent.Kind,
        displayId: String? = nil,
        normalizedX: Double? = nil,
        normalizedY: Double? = nil,
        normalizedX2: Double? = nil,
        normalizedY2: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        modifiers: [String]? = nil,
        mouseButton: Int? = nil
    ) async throws {
        guard let phoneControlSender else { throw PhoneControlSender.SendError.streamClosed }
        let emptyAuthority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let intent = HermesRealtimeRelayInputIntent(
            kind: kind,
            displayId: displayId,
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            normalizedX2: normalizedX2,
            normalizedY2: normalizedY2,
            text: text,
            key: key,
            modifiers: modifiers,
            mouseButton: mouseButton,
            authority: emptyAuthority
        )
        _ = try await phoneControlSender.send(intent: intent)
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
        case .agentUnavailable, .unknown, .none: return .scopeNotMatched
        }
    }
}
#endif
