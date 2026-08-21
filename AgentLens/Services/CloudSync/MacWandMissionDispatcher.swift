import Foundation
import OpenBurnBarKernel
@preconcurrency import FirebaseFirestore

struct MacWandDispatchResult: Sendable, Equatable {
    let groupID: String
    let childMissionIDs: [String]
}

private struct MacWandChildPayloadInput {
    let uid: String
    let missionID: String
    let title: String
    let prompt: String
    let missionKind: String
    let requestedRuntime: String
    let targetProject: String?
    let depth: String
    let approvalMode: String
    let commandsAllowed: Bool
    let fileEditsAllowed: Bool
    let groupID: String
    let siblingIndex: Int
    let siblingCount: Int
    let targetBodyID: String?
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
        mergeStrategy: String = "pick_one",
        originator: BurnBarOriginator? = nil,
        targetBodyID: String? = nil
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

        // STARTED BY attribution (War Room Command Board). The Wand is the
        // default originator; the Flame passes its decision-linked originator
        // through `originator` when it dispatches.
        let resolvedOriginator = originator ?? BurnBarOriginator(
            kind: .wand,
            missionGroupID: groupID,
            confidence: .exact
        )

        try await batch.commit()

        var leaves: [[String: any Sendable]] = []
        for index in childMissionIDs.indices {
            let missionID = childMissionIDs[index]
            let payload = try childPayload(
                MacWandChildPayloadInput(
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
                    targetBodyID: targetBodyID
                ),
                originator: resolvedOriginator,
                now: now,
                key: key
            )
            let initialEvent = try queuedEventPayload(
                uid: uid,
                missionID: missionID,
                eventID: "000001",
                now: now,
                key: key
            )
            var publicFields: [String: any Sendable] = [
                "id": missionID,
                "missionKind": missionKind,
                "requestedRuntime": runtimeTokens[index],
                "depth": depth,
                "approvalMode": approvalMode,
                "commandsAllowed": commandsAllowed,
                "fileEditsAllowed": fileEditsAllowed,
                "source": "mac",
                "sourceSurface": "mac-wand",
                "deliveryMode": "action_only",
                "schemaVersion": 1,
                "groupID": groupID,
                "siblingIndex": index,
                "siblingCount": workerCount,
                "isGroupChild": true,
                "originatorKind": resolvedOriginator.kind.rawValue
            ]
            if let originatorRef = resolvedOriginator.primaryRef {
                publicFields["originatorRef"] = originatorRef
            }
            if let targetBodyID = targetBodyID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                publicFields["targetBodyID"] = targetBodyID
            }
            var leaf: [String: any Sendable] = [
                "requestId": missionID,
                "remoteCommandID": missionID,
                "deviceId": accountManager.deviceId,
                "publicFields": publicFields,
                "initialEvent": (initialEvent["sealedPayload"] as? [String: any Sendable]) ?? [:]
            ]
            if let sealed = payload["sealedPayload"] as? [String: any Sendable] {
                leaf["sealedPayload"] = sealed
            }
            leaves.append(leaf)
        }
        for chunkStart in stride(from: 0, to: leaves.count, by: 16) {
            let slice = Array(leaves[chunkStart..<min(chunkStart + 16, leaves.count)])
            guard var parent = slice.first else { continue }
            if slice.count > 1 {
                parent["siblings"] = Array(slice.dropFirst())
            }
            _ = try await ComputerUseSecurityCallableClient.createCliAgentMission(
                payload: ComputerUseSecurityCallableClient.sendableJSONPayload(parent),
                deviceId: accountManager.deviceId
            )
        }
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
                "etaHigh": 0.0
            ],
            "createdAt": now,
            "updatedAt": now,
            "schemaVersion": 1,
            "source": "mac-wand",
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID
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
        _ input: MacWandChildPayloadInput,
        originator: BurnBarOriginator,
        now: String,
        key: CloudVaultResolvedKey
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "id": input.missionID,
            "missionKind": input.missionKind,
            "requestedRuntime": input.requestedRuntime,
            "depth": input.depth,
            "approvalMode": input.approvalMode,
            "commandsAllowed": input.commandsAllowed,
            "fileEditsAllowed": input.fileEditsAllowed,
            "source": "mac",
            "sourceSurface": "mac-wand",
            "deliveryMode": "action_only",
            "status": "pending",
            "createdAt": now,
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1,
            "groupID": input.groupID,
            "siblingIndex": input.siblingIndex,
            "siblingCount": input.siblingCount,
            "isGroupChild": true,
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID
        ]
        payload["originatorKind"] = originator.kind.rawValue
        if let originatorRef = originator.primaryRef {
            payload["originatorRef"] = originatorRef
        }
        // The Flame's routing target. Advisory: the executing Mac still decides
        // whether to claim the mission, so this steers work without becoming a
        // way to force a machine to run something.
        if let targetBodyID = input.targetBodyID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["targetBodyID"] = targetBodyID
        }
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            CLIAgentMissionPrivatePayload(
                title: input.title,
                prompt: input.prompt,
                targetProject: input.targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ),
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: CLIAgentMissionCloudSealer.missionAADContext(
                uid: input.uid,
                requestID: input.missionID,
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
            "sourceSurface": "mac-wand",
            "deliveryMode": "action_only",
            "eventImportance": "normal",
            "skillStepID": "queued",
            "isError": false,
            "contentSealed": true,
            "sealedSchemaVersion": CLIAgentMissionCloudSealer.sealedSchemaVersion,
            "vaultKeyID": key.vaultKeyID
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
