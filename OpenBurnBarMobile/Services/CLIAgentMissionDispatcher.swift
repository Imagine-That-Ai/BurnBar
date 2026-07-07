import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

private let cliMissionSignalLogger = Logger(subsystem: "com.openburnbar.mobile", category: "CLIAgentMissionDispatcher")

private struct CLIAgentMissionPrivatePayload: Codable {
    var title: String?
    var prompt: String?
    var targetProject: String?
    var liveSummary: String?
    var resultPreview: String?
    var errorMessage: String?
    var approvalTitle: String?
    var approvalMessage: String?
    var personaScopeJSON: String?
    var synthesisSummary: String?

    init(
        title: String? = nil,
        prompt: String? = nil,
        targetProject: String? = nil,
        liveSummary: String? = nil,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        approvalTitle: String? = nil,
        approvalMessage: String? = nil,
        personaScopeJSON: String? = nil,
        synthesisSummary: String? = nil
    ) {
        self.title = title
        self.prompt = prompt
        self.targetProject = targetProject
        self.liveSummary = liveSummary
        self.resultPreview = resultPreview
        self.errorMessage = errorMessage
        self.approvalTitle = approvalTitle
        self.approvalMessage = approvalMessage
        self.personaScopeJSON = personaScopeJSON
        self.synthesisSummary = synthesisSummary
    }
}

private struct CLIAgentMissionEventPrivatePayload: Codable {
    var title: String?
    var message: String
    var fullMessage: String?
    var toolName: String?
    var artifactPath: String?
    var changedFilePath: String?
}

