import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

private typealias UntypedJSONObject = [String: Any]

// MARK: - CLI mission request payload factory
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

enum CLIAgentMissionRequestPayloadFactory {
    static let createPublicKeys: Set<String> = [
        "id",
        "missionKind",
        "requestedRuntime",
        "requestedModelID",
        "depth",
        "approvalMode",
        "commandsAllowed",
        "fileEditsAllowed",
        "source",
        "sourceSkillID",
        "sourceSurface",
        "deliveryMode",
        "presentationMode",
        "parentHermesThreadID",
        "schemaVersion",
        "groupID",
        "siblingIndex",
        "siblingCount",
        "isGroupChild",
        "personaID",
        "clientThreadID",
        "parentSessionID",
        "resumeAction",
        "originatorKind",
        "originatorRef",
        "targetBodyID"
    ]

    static func publicFields(from payload: UntypedJSONObject, requestId: String) -> UntypedJSONObject {
        var out: UntypedJSONObject = ["id": requestId]
        for key in createPublicKeys where key != "id" {
            guard let value = payload[key] else { continue }
            if value is FieldValue { continue }
            out[key] = value
        }
        return out
    }

    static func createLeafPayload(
        requestId: String,
        remoteCommandID: String,
        deviceId: String,
        payload: UntypedJSONObject,
        initialEvent: UntypedJSONObject
    ) -> UntypedJSONObject {
        var leaf: UntypedJSONObject = [
            "requestId": requestId,
            "remoteCommandID": remoteCommandID,
            "deviceId": deviceId,
            "publicFields": publicFields(from: payload, requestId: requestId),
            "initialEvent": initialEvent["sealedPayload"] ?? initialEvent
        ]
        if let sealed = payload["sealedPayload"] {
            leaf["sealedPayload"] = sealed
        }
        if let envelope = payload["signalEnvelope"] {
            leaf["signalEnvelope"] = envelope
        }
        return leaf
    }

