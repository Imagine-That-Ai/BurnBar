import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

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
        fileEditsAllowed: Bool = false,
        requestedModelID: String? = nil,
        clientThreadID: String? = nil,
        parentSessionID: String? = nil,
        resumeAction: String? = nil
    ) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let id = UUID().uuidString
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? (isChatRequest ? "New chat" : "Insights mission")
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw DispatchError.emptyPrompt
        }
        let effectiveRequestedModelID = try requestedModelID?.nonEmpty
            ?? Self.selectedModelID(forRequestedRuntime: requestedRuntime)

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
            fileEditsAllowed: fileEditsAllowed,
            requestedModelID: effectiveRequestedModelID,
            clientThreadID: clientThreadID,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction
        )
        let db = firestoreProvider()
        let requestRef = db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
        let batch = db.batch()
        batch.setData(payload, forDocument: requestRef, merge: false)
        batch.setData(
            CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(
                label: isChatRequest ? "Chat" : "Mission",
                source: isChatRequest ? "ios-chat" : "ios",
                now: Date()
            ),
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

    // MARK: - Fan-out dispatch (Hermes Square §6.4)
    //
    // Writes one MissionGroupDocument parent + N child cli_agent_mission_requests
    // linked by groupID. The Mac listener claims children independently
    // but respects `parallelismLimit` so a single Mac doesn't spawn 5
    // simultaneous Codex sessions. Per-child personaScopeJSON is propagated
    // when present.
    //
    // Returns the groupID so the caller can subscribe to the group + every
    // child mission for the side-by-side UI in `MissionFanOutGroup`.
    func dispatchFanOut(
        title: String,
        prompt: String,
        missionKind: String,
        runtimeTokens: [String],
        targetProject: String? = nil,
        depth: String = "standard",
        approvalMode: String = "existing_policy",
        commandsAllowed: Bool = false,
        fileEditsAllowed: Bool = false,
        parallelismLimit: Int? = nil,
        mergeStrategy: MissionGroupMergeStrategy = .pickOne,
        personaScopeByRuntime: [String: PersonaScopeEnvelope] = [:]
    ) async throws -> FanOutDispatchResult {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        guard runtimeTokens.count >= 2 else { throw DispatchError.tooFewRuntimes }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw DispatchError.emptyPrompt }

        let groupID = "grp-\(UUID().uuidString)"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Fan-out mission"

        // Build child mission IDs up front so the group doc can list them.
        let childMissionIDs: [String] = runtimeTokens.map { _ in UUID().uuidString }

        // Forecast band: derive per-runtime forecast using
        // `MissionConsoleForecastComputer`, then aggregate via
        // `MissionGroupForecastComputer.combine`. We use the standard
        // depth + kind defaults so callers don't need to supply a forecast.
        let consoleKind = MissionConsoleKind(rawValue: missionKind) ?? .diligence
        let consoleDepth = MissionConsoleDepth(rawValue: depth) ?? .standard
        let consoleApproval = MissionConsoleApprovalMode(rawValue: approvalMode) ?? .existingPolicy
        let childForecasts: [MissionConsoleForecast] = runtimeTokens.map { token in
            let draft = MissionConsoleDispatchRequest(
                title: trimmedTitle,
                prompt: trimmedPrompt,
                kind: consoleKind,
                runtimeID: token,
                targetProject: targetProject,
                depth: consoleDepth,
                approvalMode: consoleApproval,
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed
            )
            let runtime = MissionConsoleRuntime(
                id: token,
                displayName: token.capitalized,
                callSign: String(token.prefix(3)).uppercased(),
                provider: .factory
            )
            return MissionConsoleForecastComputer.forecast(for: draft, runtime: runtime)
        }
        let plim = max(1, parallelismLimit ?? runtimeTokens.count)
        let aggregated = MissionGroupForecastComputer.combine(
            children: childForecasts,
            parallelismLimit: plim
        )

        let db = firestoreProvider()
        let groupRef = db
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let batch = db.batch()

        let groupPayload = MissionGroupPayloadFactory.buildGroupPayload(
            id: groupID,
            title: trimmedTitle,
            prompt: trimmedPrompt,
            missionKind: missionKind,
            targetProject: targetProject,
            childMissionIDs: childMissionIDs,
            runtimeTokens: runtimeTokens,
            parallelismLimit: plim,
            mergeStrategy: mergeStrategy,
            forecast: aggregated
        )
        batch.setData(groupPayload, forDocument: groupRef, merge: false)

        // Child missions: each gets the existing payload plus group hints +
        // optional persona scope.
        for (index, runtimeToken) in runtimeTokens.enumerated() {
            let missionID = childMissionIDs[index]
            var payload = CLIAgentMissionRequestPayloadFactory.build(
                id: missionID,
                title: "\(trimmedTitle) · \(runtimeToken)",
                prompt: trimmedPrompt,
                missionKind: missionKind,
                requestedRuntime: runtimeToken,
                targetProject: targetProject,
                depth: depth,
                approvalMode: approvalMode,
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                requestedModelID: try Self.selectedModelID(forRequestedRuntime: runtimeToken)
            )
            let overlay = MissionGroupPayloadFactory.childPayloadOverlay(
                groupID: groupID,
                siblingIndex: index,
                siblingCount: runtimeTokens.count
            )
            for (k, v) in overlay { payload[k] = v }
            if let envelope = personaScopeByRuntime[runtimeToken] {
                if let scopeJSON = try? envelope.jsonString() {
                    payload["personaScopeJSON"] = scopeJSON
                    payload["personaID"] = envelope.personaID
                }
            }
            let requestRef = db
                .collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(missionID)
            batch.setData(payload, forDocument: requestRef, merge: false)
            batch.setData(
                CLIAgentMissionRequestPayloadFactory.initialQueuedEvent(now: Date()),
                forDocument: requestRef.collection("events").document("000001"),
                merge: false
            )
        }

        try await batch.commit()
        return FanOutDispatchResult(groupID: groupID, childMissionIDs: childMissionIDs)
    }

    private static func selectedModelID(forRequestedRuntime runtimeToken: String) throws -> String? {
        let normalized = runtimeToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let runtime: AssistantRuntimeID?
        switch normalized {
        case "hermes":
            runtime = .hermes
        case "pi", "piagent":
            runtime = .pi
        case "codex":
            runtime = .codex
        case "claude":
            runtime = .claude
        case "openclaw":
            runtime = .openClaw
        default:
            runtime = nil
        }
        guard let runtime else { return nil }

        switch runtime {
        case .hermes:
            return try HermesService.shared.validatedModelIDForMissionDispatch()
        case .pi:
            return try PiService.shared.validatedModelIDForMissionDispatch()
        case .openClaw:
            return try OpenClawService.shared.validatedModelIDForMissionDispatch()
                ?? CLIAgentModelPreferences.preferredModelID(for: .openClaw)?.nonEmpty
        case .codex, .claude:
            return try CLIAgentModelPreferences.validatedPreferredModelID(for: runtime)?.nonEmpty
        }
    }

    struct FanOutDispatchResult: Sendable, Equatable {
        let groupID: String
        let childMissionIDs: [String]
    }

    // MARK: - Mission group observation

    /// Subscribe to live updates of a mission group document. Returns an
    /// observation handle the caller stores for cancellation. Hits the
    /// `users/{uid}/mission_groups/{id}` doc.
    func observeMissionGroup(
        groupID: String,
        onUpdate: @escaping @MainActor (MissionGroupDocument) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let registration = ref.addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error.localizedDescription) }
                return
            }
            guard let data = snapshot?.data() else { return }
            guard let doc = MissionGroupDocument(documentID: groupID, data: data) else { return }
            Task { @MainActor in onUpdate(doc) }
        }
        return CLIAgentMissionObservation(registrations: [registration])
    }

    /// Apply the user's merge choice. Sets `phase = merged`, records
    /// `winnerMissionID`, and optionally writes a synthesisSummary.
    func mergeMissionGroup(
        groupID: String,
        winnerMissionID: String?,
        synthesisSummary: String?
    ) async throws {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        var update: [String: Any] = [
            "phase": MissionGroupPhase.merged.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let winnerMissionID { update["winnerMissionID"] = winnerMissionID }
        if let synthesisSummary { update["synthesisSummary"] = synthesisSummary }
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
            .setData(update, merge: true)
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
        case tooFewRuntimes

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notSignedIn:
                return "Sign in before dispatching Mac agent missions."
            case .emptyPrompt:
                return "Mission prompt was empty."
            case .tooFewRuntimes:
                return "Fan-out dispatch needs at least 2 runtimes."
            }
        }
    }
}

