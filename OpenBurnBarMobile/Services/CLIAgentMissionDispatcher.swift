import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

let cliMissionSignalLogger = Logger(subsystem: "com.openburnbar.mobile", category: "CLIAgentMissionDispatcher")

@MainActor
final class CLIAgentMissionDispatcher {
    static let shared = CLIAgentMissionDispatcher()

    let firestoreProvider: () -> Firestore

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
        resumeAction: String? = nil,
        sourceSkillID: HermesSkillRunID? = nil,
        sourceSurface: String? = nil,
        queuedEventSource: String? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        parentHermesThreadID: String? = nil,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat
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

        let db = firestoreProvider()
        let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
        var payload = try CLIAgentMissionRequestPayloadFactory.buildSealed(
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
            resumeAction: resumeAction,
            sourceSkillID: sourceSkillID,
            sourceSurface: sourceSurface,
            deliveryMode: deliveryMode,
            parentHermesThreadID: parentHermesThreadID,
            presentationMode: presentationMode,
            uid: uid,
            vaultKey: resolvedKey.keyData,
            vaultKeyID: resolvedKey.vaultKeyID
        )
        let signalState = MobileCloudVaultSignalPayloads.signalActivationState(domainID: "conversations_chat")
        if signalState != .off {
            do {
                if let envelope = try await CLIAgentMissionCloudSealer.signalEnvelopeIfEnabled(
                    from: payload,
                    uid: uid,
                    firestore: db,
                    collection: "cli_agent_mission_requests",
                    docId: id,
                    resolvedKey: resolvedKey
                ) {
                    payload["signalEnvelope"] = envelope
                    if signalState == .required {
                        for key in ["contentSealed", "sealedSchemaVersion", "vaultKeyID", "sealedPayload"] {
                            payload.removeValue(forKey: key)
                        }
                    }
                }
            } catch {
                if signalState == .required { throw error }
            }
        }
        try MobileCloudVaultSignalPayloads.requireEnvelopeIfRequired(
            payload: payload,
            state: signalState,
            domainID: "conversations_chat"
        )
        let signalWrite = signalState != .off && payload["signalEnvelope"] != nil
        if signalWrite {
            var callablePayload = payload
            callablePayload["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            _ = try await Functions.functions()
                .httpsCallable("writeSignalAtRestDocument")
                .call([
                    "collection": "cli_agent_mission_requests",
                    "docId": id,
                    "data": callablePayload
                ])
        }
        let requestRef = db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
        let batch = db.batch()
        if !signalWrite {
            batch.setData(
                payload,
                forDocument: requestRef,
                merge: false
            )
        }
        batch.setData(
            try CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
                label: isChatRequest ? "Chat" : "Mission",
                source: Self.initialQueuedEventSource(
                    missionKind: missionKind,
                    sourceSurface: queuedEventSource ?? sourceSurface
                ),
                sourceSkillID: sourceSkillID,
                deliveryMode: deliveryMode,
                now: Date(),
                uid: uid,
                requestID: id,
                eventID: "000001",
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID
            ),
            forDocument: requestRef.collection("events").document("000001"),
            merge: false
        )
        try await batch.commit()
        return id
    }

    static func initialQueuedEventSource(
        missionKind: String,
        sourceSurface: String?
    ) -> String {
        if let sourceSurface = sourceSurface?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            switch sourceSurface {
            case "ios", "android", "ios-chat", "android-chat":
                return sourceSurface
            default:
                break
            }
        }
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        return isChatRequest ? "ios-chat" : "ios"
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
        let localVaultKey: Data?
        do {
            localVaultKey = try CloudVaultKeyStore().loadKey(uid: uid)
        } catch {
            localVaultKey = nil
        }
        let localSignalIdentity: OpenBurnBarSignalIdentityKeypair?
        do {
            let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
            localSignalIdentity = try OpenBurnBarSignalIdentityKeyStore().load(uid: uid, deviceId: deviceId)
        } catch {
            localSignalIdentity = nil
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
                    eventOverride: latestEvents.isEmpty ? nil : latestEvents,
                    vaultKey: localVaultKey,
                    signalIdentity: localSignalIdentity,
                    uid: uid
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
                    CLIAgentMissionEvent(
                        data: doc.data(),
                        vaultKey: localVaultKey,
                        uid: uid,
                        requestID: requestID,
                        eventID: doc.documentID
                    )
                } ?? []
                emitLatest()
            }
        return CLIAgentMissionObservation(registrations: [requestRegistration, eventsRegistration])
    }

    func fetchMissionSnapshot(requestID: String) async throws -> CLIAgentMissionSnapshot {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let localVaultKey: Data?
        do {
            localVaultKey = try CloudVaultKeyStore().loadKey(uid: uid)
        } catch {
            localVaultKey = nil
        }
        let localSignalIdentity: OpenBurnBarSignalIdentityKeypair?
        do {
            let deviceId = MobileDeviceIdentity.loadOrCreateDeviceId()
            localSignalIdentity = try OpenBurnBarSignalIdentityKeyStore().load(uid: uid, deviceId: deviceId)
        } catch {
            localSignalIdentity = nil
        }

        let requestRef = firestoreProvider()
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
        let requestSnapshot = try await requestRef.getDocument(source: .server)
        guard requestSnapshot.exists else {
            throw DispatchError.missionSnapshotUnavailable(requestID)
        }
        let eventSnapshot = try await requestRef
            .collection("events")
            .order(by: "sequence")
            .limit(to: 1000)
            .getDocuments(source: .server)
        let events = eventSnapshot.documents.compactMap { doc in
            CLIAgentMissionEvent(
                data: doc.data(),
                vaultKey: localVaultKey,
                uid: uid,
                requestID: requestID,
                eventID: doc.documentID
            )
        }
        guard let mission = CLIAgentMissionSnapshot(
            documentID: requestID,
            data: requestSnapshot.data() ?? [:],
            eventOverride: events.isEmpty ? nil : events,
            vaultKey: localVaultKey,
            signalIdentity: localSignalIdentity,
            uid: uid
        ) else {
            throw DispatchError.missionSnapshotUnavailable(requestID)
        }
        return mission
    }

    enum DispatchError: LocalizedError {
        case firebaseUnavailable
        case notSignedIn
        case emptyPrompt
        case tooFewRuntimes
        case tooManyRuntimes
        case wandRoutingUnavailable(String)
        case missionSnapshotUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notSignedIn:
                return "Sign in before dispatching Mac agent missions."
            case .emptyPrompt:
                return "Mission prompt was empty."
            case .tooFewRuntimes:
                return "The Wand needs at least 1 agent."
            case .tooManyRuntimes:
                return "Signal fan-out supports at most 100 agents per dispatch."
            case let .wandRoutingUnavailable(message):
                return message
            case let .missionSnapshotUnavailable(requestID):
                return "Mission snapshot \(requestID) was unavailable."
            }
        }
    }
}

