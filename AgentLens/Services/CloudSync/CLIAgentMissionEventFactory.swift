import Foundation

struct CLIAgentMissionEventFactory {
    static func eventID(for sequence: Int) -> String {
        String(format: "%06d", sequence)
    }

    static func event(
        sequence: Int,
        phase: String,
        kind: String,
        title: String?,
        message: String,
        runtime: String?,
        toolName: String?,
        artifactPath: String?,
        changedFilePath: String?,
        isError: Bool
    ) -> [String: Any] {
        let fullMessage = mobileSafeText(message, limit: 24_000)
        let shortMessage = mobileSafeText(message, limit: 600)
        var event: [String: Any] = [
            "sequence": sequence,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "phase": phase,
            "title": title ?? phase.replacingOccurrences(of: "_", with: " ").capitalized,
            "message": shortMessage,
            "fullMessage": fullMessage,
            // messageLength/messageTruncated moved into the sealed private payload
            // so the cleartext Firestore doc does not leak the byte-length of the
            // sealed body (content-size side-channel). Closes OPUS-F-020.
            "source": "mac",
            "isError": isError
        ]
        if let runtime {
            event["runtime"] = runtime
        }
        if let toolName { event["toolName"] = toolName.prefix(120).description }
        if let artifactPath { event["artifactPath"] = artifactPath.prefix(512).description }
        if let changedFilePath { event["changedFilePath"] = changedFilePath.prefix(512).description }
        return event
    }

    static func sealedEvent(
        _ event: [String: Any],
        uid: String,
        requestID: String,
        eventID: String,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        var sealed = event
        let privatePayload = CLIAgentMissionEventPrivatePayload(
            title: event["title"] as? String,
            message: (event["message"] as? String) ?? "",
            fullMessage: event["fullMessage"] as? String,
            toolName: event["toolName"] as? String,
            artifactPath: event["artifactPath"] as? String,
            changedFilePath: event["changedFilePath"] as? String
        )
        for key in ["title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath"] {
            sealed.removeValue(forKey: key)
        }
        sealed["contentSealed"] = true
        sealed["sealedSchemaVersion"] = CLIAgentMissionCloudSealer.sealedSchemaVersion
        sealed["vaultKeyID"] = vaultKeyID
        let aadContext = try CLIAgentMissionCloudSealer.missionEventAADContext(uid: uid, requestID: requestID, eventID: eventID)
        sealed["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return sealed
    }

    static func redactSecrets(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{8,}"#,
            #"(?i)bearer\s+[a-z0-9._\-]{12,}"#,
            #"[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: [.regularExpression]
            )
        }
        return redacted
    }

    static func mobileSafeText(_ text: String, limit: Int = 600) -> String {
        redactSecrets(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .prefix(limit)
            .description
    }
}