private enum CLIAgentMissionCloudSealer {
    static let sealedSchemaVersion = 2
    static let sealedStateSchemaVersion = 1

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func missionAADContext(uid: String, documentID: String, field: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests",
            docID: documentID,
            field: field
        )
    }

    static func missionEventAADContext(uid: String, requestID: String, eventID: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: "cli_agent_mission_requests/events",
            docID: "\(requestID)/\(eventID)",
            field: "sealedPayload"
        )
    }

    static func seal<T: Encodable>(
        _ payload: T,
        vaultKey: Data,
        vaultKeyID: String,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> [String: Any] {
        let data = try encoder.encode(payload)
        let sealed = try CloudVaultCrypto.sealPayload(
            data,
            keyData: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return CloudVaultCrypto.sealedPayloadDictionary(sealed)
    }

    static func signalEnvelopeIfEnabled(
        from sealedData: [String: Any],
        uid: String,
        firestore: Firestore,
        collection: String,
        docId: String,
        resolvedKey: MobileCloudVaultResolvedKey
    ) async throws -> [String: Any]? {
        guard MobileCloudVaultSignalPayloads.signalSealingIsEnabled(domainID: "conversations_chat") else {
            return nil
        }
        guard let legacyEnvelope = CloudVaultCrypto.sealedPayload(from: sealedData["sealedPayload"]) else {
            throw MobileCloudVaultSignalPayloadError.invalidSignalEnvelope
        }
        let aadContext = try missionAADContext(uid: uid, documentID: docId, field: "sealedPayload")
        let plaintext = try CloudVaultCrypto.openPayload(
            legacyEnvelope,
            keyData: resolvedKey.keyData,
            aadContext: aadContext
        )
        return try await MobileCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
            domainID: "conversations_chat",
            uid: uid,
            firestore: firestore,
            collection: collection,
            docId: docId,
            plaintext: plaintext,
            resolvedKey: resolvedKey
        )
    }

    static func openPrivatePayload(
        _ data: [String: Any],
        field: String = "sealedPayload",
        uid: String? = nil,
        documentID: String? = nil,
        vaultKey: Data?,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil
    ) -> CLIAgentMissionPrivatePayload? {
        if field == "sealedPayload", data["signalEnvelope"] != nil, let uid, let documentID {
            do {
                if let payload = try MobileCloudVaultSignalPayloads.openSignalPayloadIfPresent(
                    data,
                    uid: uid,
                    collection: "cli_agent_mission_requests",
                    docId: documentID,
                    signalIdentity: signalIdentity
                ) {
                    return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
                }
            } catch let signalError as OpenBurnBarSignalCoreError
                where !signalError.allowsLegacyAtRestFallback(senderSetComplete: false) {
                // C1: a stripped / forged sender-auth block (or relocated AAD
                // binding) is a downgrade attack — fail CLOSED, never decode the
                // sender-unauthenticated legacy payload for this mission request.
                return nil
            } catch MobileCloudVaultSignalPayloadError.signalBindingMismatch {
                // Relocated / replayed envelope — fail CLOSED.
                return nil
            } catch {
                // Phase-C rollout keeps legacy AES-GCM `sealedPayload` alongside
                // optional Signal envelopes. A missing local Signal identity or
                // malformed optional envelope must not make the legacy reader lose
                // data while activation remains flag-off.
            }
        }
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data[field])
        else { return nil }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let documentID {
                aadContext = try? missionAADContext(uid: uid, documentID: documentID, field: field)
            } else {
                aadContext = nil
            }
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
        } catch {
            // Undecryptable/undecodable mission payload is dropped — log so a key
            // mismatch or schema drift doesn't silently blank the mission feed.
            cliMissionSignalLogger.warning("mission payload open failed doc=\(documentID ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func openEventPayload(
        _ data: [String: Any],
        uid: String? = nil,
        requestID: String? = nil,
        eventID: String? = nil,
        vaultKey: Data?
    ) -> CLIAgentMissionEventPrivatePayload? {
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"])
        else { return nil }
        do {
            let aadContext: CloudVaultAADContext?
            if let uid, let requestID, let eventID {
                aadContext = try? missionEventAADContext(uid: uid, requestID: requestID, eventID: eventID)
            } else {
                aadContext = nil
            }
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: aadContext)
            return try decoder.decode(CLIAgentMissionEventPrivatePayload.self, from: payload)
        } catch {
            // Undecryptable/undecodable mission event is dropped — log so a key
            // mismatch or schema drift doesn't silently hide mission progress.
            cliMissionSignalLogger.warning("mission event open failed request=\(requestID ?? "?", privacy: .public) event=\(eventID ?? "?", privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

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
        // BEST-EFFORT at-rest Signal seal; legacy sealedPayload (already in payload) is the
        // FLOOR. On any failure log and write legacy-only rather than abort the dispatch.
        do {
            if let signalEnvelope = try await CLIAgentMissionCloudSealer.signalEnvelopeIfEnabled(
                from: payload,
                uid: uid,
                firestore: db,
                collection: "cli_agent_mission_requests",
                docId: id,
                resolvedKey: resolvedKey
            ) {
                payload["signalEnvelope"] = signalEnvelope
            }
        } catch {
            cliMissionSignalLogger.error("Signal at-rest seal failed; writing CLI mission legacy-only: \(String(describing: error), privacy: .public)")
        }
        let requestRef = db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(id)
        let batch = db.batch()
        batch.setData(payload, forDocument: requestRef, merge: false)
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
        personaScopeByRuntime: [String: PersonaScopeEnvelope] = [:],
        sourceSkillID: HermesSkillRunID? = nil,
        sourceSurface: String? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        parentHermesThreadID: String? = nil,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat,
        wandPolicy: WandPolicy? = nil
    ) async throws -> FanOutDispatchResult {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        guard runtimeTokens.count >= 1 else { throw DispatchError.tooFewRuntimes }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw DispatchError.emptyPrompt }

        let groupID = "grp-\(UUID().uuidString)"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Wand cast"
        let resolvedWandPolicy = try await Self.resolvedWandPolicy(
            wandPolicy,
            runtimeTokens: runtimeTokens
        )

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
                fileEditsAllowed: fileEditsAllowed,
                sourceSkillID: sourceSkillID,
                sourceSurface: sourceSurface,
                deliveryMode: deliveryMode,
                parentHermesThreadID: parentHermesThreadID
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
        let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
        let groupRef = db
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let batch = db.batch()

        let legacyGroupPayload = MissionGroupPayloadFactory.buildGroupPayload(
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
        let groupPayload = try CLIAgentMissionRequestPayloadFactory.sealGroupPayload(
            legacyGroupPayload,
            title: trimmedTitle,
            prompt: trimmedPrompt,
            targetProject: targetProject,
            vaultKey: resolvedKey.keyData,
            vaultKeyID: resolvedKey.vaultKeyID
        )
        batch.setData(groupPayload, forDocument: groupRef, merge: false)

        // Child missions: each gets the existing payload plus group hints +
        // optional persona scope.
        for (index, runtimeToken) in runtimeTokens.enumerated() {
            let missionID = childMissionIDs[index]
            let personaScopeJSON = try personaScopeByRuntime[runtimeToken]?.jsonString()
            var payload = try CLIAgentMissionRequestPayloadFactory.buildSealed(
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
                requestedModelID: try Self.selectedModelID(
                    forRequestedRuntime: runtimeToken,
                    wandPolicy: resolvedWandPolicy
                ),
                sourceSkillID: sourceSkillID,
                sourceSurface: sourceSurface,
                deliveryMode: deliveryMode,
                parentHermesThreadID: parentHermesThreadID,
                presentationMode: presentationMode,
                personaScopeJSON: personaScopeJSON,
                uid: uid,
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID
            )
            let overlay = MissionGroupPayloadFactory.childPayloadOverlay(
                groupID: groupID,
                siblingIndex: index,
                siblingCount: runtimeTokens.count
            )
            for (k, v) in overlay { payload[k] = v }
            if let envelope = personaScopeByRuntime[runtimeToken] {
                payload["personaID"] = envelope.personaID
            }
            // BEST-EFFORT at-rest Signal seal; legacy sealedPayload is the FLOOR. On any
            // failure log and write legacy-only rather than abort the fan-out child.
            do {
                if let signalEnvelope = try await CLIAgentMissionCloudSealer.signalEnvelopeIfEnabled(
                    from: payload,
                    uid: uid,
                    firestore: db,
                    collection: "cli_agent_mission_requests",
                    docId: missionID,
                    resolvedKey: resolvedKey
                ) {
                    payload["signalEnvelope"] = signalEnvelope
                }
            } catch {
                cliMissionSignalLogger.error("Signal at-rest seal failed; writing CLI mission child legacy-only: \(String(describing: error), privacy: .public)")
            }
            let requestRef = db
                .collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(missionID)
            batch.setData(payload, forDocument: requestRef, merge: false)
            batch.setData(
                try CLIAgentMissionRequestPayloadFactory.initialQueuedEventSealed(
                    sourceSkillID: sourceSkillID,
                    deliveryMode: deliveryMode,
                    now: Date(),
                    uid: uid,
                    requestID: missionID,
                    eventID: "000001",
                    vaultKey: resolvedKey.keyData,
                    vaultKeyID: resolvedKey.vaultKeyID
                ),
                forDocument: requestRef.collection("events").document("000001"),
                merge: false
            )
        }

        try await batch.commit()
        return FanOutDispatchResult(groupID: groupID, childMissionIDs: childMissionIDs)
    }

    func dispatchMissionGroupSynthesis(
        group: MissionGroupDocument,
        childSnapshots: [String: CLIAgentMissionSnapshot]
    ) async throws -> String {
        let draft = Self.missionGroupSynthesisDraft(
            group: group,
            childSnapshots: childSnapshots
        )
        return try await dispatch(
            title: draft.title,
            prompt: draft.prompt,
            missionKind: draft.missionKind,
            requestedRuntime: draft.requestedRuntime,
            targetProject: draft.targetProject,
            depth: draft.depth,
            approvalMode: draft.approvalMode,
            commandsAllowed: draft.commandsAllowed,
            fileEditsAllowed: draft.fileEditsAllowed,
            sourceSurface: draft.sourceSurface,
            queuedEventSource: draft.queuedEventSource,
            deliveryMode: draft.deliveryMode
        )
    }

    static func missionGroupSynthesisDraft(
        group: MissionGroupDocument,
        childSnapshots: [String: CLIAgentMissionSnapshot]
    ) -> MissionGroupSynthesisDraft {
        MissionGroupSynthesisDraft(
            title: "Synthesize \(group.title)",
            prompt: missionGroupSynthesisPrompt(
                group: group,
                childSnapshots: childSnapshots
            ),
            targetProject: group.targetProject
        )
    }

    private static func missionGroupSynthesisPrompt(
        group: MissionGroupDocument,
        childSnapshots: [String: CLIAgentMissionSnapshot]
    ) -> String {
        let childCount = max(group.childMissionIDs.count, 1)
        let perChildBudget = max(
            800,
            min(5_000, 19_000 / childCount)
        )
        let childSections = group.childMissionIDs.enumerated().map { index, missionID in
            let runtime = group.runtimeTokens.indices.contains(index)
                ? group.runtimeTokens[index]
                : "runtime-\(index + 1)"
            guard let snapshot = childSnapshots[missionID] else {
                return """
                ### \(index + 1). \(runtime) (\(missionID))
                Status: missing_snapshot
                No mobile snapshot was available when synthesis was requested.
                """
            }
            return missionGroupChildResultSection(
                index: index,
                runtime: runtime,
                snapshot: snapshot,
                limit: perChildBudget
            )
        }.joined(separator: "\n\n")

        let targetProject = group.targetProject?.nilIfEmpty ?? "not specified"
        let prompt = """
        You are OpenBurnBar's Phase B second-stage synthesizer.

        Synthesize the child mission outputs below into one final answer for the user.
        Use only the supplied child outputs; do not run shell commands, ask for repo access,
        or edit files. Resolve agreement and disagreement explicitly, keep useful minority
        findings, and produce a concise final recommendation with validation notes and
        residual risks.

        Group ID: \(group.id)
        Original title: \(trimmed(group.title, limit: 500))
        Original mission kind: \(trimmed(group.missionKind, limit: 120))
        Target project: \(trimmed(targetProject, limit: 500))

        Original prompt:
        \(trimmed(group.prompt, limit: 3_000))

        Child mission outputs:

        \(childSections)
        """
        return trimmed(prompt, limit: 24_000)
    }

    private static func missionGroupChildResultSection(
        index: Int,
        runtime: String,
        snapshot: CLIAgentMissionSnapshot,
        limit: Int = 5_000
    ) -> String {
        var lines: [String] = [
            "### \(index + 1). \(runtime) (\(snapshot.id))",
            "Status: \(snapshot.status)",
            "Requested runtime: \(snapshot.requestedRuntime)",
            "Selected runtime: \(snapshot.runtimeLabel)"
        ]
        if let model = snapshot.selectedModelID ?? snapshot.requestedModelID {
            lines.append("Model: \(model)")
        }
        if let liveSummary = snapshot.liveSummary?.nilIfEmpty {
            lines.append("Live summary:\n\(trimmed(liveSummary, limit: 1_200))")
        }
        if let finalAnswer = missionGroupFinalAnswerText(from: snapshot) {
            lines.append("Final answer:\n\(trimmed(finalAnswer, limit: max(800, limit - 1_200)))")
        } else if let resultPreview = snapshot.resultPreview?.nilIfEmpty {
            lines.append("Result preview:\n\(trimmed(resultPreview, limit: 3_000))")
        }
        if let errorMessage = snapshot.errorMessage?.nilIfEmpty {
            lines.append("Error:\n\(trimmed(errorMessage, limit: 1_200))")
        }
        let eventLines = snapshot.events
            .filter { $0.kind != "final_answer" }
            .suffix(4)
            .compactMap { event -> String? in
                let message = (event.fullMessage ?? event.message)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                guard let message else { return nil }
                let title = event.title?.nilIfEmpty ?? event.phase
                return "- \(title): \(trimmed(message, limit: min(700, max(280, limit / 8))))"
            }
        if !eventLines.isEmpty {
            lines.append("Latest events:\n\(eventLines.joined(separator: "\n"))")
        }
        return trimmed(lines.joined(separator: "\n"), limit: limit)
    }

    private static func missionGroupFinalAnswerText(from snapshot: CLIAgentMissionSnapshot) -> String? {
        snapshot.events.reversed().first { event in
            event.kind == "final_answer"
        }.flatMap { event in
            (event.fullMessage ?? event.message)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
    }

    private static func trimmed(_ value: String, limit: Int) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cutoff = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<cutoff]).trimmingCharacters(in: .whitespacesAndNewlines) + "\n[truncated]"
    }

    private static func selectedModelID(
        forRequestedRuntime runtimeToken: String,
        wandPolicy: WandPolicy? = nil
    ) throws -> String? {
        let runtime = runtimeID(forRequestedRuntime: runtimeToken)
        guard let runtime else { return nil }

        // Phase 2: when a Wand policy is active, this must be a concrete
        // catalog-backed routing table. `resolvedWandPolicy` fails before
        // Firestore writes if no selected runtime can be routed, so the UI
        // never looks like a Wand cast happened while silently using defaults.
        if let policy = wandPolicy, let routed = policy.routedModelID(for: runtime) {
            return routed
        }

        switch runtime {
        case .hermes:
            return try HermesService.shared.validatedModelIDForMissionDispatch()
        case .pi:
            return try PiService.shared.validatedModelIDForMissionDispatch()
        case .openClaw:
            return try OpenClawService.shared.validatedModelIDForMissionDispatch()
                ?? CLIAgentModelPreferences.preferredModelID(for: .openClaw)?.nonEmpty
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent, .openClaude, .omp:
            return try CLIAgentModelPreferences.validatedPreferredModelID(for: runtime)?.nonEmpty
        }
    }

    private static func resolvedWandPolicy(
        _ policy: WandPolicy?,
        runtimeTokens: [String]
    ) async throws -> WandPolicy? {
        guard let policy else { return nil }
        let runtimes = runtimeTokens.compactMap(runtimeID(forRequestedRuntime:))
        guard !runtimes.isEmpty else {
            throw DispatchError.wandRoutingUnavailable("No selected runtime can be routed by The Wand.")
        }

        var catalogs: [AssistantRuntimeID: [CLIRuntimeModelOption]] = [:]
        for runtime in runtimes {
            guard catalogs[runtime] == nil else { continue }
            do {
                let response = try await HermesService.shared.fetchCLIRuntimeModelCatalog(runtime: runtime)
                catalogs[runtime] = response.options
            } catch {
                cliMissionSignalLogger.warning("wand catalog fetch failed runtime=\(runtime.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        let routed = WandModelRouter.policy(
            selector: policy.selector,
            runtimes: runtimes,
            catalogs: catalogs
        )
        guard !routed.routedModels.isEmpty else {
            throw DispatchError.wandRoutingUnavailable(
                "The Wand could not route any selected agent. Refresh the Mac model catalog, choose agents with available catalogs, or switch to Manual."
            )
        }
        return routed
    }

    private static func runtimeID(forRequestedRuntime runtimeToken: String) -> AssistantRuntimeID? {
        let normalized = runtimeToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "hermes":
            return .hermes
        case "pi", "piagent":
            return .pi
        case "codex":
            return .codex
        case "claude":
            return .claude
        case "openclaw":
            return .openClaw
        case "droid":
            return .droid
        case "forge":
            return .forge
        case "antigravity", "agy", "google-antigravity":
            return .antigravity
        case "grok", "grok-build", "xai", "grok-agent":
            return .grok
        case "cursor", "cursor-agent", "cursoragent":
            return .cursorAgent
        default:
            return nil
        }
    }

    struct FanOutDispatchResult: Sendable, Equatable {
        let groupID: String
        let childMissionIDs: [String]
    }

    struct MissionGroupSynthesisDraft: Sendable, Equatable {
        let title: String
        let prompt: String
        let missionKind: String = "synthesizer"
        let requestedRuntime: String = "hermes"
        let targetProject: String?
        let depth: String = "standard"
        let approvalMode: String = "read_only"
        let commandsAllowed: Bool = false
        let fileEditsAllowed: Bool = false
        let sourceSurface: String = "ios-hermes-square"
        let queuedEventSource: String = "ios"
        let deliveryMode: SkillRunDeliveryMode = .fullStream
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
        let localVaultKey: Data?
        do {
            localVaultKey = try CloudVaultKeyStore().loadKey(uid: uid)
        } catch {
            localVaultKey = nil
        }
        let ref = firestoreProvider()
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let registration = ref.addSnapshotListener { snapshot, error in
            if let error {
                Task { @MainActor in onError(error.localizedDescription) }
                return
            }
            guard let data = snapshot?.data() else { return }
            guard let doc = MissionGroupDocument(documentID: groupID, data: data, vaultKey: localVaultKey) else { return }
            Task { @MainActor in onUpdate(doc) }
        }
        return CLIAgentMissionObservation(registrations: [registration])
    }

    /// Apply the user's merge choice. Sets `phase = merged`, records
    /// `winnerMissionID`, and optionally seals a `synthesisSummary` into
    /// `sealedStatePayload`.
    ///
    /// `synthesisSummary` is private user-facing text, so it is NEVER written
    /// as a top-level plaintext field — `validMissionGroup` (firestore.rules)
    /// rejects a top-level `synthesisSummary` and the seal mirrors Android's
    /// `sealGroupPayload`/`sealedMissionStateUpdate` shape. The reader
    /// (`MissionGroupDocument`) already opens `sealedStatePayload` for the
    /// synthesis with a legacy top-level fallback during migration.
    func mergeMissionGroup(
        groupID: String,
        winnerMissionID: String?,
        synthesisSummary: String?
    ) async throws {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        let db = firestoreProvider()
        let update: [String: Any]
        if let synthesisSummary {
            // Sealing the synthesis requires the writable vault key; mirror the
            // dispatch path so a merge after dispatch always re-seals locally.
            let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
            update = try Self.mergeMissionGroupUpdate(
                winnerMissionID: winnerMissionID,
                synthesisSummary: synthesisSummary,
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID
            )
        } else {
            update = Self.mergeMissionGroupUpdate(winnerMissionID: winnerMissionID)
        }
        try await db
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
            .setData(update, merge: true)
    }

    /// Build the merge update WITHOUT a synthesis summary (no seal needed).
    /// Writes only non-private fields: `phase`, `winnerMissionID`, `updatedAt`.
    static func mergeMissionGroupUpdate(winnerMissionID: String?) -> [String: Any] {
        var update: [String: Any] = [
            "phase": MissionGroupPhase.merged.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let winnerMissionID { update["winnerMissionID"] = winnerMissionID }
        return update
    }

    /// Build the merge update WITH a sealed synthesis summary. The private
    /// `synthesisSummary` lives only inside `sealedStatePayload`; the triplet
    /// of state fields (`contentSealed`/`sealedStateSchemaVersion`/
    /// `sealedStateVaultKeyID`) matches the Firestore state-update contract.
    static func mergeMissionGroupUpdate(
        winnerMissionID: String?,
        synthesisSummary: String,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        var update = mergeMissionGroupUpdate(winnerMissionID: winnerMissionID)
        let privatePayload = CLIAgentMissionPrivatePayload(synthesisSummary: synthesisSummary)
        update["contentSealed"] = true
        update["sealedStateSchemaVersion"] = CLIAgentMissionCloudSealer.sealedStateSchemaVersion
        update["sealedStateVaultKeyID"] = vaultKeyID
        update["sealedStatePayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID
        )
        return update
    }

    func respondToApproval(
        requestID: String,
        approve: Bool
    ) async throws {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard Auth.auth().currentUser?.uid != nil else {
            throw DispatchError.notSignedIn
        }
        // Bind the approve/reject to this trusted native escrow device via the
        // App-Check-enforced callable. The bare Firestore status flip is no
        // longer accepted by firestore.rules (it must carry approvedByDeviceId
        // resolving to a trusted escrow device), so a stolen owner token cannot
        // self-approve a high-risk mission.
        let deviceId = await MainActor.run { MobileDeviceIdentity.loadOrCreateDeviceId() }
        try await ComputerUseSecurityCallableClient.respondMissionApproval(
            requestId: requestID,
            approve: approve,
            deviceId: deviceId
        )
    }

    func cancelMission(requestID: String) async throws {
        guard FirebaseApp.app() != nil else {
            throw DispatchError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw DispatchError.notSignedIn
        }
        let db = firestoreProvider()
        // The user-facing cancel summary is private text. Seal it into
        // `sealedStatePayload` (mirroring Android `sealedMissionStateUpdate`)
        // instead of writing a top-level plaintext `liveSummary`. The reader
        // (`CLIAgentMissionSnapshot`) already prefers the sealed state summary
        // with a legacy top-level fallback. This shape also satisfies the new
        // `validMobileMissionCancel()` rule predicate (owned by stream SD):
        // diff hasOnly(status, contentSealed, sealedStatePayload,
        // sealedStateSchemaVersion, sealedStateVaultKeyID, updatedAt).
        let resolvedKey = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid, firestore: db)
        let update = try Self.cancelMissionUpdate(
            uid: uid,
            requestID: requestID,
            vaultKey: resolvedKey.keyData,
            vaultKeyID: resolvedKey.vaultKeyID
        )
        try await db
            .collection("users").document(uid)
            .collection("cli_agent_mission_requests").document(requestID)
            .setData(update, merge: true)
    }

    /// Build the sealed cancel update. `status` flips to `cancelled` and the
    /// cancel summary is sealed into `sealedStatePayload`; no plaintext
    /// `liveSummary` is written. Diff keys exactly match the
    /// `validMobileMissionCancel()` rule allowlist.
    static func cancelMissionUpdate(
        uid: String? = nil,
        requestID: String? = nil,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        let privatePayload = CLIAgentMissionPrivatePayload(liveSummary: "Mission cancelled by user.")
        let aadContext: CloudVaultAADContext?
        if let uid, let requestID {
            aadContext = try CLIAgentMissionCloudSealer.missionAADContext(
                uid: uid,
                documentID: requestID,
                field: "sealedStatePayload"
            )
        } else {
            aadContext = nil
        }
        return [
            "status": "cancelled",
            "contentSealed": true,
            "sealedStateSchemaVersion": CLIAgentMissionCloudSealer.sealedStateSchemaVersion,
            "sealedStateVaultKeyID": vaultKeyID,
            "sealedStatePayload": try CLIAgentMissionCloudSealer.seal(
                privatePayload,
                vaultKey: vaultKey,
                vaultKeyID: vaultKeyID,
                aadContext: aadContext
            ),
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    enum DispatchError: LocalizedError {
        case firebaseUnavailable
        case notSignedIn
        case emptyPrompt
        case tooFewRuntimes
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
            case let .wandRoutingUnavailable(message):
                return message
            case let .missionSnapshotUnavailable(requestID):
                return "Mission snapshot \(requestID) was unavailable."
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
        now: Date = Date(),
        uid: String? = nil,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
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
            synthesisSummary: nil
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
        _ payload: [String: Any],
        title: String,
        prompt: String,
        targetProject: String?,
        vaultKey: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
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
    ) -> [String: Any] {
        let timestamp = ISO8601DateFormatter().string(from: now)
        let isChatRequest = missionKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chat"
        let baseSource = isChatRequest ? "ios-chat" : "ios-insights"
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
    ) -> [String: Any] {
        var event: [String: Any] = [
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
    ) throws -> [String: Any] {
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
        to payload: [String: Any],
        vaultKey: Data,
        vaultKeyID: String,
        aadContext: CloudVaultAADContext? = nil
    ) throws -> [String: Any] {
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
        to event: inout [String: Any],
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
