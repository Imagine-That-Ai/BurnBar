import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
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
        case .codex, .claude, .droid, .forge, .antigravity, .grok, .cursorAgent, .openClaude, .omp, .junie:
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
        case "junie", "junie-agent", "jetbrains-junie":
            return .junie
        case "omp", "ohmypi", "oh-my-pi", "oh my pi":
            return .omp
        default:
            return nil
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
        // `sealedStatePayload` instead of writing a top-level plaintext
        // `liveSummary`.
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
    /// `liveSummary` is written.
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
