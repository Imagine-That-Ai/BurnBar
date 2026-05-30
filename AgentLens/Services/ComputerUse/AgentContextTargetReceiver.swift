#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Receiver class for controlAgentContextTarget frames on the Mac side.
/// It validates the Ed25519 signature of incoming context targets,
/// denormalizes targeting coordinates, performs AX tree probes at the target point,
/// performs deny-region checks, and routes the context cleanly to the active agent thread in ChatSessionController.
final class AgentContextTargetReceiver: @unchecked Sendable {
    typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    typealias DisplayBoundsProvider = @Sendable () -> [MacInputCore.DisplayBounds]

    let sessionId: ComputerUseSessionID
    let validator: PhoneControlAuthorityValidator
    private let chatControllerProvider: @MainActor () -> ChatSessionController?
    private let macAccessibilityInspector: MacAccessibilityInspector
    private let displayBoundsProvider: DisplayBoundsProvider
    private let replyFrameSink: FrameSink
    private let auditLoggerProvider: () -> ComputerUseAuditLogger?

    private var seenClientIntentIds: Set<String> = []
    private let seenIntentQueue = DispatchQueue(label: "com.openburnbar.agentContextTarget.receiver.seenIntentIds")

    init(
        sessionId: ComputerUseSessionID,
        validator: PhoneControlAuthorityValidator,
        chatControllerProvider: @escaping @MainActor () -> ChatSessionController?,
        macAccessibilityInspector: MacAccessibilityInspector = MacAccessibilityInspector(),
        displayBoundsProvider: @escaping DisplayBoundsProvider,
        replyFrameSink: @escaping FrameSink,
        auditLoggerProvider: @escaping () -> ComputerUseAuditLogger?
    ) {
        self.sessionId = sessionId
        self.validator = validator
        self.chatControllerProvider = chatControllerProvider
        self.macAccessibilityInspector = macAccessibilityInspector
        self.displayBoundsProvider = displayBoundsProvider
        self.replyFrameSink = replyFrameSink
        self.auditLoggerProvider = auditLoggerProvider
    }