    static func buildSealed(
        id: String,
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String,
        targetProject: String?,
        depth: String,
        approvalMode: String,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        requestedModelID: String? = nil,
        clientThreadID: String? = nil,
        parentSessionID: String? = nil,
        resumeAction: String? = nil,
        sourceSkillID: HermesSkillRunID? = nil,
        sourceSurface: String? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        parentHermesThreadID: String? = nil,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat,
        personaScopeJSON: String? = nil,
        attachments: [CLIAgentMissionAttachmentRef] = [],
        now: Date = Date(),
        uid: String? = nil,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> UntypedJSONObject {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = build(
            id: id,
            title: title,
            prompt: prompt,
            missionKind: missionKind,
            requestedRuntime: requestedRuntime,
            targetProject: targetProject,
            depth: depth,
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed,
            requestedModelID: requestedModelID,
            clientThreadID: clientThreadID,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction,
            sourceSkillID: sourceSkillID,
            sourceSurface: sourceSurface,
            deliveryMode: deliveryMode,
            parentHermesThreadID: parentHermesThreadID,
            presentationMode: presentationMode,
            now: now
        )
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        let privatePayload = CLIAgentMissionPrivatePayload(
            title: trimmedTitle ?? (isChatRequest ? "New chat" : "Insights mission"),
            prompt: trimmedPrompt,
            targetProject: targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            liveSummary: isChatRequest
                ? "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                : "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            resultPreview: nil,
            errorMessage: nil,
            approvalTitle: nil,
            approvalMessage: nil,
            personaScopeJSON: personaScopeJSON?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            synthesisSummary: nil,
            attachments: attachments.isEmpty ? nil : attachments
        )
        let aadContext = try uid.map {
            try CLIAgentMissionCloudSealer.missionAADContext(uid: $0, documentID: id, field: "sealedPayload")
        }
        return try applySealedPrivatePayload(
            privatePayload,
            to: payload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
    }

    static func sealGroupPayload(
        _ payload: UntypedJSONObject,
        title: String,
        prompt: String,
        targetProject: String?,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> UntypedJSONObject {
        let privatePayload = CLIAgentMissionPrivatePayload(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            targetProject: targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            liveSummary: nil,
            resultPreview: nil,
            errorMessage: nil,
            approvalTitle: nil,
            approvalMessage: nil,
            personaScopeJSON: nil,
            synthesisSummary: nil
        )
        return try applySealedPrivatePayload(privatePayload, to: payload, vaultKey: vaultKey, vaultKeyID: vaultKeyID)
    }

    static func build(
        id: String,
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String,
        targetProject: String?,
        depth: String,
        approvalMode: String,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        requestedModelID: String? = nil,
        clientThreadID: String? = nil,
        parentSessionID: String? = nil,
        resumeAction: String? = nil,
        sourceSkillID: HermesSkillRunID? = nil,
        sourceSurface: String? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        parentHermesThreadID: String? = nil,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat,
        now: Date = Date()
    ) -> UntypedJSONObject {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        let baseSource = isChatRequest ? "ios-chat" : "ios-insights"
        var payload: UntypedJSONObject = [
            "id": id,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? (isChatRequest ? "New chat" : "Insights mission"),
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "missionKind": missionKind,
            "requestedRuntime": requestedRuntime,
            "targetProject": targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "",
            "depth": depth,
            "approvalMode": approvalMode,
            "commandsAllowed": commandsAllowed,
            "fileEditsAllowed": fileEditsAllowed,
            "source": baseSource,
            "sourceSurface": sourceSurface?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? baseSource,
            "deliveryMode": deliveryMode.rawValue,
            "presentationMode": presentationMode.rawValue,
            "status": "pending",
            "liveSummary": isChatRequest
                ? "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                : "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            "createdAt": timestamp,
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 3
        ]
        if let sourceSkillID {
            payload["sourceSkillID"] = sourceSkillID.rawValue
        }
        if let clientThreadID = clientThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["clientThreadID"] = clientThreadID
        }
        if let parentHermesThreadID = parentHermesThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["parentHermesThreadID"] = parentHermesThreadID
        }
        if let requestedModelID = requestedModelID?.nonEmpty {
            payload["requestedModelID"] = requestedModelID
        }
        if let parentSessionID = parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["parentSessionID"] = parentSessionID
        }
        if let resumeAction = resumeAction?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["resumeAction"] = resumeAction
        }
        return payload
    }

    static func initialQueuedEvent(
        label: String = "Mission",
        source: String = "ios",
        sourceSkillID: HermesSkillRunID? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        eventImportance: SkillRunEventImportance = .normal,
        skillStepID: String = "queued",
        now: Date = Date()
    ) -> UntypedJSONObject {
        var event: UntypedJSONObject = [
            "sequence": 1,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "kind": "status",
            "phase": "queued",
            "title": "Queued",
            "message": "\(label) queued from this device.",
            "source": source,
            "deliveryMode": deliveryMode.rawValue,
            "eventImportance": eventImportance.rawValue,
            "skillStepID": skillStepID,
            "isError": false
        ]
        if let sourceSkillID {
            event["sourceSkillID"] = sourceSkillID.rawValue
        }
        return event
    }

    static func initialQueuedEventSealed(
        label: String = "Mission",
        source: String = "ios",
        sourceSkillID: HermesSkillRunID? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        eventImportance: SkillRunEventImportance = .normal,
        skillStepID: String = "queued",
        now: Date = Date(),
        uid: String? = nil,
        requestID: String? = nil,
        eventID: String = "000001",
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> UntypedJSONObject {
        var event = initialQueuedEvent(
            label: label,
            source: source,
            sourceSkillID: sourceSkillID,
            deliveryMode: deliveryMode,
            eventImportance: eventImportance,
            skillStepID: skillStepID,
            now: now
        )
        let privatePayload = CLIAgentMissionEventPrivatePayload(
            title: event["title"] as? String,
            message: (event["message"] as? String) ?? "\(label) queued from this device.",
            fullMessage: event["fullMessage"] as? String,
            toolName: event["toolName"] as? String,
            artifactPath: event["artifactPath"] as? String,
            changedFilePath: event["changedFilePath"] as? String
        )
        let aadContext: CloudVaultAADContext?
        if let uid, let requestID {
            aadContext = try CLIAgentMissionCloudSealer.missionEventAADContext(
                uid: uid,
                requestID: requestID,
                eventID: eventID
            )
        } else {
            aadContext = nil
        }
        try applySealedEventPayload(
            privatePayload,
            to: &event,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return event
    }

    private static func applySealedPrivatePayload(
        _ privatePayload: CLIAgentMissionPrivatePayload,
        to payload: UntypedJSONObject,
        vaultKey: Data,
        vaultKeyID: String,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> UntypedJSONObject {
        var payload = payload
        for key in [
            "title",
            "prompt",
            "targetProject",
            "liveSummary",
            "resultPreview",
            "errorMessage",
            "approvalTitle",
            "approvalMessage",
            "personaScopeJSON",
            "synthesisSummary"
        ] {
            payload.removeValue(forKey: key)
        }
        payload["contentSealed"] = true
        payload["sealedSchemaVersion"] = CLIAgentMissionCloudSealer.sealedSchemaVersion
        payload["vaultKeyID"] = vaultKeyID
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return payload
    }

    private static func applySealedEventPayload(
        _ privatePayload: CLIAgentMissionEventPrivatePayload,
        to event: inout UntypedJSONObject,
        vaultKey: Data,
        vaultKeyID: String,
        aadContext: CloudVaultAADContext? = nil
    ) throws {
        for key in ["title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath"] {
            event.removeValue(forKey: key)
        }
        event["contentSealed"] = true
        event["sealedSchemaVersion"] = CLIAgentMissionCloudSealer.sealedSchemaVersion
        event["vaultKeyID"] = vaultKeyID
        event["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
    }
}
