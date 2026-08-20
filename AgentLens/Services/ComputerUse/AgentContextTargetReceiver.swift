#if canImport(AppKit) && !DISTRIBUTION_MAS
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// Receiver class for controlAgentContextTarget frames on the Mac side.
/// It validates the Ed25519 signature of incoming context targets,
/// denormalizes targeting coordinates, performs AX tree probes at the target point,
/// performs deny-region checks, and routes the context cleanly to the active agent thread in ChatSessionController.
final class AgentContextTargetReceiver: Sendable {
    typealias FrameSink = @Sendable (HermesRealtimeRelayFrame) async throws -> Void
    typealias DisplayBoundsProvider = @Sendable () -> [MacInputCore.DisplayBounds]
    typealias AuthorizedPeerNodeProvider = @MainActor @Sendable () -> String?

    let sessionId: ComputerUseSessionID
    let validator: PhoneControlAuthorityValidator
    private let chatControllerProvider: @MainActor () -> ChatSessionController?
    private let macAccessibilityInspector: MacAccessibilityInspector
    private let displayBoundsProvider: DisplayBoundsProvider
    private let replyFrameSink: FrameSink
    private let auditLoggerProvider: @MainActor () -> ComputerUseAuditLogger?
    private let authorizedPeerNodeProvider: AuthorizedPeerNodeProvider?

    private let seenClientIntentIds = Locked<Set<String>>([])

    init(
        sessionId: ComputerUseSessionID,
        validator: PhoneControlAuthorityValidator,
        chatControllerProvider: @escaping @MainActor () -> ChatSessionController?,
        macAccessibilityInspector: MacAccessibilityInspector = MacAccessibilityInspector(),
        displayBoundsProvider: @escaping DisplayBoundsProvider,
        authorizedPeerNodeProvider: AuthorizedPeerNodeProvider? = nil,
        replyFrameSink: @escaping FrameSink,
        auditLoggerProvider: @escaping @MainActor () -> ComputerUseAuditLogger?
    ) {
        self.sessionId = sessionId
        self.validator = validator
        self.chatControllerProvider = chatControllerProvider
        self.macAccessibilityInspector = macAccessibilityInspector
        self.displayBoundsProvider = displayBoundsProvider
        self.replyFrameSink = replyFrameSink
        self.auditLoggerProvider = auditLoggerProvider
        self.authorizedPeerNodeProvider = authorizedPeerNodeProvider
    }

    func ingest(_ frame: HermesRealtimeRelayFrame) async {
        guard frame.type == .controlAgentContextTarget,
              let payload = frame.control,
              let target = payload.agentContextTarget else { return }

        let targetSessionID = Self.nonEmptyTrimmed(target.sessionId)
        let payloadSessionID = Self.nonEmptyTrimmed(payload.sessionId)
        if let targetSessionID, targetSessionID != sessionId.rawValue {
            await emitDeniedFrame(
                reason: .scope,
                detail: "session_mismatch",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }
        if targetSessionID == nil, let payloadSessionID, payloadSessionID != sessionId.rawValue {
            await emitDeniedFrame(
                reason: .scope,
                detail: "session_mismatch",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        guard let authorizedPeerNode = await activeAuthorizedPeerNode() else {
            await emitDeniedFrame(
                reason: .scope,
                detail: "no_active_control_viewer",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
            return
        }

        // 1. Validate authority & counter replay.
        let validation: PhoneControlAuthorityValidator.ValidationResult
        do {
            validation = try validator.validate(
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

        if validation.peerNodeId != authorizedPeerNode {
            await emitDeniedFrame(
                reason: .scope,
                detail: "control_owned_by_other_viewer",
                uid: frame.uid,
                connectionId: frame.connectionId
            )
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
            // try?-ok(fallback to {} below)
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]),
               let str = String(data: data, encoding: .utf8) {
                metadataString = str
            } else {
                metadataString = "{}"
            }

            // Visible user content: Use this screen target: <instruction>
            // Plus hidden structured metadata.
            let fullContent = "Use this screen target: \(target.instruction)\n\n<metadata>\n\(metadataString)\n</metadata>"

            let workspaceRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".burnbar/attachments", isDirectory: true)
            let landed = MacAttachmentLandingService.hermesAttachments(
                from: MacAttachmentLandingService.takePending(),
                workspaceRoot: workspaceRoot
            )
            let userMsg = ChatMessageRecord(
                role: .user,
                content: fullContent,
                attachments: landed
            )

            chatController.messages.append(userMsg)
            Task {
                do {
                    try await chatController.dataStore.saveChatMessage(userMsg, threadID: activeThread)
                } catch {
                    AppLogger.chat.silentFailure("saveChatMessage (copilot)", error: error)
                }
            }
            chatController.refreshHistory()

            // Automatically trigger agent execution loop if it is not already busy.
            if !chatController.isSendBusy {
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
        // ComputerUseAuditLogger maintains a mutable hash chain and is owned by the
        // @MainActor coordinator, so the whole audit append runs on the main actor;
        // only Sendable primitives cross the hop (no non-Sendable target/snapshot/logger).
        let auditNormalizedX = target.normalizedX
        let auditNormalizedY = target.normalizedY
        let auditInstruction = target.instruction
        let auditBundleId = snapshot?.bundleId
        let auditWindowTitle = snapshot?.title
        await MainActor.run {
            guard let logger = auditLoggerProvider() else { return }
            let contextIntent = PhoneControlIntent(
                kind: .contextTarget,
                normalizedX: auditNormalizedX,
                normalizedY: auditNormalizedY,
                text: auditInstruction
            )
            let action = ComputerUseAction.phoneIntent(contextIntent)

            let scopeContext = ComputerUseScopeContext(
                url: nil,
                bundleId: auditBundleId,
                windowTitle: auditWindowTitle
            )

            do {
                let entry = try logger.makeEntry(
                    for: action,
                    approvedBy: .phone,
                    scopeContext: scopeContext
                )
                try logger.append(entry)
            } catch {
                // A dropped phone-intent entry is a gap in the tamper-evident
                // audit chain — surface it instead of swallowing.
                AppLogger.chat.error(
                    "computer_use_phone_intent_audit_entry_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
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
        try? await replyFrameSink(ackFrame) // try?-ok(fire-and-forget ack)
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
        seenClientIntentIds.withLock { seenClientIntentIds in
            if seenClientIntentIds.contains(clientIntentId) {
                return false
            }
            seenClientIntentIds.insert(clientIntentId)
            return true
        }
    }

    private func activeAuthorizedPeerNode() async -> String? {
        await MainActor.run {
            Self.nonEmptyTrimmed(authorizedPeerNodeProvider?())
        }
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        try? await replyFrameSink(frame) // try?-ok(notify already-enforced deny)
    }

    private func deniedReason(for error: PhoneControlAuthorityValidator.ValidationError) -> HermesRealtimeRelayControlDenied.Reason {
        error.relayControlDeniedReason
    }
}
#endif
