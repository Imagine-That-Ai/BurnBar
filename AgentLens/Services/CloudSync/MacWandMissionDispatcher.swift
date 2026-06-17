import Foundation
@preconcurrency import FirebaseFirestore

struct MacWandDispatchResult: Sendable, Equatable {
    let groupID: String
    let childMissionIDs: [String]
}

enum MacWandDispatchError: LocalizedError {
    case firebaseUnavailable
    case notSignedIn
    case emptyPrompt
    case invalidWidth

    var errorDescription: String? {
        switch self {
        case .firebaseUnavailable:
            return "Cloud is not configured on this Mac."
        case .notSignedIn:
            return "Sign in before casting The Wand from this Mac."
        case .emptyPrompt:
            return "Mission prompt was empty."
        case .invalidWidth:
            return "The Wand needs at least one worker."
        }
    }
}

@MainActor
struct MacWandMissionDispatcher {
    let accountManager: AccountManaging
    let firestore: Firestore

    init(
        accountManager: AccountManaging = AccountManager.shared,
        firestore: Firestore = Firestore.firestore()
    ) {
        self.accountManager = accountManager
        self.firestore = firestore
    }

    func dispatch(
        title: String,
        prompt: String,
        workerCount: Int,
        missionKind: String = "custom",
        targetProject: String? = nil,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Bool = false,
        fileEditsAllowed: Bool = false,
        mergeStrategy: String = "pick_one"
    ) async throws -> MacWandDispatchResult {
        guard accountManager.isFirebaseAvailable else { throw MacWandDispatchError.firebaseUnavailable }
        guard let uid = accountManager.currentUID else { throw MacWandDispatchError.notSignedIn }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw MacWandDispatchError.emptyPrompt }
        guard workerCount >= 1 else { throw MacWandDispatchError.invalidWidth }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Wand mission"
        let groupID = "grp-\(UUID().uuidString)"
        let childMissionIDs = (0..<workerCount).map { _ in UUID().uuidString }
        let runtimeTokens = Array(repeating: ChatBackendID.droid.rawValue, count: workerCount)
        let now = ISO8601DateFormatter().string(from: Date())
        let key = try await MacCloudVaultKeyAccess.keyForWriting(
            uid: uid,
            deviceId: accountManager.deviceId,
            firestore: firestore
        )

        let userRef = firestore.collection("users").document(uid)
        let batch = firestore.batch()
        let groupRef = userRef.collection("mission_groups").document(groupID)
        batch.setData(
            try groupPayload(
                uid: uid,
                groupID: groupID,
                title: trimmedTitle,
                prompt: trimmedPrompt,
                missionKind: missionKind,
                targetProject: targetProject,
                childMissionIDs: childMissionIDs,
                runtimeTokens: runtimeTokens,
                parallelismLimit: workerCount,
                mergeStrategy: mergeStrategy,
                now: now,
                key: key
            ),
            forDocument: groupRef,
            merge: false
        )

        for index in childMissionIDs.indices {
            let missionID = childMissionIDs[index]
            let requestRef = userRef.collection("cli_agent_mission_requests").document(missionID)
            batch.setData(
                try childPayload(
                    uid: uid,
                    missionID: missionID,
                    title: "\(trimmedTitle) · Worker \(index + 1)",
                    prompt: trimmedPrompt,
                    missionKind: missionKind,
                    requestedRuntime: runtimeTokens[index],
                    targetProject: targetProject,
                    depth: depth,
                    approvalMode: approvalMode,
                    commandsAllowed: commandsAllowed,
                    fileEditsAllowed: fileEditsAllowed,
                    groupID: groupID,
                    siblingIndex: index,
                    siblingCount: workerCount,
                    now: now,
                    key: key
                ),
                forDocument: requestRef,
                merge: false
            )
            batch.setData(
                try queuedEventPayload(
                    uid: uid,
                    missionID: missionID,
                    eventID: "000001",
                    now: now,
                    key: key
                ),
                forDocument: requestRef.collection("events").document("000001"),
                merge: false
            )
        }

        try await batch.commit()
        return MacWandDispatchResult(groupID: groupID, childMissionIDs: childMissionIDs)
    }

    private func groupPayload(
        uid: String,
        groupID: String,
        title: String,
        prompt: String,
        missionKind: String,
        targetProject: String?,
        childMissionIDs: [String],
        runtimeTokens: [String],
        parallelismLimit: Int,
        mergeStrategy: String,
        now: String,
        key: CloudVaultResolvedKey
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "id": groupID,
            "missionKind": missionKind,
            "childMissionIDs": childMissionIDs,
            "runtimeTokens": runtimeTokens,
            "parallelismLimit": parallelismLimit,
            "mergeStrategy": mergeStrategy,
            "phase": "queued",
            "winnerMissionID": "",
            "forecast": [
                "tokensLow": 0,
                "tokensHigh": 0,
                "costLowUSD": 0.0,
                "costHighUSD": 0.0,
                "etaLow": 0.0,
                "etaHigh": 0.0,
            ],
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 1,
            "source": "mac-wand",
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID,
        ]
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            CLIAgentMissionPrivatePayload(
                title: title,
                prompt: prompt,
                targetProject: targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID
        )
        return payload
    }

    private func childPayload(
        uid: String,
        missionID: String,
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String,
        targetProject: String?,
        depth: String,
        approvalMode: String,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        groupID: String,
        siblingIndex: Int,
        siblingCount: Int,
        now: String,
        key: CloudVaultResolvedKey
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "id": missionID,
            "missionKind": missionKind,
            "requestedRuntime": requestedRuntime,
            "depth": depth,
            "approvalMode": approvalMode,
            "commandsAllowed": commandsAllowed,
            "fileEditsAllowed": fileEditsAllowed,
            "source": "mac",
            "sourceSurface": "mac-wand",
            "deliveryMode": "action_only",
            "status": "pending",
            "createdAt": now,
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1,
            "groupID": groupID,
            "siblingIndex": siblingIndex,
            "siblingCount": siblingCount,
            "isGroupChild": true,
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID,
        ]
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            CLIAgentMissionPrivatePayload(
                title: title,
                prompt: prompt,
                targetProject: targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: CLIAgentMissionCloudSealer.missionAADContext(
                uid: uid,
                requestID: missionID,
                field: "sealedPayload"
            )
        )
        return payload
    }

    private func queuedEventPayload(
        uid: String,
        missionID: String,
        eventID: String,
        now: String,
        key: CloudVaultResolvedKey
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "sequence": 1,
            "timestamp": now,
            "kind": "status",
            "phase": "queued",
            "source": "mac",
            "deliveryMode": "action_only",
            "eventImportance": "normal",
            "skillStepID": "queued",
            "isError": false,
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID,
        ]
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            CLIAgentMissionEventPrivatePayload(
                title: "Queued",
                message: "Wand worker queued from this Mac."
            ),
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: CLIAgentMissionCloudSealer.missionEventAADContext(
                uid: uid,
                requestID: missionID,
                eventID: eventID
            )
        )
        return payload
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