@MainActor
final class AgentHarnessImportJobDispatcher {
    static let shared = AgentHarnessImportJobDispatcher()

    private let firestoreProvider: () -> Firestore

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func create(selectedHarnesses: [String], source: String = "ios-import") async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw CLIAgentMissionDispatcher.DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CLIAgentMissionDispatcher.DispatchError.notSignedIn
        }
        let normalized = selectedHarnesses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else {
            throw CLIAgentMissionDispatcher.DispatchError.emptyPrompt
        }
        let id = "import-\(UUID().uuidString)"
        let payload: [String: Any] = [
            "id": id,
            "selectedHarnesses": Array(Set(normalized)).sorted(),
            "status": "pending",
            "source": source,
            "progressMessage": "Waiting for a trusted Mac.",
            "scannedCount": 0,
            "importedCount": 0,
            "mirroredSessionCount": 0,
            "uploadedSessionLogCount": 0,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1
        ]
        try await firestoreProvider()
            .collection("users").document(uid)
            .collection("agent_import_jobs").document(id)
            .setData(payload, merge: false)
        return id
    }

    func observe(
        jobID: String,
        onUpdate: @escaping @MainActor (AgentHarnessImportJobSnapshot) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) throws -> CLIAgentMissionObservation {
        guard FirebaseApp.app() != nil else {
            throw CLIAgentMissionDispatcher.DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CLIAgentMissionDispatcher.DispatchError.notSignedIn
        }
        let registration = firestoreProvider()
            .collection("users").document(uid)
            .collection("agent_import_jobs").document(jobID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    Task { @MainActor in onError(error.localizedDescription) }
                    return
                }
                guard let data = snapshot?.data(),
                      let snapshot = AgentHarnessImportJobSnapshot(documentID: jobID, data: data) else { return }
                Task { @MainActor in onUpdate(snapshot) }
            }
        return CLIAgentMissionObservation(registrations: [registration])
    }
}

