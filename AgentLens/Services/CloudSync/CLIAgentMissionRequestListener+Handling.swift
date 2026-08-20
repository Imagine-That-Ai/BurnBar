import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Mission document handling and group-claim validation.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module.

private struct MissionGroupValidationError: LocalizedError {
    let reason: String

    var errorDescription: String? {
        "Invalid Wand mission group: \(reason)"
    }
}

private enum WandMissionEntitlements {
    static let premiumProductIDs: Set<String> = [
        "com.openburnbar.hostedQuotaSync.cloud.monthly",
        "com.openburnbar.hostedQuotaSync.monthly",
        "com.openburnbar.pro.monthly",
        "com.openburnbar.pro.annual",
        "com.openburnbar.proMax.bundle.monthly",
        "com.openburnbar.proMax.v2.monthly",
        "com.openburnbar.proMax.annual",
        "com.openburnbar.ultra.monthly",
        "com.openburnbar.ultra.annual",
        "com.openburnbar.ultra.annual.v2",
        "com.openburnbar.hostedComputerUseSync.monthly",
        "com.openburnbar.computerUse.monthly"
    ]

    static let hostedComputerUseProductIDs: Set<String> = [
        "com.openburnbar.hostedComputerUseSync.monthly",
        "com.openburnbar.computerUse.monthly"
    ]

    static let proMaxProductIDs: Set<String> = [
        "com.openburnbar.proMax.bundle.monthly",
        "com.openburnbar.proMax.v2.monthly",
        "com.openburnbar.proMax.annual"
    ]

    static let ultraProductIDs: Set<String> = [
        "com.openburnbar.ultra.monthly",
        "com.openburnbar.ultra.annual",
        "com.openburnbar.ultra.annual.v2"
    ]
}

extension CLIAgentMissionRequestListener {
    struct ShadowContextFields {
        let requestedRuntime: String?, requestedModelID: String?, commandsAllowed: Bool?, fileEditsAllowed: Bool?, originDeviceID: String?
        let createdBy: String?, originPlatform: String?, source: String?, personaScopeJSON: String?, approvalMode: String?
        let approvalStatus: String?, approverDeviceID: String?, entitlementTier: String?, workingDirectory: String?
    }