    func ingest(_ frame: HermesRealtimeRelayFrame) async {
        guard frame.type == .controlAgentContextTarget,
              let payload = frame.control,
              let target = payload.agentContextTarget else { return }

        // 1. Validate authority & counter replay.
        do {
            _ = try validator.validate(
                envelope: target.authority,
                target: target,
                now: Date()
            )
        } catch let error as PhoneControlAuthorityValidator.ValidationError {
            await emitDeniedFrame(reason: deniedReason(for: error), uid: frame.uid, connectionId: frame.connectionId)
            return
        } catch {
            await emitDeniedFrame(reason: .signatureFailure, uid: frame.uid, connectionId: frame.connectionId)
            return
        }

        if !target.clientIntentId.isEmpty, markClientIntentSeen(target.clientIntentId) == false {
            await emitDeniedFrame(
                reason: .counterReplay,
                detail: "duplicate_client_intent",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        // 2. Coordinate denormalization.
        guard let (displayX, displayY) = denormalize(target.normalizedX, target.normalizedY, displayId: target.displayId) else {
            await emitDeniedFrame(
                reason: .unknown,
                detail: "malformed_coordinates",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        // 3. Accessibility enrichment.
        let snapshot = macAccessibilityInspector.snapshotAtPoint(x: displayX, y: displayY)

        // 4. Reject secure & hard-deny regions (loginwindow, secure fields, auth dialogs, etc.).
        if let deny = macAccessibilityInspector.denyReason(for: snapshot) {
            await emitDeniedFrame(
                reason: .denyRegion,
                detail: "deny_region_\(deny.rawValue)",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        // 5. Dispatch target context to the active agent.
        let dispatched = await MainActor.run { () -> Bool in
            guard let chatController = chatControllerProvider() else {
                return false
            }

            // Map target.runtime ("hermes", "pi", "codex", "claude", "openclaw") to ChatBackendID.
            let backend: ChatBackendID
            switch target.runtime.lowercased() {
            case "hermes": backend = .hermes
            case "pi", "piagent": backend = .piAgent
            case "codex": backend = .codex
            case "claude": backend = .claude
            case "openclaw": backend = .openclaw
            default: return false
            }

            // Route to target thread if explicit threadId is present.
            if let threadId = target.threadId, !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chatController.openOrCreateChatThread(id: threadId)
            } else {
                // Otherwise, switch backend and resolve active thread.
                chatController.setChatBackend(backend)
            }

            // Check if active thread is available. If none exists, return false.
            let activeThread = chatController.activeThreadID
            if activeThread.isEmpty {
                return false
            }

            // Build structured metadata
            var focusDict: [String: String] = [:]
            if let snap = snapshot {
                focusDict["appName"] = snap.bundleId ?? ""
                focusDict["bundleId"] = snap.bundleId ?? ""
                focusDict["windowTitle"] = snap.title ?? ""
                focusDict["axRole"] = snap.role ?? ""
                focusDict["axTitle"] = snap.title ?? ""
            }

            let metadata: [String: Any] = [
                "kind": "mac_screen_target",
                "runtime": target.runtime,
                "threadId": activeThread,
                "displayId": target.displayId ?? "",
                "normalizedPoint": ["x": target.normalizedX, "y": target.normalizedY],
                "displayPoint": ["x": displayX, "y": displayY],
                "focus": focusDict
            ]

            let metadataString: String
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                metadataString = str
            } else {
                metadataString = "{}"
            }

            // Visible user content: Use this screen target: <instruction>
            // Plus hidden structured metadata.
            let fullContent = "Use this screen target: \(target.instruction)\n\n<metadata>\n\(metadataString)\n</metadata>"

            let userMsg = ChatMessageRecord(
                role: .user,
                content: fullContent,
                attachments: []
            )

            chatController.messages.append(userMsg)
            do {
                try chatController.dataStore.saveChatMessage(userMsg, threadID: activeThread)
            } catch {
                AppLogger.chat.silentFailure("saveChatMessage (copilot)", error: error)
            }
            chatController.refreshHistory()

            // Automatically trigger agent execution loop if it's not streaming!
            if !chatController.isStreaming {
                chatController.fireAndForgetSend()
            }

            return true
        }

        if !dispatched {
            await emitDeniedFrame(
                reason: .agentUnavailable,
                detail: "no_active_agent_thread",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        // 6. Audit target event without sensitive values or screenshot bytes.
        if let logger = auditLoggerProvider() {
            let contextIntent = PhoneControlIntent(
                kind: .contextTarget,
                normalizedX: target.normalizedX,
                normalizedY: target.normalizedY,
                text: target.instruction
            )
            let action = ComputerUseAction.phoneIntent(contextIntent)

            let scopeContext = ComputerUseScopeContext(
                url: nil,
                bundleId: snapshot?.bundleId,
                windowTitle: snapshot?.title
            )

            if let entry = try? logger.makeEntry(
                for: action,
                approvedBy: .phone,
                scopeContext: scopeContext
            ) {
                _ = try? logger.append(entry)
            }
        }

        // 7. Acknowledge back to the phone.
        let ackPayload = HermesRealtimeRelayControlPayload(
            streamClass: "control.input",
            sessionId: sessionId.rawValue,
            agentContextTarget: target
        )
        let ackFrame = HermesRealtimeRelayFrame(
            type: .controlAgentContextTarget,
            uid: frame.uid,
            connectionId: frame.connectionId,
            control: ackPayload
        )
        try? await replyFrameSink(ackFrame)
    }

    private func denormalize(_ nx: Double?, _ ny: Double?, displayId: String?) -> (Int, Int)? {
        guard let nx, let ny else { return nil }
        let displays = displayBoundsProvider()
        let display = displayId.flatMap { id in
            displays.first { $0.displayId == id }
        } ?? displays.first
        guard let point = MacInputCore.denormalize(normalizedX: nx, normalizedY: ny, in: display) else {
            return nil
        }
        return (point.x, point.y)
    }

    private func markClientIntentSeen(_ clientIntentId: String) -> Bool {
        seenIntentQueue.sync {
            if seenClientIntentIds.contains(clientIntentId) {
                return false
            }
            seenClientIntentIds.insert(clientIntentId)
            return true
        }
    }

    private func emitDeniedFrame(
        reason: HermesRealtimeRelayControlDenied.Reason,
        detail: String? = nil,
        uid: String,
        connectionId: String
    ) async {
        let payload = HermesRealtimeRelayControlPayload(
            streamClass: "control.input",
            sessionId: sessionId.rawValue,
            denied: HermesRealtimeRelayControlDenied(reason: reason, detail: detail)
        )
        let frame = HermesRealtimeRelayFrame(
            type: .controlDenied,
            uid: uid,
            connectionId: connectionId,
            control: payload
        )
        try? await replyFrameSink(frame)
    }

    private func deniedReason(for error: PhoneControlAuthorityValidator.ValidationError) -> HermesRealtimeRelayControlDenied.Reason {
        error.relayControlDeniedReason
    }
}
#endif
