import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

// MARK: - CLI mission observation handle + snapshot/event models
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

final class CLIAgentMissionObservation {
    private let registrations: [ListenerRegistration]

    init(registrations: [ListenerRegistration]) {
        self.registrations = registrations
    }

    func cancel() {
        registrations.forEach { $0.remove() }
    }

    deinit {
        registrations.forEach { $0.remove() }
    }
}

struct CLIAgentMissionEvent: Equatable, Sendable, Identifiable {
    let sequence: Int
    let timestamp: String
    let kind: String
    let phase: String
    let title: String?
    let message: String
    let fullMessage: String?
    let messageLength: Int?
    let messageTruncated: Bool
    let runtime: String?
    let source: String?
    let toolName: String?
    let artifactPath: String?
    let changedFilePath: String?
    let sourceSkillID: String?
    let deliveryMode: SkillRunDeliveryMode
    let eventImportance: SkillRunEventImportance
    let skillStepID: String?
    let isError: Bool

    var id: String { "\(sequence)-\(timestamp)-\(phase)-\(message)" }

    init?(data: Any) {
        self.init(data: data, vaultKey: nil)
    }

    init?(
        data: Any,
        vaultKey: Data?,
        uid: String? = nil,
        requestID: String? = nil,
        eventID: String? = nil
    ) {
        guard let map = data as? [String: Any],
              let timestamp = map["timestamp"] as? String,
              let phase = map["phase"] as? String else {
            return nil
        }
        let sealed = CLIAgentMissionCloudSealer.openEventPayload(
            map,
            uid: uid,
            requestID: requestID,
            eventID: eventID,
            vaultKey: vaultKey
        )
        guard let message = sealed?.message ?? map["message"] as? String else {
            return nil
        }
        self.sequence = (map["sequence"] as? Int) ?? 0
        self.timestamp = timestamp
        self.kind = (map["kind"] as? String) ?? phase
        self.phase = phase
        self.title = sealed?.title ?? map["title"] as? String
        self.message = message
        self.fullMessage = sealed?.fullMessage ?? map["fullMessage"] as? String
        self.messageLength = map["messageLength"] as? Int
        self.messageTruncated = (map["messageTruncated"] as? Bool) ?? false
        self.runtime = map["runtime"] as? String
        self.source = map["source"] as? String
        self.toolName = sealed?.toolName ?? map["toolName"] as? String
        self.artifactPath = sealed?.artifactPath ?? map["artifactPath"] as? String
        self.changedFilePath = sealed?.changedFilePath ?? map["changedFilePath"] as? String
        self.sourceSkillID = map["sourceSkillID"] as? String
        self.deliveryMode = (map["deliveryMode"] as? String)
            .flatMap(SkillRunDeliveryMode.init(rawValue:)) ?? .actionOnly
        self.eventImportance = (map["eventImportance"] as? String)
            .flatMap(SkillRunEventImportance.init(rawValue:)) ?? .normal
        self.skillStepID = map["skillStepID"] as? String
        self.isError = (map["isError"] as? Bool) ?? (phase == "failed")
    }
}

