import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Mission event recording, transcript mirroring, and summaries.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

extension CLIAgentMissionRequestListener {
    func recordChangedFileEvents(
        before: Set<String>,
        after: Set<String>,
        reference: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async {
        let changedFiles = after.subtracting(before).sorted().prefix(40)
        for path in changedFiles {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "changed_file",
                kind: "changed_file",
                title: "Changed file",
                message: path,
                backend: backend,
                changedFilePath: path
            )
        }
    }

    func mirrorTranscriptPieces(
        _ pieces: [ChatTranscriptPiece],
        mirroredPieceIDs: inout Set<String>,
        reference: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async {
        for piece in pieces where !mirroredPieceIDs.contains(piece.id) {
            mirroredPieceIDs.insert(piece.id)
            switch piece.kind {
            case .toolUse:
                let detail = piece.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "tool_use",
                    kind: "tool_call",
                    title: piece.value,
                    message: detail.map { "\(piece.value): \($0)" } ?? piece.value,
                    backend: backend,
                    toolName: piece.value
                )
            case .toolResult:
                let detail = piece.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "tool_result",
                    kind: "tool_result",
                    title: piece.value,
                    message: detail.map { "\(piece.value): \($0)" } ?? piece.value,
                    backend: backend,
                    toolName: piece.value
                )
            case .text:
                let text = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "assistant_response",
                    kind: "llm_response",
                    title: "Assistant",
                    message: text,
                    backend: backend
                )
            case .reasoning, .refusal:
                let text = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: piece.kind == .reasoning ? "reasoning" : "refusal",
                    kind: piece.kind == .reasoning ? "llm_reasoning" : "llm_refusal",
                    title: piece.kind == .reasoning ? "Reasoning" : "Refusal",
                    message: text,
                    backend: backend
                )
            }
        }
    }

    func recordEvent(
        reference _: DocumentReference,
        requestID: String,
        phase: String,
        kind: String,
        title: String?,
        message: String,
        backend: CLIAgentMissionBackend?,
        toolName: String? = nil,
        artifactPath: String? = nil,
        changedFilePath: String? = nil,
        isError: Bool = false
    ) async {
        let trimmed = CLIAgentMissionEventFactory.redactSecrets(message.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return }
        let nextSequence = (missionEventSequences[requestID] ?? 1) + 1
        missionEventSequences[requestID] = nextSequence
        let event = CLIAgentMissionEventFactory.event(
            sequence: nextSequence,
            phase: phase,
            kind: kind,
            title: title,
            message: trimmed,
            runtime: backend?.rawValue,
            toolName: toolName,
            artifactPath: artifactPath,
            changedFilePath: changedFilePath,
            isError: isError
        )
        do {
            guard let uid = accountManager.currentUID else { return }
            guard let handle = claimedMissions[requestID] else {
                logger.warning("refusing unclaimed event append for \(requestID, privacy: .public)")
                return
            }
            let eventID = CLIAgentMissionEventFactory.eventID(for: nextSequence)
            let key = try await missionVaultKey(uid: uid)
            let sealed = try CLIAgentMissionEventFactory.sealedEvent(
                event,
                uid: uid,
                requestID: requestID,
                eventID: eventID,
                vaultKey: key.keyData,
                vaultKeyID: key.vaultKeyID
            )
            guard let sealedEvent = sealed["sealedPayload"] as? [String: Any] else { return }
            try await ComputerUseSecurityCallableClient.appendCliAgentMissionEvent(
                requestId: requestID,
                deviceId: handle.deviceId,
                hostWriteNonce: handle.hostWriteNonce,
                eventId: eventID,
                sealedEvent: sealedEvent,
                publicEventShape: [
                    "sequence": nextSequence,
                    "kind": kind,
                    "phase": phase,
                    "runtime": backend?.rawValue ?? "hermes",
                    "source": "mac",
                    "isError": isError
                ]
            )
        } catch {
            logger.warning("mission event update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func deriveStreamingStatusMessage(
        assistantMessage: ChatMessageRecord?,
        backend: CLIAgentMissionBackend
    ) -> String {
        let assistantPreview = assistantMessage?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview = assistantPreview, !preview.isEmpty {
            return CLIAgentMissionEventFactory.mobileSafeText(preview, limit: 420)
        }
        let latestTool = assistantMessage?.displayTranscript.last(where: { $0.kind == .toolUse })
        if let tool = latestTool {
            let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let message = detail.map { "\(tool.value): \($0)" } ?? tool.value
            return CLIAgentMissionEventFactory.mobileSafeText(message, limit: 420)
        }
        return "\(backend.displayName) is composing a response…"
    }

    func resultSummary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.nilIfEmpty ?? "Mission finished without a text result."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
