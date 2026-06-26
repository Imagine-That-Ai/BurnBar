import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

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

@MainActor
final class CLIAgentMissionRequestListener {

    let accountManager: AccountManaging
    let settingsManager: SettingsManager
    let chatController: ChatSessionController
    let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    var listener: ListenerRegistration?
    var listenerUID: String?
    var attachTask: Task<Void, Never>?
    var processingDocs = Set<String>()
    var lastAttachState: String?
    var missionEventSequences: [String: Int] = [:]

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        chatController: ChatSessionController,
        deviceTrustChecker: CLIAgentMissionDeviceTrustChecking = LiveCLIAgentMissionDeviceTrustChecker()
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.chatController = chatController
        self.deviceTrustChecker = deviceTrustChecker
    }

    func start() {
        logger.info("mission listener start requested")
        if attachTask == nil {
            attachTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // try?-ok(cancellation only)
                }
            }
        }
        attachIfPossible()
    }

    func stop() {
        logger.info("mission listener stopped")
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingDocs.removeAll()
        missionEventSequences.removeAll()
    }

    func attachIfPossible() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            let state = "waiting firebase=\(accountManager.isFirebaseAvailable) uid=\(accountManager.currentUID == nil ? "nil" : "present")"
            if lastAttachState != state {
                logger.warning("mission listener \(state, privacy: .public)")
                lastAttachState = state
            }
            listener?.remove()
            listener = nil
            listenerUID = nil
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        lastAttachState = "attached"
        logger.info("mission listener attaching uidSuffix=\(uid.suffix(6), privacy: .public) device=\(self.accountManager.deviceId, privacy: .public)")
        listener = Firestore.firestore().collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .whereField("status", in: ["pending", "waiting_for_approval"])
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.logger.error("mission listener snapshot failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.logger.info("mission listener received \(docs.count, privacy: .public) pending docs")
                    self?.processDocs(docs)
                }
            }
    }

    func processDocs(_ docs: [QueryDocumentSnapshot]) {
        for doc in docs where !processingDocs.contains(doc.documentID) {
            processingDocs.insert(doc.documentID)
            Task { @MainActor in
                defer { processingDocs.remove(doc.documentID) }
                await handle(document: doc)
            }
        }
    }

    func missionVaultKey(uid: String) async throws -> CloudVaultResolvedKey {
        try await MacCloudVaultKeyAccess.keyForWriting(
            uid: uid,
            deviceId: accountManager.deviceId,
            firestore: Firestore.firestore()
        )
    }

    func openMissionPrivatePayload(
        data: [String: Any],
        uid: String,
        requestID: String
    ) async throws -> CLIAgentMissionPrivatePayload? {
        guard data["sealedPayload"] != nil else { return nil }
        guard let key = try await MacCloudVaultKeyAccess.keyForReading(
            uid: uid,
            deviceId: accountManager.deviceId,
            firestore: Firestore.firestore()
        ) else {
            throw CloudVaultAccessError.vaultKeyUnavailable
        }
        guard let privatePayload = CLIAgentMissionCloudSealer.openPrivatePayload(
            data,
            uid: uid,
            requestID: requestID,
            vaultKey: key.keyData
        ) else {
            throw CloudVaultAccessError.vaultKeyMismatch(expected: (data["vaultKeyID"] as? String) ?? "unknown", actual: key.vaultKeyID)
        }
        return privatePayload
    }

    func mergePrivateMissionPayload(_ privatePayload: CLIAgentMissionPrivatePayload?, into data: [String: Any]) -> [String: Any] {
        guard let privatePayload else { return data }
        var merged = data
        if let title = privatePayload.title { merged["title"] = title }
        if let prompt = privatePayload.prompt { merged["prompt"] = prompt }
        if let targetProject = privatePayload.targetProject { merged["targetProject"] = targetProject }
        if let liveSummary = privatePayload.liveSummary { merged["liveSummary"] = liveSummary }
        if let resultPreview = privatePayload.resultPreview { merged["resultPreview"] = resultPreview }
        if let errorMessage = privatePayload.errorMessage { merged["errorMessage"] = errorMessage }
        if let approvalTitle = privatePayload.approvalTitle { merged["approvalTitle"] = approvalTitle }
        if let approvalMessage = privatePayload.approvalMessage { merged["approvalMessage"] = approvalMessage }
        if let personaScopeJSON = privatePayload.personaScopeJSON { merged["personaScopeJSON"] = personaScopeJSON }
        if let synthesisSummary = privatePayload.synthesisSummary { merged["synthesisSummary"] = synthesisSummary }
        return merged
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

    private func resolvedWandFanOutCap(uid: String) async throws -> Int {
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

    func sealedStateUpdate(
        uid: String,
        requestID: String,
        payload: [String: Any],
        liveSummary: String? = nil,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        approvalTitle: String? = nil,
        approvalMessage: String? = nil,
        synthesisSummary: String? = nil
    ) async throws -> [String: Any] {
        var payload = payload
        for key in ["liveSummary", "resultPreview", "errorMessage", "approvalTitle", "approvalMessage", "synthesisSummary"] {
            payload[key] = FieldValue.delete()
        }
        let privatePayload = CLIAgentMissionPrivatePayload(
            title: nil,
            prompt: nil,
            targetProject: nil,
            liveSummary: liveSummary,
            resultPreview: resultPreview,
            errorMessage: errorMessage,
            approvalTitle: approvalTitle,
            approvalMessage: approvalMessage,
            personaScopeJSON: nil,
            synthesisSummary: synthesisSummary
        )
        let key = try await missionVaultKey(uid: uid)
        let aadContext = try CLIAgentMissionCloudSealer.missionAADContext(
            uid: uid,
            requestID: requestID,
            field: "sealedStatePayload"
        )
        payload["sealedStatePayload"] = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: key.keyData,
            vaultKeyID: key.vaultKeyID,
            aadContext: aadContext
        )
        payload["sealedStateSchemaVersion"] = CLIAgentMissionCloudSealer.sealedStateSchemaVersion
        payload["sealedStateVaultKeyID"] = key.vaultKeyID
        return payload
    }

    func handle(document: QueryDocumentSnapshot) async {
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

        let rawData = document.data()
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
            do {
                try await document.reference.setData([
                    "status": "vault_key_unavailable",
                    "claimedBy": accountManager.deviceId,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } catch {
                logger.warning("mission id=\(document.documentID, privacy: .public) failed to mark vault key unavailable: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        var data = mergePrivateMissionPayload(privatePayload, into: rawData)
        let missionGroupContext: MissionGroupClaimContext?
        do {
            missionGroupContext = try await validateMissionGroupClaimIfNeeded(
                data: data,
                uid: uid,
                requestID: document.documentID
            )
        } catch {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused before claim: \(error.localizedDescription, privacy: .public)")
            await fail(document: document, message: error.localizedDescription)
            return
        }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Insights mission"
        guard let prompt = (data["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            await fail(document: document, message: "Mission prompt was empty.")
            return
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
        guard trustResult.isTrusted else {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused for untrusted Mac device=\(self.accountManager.deviceId, privacy: .public)")
            return
        }

        var backend = resolveBackend(
            requestedRuntime: requestedRuntime,
            missionKind: data["missionKind"] as? String
        )
        let wandRoutingSelection: CLIAgentMissionWandRoutingSelection?
        do {
            wandRoutingSelection = try await resolveWandRoutingIfNeeded(
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
            await fail(document: document, message: error.localizedDescription)
            return
        }
        if await shouldPauseForApproval(document: document, data: data, backend: backend) {
            return
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        logger.info("claiming mission id=\(document.documentID, privacy: .public) kind=\(missionKind, privacy: .public) requested=\(requestedRuntime, privacy: .public) selected=\(backend.rawValue, privacy: .public) model=\(requestedModelID ?? "auto", privacy: .public)")
        do {
            let baseClaimSummary = requestedModelID.map { "\(backend.displayName) claimed the mission on this Mac with model \($0)." }
                ?? "\(backend.displayName) claimed the mission on this Mac."
            let claimSummary = wandRoutingSelection.map {
                "\(baseClaimSummary) \($0.claimSummaryFragment)"
            } ?? baseClaimSummary
            var claimPayload: [String: Any] = [
                "status": "accepted",
                "claimedBy": accountManager.deviceId,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "lastEventSequence": FieldValue.increment(Int64(1)),
                "startedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let requestedModelID {
                claimPayload["selectedModelID"] = requestedModelID
            }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: claimPayload,
                    liveSummary: claimSummary
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "accepted",
                kind: "status",
                title: "Accepted",
                message: claimSummary,
                backend: backend
            )
            logger.info("claimed mission id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission claim failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await fail(document: document, message: "Mac could not claim the mission: \(error.localizedDescription)")
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
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "starting",
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: summary
                ),
                merge: true
            )
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
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "running",
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: summary
                ),
                merge: true
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
            do {
                try await document.reference.setData(
                    try await sealedStateUpdate(
                        uid: uid,
                        requestID: document.documentID,
                        payload: payload,
                        liveSummary: liveSummary,
                        resultPreview: safeDirectOutput,
                        errorMessage: sealedErrorMessage
                    ),
                    merge: true
                )
                logger.info("finished direct CLI mission id=\(document.documentID, privacy: .public) status=\(directResult.status, privacy: .public)")
            } catch {
                logger.error("direct CLI mission update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
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
        do {
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: payload,
                    liveSummary: liveSummary,
                    resultPreview: sealedResultPreview,
                    errorMessage: sealedErrorMessage
                ),
                merge: true
            )
            logger.info("finished mission id=\(document.documentID, privacy: .public) status=\(status, privacy: .public)")
        } catch {
            logger.error("mission final update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

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

    func handleCancellation(document: QueryDocumentSnapshot, backend: CLIAgentMissionBackend) async {
        logger.warning("handling cancellation for mission id=\(document.documentID, privacy: .public)")
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "cancelled",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: "Mission cancelled by user."
                ),
                merge: true
            )
        } catch {
            logger.error("failed to update cancellation status in firestore: \(error.localizedDescription, privacy: .public)")
        }
        await recordEvent(
            reference: document.reference,
            requestID: document.documentID,
            phase: "cancelled",
            kind: "status",
            title: "Cancelled",
            message: "Mission cancelled by user.",
            backend: backend,
            isError: true
        )
    }

    func modelAwareSuccessMessage(
        backend: CLIAgentMissionBackend,
        requestedModelID: String?,
        fallback: String
    ) -> String {
        let preview = fallback.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let preview {
            return "\(backend.displayName): \(preview.prefix(180).description)"
        }
        if let requestedModelID {
            return "\(backend.displayName) returned a result from model \(requestedModelID)."
        }
        return "\(backend.displayName) returned a result."
    }

    func modelAwareFailureMessage(
        backend: CLIAgentMissionBackend,
        requestedModelID: String?,
        errorMessage: String?
    ) -> String {
        let safeError = errorMessage
            .flatMap { CLIAgentMissionEventFactory.mobileSafeText($0, limit: 1800).nilIfEmpty }
        let prefix = requestedModelID.map {
            "\(backend.displayName) failed while running selected model \($0)."
        } ?? "\(backend.displayName) mission failed."
        guard let safeError else { return prefix }
        return "\(prefix) \(safeError)"
    }

    func fail(document: QueryDocumentSnapshot, message: String) async {
        let safeMessage = CLIAgentMissionEventFactory.mobileSafeText(message, limit: 2048)
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "failed",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: safeMessage,
                    errorMessage: safeMessage
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "failed",
                kind: "error",
                title: "Failed",
                message: safeMessage,
                backend: nil,
                isError: true
            )
            logger.info("marked mission failed id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission failure update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func shouldPauseForApproval(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend
    ) async -> Bool {
        let approvalStatus = ((data["approvalStatus"] as? String) ?? "none").lowercased()
        let status = ((data["status"] as? String) ?? "pending").lowercased()
        if approvalStatus == "rejected" || approvalStatus == "canceled" || approvalStatus == "cancelled" {
            await cancelAfterApprovalDecision(document: document, approvalStatus: approvalStatus)
            return true
        }
        if CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(backend: backend),
           !settingsManager.cliAssistantAllowed {
            await failAfterTrustedClaim(
                document: document,
                backend: backend,
                message: "Mac CLI assistants are off. Enable Mac CLI assistants in Settings -> Privacy & Indexing before this Mac can run remote agent missions."
            )
            return true
        }
        if approvalStatus == "approved" {
            return false
        }
        guard missionRequiresApproval(data: data, backend: backend) else {
            return false
        }
        if status == "waiting_for_approval" {
            return true
        }
        await requestApproval(document: document, data: data, backend: backend)
        return true
    }

    func missionRequiresApproval(data: [String: Any], backend: CLIAgentMissionBackend) -> Bool {
        CLIAgentMissionRuntimePlanner.requiresPreDispatchApproval(data: data, backend: backend)
    }

    func failAfterTrustedClaim(document: QueryDocumentSnapshot, backend: CLIAgentMissionBackend, message: String) async {
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "failed",
                        "claimedBy": accountManager.deviceId,
                        "selectedRuntime": backend.rawValue,
                        "selectedRuntimeName": backend.displayName,
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    errorMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "failed",
                kind: "error",
                title: "Failed",
                message: message,
                backend: backend,
                isError: true
            )
            logger.info("marked trusted mission failed id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("trusted mission failure update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestApproval(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend
    ) async {
        let approvalID = (data["approvalRequestId"] as? String)?.nilIfEmpty ?? "approval-\(UUID().uuidString)"
        let title = (data["title"] as? String)?.nilIfEmpty ?? "Mobile mission"
        let approvalMode = (data["approvalMode"] as? String)?.nilIfEmpty ?? "existing_policy"
        let commandsAllowed = ((data["commandsAllowed"] as? Bool) ?? false) ? "commands" : nil
        let fileEditsAllowed = ((data["fileEditsAllowed"] as? Bool) ?? false) ? "file edits" : nil
        let riskyScope = [commandsAllowed, fileEditsAllowed].compactMap { $0 }.joined(separator: " and ")
        let scope = riskyScope.nilIfEmpty ?? "mission execution"
        let message = "\(backend.displayName) is waiting for approval before \(scope). Approval mode: \(approvalMode)."
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "waiting_for_approval",
                        "claimedBy": accountManager.deviceId,
                        "approvalRequestId": approvalID,
                        "approvalStatus": "pending",
                        "approvalRequestedAt": ISO8601DateFormatter().string(from: Date()),
                        "selectedRuntime": backend.rawValue,
                        "selectedRuntimeName": backend.displayName,
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    approvalTitle: "Approve \(title)",
                    approvalMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "accepted",
                kind: "status",
                title: "Accepted",
                message: "\(backend.displayName) accepted the mission on this Mac and is waiting for approval.",
                backend: backend
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "approval_requested",
                kind: "approval_request",
                title: "Approval required",
                message: message,
                backend: backend
            )
            logger.info("mission id=\(document.documentID, privacy: .public) waiting for mobile approval")
        } catch {
            logger.error("mission approval request failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await fail(document: document, message: "Mac could not request mission approval: \(error.localizedDescription)")
        }
    }

    func cancelAfterApprovalDecision(document: QueryDocumentSnapshot, approvalStatus: String) async {
        let message = approvalStatus == "rejected"
            ? "Mission approval was rejected from mobile."
            : "Mission approval was canceled from mobile."
        do {
            guard let uid = accountManager.currentUID else { return }
            try await document.reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: document.documentID,
                    payload: [
                        "status": "canceled",
                        "completedAt": ISO8601DateFormatter().string(from: Date()),
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: message,
                    errorMessage: message
                ),
                merge: true
            )
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "approval_resolved",
                kind: "status",
                title: "Approval \(approvalStatus)",
                message: message,
                backend: nil,
                isError: true
            )
            logger.info("mission approval \(approvalStatus, privacy: .public) id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission approval cancellation failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func resolveBackend(requestedRuntime: String?, missionKind: String?) -> CLIAgentMissionBackend {
        CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: requestedRuntime,
            missionKind: missionKind,
            enabledBackends: settingsManager.enabledChatBackends
        )
    }

    func missionPrompt(title: String, prompt: String, backend: CLIAgentMissionBackend, data: [String: Any]) -> String {
        CLIAgentMissionRuntimePlanner.prompt(
            title: title,
            prompt: prompt,
            backend: backend,
            data: data
        )
    }

    struct DirectCLIMissionResult {
        let status: String
        let output: String
        let errorMessage: String?
        let sessionID: String
    }

    struct DirectCLIStreamEvent: Sendable {
        let phase: String
        let kind: String
        let title: String
        let message: String
        let toolName: String?
        let isError: Bool

        static func assistant(_ message: String, title: String = "Assistant") -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "assistant_response",
                kind: "llm_response",
                title: title,
                message: message,
                toolName: nil,
                isError: false
            )
        }

        static func toolCall(_ message: String, title: String = "Tool call", toolName: String? = nil) -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "tool_use",
                kind: "tool_call",
                title: title,
                message: message,
                toolName: toolName,
                isError: false
            )
        }

        static func toolResult(_ message: String, title: String = "Tool result", toolName: String? = nil, isError: Bool = false) -> DirectCLIStreamEvent {
            DirectCLIStreamEvent(
                phase: "tool_result",
                kind: isError ? "error" : "tool_result",
                title: title,
                message: message,
                toolName: toolName,
                isError: isError
            )
        }
    }

    func runDirectCLIMissionIfNeeded(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: [String: Any],
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult? {
        let workingDirectoryURL = workingDirectoryURL(from: data)
        // Hermes Square §6.5 — merge any persona-scope env namespace the
        // phone attached. A missing scope resolves to `.empty` (missions
        // without a scope keep using the plan's env verbatim); a PRESENT but
        // malformed scope is FAIL-CLOSED — refuse the mission rather than
        // dispatch the spawned CLI with no persona sandbox (full shell +
        // unrestricted file edits). See CLIAgentMissionPersonaScopeResolution.
        let personaOverrides: CLIAgentMissionPersonaScopeApplier.RuntimeOverrides
        switch CLIAgentMissionPersonaScopeResolution.resolve(from: data) {
        case .resolved(let overrides):
            personaOverrides = overrides
        case .refused(let message):
            AppLogger.sync.error(
                "mission_persona_scope_rejected",
                metadata: ["requestID": requestID]
            )
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: message,
                sessionID: "persona-scope-rejected-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }
        if CLIAgentMissionRuntimePlanner.presentationMode(from: data) == .macVisibleCLI {
            guard let plan = CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
                title: title,
                prompt: prompt,
                backend: backend,
                data: data
            ) else {
                return DirectCLIMissionResult(
                    status: "failed",
                    output: "",
                    errorMessage: "\(backend.displayName) does not expose a visible Mac CLI launch path yet.",
                    sessionID: "visible-\(backend.rawValue)-\(UUID().uuidString)"
                )
            }
            var env = plan.extraEnvironment
            for (k, v) in personaOverrides.extraEnvironment { env[k] = v }
            return await runVisibleTerminalMission(
                executableName: plan.executableName,
                arguments: plan.arguments,
                backend: backend,
                extraEnvironment: env,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                cancellationTracker: cancellationTracker
            )
        }

        if let plan = CLIAgentMissionRuntimePlanner.directLaunchPlan(title: title, prompt: prompt, backend: backend, data: data) {
            var env = plan.extraEnvironment
            for (k, v) in personaOverrides.extraEnvironment { env[k] = v }
            return await runDirectCLIMission(
                executableName: plan.executableName,
                arguments: plan.arguments,
                backend: backend,
                extraEnvironment: env,
                workingDirectoryURL: workingDirectoryURL,
                reference: reference,
                requestID: requestID,
                cancellationTracker: cancellationTracker
            )
        }

        if backend.chatBackend != nil {
            return nil
        }

        return DirectCLIMissionResult(
            status: "failed",
            output: "",
            errorMessage: "Unsupported mission runtime '\(backend.rawValue)'.",
            sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
        )
    }

    func workingDirectoryURL(from data: [String: Any]) -> URL? {
        guard let rawPath = (data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: true)
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

    func recordChangedFileEvents(
        before: Set<String>,
        after: Set<String>,
        reference: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async {
        let changedFiles = after.subtracting(before).sorted().prefix(40)
        for path in changedFiles {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "changed_file",
                kind: "changed_file",
                title: "Changed file",
                message: path,
                backend: backend,
                changedFilePath: path
            )
        }
    }

    func mirrorTranscriptPieces(
        _ pieces: [ChatTranscriptPiece],
        mirroredPieceIDs: inout Set<String>,
        reference: DocumentReference,
        requestID: String,
        backend: CLIAgentMissionBackend
    ) async {
        for piece in pieces where !mirroredPieceIDs.contains(piece.id) {
            mirroredPieceIDs.insert(piece.id)
            switch piece.kind {
            case .toolUse:
                let detail = piece.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "tool_use",
                    kind: "tool_call",
                    title: piece.value,
                    message: detail.map { "\(piece.value): \($0)" } ?? piece.value,
                    backend: backend,
                    toolName: piece.value
                )
            case .toolResult:
                let detail = piece.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "tool_result",
                    kind: "tool_result",
                    title: piece.value,
                    message: detail.map { "\(piece.value): \($0)" } ?? piece.value,
                    backend: backend,
                    toolName: piece.value
                )
            case .text:
                let text = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: "assistant_response",
                    kind: "llm_response",
                    title: "Assistant",
                    message: text,
                    backend: backend
                )
            case .reasoning, .refusal:
                let text = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                await recordEvent(
                    reference: reference,
                    requestID: requestID,
                    phase: piece.kind == .reasoning ? "reasoning" : "refusal",
                    kind: piece.kind == .reasoning ? "llm_reasoning" : "llm_refusal",
                    title: piece.kind == .reasoning ? "Reasoning" : "Refusal",
                    message: text,
                    backend: backend
                )
            }
        }
    }

    func runVisibleTerminalMission(
        executableName: String,
        arguments: [String],
        backend: CLIAgentMissionBackend,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult {
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: executableName) else {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: "\(backend.displayName) CLI executable '\(executableName)' was not found on the Mac PATH.",
                sessionID: "visible-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }

        let sessionID = "visible-\(backend.rawValue)-\(UUID().uuidString)"
        do {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "terminal_started",
                kind: "tool_call",
                title: "Terminal session",
                message: "Opening \(backend.displayName) in a visible Mac Terminal session.",
                backend: backend
            )
            let output = try await runVisibleTerminalProcess(
                sessionID: sessionID,
                executable: executable,
                executableName: executableName,
                arguments: arguments,
                backendDisplayName: backend.displayName,
                timeoutSeconds: 60 * 60,
                extraEnvironment: extraEnvironment,
                workingDirectoryURL: workingDirectoryURL,
                cancellationTracker: cancellationTracker,
                eventSink: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.recordEvent(
                            reference: reference,
                            requestID: requestID,
                            phase: event.phase,
                            kind: event.kind,
                            title: event.title,
                            message: event.message,
                            backend: backend,
                            toolName: event.toolName,
                            isError: event.isError
                        )
                    }
                }
            )
            return DirectCLIMissionResult(
                status: "completed",
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                errorMessage: nil,
                sessionID: sessionID
            )
        } catch {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: error.localizedDescription,
                sessionID: sessionID
            )
        }
    }

    nonisolated func runVisibleTerminalProcess(
        sessionID: String,
        executable: String,
        executableName: String,
        arguments: [String],
        backendDisplayName: String,
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        cancellationTracker: MissionCancellationTracker,
        eventSink: @escaping @Sendable (DirectCLIStreamEvent) -> Void
    ) async throws -> String {
        let fileManager = FileManager.default
        let workspace = try VisibleTerminalSessionWorkspace.prepare(sessionID: sessionID, fileManager: fileManager)
        defer { workspace.cleanup() }

        let logURL = workspace.logURL
        let scriptURL = workspace.scriptURL
        let exitURL = workspace.exitURL
        let pidURL = workspace.pidURL
        let command = ([executable] + arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")

        var scriptEnvironment = ["PATH": CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)["PATH"] ?? ""]
        scriptEnvironment.merge(extraEnvironment) { _, new in new }
        let exportLines = scriptEnvironment
            .filter { Self.isValidEnvironmentKey($0.key) }
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(Self.shellQuoted($0.value))" }
            .joined(separator: "\n")
        let cdLine = workingDirectoryURL.map { "cd \(Self.shellQuoted($0.path))" } ?? ""
        let script = """
        #!/bin/zsh
        set +e
        setopt pipefail
        echo $$ > \(Self.shellQuoted(pidURL.path))
        \(exportLines)
        \(cdLine)
        echo "OpenBurnBar visible CLI session"
        echo "Runtime: \(backendDisplayName)"
        echo "Executable: \(executableName)"
        echo ""
        ( \(command) ) 2>&1 | tee \(Self.shellQuoted(logURL.path))
        status=${pipestatus[1]}
        echo "$status" > \(Self.shellQuoted(exitURL.path))
        echo ""
        echo "OpenBurnBar visible CLI session finished with exit $status"
        exit "$status"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", scriptURL.path]
        try opener.run()
        opener.waitUntilExit()
        guard opener.terminationStatus == 0 else {
            throw NSError(
                domain: "OpenBurnBar.VisibleTerminalMission",
                code: Int(opener.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "macOS could not open Terminal for the visible CLI session."]
            )
        }

        eventSink(.toolCall("Terminal opened a visible \(backendDisplayName) CLI session.", title: "Terminal session", toolName: "Terminal"))

        let streamMirror = DirectCLIStreamMirror()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var offset: UInt64 = 0
        var output = ""
        var lastEventAt = Date.distantPast

        while Date() < deadline {
            if cancellationTracker.isCancelled {
                Self.killVisibleTerminalSession(pidURL: pidURL)
                throw NSError(
                    domain: "OpenBurnBar.VisibleTerminalMission",
                    code: 299,
                    userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
                )
            }

            let chunk = Self.readVisibleTerminalLogChunk(logURL: logURL, offset: &offset)
            if !chunk.isEmpty {
                output += chunk
                let emittedStructuredEvents = streamMirror.consumeStdout(chunk, eventSink: eventSink)
                if !emittedStructuredEvents,
                   Date().timeIntervalSince(lastEventAt) >= 1,
                   let message = chunk.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    lastEventAt = Date()
                    eventSink(.assistant(message, title: "Terminal output"))
                }
            }

            if fileManager.fileExists(atPath: exitURL.path) {
                let finalChunk = Self.readVisibleTerminalLogChunk(logURL: logURL, offset: &offset)
                if !finalChunk.isEmpty {
                    output += finalChunk
                    _ = streamMirror.consumeStdout(finalChunk, eventSink: eventSink)
                }
                // try?-ok(sidecar read fallback)
                let rawStatus = (try? String(contentsOf: exitURL, encoding: .utf8))
                    ?? "1"
                let status = Int(rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
                let finalOutput = streamMirror.finalOutputSnapshot(fallback: output.nilIfEmpty ?? rawStatus)
                guard status == 0 else {
                    throw NSError(
                        domain: "OpenBurnBar.VisibleTerminalMission",
                        code: status,
                        userInfo: [NSLocalizedDescriptionKey: finalOutput.nilIfEmpty ?? "Visible \(backendDisplayName) CLI session failed with exit \(status)."]
                    )
                }
                return finalOutput
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                // Task cancellation throws here and would skip the tracker/timeout
                // teardown below, so tear down the visible Terminal session now —
                // matching the former detached task, which reaped it via its
                // orphan running on to the deadline.
                Self.killVisibleTerminalSession(pidURL: pidURL)
                throw CancellationError()
            }
        }

        Self.killVisibleTerminalSession(pidURL: pidURL)
        throw NSError(
            domain: "OpenBurnBar.VisibleTerminalMission",
            code: 124,
            userInfo: [NSLocalizedDescriptionKey: "Visible \(backendDisplayName) CLI session timed out after \(Int(timeoutSeconds)) seconds."]
        )
    }

    func runDirectCLIMission(
        executableName: String,
        arguments: [String],
        backend: CLIAgentMissionBackend,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        reference: DocumentReference,
        requestID: String,
        cancellationTracker: MissionCancellationTracker
    ) async -> DirectCLIMissionResult {
        guard let executable = await CLIExecutableResolver().resolveExecutable(named: executableName) else {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: "\(backend.displayName) CLI executable '\(executableName)' was not found on the Mac PATH.",
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }

        do {
            await recordEvent(
                reference: reference,
                requestID: requestID,
                phase: "process_started",
                kind: "tool_call",
                title: "Process started",
                message: "Launching \(backend.displayName) CLI process.",
                backend: backend
            )
            let output = try await runProcess(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 180,
                extraEnvironment: extraEnvironment,
                workingDirectoryURL: workingDirectoryURL,
                cancellationTracker: cancellationTracker,
                eventSink: { [weak self] event in
                    Task { @MainActor [weak self] in
                        await self?.recordEvent(
                            reference: reference,
                            requestID: requestID,
                            phase: event.phase,
                            kind: event.kind,
                            title: event.title,
                            message: event.message,
                            backend: backend,
                            toolName: event.toolName,
                            isError: event.isError
                        )
                    }
                }
            )
            return DirectCLIMissionResult(
                status: "completed",
                output: output.trimmingCharacters(in: .whitespacesAndNewlines),
                errorMessage: nil,
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        } catch {
            return DirectCLIMissionResult(
                status: "failed",
                output: "",
                errorMessage: error.localizedDescription,
                sessionID: "direct-\(backend.rawValue)-\(UUID().uuidString)"
            )
        }
    }

    private nonisolated func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        cancellationTracker: MissionCancellationTracker,
        eventSink: @escaping @Sendable (DirectCLIStreamEvent) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        process.currentDirectoryURL = workingDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        let output = LockedProcessOutput()
        let streamMirror = DirectCLIStreamMirror()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            output.appendStdout(text)
            let emittedStructuredEvents = streamMirror.consumeStdout(text, eventSink: eventSink)
            if !emittedStructuredEvents,
               let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                eventSink(.assistant(chunk))
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)
            else { return }
            output.appendStderr(text)
            let emittedStructuredEvents = streamMirror.consumeStderr(text, eventSink: eventSink)
            if !emittedStructuredEvents,
               let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                eventSink(.toolResult(chunk, title: "Process stderr", isError: true))
            }
        }

        if cancellationTracker.isCancelled {
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: 299,
                userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
            )
        }

        try process.run()

        // Safety net for the task-cancellation path: a `CancellationError` thrown
        // from `Task.sleep` below skips the tracker/timeout cleanup, so reap the
        // process and detach the stream handlers on every exit here. (The former
        // detached task was cancellation-immune and reaped via its orphan.)
        // No-op on the normal return path, where the process has already exited
        // and the handlers were already cleared.
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            if cancellationTracker.isCancelled {
                let pid = process.processIdentifier
                let killScript = """
                kill_tree() {
                    local _pid=$1
                    for _child in $(pgrep -P $_pid); do
                        kill_tree $_child
                    done
                    kill -TERM $_pid 2>/dev/null
                }
                kill_tree \(pid)
                """
                let killTask = Process()
                killTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
                killTask.arguments = ["-c", killScript]
                try? killTask.run() // try?-ok(fire-and-forget kill)
                killTask.waitUntilExit()

                process.terminate()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                throw NSError(
                    domain: "OpenBurnBar.DirectCLIMission",
                    code: 299,
                    userInfo: [NSLocalizedDescriptionKey: "Mission was cancelled by the user."]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            let killScript = """
            kill_tree() {
                local _pid=$1
                for _child in $(pgrep -P $_pid); do
                    kill_tree $_child
                done
                kill -TERM $_pid 2>/dev/null
            }
            kill_tree \(pid)
            """
            let killTask = Process()
            killTask.executableURL = URL(fileURLWithPath: "/bin/zsh")
            killTask.arguments = ["-c", killScript]
            try? killTask.run() // try?-ok(fire-and-forget kill)
            killTask.waitUntilExit()

            process.terminate()
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "Direct \(URL(fileURLWithPath: executable).lastPathComponent) mission timed out after \(Int(timeoutSeconds)) seconds."]
            )
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let captured = output.snapshot()
        let stdoutText = captured.stdout
        let stderrText = captured.stderr
        let finalOutput = streamMirror.finalOutputSnapshot(fallback: stdoutText.nilIfEmpty ?? stderrText)
        guard process.terminationStatus == 0 else {
            let message = [stdoutText, stderrText]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "OpenBurnBar.DirectCLIMission",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message.nilIfEmpty ?? "Direct CLI mission failed with exit \(process.terminationStatus)."]
            )
        }

        return finalOutput
    }

    func recordEvent(
        reference: DocumentReference,
        requestID: String,
        phase: String,
        kind: String,
        title: String?,
        message: String,
        backend: CLIAgentMissionBackend?,
        toolName: String? = nil,
        artifactPath: String? = nil,
        changedFilePath: String? = nil,
        isError: Bool = false
    ) async {
        let trimmed = CLIAgentMissionEventFactory.redactSecrets(message.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return }
        let nextSequence = (missionEventSequences[requestID] ?? 0) + 1
        missionEventSequences[requestID] = nextSequence
        let event = CLIAgentMissionEventFactory.event(
            sequence: nextSequence,
            phase: phase,
            kind: kind,
            title: title,
            message: trimmed,
            runtime: backend?.rawValue,
            toolName: toolName,
            artifactPath: artifactPath,
            changedFilePath: changedFilePath,
            isError: isError
        )
        do {
            guard let uid = accountManager.currentUID else { return }
            try await reference.setData(
                try await sealedStateUpdate(
                    uid: uid,
                    requestID: requestID,
                    payload: [
                        "lastEventSequence": nextSequence,
                        "updatedAt": FieldValue.serverTimestamp()
                    ],
                    liveSummary: trimmed.prefix(600).description
                ),
                merge: true
            )
            let eventID = CLIAgentMissionEventFactory.eventID(for: nextSequence)
            let key = try await missionVaultKey(uid: uid)
            try await reference.collection("events").document(eventID).setData(
                try CLIAgentMissionEventFactory.sealedEvent(
                    event,
                    uid: uid,
                    requestID: requestID,
                    eventID: eventID,
                    vaultKey: key.keyData,
                    vaultKeyID: key.vaultKeyID
                ),
                merge: false
            )
        } catch {
            logger.warning("mission event update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_").contains(first)
        else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        return key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private nonisolated static func readVisibleTerminalLogChunk(
        logURL: URL,
        offset: inout UInt64
    ) -> String {
        guard FileManager.default.fileExists(atPath: logURL.path),
              // try?-ok(sidecar log read)
              let handle = try? FileHandle(forReadingFrom: logURL)
        else { return "" }
        defer { try? handle.close() } // try?-ok(handle teardown)
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            offset += UInt64(data.count)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private nonisolated static func killVisibleTerminalSession(pidURL: URL) {
        // try?-ok(sidecar pid read)
        guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(rawPID),
              pid > 0
        else { return }
        let killScript = """
        kill_tree() {
            local _pid=$1
            for _child in $(pgrep -P $_pid); do
                kill_tree $_child
            done
            kill -TERM $_pid 2>/dev/null
        }
        kill_tree \(pid)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", killScript]
        try? process.run() // try?-ok(fire-and-forget kill)
        process.waitUntilExit()
    }

    nonisolated static func deriveStreamingStatusMessage(
        assistantMessage: ChatMessageRecord?,
        backend: CLIAgentMissionBackend
    ) -> String {
        let assistantPreview = assistantMessage?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview = assistantPreview, !preview.isEmpty {
            return CLIAgentMissionEventFactory.mobileSafeText(preview, limit: 420)
        }
        let latestTool = assistantMessage?.displayTranscript.last(where: { $0.kind == .toolUse })
        if let tool = latestTool {
            let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let message = detail.map { "\(tool.value): \($0)" } ?? tool.value
            return CLIAgentMissionEventFactory.mobileSafeText(message, limit: 420)
        }
        return "\(backend.displayName) is composing a response…"
    }

    func resultSummary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.nilIfEmpty ?? "Mission finished without a text result."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