struct AgentHarnessImportJobSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let progressMessage: String
    let scannedCount: Int
    let importedCount: Int
    let mirroredSessionCount: Int
    let uploadedSessionLogCount: Int
    let errorMessage: String?

    init?(documentID: String, data: [String: Any]) {
        self.id = (data["id"] as? String)?.nilIfEmpty ?? documentID
        self.status = (data["status"] as? String)?.nilIfEmpty ?? "pending"
        self.progressMessage = (data["progressMessage"] as? String)?.nilIfEmpty ?? "Waiting for a trusted Mac."
        self.scannedCount = data["scannedCount"] as? Int ?? 0
        self.importedCount = data["importedCount"] as? Int ?? 0
        self.mirroredSessionCount = data["mirroredSessionCount"] as? Int ?? 0
        self.uploadedSessionLogCount = data["uploadedSessionLogCount"] as? Int ?? 0
        self.errorMessage = (data["errorMessage"] as? String)?.nilIfEmpty
    }

    var isTerminal: Bool {
        ["completed", "failed", "canceled", "cancelled"].contains(status)
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
        requestedModelID: String? = nil,
        clientThreadID: String? = nil,
        parentSessionID: String? = nil,
        resumeAction: String? = nil,
        now: Date = Date()
    ) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        var payload: [String: Any] = [
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
            "source": isChatRequest ? "ios-chat" : "ios-insights",
            "status": "pending",
            "liveSummary": isChatRequest
                ? "Chat queued from this device. Waiting for the signed-in Mac agent listener to claim it."
                : "Mission queued from this device. Waiting for the signed-in Mac agent listener to claim it.",
            "createdAt": timestamp,
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 2
        ]
        if let clientThreadID = clientThreadID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            payload["clientThreadID"] = clientThreadID
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
        now: Date = Date()
    ) -> [String: Any] {
        [
            "sequence": 1,
            "timestamp": ISO8601DateFormatter().string(from: now),
            "kind": "status",
            "phase": "queued",
            "title": "Queued",
            "message": "\(label) queued from this device.",
            "source": source,
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
    let requestedModelID: String?
    let selectedRuntime: String?
    let selectedRuntimeName: String?
    let selectedModelID: String?
    let targetProject: String?
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
        self.requestedModelID = (data["requestedModelID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.selectedRuntime = data["selectedRuntime"] as? String
        self.selectedRuntimeName = data["selectedRuntimeName"] as? String
        self.selectedModelID = (data["selectedModelID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        self.targetProject = (data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
