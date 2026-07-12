import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Mission cancellation, approval, and failure state flow.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

extension CLIAgentMissionRequestListener {
    func handleCancellation(document: QueryDocumentSnapshot, backend: CLIAgentMissionBackend) async {
        logger.warning("handling cancellation for mission id=\(document.documentID, privacy: .public)")
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "cancelled",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: "Mission cancelled by user."
                ),
                merge: true
            )
        } catch {
            logger.error("failed to update cancellation status in firestore: \(error.localizedDescription, privacy: .public)")
        }
        await recordEvent(
            reference: document.reference,
            requestID: document.documentID,
            phase: "cancelled",
            kind: "status",
            title: "Cancelled",
            message: "Mission cancelled by user.",
            backend: backend,
            isError: true
        )
    }

    func modelAwareSuccessMessage(
        backend: CLIAgentMissionBackend,
        requestedModelID: String?,
        fallback: String
    ) -> String {
        let preview = fallback.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let preview {
            return "\(backend.displayName): \(preview.prefix(180).description)"
        }
        if let requestedModelID {
            return "\(backend.displayName) returned a result from model \(requestedModelID)."
        }
        return "\(backend.displayName) returned a result."
    }

    func modelAwareFailureMessage(
        backend: CLIAgentMissionBackend,
        requestedModelID: String?,
        errorMessage: String?
    ) -> String {
        let safeError = errorMessage
            .flatMap { CLIAgentMissionEventFactory.mobileSafeText($0, limit: 1800).nilIfEmpty }
        let prefix = requestedModelID.map {
            "\(backend.displayName) failed while running selected model \($0)."
        } ?? "\(backend.displayName) mission failed."
        guard let safeError else { return prefix }
        return "\(prefix) \(safeError)"
    }

    func fail(document: QueryDocumentSnapshot, message: String) async {
        let safeMessage = CLIAgentMissionEventFactory.mobileSafeText(message, limit: 2048)
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "failed",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: safeMessage,
                    errorMessage: safeMessage
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "failed",
                kind: "error",
                title: "Failed",
                message: safeMessage,
                backend: nil,
                isError: true
            )
            logger.info("marked mission failed id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission failure update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // The allow / requires-approval / deny DECISION (`shouldPauseForApproval`,
    // `missionRequiresApproval`) moved to the daemon in split-brain M4; the
    // daemon-driven writeback helpers live in
    // `MissionRemoteAuthorizationEnforcement.swift` (outside the frozen cluster).
    // The approval-request writeback (`requestApproval`) and cancellation
    // writeback (`cancelAfterApprovalDecision`) below stay: they render the
    // daemon's `.requiresApproval` / `.denied` verdicts into mission state.

    func failAfterTrustedClaim(document: QueryDocumentSnapshot, backend: CLIAgentMissionBackend, message: String) async {
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "failed",
                        "claimedBy": accountManager.deviceId,
                        "selectedRuntime": backend.rawValue,
                        "selectedRuntimeName": backend.displayName,
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    errorMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "failed",
                kind: "error",
                title: "Failed",
                message: message,
                backend: backend,
                isError: true
            )
            logger.info("marked trusted mission failed id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("trusted mission failure update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestApproval(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend
    ) async {
        let approvalID = (data["approvalRequestId"] as? String)?.nilIfEmpty ?? "approval-\(UUID().uuidString)"
        let title = (data["title"] as? String)?.nilIfEmpty ?? "Mobile mission"
        let approvalMode = (data["approvalMode"] as? String)?.nilIfEmpty ?? "existing_policy"
        let commandsAllowed = ((data["commandsAllowed"] as? Bool) ?? false) ? "commands" : nil
        let fileEditsAllowed = ((data["fileEditsAllowed"] as? Bool) ?? false) ? "file edits" : nil
        let riskyScope = [commandsAllowed, fileEditsAllowed].compactMap { $0 }.joined(separator: " and ")
        let scope = riskyScope.nilIfEmpty ?? "mission execution"
        let message = "\(backend.displayName) is waiting for approval before \(scope). Approval mode: \(approvalMode)."
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "waiting_for_approval",
                        "claimedBy": accountManager.deviceId,
                        "approvalRequestId": approvalID,
                        "approvalStatus": "pending",
                        "approvalRequestedAt": ISO8601DateFormatter().string(from: Date()),
                        "selectedRuntime": backend.rawValue,
                        "selectedRuntimeName": backend.displayName,
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    approvalTitle: "Approve \(title)",
                    approvalMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "accepted",
                kind: "status",
                title: "Accepted",
                message: "\(backend.displayName) accepted the mission on this Mac and is waiting for approval.",
                backend: backend
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "approval_requested",
                kind: "approval_request",
                title: "Approval required",
                message: message,
                backend: backend
            )
            logger.info("mission id=\(document.documentID, privacy: .public) waiting for mobile approval")
        } catch {
            logger.error("mission approval request failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await fail(document: document, message: "Mac could not request mission approval: \(error.localizedDescription)")
        }
    }

    func cancelAfterApprovalDecision(document: QueryDocumentSnapshot, approvalStatus: String) async {
        let message = approvalStatus == "rejected"
            ? "Mission approval was rejected from mobile."
            : "Mission approval was canceled from mobile."
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "canceled",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    errorMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "approval_resolved",
                kind: "status",
                title: "Approval \(approvalStatus)",
                message: message,
                backend: nil,
                isError: true
            )
            logger.info("mission approval \(approvalStatus, privacy: .public) id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission approval cancellation failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolveBackend(requestedRuntime: String?, missionKind: String?) -> CLIAgentMissionBackend {
        CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: requestedRuntime,
            missionKind: missionKind,
            enabledBackends: settingsManager.enabledChatBackends
        )
    }

    func missionPrompt(title: String, prompt: String, backend: CLIAgentMissionBackend, data: [String: Any]) -> String {
        CLIAgentMissionRuntimePlanner.prompt(
            title: title,
            prompt: prompt,
            backend: backend,
            data: data
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