    private func validateMissionGroupClaimIfNeeded(
        data: [String: Any],
        uid: String,
        requestID: String
    ) async throws -> MissionGroupClaimContext? {
        let groupKeys = ["groupID", "siblingIndex", "siblingCount", "isGroupChild"]
        guard groupKeys.contains(where: { data[$0] != nil }) else { return nil }

        guard (data["id"] as? String) == requestID else {
            throw MissionGroupValidationError(reason: "child document id does not match mission id")
        }
        guard data["isGroupChild"] as? Bool == true else {
            throw MissionGroupValidationError(reason: "grouped child missing isGroupChild=true")
        }
        guard let groupID = (data["groupID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !groupID.isEmpty,
              groupID.count <= 512 else {
            throw MissionGroupValidationError(reason: "missing or invalid groupID")
        }
        guard let siblingIndex = integerField(data["siblingIndex"]),
              let siblingCount = integerField(data["siblingCount"]),
              siblingCount > 0,
              siblingCount <= WandFanOut.maxParallel(for: .ultra) else {
            throw MissionGroupValidationError(reason: "invalid sibling metadata")
        }

        let groupRef = Firestore.firestore()
            .collection("users").document(uid)
            .collection("mission_groups").document(groupID)
        let snapshot = try await groupRef.getDocument()
        guard let group = snapshot.data() else {
            throw MissionGroupValidationError(reason: "parent group is missing")
        }
        guard (group["id"] as? String) == groupID else {
            throw MissionGroupValidationError(reason: "parent group id mismatch")
        }
        let tierCap = try await resolvedWandFanOutCap(uid: uid)
        guard let childMissionIDs = group["childMissionIDs"] as? [String],
              !childMissionIDs.isEmpty,
              childMissionIDs.count <= tierCap else {
            throw MissionGroupValidationError(reason: "parent child list is invalid")
        }
        guard childMissionIDs.contains(requestID) else {
            throw MissionGroupValidationError(reason: "child is not declared by parent group")
        }
        guard siblingCount == childMissionIDs.count,
              siblingIndex >= 0,
              siblingIndex < childMissionIDs.count else {
            throw MissionGroupValidationError(reason: "child sibling metadata does not match parent")
        }
        guard let runtimeTokens = group["runtimeTokens"] as? [String],
              runtimeTokens.count == childMissionIDs.count else {
            throw MissionGroupValidationError(reason: "parent runtime list is invalid")
        }
        let parallelismLimit = integerField(group["parallelismLimit"]) ?? childMissionIDs.count
        guard parallelismLimit >= 1,
              parallelismLimit <= childMissionIDs.count,
              parallelismLimit <= tierCap else {
            throw MissionGroupValidationError(reason: "parent parallelism limit is invalid")
        }
        return MissionGroupClaimContext(
            groupID: groupID,
            siblingIndex: siblingIndex,
            siblingCount: siblingCount,
            parallelismLimit: parallelismLimit,
            tierCap: tierCap
        )
    }

    // Internal (not private): the M4 authorization gate in
    // MissionRemoteAuthorizationEnforcement.swift calls this.
    func resolvedWandFanOutCap(uid: String) async throws -> Int {
        let entitlements = Firestore.firestore()
            .collection("users").document(uid)
            .collection("entitlements")

        let ultra = try await entitlements.document("burnbar_ultra").getDocument()
        if activeEntitlement(ultra, productIDs: WandMissionEntitlements.ultraProductIDs) {
            return WandFanOut.maxParallel(for: .ultra)
        }

        let proMax = try await entitlements.document("burnbar_pro_max").getDocument()
        if activeEntitlement(proMax, productIDs: WandMissionEntitlements.proMaxProductIDs) {
            return WandFanOut.maxParallel(for: .pro)
        }

        let hostedComputerUse = try await entitlements.document("hosted_computer_use_sync").getDocument()
        if activeEntitlement(hostedComputerUse, productIDs: WandMissionEntitlements.hostedComputerUseProductIDs) {
            return WandFanOut.maxParallel(for: .pro)
        }

        async let hostedQuota = entitlements.document("hosted_quota_sync").getDocument()
        async let burnBarPro = entitlements.document("burnbar_pro").getDocument()
        let cloudCandidates = try await [hostedQuota, burnBarPro, proMax]
        if cloudCandidates.contains(where: { activeEntitlement($0, productIDs: WandMissionEntitlements.premiumProductIDs) }) {
            return WandFanOut.maxParallel(for: .cloud)
        }

        return WandFanOut.maxParallel(for: .none)
    }

    private func activeEntitlement(_ snapshot: DocumentSnapshot, productIDs: Set<String>) -> Bool {
        guard snapshot.exists,
              let data = snapshot.data(),
              data["active"] as? Bool == true,
              let productID = data["productID"] as? String,
              productIDs.contains(productID) else {
            return false
        }
        let expireAt = entitlementTimestamp(data["expireAt"])
            ?? entitlementTimestamp(data["expiresAt"])
            ?? entitlementTimestamp(data["expirationDate"])
        return expireAt.map { $0 > Date() } ?? true
    }

    private func entitlementTimestamp(_ value: Any?) -> Date? {
        switch value {
        case let timestamp as Timestamp:
            return timestamp.dateValue()
        case let date as Date:
            return date
        case let seconds as TimeInterval:
            return Date(timeIntervalSince1970: seconds)
        case let int as Int:
            return Date(timeIntervalSince1970: TimeInterval(int))
        case let string as String:
            return ISO8601DateFormatter().date(from: string)
        default:
            return nil
        }
    }

    private func integerField(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }
    /// Builds the typed authorization input from the listener's post-decryption data.
    /// Kept as a pure helper so the security-sensitive field mapping is
    /// directly testable without requiring a live Firestore listener.
    nonisolated static func makeShadowContext(
        fields: ShadowContextFields,
        missionID: String,
        prompt: String,
        fanOutCount: Int
        ) -> MissionRemoteAuthorizationShadow.ShadowContext {
        MissionRemoteAuthorizationShadow.ShadowContext(
            missionID: missionID, prompt: prompt,
            runtime: fields.requestedRuntime ?? "auto", modelID: fields.requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
            commandsAllowed: fields.commandsAllowed ?? false, fileEditsAllowed: fields.fileEditsAllowed ?? false,
            originDeviceID: fields.originDeviceID?.nilIfBlank ?? fields.createdBy?.nilIfBlank ?? "unknown",
            originPlatform: fields.originPlatform?.nilIfBlank ?? fields.source?.nilIfBlank ?? "unknown",
            personaScopeJSON: fields.personaScopeJSON?.nilIfBlank, approvalMode: fields.approvalMode?.nilIfBlank,
            approvalStatus: fields.approvalStatus ?? "", approverDeviceID: fields.approverDeviceID?.nilIfBlank,
            entitlementTier: fields.entitlementTier?.nilIfBlank ?? "none", workingDirectory: fields.workingDirectory?.nilIfBlank,
            fanOutCount: fanOutCount
        )
    }
    func handle(document: QueryDocumentSnapshot) async {
        let rawData = document.data()
        if let ignored = MissionClaimGate.ignoreReason(rawData, localBodyID: localBodyIDProvider()) {
            logger.debug("mission id=\(document.documentID, privacy: .public) \(ignored, privacy: .public)")
            return
        }
        let cancellationTracker = MissionCancellationTracker()
        let logger = self.logger
        let docID = document.documentID
        let cancellationListener = document.reference.addSnapshotListener { snapshot, _ in
            guard let snapshot, snapshot.exists else { return }
            let status = snapshot.data()?["status"] as? String
            if status == "cancelled" || status == "canceled" {
                logger.warning("cancellation signal received for mission id=\(docID, privacy: .public)")
                cancellationTracker.cancel()
            }
        }
        defer { cancellationListener.remove() }

        guard let uid = accountManager.currentUID else {
            logger.warning("mission id=\(document.documentID, privacy: .public) ignored because this Mac is not signed in")
            return
        }
        let privatePayload: CLIAgentMissionPrivatePayload?
        do {
            privatePayload = try await openMissionPrivatePayload(
                data: rawData,
                uid: uid,
                requestID: document.documentID
            )
        } catch {
            logger.error("mission id=\(document.documentID, privacy: .public) cannot be opened with this Mac vault key: \(error.localizedDescription, privacy: .public)")
            return
        }
        var data = mergePrivateMissionPayload(privatePayload, into: rawData)
        var missionGroupContext: MissionGroupClaimContext?
        do {
            missionGroupContext = try await validateMissionGroupClaimIfNeeded(
                data: data, uid: uid, requestID: document.documentID)
        } catch {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused before claim: \(error.localizedDescription, privacy: .public)")
            // cov:ignore-start -- live Firestore mission-listener denial telemetry; reducer behavior is unit-tested.
            MissionRemoteAuthorizationShadow.observeDeny(
                ctx: .fromMissionData(data, missionID: document.documentID, prompt: "", fanOutCount: 1),
                executorTrustState: "trusted")
            // cov:ignore-end
            data["_preClaimFailure"] = error.localizedDescription
        }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Insights mission"
        let prompt = (data["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prompt.isEmpty {
            data["_preClaimFailure"] = "Mission prompt was empty."
        }

        var requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        var requestedModelID = (data["requestedModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let missionKind = (data["missionKind"] as? String) ?? "unknown"
        missionEventSequences[document.documentID] = max(
            data["lastEventSequence"] as? Int ?? 1,
            ((data["events"] as? [Any])?.count ?? 1)
        )

        let trustResult = await deviceTrustChecker.prepareAndValidateTrustedExecutor(
            uid: uid,
            deviceID: accountManager.deviceId
        )
        let executorTrustState = trustResult.rawTrustState

        var backend = resolveBackend(
            requestedRuntime: requestedRuntime,
            missionKind: data["missionKind"] as? String
        )
        let wandRoutingSelection: CLIAgentMissionWandRoutingSelection?
        do {
            wandRoutingSelection = try await Self.resolveWandRoutingIfNeeded(
                context: missionGroupContext,
                data: data
            )
            if let wandRoutingSelection {
                requestedRuntime = wandRoutingSelection.requestedRuntime
                requestedModelID = wandRoutingSelection.modelID
                data["requestedRuntime"] = requestedRuntime
                data["requestedModelID"] = requestedModelID
                backend = resolveBackend(
                    requestedRuntime: requestedRuntime,
                    missionKind: data["missionKind"] as? String
                )
                logger.info("wand routing selected mission id=\(document.documentID, privacy: .public) model=\(wandRoutingSelection.modelID, privacy: .public) provider=\(wandRoutingSelection.provider ?? "unknown", privacy: .public) source=\(wandRoutingSelection.source ?? "unknown", privacy: .public)")
            }
        } catch {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused before claim: \(error.localizedDescription, privacy: .public)")
            return
        }

        let claimDecision = CLIAgentMissionClaimDecision.make(
            thisDeviceId: accountManager.deviceId,
            claimedBy: data["claimedBy"] as? String,
            status: data["status"] as? String,
            hasLocalHandle: claimedMissions[document.documentID] != nil,
            inFlight: inFlightExecutions.contains(document.documentID)
        )
        switch claimDecision {
        case .skip:
            logger.info("mission id=\(document.documentID, privacy: .public) skip duplicate in-flight handle")
            return
        case .continueWithoutClaim:
            logger.info("mission id=\(document.documentID, privacy: .public) continue-after-approve without a second claim")
        case .claim:
            logger.info("claiming mission id=\(document.documentID, privacy: .public) kind=\(missionKind, privacy: .public) requested=\(requestedRuntime, privacy: .public) selected=\(backend.rawValue, privacy: .public) model=\(requestedModelID ?? "auto", privacy: .public)")
            do {
                let baseClaimSummary = requestedModelID.map { "\(backend.displayName) claimed the mission on this Mac with model \($0)." }
                    ?? "\(backend.displayName) claimed the mission on this Mac."
                let claimSummary = wandRoutingSelection.map {
                    "\(baseClaimSummary) \($0.claimSummaryFragment)"
                } ?? baseClaimSummary
                let sealed = try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [:],
                    liveSummary: claimSummary
                )
                guard let sealedState = sealed["sealedStatePayload"] as? [String: Any] else {
                    logger.error("mission claim missing sealed state id=\(document.documentID, privacy: .public)")
                    return
                }
                let hostWriteNonce = try await ComputerUseSecurityCallableClient.claimCliAgentMission(
                    requestId: document.documentID,
                    deviceId: accountManager.deviceId,
                    nextStatus: "accepted",
                    selectedRuntime: backend.rawValue,
                    selectedRuntimeName: backend.displayName,
                    selectedModelID: requestedModelID,
                    approvalRequestId: nil,
                    sealedStatePayload: sealedState
                )
                claimedMissions[document.documentID] = .init(hostWriteNonce: hostWriteNonce, deviceId: accountManager.deviceId)
                if missionEventSequences[document.documentID] == nil {
                    missionEventSequences[document.documentID] = 1
                }
                logger.info("claimed mission id=\(document.documentID, privacy: .public)")
            } catch {
                logger.error("mission claim failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        inFlightExecutions.insert(document.documentID)
        defer { inFlightExecutions.remove(document.documentID) }

        if let preClaimFailure = data["_preClaimFailure"] as? String {
            await fail(document: document, message: preClaimFailure)
            return
        }
        guard !prompt.isEmpty else {
            await fail(document: document, message: "Mission prompt was empty.")
            return
        }

        // The daemon is the sole mission authority (M4). Exclusive claim happens
        // first so a losing Mac never evaluates.
        switch await resolveRemoteMissionAuthorization(
            document: document, data: data, backend: backend, uid: uid, prompt: prompt,
            executorTrustState: executorTrustState, missionGroupContext: missionGroupContext
        ) {
        case .stop:
            return
        case let .proceed(grantCeiling):
            data["commandsAllowed"] = grantCeiling.commandsAllowed
            data["fileEditsAllowed"] = grantCeiling.fileEditsAllowed
        }

        // Execution-side local-privacy gate (NOT remote authorization): this Mac
        // spawns a CLI assistant only when the operator enabled Mac CLI assistants.
        if CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(backend: backend),
           !settingsManager.cliAssistantAllowed {
            await failAfterTrustedClaim(
                document: document,
                backend: backend,
                message: "Mac CLI assistants are off. Enable Mac CLI assistants in Settings -> Privacy & Indexing before this Mac can run remote agent missions."
            )
            return
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        if chatController.isStreaming {
            logger.warning("mission id=\(document.documentID, privacy: .public) blocked because chat controller is already streaming")
            await fail(document: document, message: "Mac chat controller is already running another mission.")
            return
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        logger.info("starting mission id=\(document.documentID, privacy: .public) backend=\(backend.rawValue, privacy: .public)")
        do {
            let summary = requestedModelID.map { "Starting \(backend.displayName) with model \($0)." }
                ?? "Starting \(backend.displayName) with the mission prompt."
            guard let handle = claimedMissions[document.documentID] else { return }
            let sealed = try await sealedStateUpdate(
                uid: uid,
                requestID: document.documentID,
                payload: [:],
                liveSummary: summary
            )
            if let sealedState = sealed["sealedStatePayload"] as? [String: Any] {
                try await ComputerUseSecurityCallableClient.updateCliAgentMissionStatus(
                    requestId: document.documentID,
                    deviceId: handle.deviceId,
                    status: "starting",
                    hostWriteNonce: handle.hostWriteNonce,
                    sealedStatePayload: sealedState
                )
            }
        } catch {
            logger.error("mission starting update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await recordEvent(
            reference: document.reference,
            requestID: document.documentID,
            phase: "starting",
            kind: "status",
            title: "Starting",
            message: requestedModelID.map { "Starting \(backend.displayName) with model \($0)." }
                ?? "Starting \(backend.displayName) with the mission prompt.",
            backend: backend
        )

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        let missionWorkingDirectoryURL = workingDirectoryURL(from: data)
        let changedFilesBefore = await gitChangedFiles(in: missionWorkingDirectoryURL)
        do {
            let summary = requestedModelID.map { "\(backend.displayName) is running \($0) on this Mac." }
                ?? "\(backend.displayName) is running on this Mac."
            await applyHostStatus(
                document: document,
                status: "running",
                liveSummary: summary
            )
        } catch {
            logger.error("mission running update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        if let directResult = await runDirectCLIMissionIfNeeded(title: title, prompt: prompt, backend: backend, data: data, reference: document.reference, requestID: document.documentID, cancellationTracker: cancellationTracker) {
            if cancellationTracker.isCancelled {
                await handleCancellation(document: document, backend: backend)
                return
            }
            await recordChangedFileEvents(
                before: changedFilesBefore,
                after: await gitChangedFiles(in: missionWorkingDirectoryURL),
                reference: document.reference,
                requestID: document.documentID,
                backend: backend
            )
            let safeDirectOutput = CLIAgentMissionEventFactory.mobileSafeText(directResult.output)
            let directFailure = directResult.errorMessage.map {
                modelAwareFailureMessage(
                    backend: backend,
                    requestedModelID: requestedModelID,
                    errorMessage: $0
                )
            }
            var payload: [String: Any] = [
                "status": directResult.status == "failed" ? "agent_launch_failed" : directResult.status,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "sessionId": directResult.sessionID,
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let requestedModelID {
                payload["selectedModelID"] = requestedModelID
            }
            let liveSummary = directResult.status == "completed"
                ? modelAwareSuccessMessage(backend: backend, requestedModelID: requestedModelID, fallback: safeDirectOutput)
                : directFailure ?? modelAwareFailureMessage(backend: backend, requestedModelID: requestedModelID, errorMessage: nil)
            var sealedErrorMessage: String?
            if let errorMessage = directResult.errorMessage {
                sealedErrorMessage = CLIAgentMissionEventFactory.mobileSafeText(
                    modelAwareFailureMessage(
                        backend: backend,
                        requestedModelID: requestedModelID,
                        errorMessage: errorMessage
                    )
                )
            }
            await applyHostStatus(
                document: document,
                status: directResult.status == "failed" ? "failed" : directResult.status,
                liveSummary: liveSummary,
                errorMessage: sealedErrorMessage,
                resultPreview: safeDirectOutput
            )
            logger.info("finished direct CLI mission id=\(document.documentID, privacy: .public) status=\(directResult.status, privacy: .public)")
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: directResult.status == "completed" ? "completed" : "agent_launch_failed",
                kind: directResult.status == "completed" ? "final_answer" : "error",
                title: directResult.status == "completed" ? "Completed" : "Agent launch failed",
                message: directResult.status == "completed"
                    ? resultSummary(from: directResult.output)
                    : (directFailure ?? modelAwareFailureMessage(backend: backend, requestedModelID: requestedModelID, errorMessage: nil)),
                backend: backend,
                isError: directResult.status != "completed"
            )
            return
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        guard let chatBackend = backend.chatBackend else {
            await fail(document: document, message: "\(backend.displayName) is not available through the interactive Mac chat controller.")
            return
        }
        guard !chatController.isSendBusy else {
            await fail(
                document: document,
                message: modelAwareFailureMessage(
                    backend: backend,
                    requestedModelID: requestedModelID,
                    errorMessage: "A Mac CLI agent is already responding. Wait for the current reply to finish, then send again."
                )
            )
            return
        }

        chatController.setChatBackend(chatBackend)
        if let requestedModelID {
            chatController.setChatModelSelection(requestedModelID, for: chatBackend)
        }
        if let clientThreadID = CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: data) {
            chatController.openOrCreateChatThread(id: clientThreadID)
        } else {
            chatController.startNewChatThread()
        }
        let threadID = chatController.activeThreadID
        chatController.inputText = missionPrompt(title: title, prompt: prompt, backend: backend, data: data)

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        await chatController.send()

        var lastStreamingEvent = Date.distantPast
        var mirroredTranscriptPieceIDs = Set<String>()
        while chatController.isStreaming {
            if cancellationTracker.isCancelled {
                logger.warning("cancelling active streaming chat generation for mission id=\(document.documentID, privacy: .public)")
                chatController.cancelGeneration()
                break
            }
            let assistantMessage = chatController.messages.last(where: { $0.role == .assistant })
            await mirrorTranscriptPieces(
                assistantMessage?.displayTranscript ?? [],
                mirroredPieceIDs: &mirroredTranscriptPieceIDs,
                reference: document.reference,
                requestID: document.documentID,
                backend: backend
            )
            if Date().timeIntervalSince(lastStreamingEvent) >= 2 {
                lastStreamingEvent = Date()
                let streamingMessage = Self.deriveStreamingStatusMessage(
                    assistantMessage: assistantMessage,
                    backend: backend
                )
                await recordEvent(
                    reference: document.reference,
                    requestID: document.documentID,
                    phase: "streaming",
                    kind: "status",
                    title: "Streaming",
                    message: streamingMessage,
                    backend: backend
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // try?-ok(cancellation only)
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        await mirrorTranscriptPieces(
            chatController.messages.last(where: { $0.role == .assistant })?.displayTranscript ?? [],
            mirroredPieceIDs: &mirroredTranscriptPieceIDs,
            reference: document.reference,
            requestID: document.documentID,
            backend: backend
        )

        let status = chatController.streamError == nil ? "completed" : "failed"
        let finalSummary = chatController.messages.last(where: { $0.role == .assistant })?.content ?? ""
        let safeFinalSummary = CLIAgentMissionEventFactory.mobileSafeText(finalSummary)
        let liveSummary = status == "completed"
            ? modelAwareSuccessMessage(backend: backend, requestedModelID: requestedModelID, fallback: safeFinalSummary)
            : modelAwareFailureMessage(backend: backend, requestedModelID: requestedModelID, errorMessage: chatController.streamError)
        var payload: [String: Any] = [
            "status": status,
            "selectedRuntime": backend.rawValue,
            "selectedRuntimeName": backend.displayName,
            "sessionId": threadID,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let requestedModelID {
            payload["selectedModelID"] = requestedModelID
        }
        var sealedErrorMessage: String?
        var sealedResultPreview: String?
        if let streamError = chatController.streamError {
            sealedErrorMessage = CLIAgentMissionEventFactory.mobileSafeText(
                modelAwareFailureMessage(
                    backend: backend,
                    requestedModelID: requestedModelID,
                    errorMessage: streamError
                )
            )
        } else {
            sealedResultPreview = safeFinalSummary
        }
        await applyHostStatus(
            document: document,
            status: status,
            liveSummary: liveSummary,
            errorMessage: sealedErrorMessage,
            resultPreview: sealedResultPreview
        )
        logger.info("finished mission id=\(document.documentID, privacy: .public) status=\(status, privacy: .public)")

        await recordChangedFileEvents(
            before: changedFilesBefore,
            after: await gitChangedFiles(in: missionWorkingDirectoryURL),
            reference: document.reference,
            requestID: document.documentID,
            backend: backend
        )
        await recordEvent(
            reference: document.reference,
            requestID: document.documentID,
            phase: status == "completed" ? "completed" : "failed",
            kind: status == "completed" ? "final_answer" : "error",
            title: status == "completed" ? "Completed" : "Failed",
            message: status == "completed"
                ? resultSummary(from: finalSummary)
                : modelAwareFailureMessage(backend: backend, requestedModelID: requestedModelID, errorMessage: chatController.streamError),
            backend: backend,
            isError: status != "completed"
        )
    }

    /// `nonisolated` so the blocking `git status` runs off the main actor
    /// (SE-0338); it touches no main-actor state, so it needs no detached task.
    private nonisolated func gitChangedFiles(in workingDirectoryURL: URL?) async -> Set<String> {
        let directoryURL = workingDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let gitPath = "/usr/bin/git"
        guard FileManager.default.fileExists(atPath: gitPath) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directoryURL.path, "status", "--porcelain=v1"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return Set<String>() }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return Set(text
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard line.count >= 4 else { return nil }
                    return String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                })
        } catch {
            return []
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum CLIAgentMissionClaimDecision: Equatable {
    case claim
    case continueWithoutClaim
    case skip

    static func make(
        thisDeviceId: String,
        claimedBy: String?,
        status: String?,
        hasLocalHandle: Bool,
        inFlight: Bool
    ) -> CLIAgentMissionClaimDecision {
        if inFlight { return .skip }
        let status = (status ?? "").lowercased()
        let live = ["waiting_for_approval", "accepted", "starting", "running"].contains(status)
        if claimedBy == thisDeviceId, live {
            return hasLocalHandle ? .continueWithoutClaim : .skip
        }
        return .claim
    }
}

enum CLIAgentMissionClaimThenEvaluate {
    enum Failure: Error { case failedPrecondition }

    static func run(
        decision: CLIAgentMissionClaimDecision,
        claim: () async throws -> String,
        evaluate: () async throws -> Void,
        fail: () async throws -> Void
    ) async throws {
        switch decision {
        case .skip:
            return
        case .continueWithoutClaim:
            break
        case .claim:
            do {
                _ = try await claim()
            } catch Failure.failedPrecondition {
                return
            }
        }
        do {
            try await evaluate()
        } catch {
            try await fail()
            throw error
        }
    }
}
