import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

@MainActor
final class CLIAgentMissionDispatcher {
    static let shared = CLIAgentMissionDispatcher()

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func dispatch(
        title: String,
        prompt: String,
        missionKind: String,
        requestedRuntime: String = "auto",
        targetProject: String? = nil,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Bool = false,
        fileEditsAllowed: Bool = false
    ) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let id = UUID().uuidString
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Insights mission"
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw DispatchError.emptyPrompt
        }

        let payload = CLIAgentMissionRequestPayloadFactory.build(
            id: id,
            title: trimmedTitle,
            prompt: trimmedPrompt,
            missionKind: missionKind,
            requestedRuntime: requestedRuntime,
            targetProject: targetProject,
            depth: depth,
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
        let db = firestoreProvider()
        let requestRef = db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
        let batch = db.batch()
        batch.setData(payload, forDocument: requestRef, merge: false)
        batch.setData(
            CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(now: Date()),
            forDocument: requestRef.collection("events").document("000001"),
            merge: false
        )
        try await batch.commit()
        return id
    }

    func observe(
        requestID: String,
        onUpdate: @escaping @MainActor (CLIAgentMissionSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }

        let requestRef = firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)

        var latestData: [String: Any]?
        var latestEvents: [CLIAgentMissionEvent] = []

        func emitLatest() {
            guard let latestData,
                  let mission = CLIAgentMissionSnapshot(
                    documentID: requestID,
                    data: latestData,
                    eventOverride: latestEvents.isEmpty ? nil : latestEvents
                  ) else { return }
            Task { @MainActor in onUpdate(mission) }
        }

        let requestRegistration = requestRef
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error.localizedDescription) }
                    return
                }
                guard let snapshot, snapshot.exists else {
                    Task { @MainActor in onError("Mission request disappeared before the Mac returned a result.") }
                    return
                }
                latestData = snapshot.data() ?? [:]
                emitLatest()
            }

        let eventsRegistration = requestRef
            .collection("events")
            .order(by: "sequence")
            .limit(to: 1000)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error.localizedDescription) }
                    return
                }
                latestEvents = snapshot?.documents.compactMap { doc in
                    CLIAgentMissionEvent(data: doc.data())
                } ?? []
                emitLatest()
            }
        return CLIAgentMissionObservation(registrations: [requestRegistration, eventsRegistration])
    }

    func respondToApproval(
        requestID: String,
        approve: Bool
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .setData([
                "approvalStatus": approve ? "approved" : "rejected",
                "approvalRespondedAt": ISO8601DateFormatter().string(from: Date()),
                "liveSummary": approve ? "Approval granted from mobile. Waiting for the Mac to resume." : "Approval rejected from mobile.",
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    enum DispatchError: LocalizedError {
        case firebaseUnavailable
        case notSignedIn
        case emptyPrompt

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notSignedIn:
                return "Sign in before dispatching Mac agent missions."
            case .emptyPrompt:
                return "Mission prompt was empty."
            }
        }
    }
}

enum CLIAgentMissionRequestPayloadFactory {
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
        now: Date = Date()
    ) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: now)
        return [
            "id": id,
            "title": title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Insights mission",
            "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            "missionKind": missionKind,
            "requestedRuntime": requestedRuntime,
            "targetProject": targetProject?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "",
            "depth": depth,
            "approvalMode": approvalMode,
            "commandsAllowed": commandsAllowed,
            "fileEditsAllowed": fileEditsAllowed,
            "source": "ios-insights",
            "status": "pending",
            "liveSummary": "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            "createdAt": timestamp,
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 2
        ]
    }

    static func initialQueuedEvent(now: Date = Date()) -> [String: Any] {
        [
            "sequence": 1,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "kind": "status",
            "phase": "queued",
            "title": "Queued",
            "message": "Mission queued from this device.",
            "source": "ios",
            "isError": false
        ]
    }
}

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
    let isError: Bool

    var id: String { "\(sequence)-\(timestamp)-\(phase)-\(message)" }

    init?(data: Any) {
        guard let map = data as? [String: Any],
              let timestamp = map["timestamp"] as? String,
              let phase = map["phase"] as? String,
              let message = map["message"] as? String else {
            return nil
        }
        self.sequence = (map["sequence"] as? Int) ?? 0
        self.timestamp = timestamp
        self.kind = (map["kind"] as? String) ?? phase
        self.phase = phase
        self.title = map["title"] as? String
        self.message = message
        self.fullMessage = map["fullMessage"] as? String
        self.messageLength = map["messageLength"] as? Int
        self.messageTruncated = (map["messageTruncated"] as? Bool) ?? false
        self.runtime = map["runtime"] as? String
        self.source = map["source"] as? String
        self.toolName = map["toolName"] as? String
        self.artifactPath = map["artifactPath"] as? String
        self.changedFilePath = map["changedFilePath"] as? String
        self.isError = (map["isError"] as? Bool) ?? (phase == "failed")
    }
}

struct CLIAgentMissionSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let status: String
    let requestedRuntime: String
    let selectedRuntime: String?
    let selectedRuntimeName: String?
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
        guard let title = data["title"] as? String,
              let status = data["status"] as? String else {
            return nil
        }
        self.id = (data["id"] as? String) ?? documentID
        self.title = title
        self.status = status
        self.requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        self.selectedRuntime = data["selectedRuntime"] as? String
        self.selectedRuntimeName = data["selectedRuntimeName"] as? String
        self.liveSummary = data["liveSummary"] as? String
        self.resultPreview = data["resultPreview"] as? String
        self.errorMessage = data["errorMessage"] as? String
        self.sessionID = data["sessionId"] as? String
        self.approvalRequestId = data["approvalRequestId"] as? String
        self.approvalStatus = data["approvalStatus"] as? String
        self.approvalTitle = data["approvalTitle"] as? String
        self.approvalMessage = data["approvalMessage"] as? String
        self.createdAt = (data["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let documentEvents = (data["events"] as? [Any] ?? []).compactMap(CLIAgentMissionEvent.init(data:))
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

    var isTerminal: Bool {
        ["completed", "failed", "canceled", "cancelled", "unauthorized", "agent_launch_failed"].contains(status)
    }

    var isWaitingForApproval: Bool {
        status == "waiting_for_approval" && (approvalStatus ?? "pending") == "pending"
    }

    var displayStatus: String {
        let normalized = status.lowercased()
        guard ["pending", "queued"].contains(normalized),
              let createdAt,
              Date().timeIntervalSince(createdAt) > 120
        else {
            return status
        }
        return "mac_offline"
    }

    var displayLiveSummary: String? {
        guard displayStatus == "mac_offline" else { return liveSummary }
        return "No signed-in Mac has claimed this mission yet. Open BurnBar on the paired Mac to start execution."
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
