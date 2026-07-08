import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Mission vault payload opening and sealed state updates.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

extension CLIAgentMissionRequestListener {
    func missionVaultKey(uid: String) async throws -> CloudVaultResolvedKey {
        try await MacCloudVaultKeyAccess.keyForWriting(
            uid: uid,
            deviceId: accountManager.deviceId,
            firestore: Firestore.firestore()
        )
    }

    func openMissionPrivatePayload(
        data: [String: Any],
        uid: String,
        requestID: String
    ) async throws -> CLIAgentMissionPrivatePayload? {
        guard data["sealedPayload"] != nil else { return nil }
        guard let key = try await MacCloudVaultKeyAccess.keyForReading(
            uid: uid,
            deviceId: accountManager.deviceId,
            firestore: Firestore.firestore()
        ) else {
            throw CloudVaultAccessError.vaultKeyUnavailable
        }
        guard let privatePayload = CLIAgentMissionCloudSealer.openPrivatePayload(
            data,
            uid: uid,
            requestID: requestID,
            vaultKey: key.keyData
        ) else {
            throw CloudVaultAccessError.vaultKeyMismatch(expected: (data["vaultKeyID"] as? String) ?? "unknown", actual: key.vaultKeyID)
        }
        return privatePayload
    }

    func mergePrivateMissionPayload(_ privatePayload: CLIAgentMissionPrivatePayload?, into data: [String: Any]) -> [String: Any] {
        guard let privatePayload else { return data }
        var merged = data
        if let title = privatePayload.title { merged["title"] = title }
        if let prompt = privatePayload.prompt { merged["prompt"] = prompt }
        if let targetProject = privatePayload.targetProject { merged["targetProject"] = targetProject }
        if let liveSummary = privatePayload.liveSummary { merged["liveSummary"] = liveSummary }
        if let resultPreview = privatePayload.resultPreview { merged["resultPreview"] = resultPreview }
        if let errorMessage = privatePayload.errorMessage { merged["errorMessage"] = errorMessage }
        if let approvalTitle = privatePayload.approvalTitle { merged["approvalTitle"] = approvalTitle }
        if let approvalMessage = privatePayload.approvalMessage { merged["approvalMessage"] = approvalMessage }
        if let personaScopeJSON = privatePayload.personaScopeJSON { merged["personaScopeJSON"] = personaScopeJSON }
        if let synthesisSummary = privatePayload.synthesisSummary { merged["synthesisSummary"] = synthesisSummary }
        return merged
    }

    func sealedStateUpdate(
        uid: String,
        requestID: String,
        payload: [String: Any],
        liveSummary: String? = nil,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        approvalTitle: String? = nil,
        approvalMessage: String? = nil,
        synthesisSummary: String? = nil
    ) async throws -> [String: Any] {
        var payload = payload
        for key in ["liveSummary", "resultPreview", "errorMessage", "approvalTitle", "approvalMessage", "synthesisSummary"] {
            payload[key] = FieldValue.delete()
        }
        let privatePayload = CLIAgentMissionPrivatePayload(
            title: nil,
            prompt: nil,
            targetProject: nil,
            liveSummary: liveSummary,
            resultPreview: resultPreview,
            errorMessage: errorMessage,
            approvalTitle: approvalTitle,
            approvalMessage: approvalMessage,
            personaScopeJSON: nil,
            synthesisSummary: synthesisSummary
        )
        let key = try await missionVaultKey(uid: uid)
        let aadContext = try CLIAgentMissionCloudSealer.missionAADContext(
            uid: uid,
            requestID: requestID,
            field: "sealedStatePayload"
        )
        payload["sealedStatePayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: aadContext
        )
        payload["sealedStateSchemaVersion"] = CLIAgentMissionCloudSealer.sealedStateSchemaVersion
        payload["sealedStateVaultKeyID"] = key.vaultKeyID
        return payload
    }
}
