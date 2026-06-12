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

    static func seal<T: Encodable>(_ payload: T, vaultKey: Data, vaultKeyID: String) throws -> [String: Any] {
        let data = try encoder.encode(payload)
        let sealed = try CloudVaultCrypto.sealPayload(data, keyData: vaultKey, vaultKeyID: vaultKeyID)
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
        let plaintext = try CloudVaultCrypto.openPayload(legacyEnvelope, keyData: resolvedKey.keyData)
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
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey)
            return try decoder.decode(CLIAgentMissionPrivatePayload.self, from: payload)
        } catch {
            return nil
        }
    }

    static func openEventPayload(_ data: [String: Any], vaultKey: Data?) -> CLIAgentMissionEventPrivatePayload? {
        guard let vaultKey,
              let envelope = CloudVaultCrypto.sealedPayload(from: data["sealedPayload"])
        else { return nil }
        do {
            let payload = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey)
            return try decoder.decode(CLIAgentMissionEventPrivatePayload.self, from: payload)
        } catch {
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
                source: sourceSurface?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? (isChatRequest ? "ios-chat" : "ios"),
                sourceSkillID: sourceSkillID,
                deliveryMode: deliveryMode,
                now: Date(),
                vaultKey: resolvedKey.keyData,
                vaultKeyID: resolvedKey.vaultKeyID
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
                    CLIAgentMissionEvent(data: doc.data(), vaultKey: localVaultKey)
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
        personaScopeByRuntime: [String: PersonaScopeEnvelope] = [:],
        sourceSkillID: HermesSkillRunID? = nil,
        sourceSurface: String? = nil,
        deliveryMode: SkillRunDeliveryMode = .actionOnly,
        parentHermesThreadID: String? = nil,
        presentationMode: CLIAgentChatPresentationMode = .nativeChat
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
                requestedModelID: try Self.selectedModelID(forRequestedRuntime: runtimeToken),
                sourceSkillID: sourceSkillID,
                sourceSurface: sourceSurface,
                deliveryMode: deliveryMode,
                parentHermesThreadID: parentHermesThreadID,
                presentationMode: presentationMode,
                personaScopeJSON: personaScopeJSON,
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
        case "droid":
            runtime = .droid
        case "forge":
            runtime = .forge
        case "antigravity", "agy", "google-antigravity":
            runtime = .antigravity
        case "grok", "grok-build", "xai", "grok-agent":
            runtime = .grok
        case "cursor", "cursor-agent", "cursoragent":
            runtime = .cursorAgent
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent:
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
    static func cancelMissionUpdate(vaultKey: Data, vaultKeyID: String) throws -> [String: Any] {
        let privatePayload = CLIAgentMissionPrivatePayload(liveSummary: "Mission cancelled by user.")
        return [
            "status": "cancelled",
            "contentSealed": true,
            "sealedStateSchemaVersion": CLIAgentMissionCloudSealer.sealedStateSchemaVersion,
            "sealedStateVaultKeyID": vaultKeyID,
            "sealedStatePayload": try CLIAgentMissionCloudSealer.seal(
                privatePayload,
                vaultKey: vaultKey,
                vaultKeyID: vaultKeyID
            ),
            "updatedAt": FieldValue.serverTimestamp()
        ]
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
        return try applySealedPrivatePayload(privatePayload, to: payload, vaultKey: vaultKey, vaultKeyID: vaultKeyID)
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
        try applySealedEventPayload(privatePayload, to: &event, vaultKey: vaultKey, vaultKeyID: vaultKeyID)
        return event
    }

    private static func applySealedPrivatePayload(
        _ privatePayload: CLIAgentMissionPrivatePayload,
        to payload: [String: Any],
        vaultKey: Data,
        vaultKeyID: String
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
        payload["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(privatePayload, vaultKey: vaultKey, vaultKeyID: vaultKeyID)
        return payload
    }

    private static func applySealedEventPayload(
        _ privatePayload: CLIAgentMissionEventPrivatePayload,
        to event: inout [String: Any],
        vaultKey: Data,
        vaultKeyID: String
    ) throws {
        for key in ["title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath"] {
            event.removeValue(forKey: key)
        }
        event["contentSealed"] = true
        event["sealedSchemaVersion"] = CLIAgentMissionCloudSealer.sealedSchemaVersion
        event["vaultKeyID"] = vaultKeyID
        event["sealedPayload"] = try CLIAgentMissionCloudSealer.seal(privatePayload, vaultKey: vaultKey, vaultKeyID: vaultKeyID)
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

    init?(data: Any, vaultKey: Data?) {
        guard let map = data as? [String: Any],
              let timestamp = map["timestamp"] as? String,
              let phase = map["phase"] as? String else {
            return nil
        }
        let sealed = CLIAgentMissionCloudSealer.openEventPayload(map, vaultKey: vaultKey)
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
