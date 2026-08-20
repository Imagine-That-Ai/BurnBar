import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore
import os

// MARK: - Fan-out dispatch, synthesis + model routing
//
// Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14
// structural decomposition). Pure move — no behavior change.

extension CLIAgentMissionDispatcher {
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
        wandPolicy: WandPolicy? = nil,
        catalogProvider: (any CLIRuntimeCatalogProviding)? = nil
    ) async throws -> FanOutDispatchResult {
        guard FirebaseApp.app() != nil else { throw DispatchError.firebaseUnavailable }
        guard let uid = Auth.auth().currentUser?.uid else { throw DispatchError.notSignedIn }
        guard runtimeTokens.count >= 1 else { throw DispatchError.tooFewRuntimes }
        let signalActivationState = MobileCloudVaultSignalPayloads.signalActivationState(domainID: "conversations_chat")
        guard signalActivationState == .off || runtimeTokens.count <= 100 else {
            throw DispatchError.tooManyRuntimes
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw DispatchError.emptyPrompt }

        let groupID = "grp-\(UUID().uuidString)"
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Wand cast"
        let resolvedWandPolicy = try await Self.resolvedWandPolicy(
            wandPolicy,
            runtimeTokens: runtimeTokens,
            catalogProvider: catalogProvider ?? HermesService.shared
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
        let plim = Self.resolvedParallelismLimit(
            parallelismLimit,
            childCount: runtimeTokens.count
        )
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

        // Signal children are persisted through the `writeSignalAtRestDocument`
        // callable (Firestore rules deny direct `signalEnvelope` writes on
        // `cli_agent_mission_requests`), which cannot join the client batch.
        // Stage them here and run the callables ONLY AFTER the group + events
        // batch commits, so a Mac listener can never claim a child while its
        // parent group and initial event exist only in an uncommitted batch,
        // and a batch failure leaves nothing behind.
        var stagedSignalChildren: [(missionID: String, payload: NSDictionary)] = []

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
            let signalState = MobileCloudVaultSignalPayloads.signalActivationState(domainID: "conversations_chat")
            if signalState != .off {
                do {
                    if let envelope = try await CLIAgentMissionCloudSealer.signalEnvelopeIfEnabled(
                        from: payload,
                        uid: uid,
                        firestore: db,
                        collection: "cli_agent_mission_requests",
                        docId: missionID,
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
            let requestRef = db
                .collection("users").document(uid)
                .collection("cli_agent_mission_requests").document(missionID)
            let signalWrite = signalState != .off && payload["signalEnvelope"] != nil
            if signalWrite {
                var callablePayload = payload
                callablePayload["updatedAt"] = ISO8601DateFormatter().string(from: Date())
                stagedSignalChildren.append((missionID: missionID, payload: callablePayload as NSDictionary))
            } else {
                batch.setData(
                    payload,
                    forDocument: requestRef,
                    merge: false
                )
            }
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

        // Persist Signal children only after the group + initial events are
        // durable. If a callable fails mid-way, compensate by marking the
        // already-committed group cancelled (best-effort) so the fan-out is
        // visibly terminal instead of silently waiting on children that will
        // never arrive. The callable accepts the complete child set and commits
        // it in one server-side batch, so no partial child set can be exposed.
        do {
            if !stagedSignalChildren.isEmpty {
                _ = try await Functions.functions()
                    .httpsCallable("writeSignalAtRestDocument")
                    .call([
                        "documents": stagedSignalChildren.map { staged in
                            [
                                "collection": "cli_agent_mission_requests",
                                "docId": staged.missionID,
                                "data": staged.payload
                            ]
                        }
                    ])
            }
        } catch {
            let cleanup = db.batch()
            for staged in stagedSignalChildren {
                cleanup.deleteDocument(
                    db.collection("users").document(uid)
                        .collection("cli_agent_mission_requests").document(staged.missionID)
                        .collection("events").document("000001")
                )
            }
            cleanup.setData(
                ["phase": MissionGroupPhase.cancelled.rawValue],
                forDocument: groupRef,
                merge: true
            )
            try? await cleanup.commit()
            throw error
        }
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

    static func selectedModelID(
        forRequestedRuntime runtimeToken: String,
        wandPolicy: WandPolicy? = nil
    ) throws -> String? {
        let runtime = runtimeID(forRequestedRuntime: runtimeToken)
        guard let runtime else {
            guard wandPolicy == nil else {
                throw DispatchError.wandRoutingUnavailable(
                    "The selected agent runtime is not recognized by The Wand. Refresh the agent list or switch to Manual."
                )
            }
            return nil
        }

        // Phase 2: when a Wand policy is active, this must be a concrete
        // catalog-backed routing table. `resolvedWandPolicy` fails before
        // Firestore writes if no selected runtime can be routed, so the UI
        // never looks like a Wand cast happened while silently using defaults.
        if let policy = wandPolicy {
            guard let routed = policy.routedModelID(for: runtime) else {
                throw DispatchError.wandRoutingUnavailable(
                    "The Wand did not produce a model route for \(runtime.displayName). Refresh the Mac model catalog or switch to Manual."
                )
            }
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

    static func resolvedParallelismLimit(_ requested: Int?, childCount: Int) -> Int {
        let boundedChildCount = max(1, childCount)
        return min(boundedChildCount, max(1, requested ?? boundedChildCount))
    }

    static func resolvedWandPolicy(
        _ policy: WandPolicy?,
        runtimeTokens: [String],
        catalogProvider: any CLIRuntimeCatalogProviding
    ) async throws -> WandPolicy? {
        guard let policy else { return nil }
        let runtimes = runtimeTokens.compactMap(runtimeID(forRequestedRuntime:))
        guard !runtimes.isEmpty else {
            throw DispatchError.wandRoutingUnavailable("No selected runtime can be routed by The Wand.")
        }

        var attemptedRuntimes: Set<AssistantRuntimeID> = []
        let uniqueRuntimes = runtimes.filter { attemptedRuntimes.insert($0).inserted }
        let catalogTasks = uniqueRuntimes.map { runtime in
            Task { @MainActor () -> (AssistantRuntimeID, [CLIRuntimeModelOption]?, String?) in
                do {
                    let response = try await catalogProvider.fetchCLIRuntimeModelCatalog(runtime: runtime)
                    return (runtime, response.options, nil as String?)
                } catch {
                    cliMissionSignalLogger.warning("wand catalog fetch failed runtime=\(runtime.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    return (runtime, nil, wandCatalogFailureSummary(error))
                }
            }
        }
        defer { catalogTasks.forEach { $0.cancel() } }

        var catalogs: [AssistantRuntimeID: [CLIRuntimeModelOption]] = [:]
        var catalogFailures: [AssistantRuntimeID: String] = [:]
        for task in catalogTasks {
            let (runtime, options, failure) = await task.value
            if let options {
                catalogs[runtime] = options
            } else if let failure {
                catalogFailures[runtime] = failure
            }
        }

        let routed = WandModelRouter.policy(
            selector: policy.selector,
            runtimes: runtimes,
            catalogs: catalogs
        )
        let missingRuntimes = Set(runtimes.filter { routed.routedModelID(for: $0) == nil })
            .sorted { $0.rawValue < $1.rawValue }
        guard missingRuntimes.isEmpty else {
            let details = missingRuntimes.map { runtime in
                let reason = catalogFailures[runtime] ?? "no compatible model was advertised"
                return "\(runtime.displayName): \(reason)"
            }.joined(separator: "; ")
            throw DispatchError.wandRoutingUnavailable(
                "The Wand could not load a usable live model for every selected agent. \(details). No agents were dispatched. Keep OpenBurnBar open on the paired Mac, confirm both devices use the same account, then retry or switch to Manual."
            )
        }
        return routed
    }

    private static func wandCatalogFailureSummary(_ error: Error) -> String {
        let flattened = error.localizedDescription
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "the Mac model catalog request failed" }
        guard flattened.count > 240 else { return flattened }
        return String(flattened.prefix(240)) + "..."
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
        case "openclaude", "open-claude":
            return .openClaude
        case "omp", "ohmypi", "oh-my-pi", "oh my pi":
            return .omp
        case "junie", "jetbrains-junie", "jetbrainsjunie", "jetbrains junie":
            return .junie
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
}