struct CLIAgentMissionSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let status: String
    let requestedRuntime: String
    let requestedModelID: String?
    let selectedRuntime: String?
    let selectedRuntimeName: String?
    let selectedModelID: String?
    let targetProject: String?
    let sourceSkillID: String?
    let sourceSurface: String?
    let deliveryMode: SkillRunDeliveryMode
    let parentHermesThreadID: String?
    let liveSummary: String?
    let resultPreview: String?
    let errorMessage: String?
    let sessionID: String?
    let approvalRequestId: String?
    let approvalStatus: String?
    let approvalTitle: String?
    let approvalMessage: String?
    let events: [CLIAgentMissionEvent]
    let createdAt: Date?

    init?(documentID: String, data: [String: Any], eventOverride: [CLIAgentMissionEvent]? = nil) {
        self.init(documentID: documentID, data: data, eventOverride: eventOverride, vaultKey: nil)
    }

    init?(
        documentID: String,
        data: [String: Any],
        eventOverride: [CLIAgentMissionEvent]? = nil,
        vaultKey: Data?,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil,
        uid: String? = nil
    ) {
        let requestPrivate = CLIAgentMissionCloudSealer.openPrivatePayload(
            data,
            uid: uid,
            documentID: documentID,
            vaultKey: vaultKey,
            signalIdentity: signalIdentity
        )
        let statePrivate = CLIAgentMissionCloudSealer.openPrivatePayload(
            data,
            field: "sealedStatePayload",
            uid: uid,
            documentID: documentID,
            vaultKey: vaultKey
        )
        guard let title = requestPrivate?.title ?? data["title"] as? String,
              let status = data["status"] as? String else {
            return nil
        }
        self.id = (data["id"] as? String) ?? documentID
        self.title = title
        self.status = status
        self.requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        self.requestedModelID = (data["requestedModelID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.selectedRuntime = data["selectedRuntime"] as? String
        self.selectedRuntimeName = data["selectedRuntimeName"] as? String
        self.selectedModelID = (data["selectedModelID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.targetProject = (requestPrivate?.targetProject ?? data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.sourceSkillID = (data["sourceSkillID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.sourceSurface = (data["sourceSurface"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.deliveryMode = (data["deliveryMode"] as? String)
            .flatMap(SkillRunDeliveryMode.init(rawValue:)) ?? .actionOnly
        self.parentHermesThreadID = (data["parentHermesThreadID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.liveSummary = statePrivate?.liveSummary ?? requestPrivate?.liveSummary ?? data["liveSummary"] as? String
        self.resultPreview = statePrivate?.resultPreview ?? requestPrivate?.resultPreview ?? data["resultPreview"] as? String
        self.errorMessage = statePrivate?.errorMessage ?? requestPrivate?.errorMessage ?? data["errorMessage"] as? String
        self.sessionID = data["sessionId"] as? String
        self.approvalRequestId = data["approvalRequestId"] as? String
        self.approvalStatus = data["approvalStatus"] as? String
        self.approvalTitle = statePrivate?.approvalTitle ?? requestPrivate?.approvalTitle ?? data["approvalTitle"] as? String
        self.approvalMessage = statePrivate?.approvalMessage ?? requestPrivate?.approvalMessage ?? data["approvalMessage"] as? String
        self.createdAt = (data["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let documentEvents = (data["events"] as? [Any] ?? []).compactMap { CLIAgentMissionEvent(data: $0, vaultKey: vaultKey) }
        self.events = (eventOverride ?? documentEvents).sorted {
            if $0.sequence == $1.sequence { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }
    }

    var runtimeLabel: String {
        selectedRuntimeName
            ?? selectedRuntime
            ?? (requestedRuntime == "auto" ? "Mac agent fleet" : requestedRuntime)
    }

    var skillRunID: HermesSkillRunID? {
        sourceSkillID.flatMap(HermesSkillRunID.init(rawValue:))
    }

    var isTerminal: Bool {
        ["completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"].contains(status.lowercased())
    }

    var isWaitingForApproval: Bool {
        status.lowercased() == "waiting_for_approval" && (approvalStatus ?? "pending").lowercased() == "pending"
    }

    var displayStatus: String {
        status
    }

    var displayLiveSummary: String? {
        guard isStaleUnclaimed else { return liveSummary }
        return "This queued mission was not claimed. Compose a fresh dispatch after the Mac shows online."
    }

    var isStaleUnclaimed: Bool {
        let normalized = status.lowercased()
        guard ["pending", "queued"].contains(normalized),
              let createdAt,
              Date().timeIntervalSince(createdAt) > 120
        else {
            return false
        }
        return !hasBeenClaimedByMac
    }

    var hasBeenClaimedByMac: Bool {
        if selectedRuntime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if selectedRuntimeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        return events.contains { event in
            event.source?.lowercased() == "mac" || event.runtime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    var currentStepLabel: String {
        guard let event = events.last else { return displayStatus }
        return event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? event.phase.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var activeToolName: String? {
        guard let event = events.reversed().first(where: { event in
            event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || event.kind == "tool_call"
                || event.kind == "tool_result"
                || event.phase == "tool_use"
                || event.phase == "tool_result"
        }) else { return nil }
        return event.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    var latestArtifactLabel: String? {
        events.reversed().compactMap { event in
            event.changedFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? event.artifactPath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }.first
    }
}

