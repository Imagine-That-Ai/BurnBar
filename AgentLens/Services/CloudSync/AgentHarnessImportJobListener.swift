import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarKernel
import OpenBurnBarLogParsers
import OSLog

// MARK: - Agent Harness Import Jobs

/// Mac-side processor for mobile-triggered history imports.
///
/// Mobile creates `agent_import_jobs/{id}`. The signed-in trusted Mac claims
/// the job, parses selected local harness histories, indexes them into the
/// local store, mirrors CLI rows for mobile, and lets the existing session-log
/// sync path upload encrypted transcript bodies when cloud backup is enabled.
@MainActor
final class AgentHarnessImportJobListener {
    let accountManager: AccountManaging
    let settingsManager: SettingsManager
    let dataStore: DataStore
    let cloudSyncService: CloudSyncService?
    let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    let firestoreProvider: @Sendable () -> Firestore
    let parserFactory: @Sendable (AgentProvider) -> (any LogParser)?
    let logger = Logger(subsystem: "com.openburnbar.app", category: "AgentHarnessImportJobListener")

    var listener: ListenerRegistration?
    var listenerUID: String?
    var attachTask: Task<Void, Never>?
    var processingDocs = Set<String>()

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        dataStore: DataStore,
        cloudSyncService: CloudSyncService?,
        deviceTrustChecker: CLIAgentMissionDeviceTrustChecking = LiveCLIAgentMissionDeviceTrustChecker(),
        firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() },
        parserFactory: @escaping @Sendable (AgentProvider) -> (any LogParser)? = { ParserRegistry.defaultParsers()[$0] }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.dataStore = dataStore
        self.cloudSyncService = cloudSyncService
        self.deviceTrustChecker = deviceTrustChecker
        self.firestoreProvider = firestoreProvider
        self.parserFactory = parserFactory
    }

    func start() {
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
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingDocs.removeAll()
    }

    func attachIfPossible() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = firestoreProvider().collection("users").document(uid)
            .collection("agent_import_jobs")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.logger.warning("import job listener failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
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

    func handle(document: QueryDocumentSnapshot) async {
        guard let uid = accountManager.currentUID else { return }
        let trust = await deviceTrustChecker.prepareAndValidateTrustedExecutor(
            uid: uid,
            deviceID: accountManager.deviceId
        )
        guard trust.isTrusted else {
            logger.warning("import job \(document.documentID, privacy: .public) ignored because this Mac is not trusted")
            return
        }

        let selected = (document.data()["selectedHarnesses"] as? [String]) ?? []
        let providers = Self.providers(for: selected)
        do {
            let claimed = try await claimImportJob(reference: document.reference, providers: providers)
            guard claimed else { return }
        } catch {
            logger.error("import job claim failed \(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        var allUsages: [TokenUsage] = []
        var allConversations: [ConversationRecord] = []
        var errors: [String] = []

        for (index, provider) in providers.enumerated() {
            do {
                try await document.reference.setData([
                    "progressMessage": "Scanning \(provider.displayName) history.",
                    "scannedCount": index,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
                guard let parser = parserFactory(provider) else {
                    errors.append("No parser is available for \(provider.displayName).")
                    continue
                }
                let result = try await parser.parse()
                allUsages.append(contentsOf: result.usages)
                allConversations.append(contentsOf: result.conversations)
            } catch {
                errors.append("\(provider.displayName): \(error.localizedDescription)")
            }
        }

        do {
            if !allUsages.isEmpty {
                try await dataStore.insertChunked(allUsages)
            }
            let report = try await ConversationIndexer.shared.index(allConversations, in: dataStore)
            var mirrored = 0
            for conversation in allConversations where CLIAgentSessionMirror.archivedAgent(for: conversation.provider) != nil {
                await CLIAgentSessionMirror.shared.mirrorArchivedLog(conversation)
                mirrored += 1
            }
            await cloudSyncService?.uploadPendingConversations()
            await cloudSyncService?.uploadPendingSessionLogs()

            let status = errors.isEmpty ? "completed" : (allConversations.isEmpty && allUsages.isEmpty ? "failed" : "completed")
            let importedCount = report.changedRecordCount + report.skippedRecordCount
            let noHistory = importedCount == 0 && allUsages.isEmpty && errors.isEmpty
            var payload: [String: Any] = [
                "status": status,
                "progressMessage": noHistory ? "No selected agent history was found on this Mac." : "Imported \(importedCount) session\(importedCount == 1 ? "" : "s") from this Mac.",
                "scannedCount": providers.count,
                "importedCount": importedCount,
                "mirroredSessionCount": mirrored,
                "uploadedSessionLogCount": settingsManager.sessionLogCloudBackupEnabled ? importedCount : 0,
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if !errors.isEmpty {
                payload["errorMessage"] = errors.joined(separator: "\n").prefixString(2048)
            }
            try await document.reference.setData(payload, merge: true)
        } catch {
            let failureMessage = error.localizedDescription
            do {
                try await document.reference.setData([
                    "status": "failed",
                    "errorMessage": "Import failed after scanning: \(failureMessage)".prefixString(2048),
                    "progressMessage": "Import failed after scanning.",
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } catch {
                logger.warning("failed to mark import mission as failed after scan error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func claimImportJob(reference: DocumentReference, providers: [AgentProvider]) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            firestoreProvider().runTransaction({ transaction, errorPointer in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(reference)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }

                guard snapshot.data()?["status"] as? String == "pending" else {
                    return false as NSNumber
                }

                transaction.setData([
                    "status": "scanning",
                    "claimedBy": self.accountManager.deviceId,
                    "startedAt": ISO8601DateFormatter().string(from: Date()),
                    "progressMessage": providers.isEmpty ? "No supported harnesses were selected." : "Scanning \(providers.map(\.displayName).joined(separator: ", ")).",
                    "scannedCount": 0,
                    "importedCount": 0,
                    "mirroredSessionCount": 0,
                    "uploadedSessionLogCount": 0,
                    "updatedAt": FieldValue.serverTimestamp()
                ], forDocument: reference, merge: true)
                return true as NSNumber
            }, completion: { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (result as? NSNumber)?.boolValue == true)
            })
        }
    }

    static func providers(for harnesses: [String]) -> [AgentProvider] {
        var ordered: [AgentProvider] = []
        var seen = Set<AgentProvider>()
        for harness in harnesses {
            guard let provider = provider(for: harness), !seen.contains(provider) else { continue }
            ordered.append(provider)
            seen.insert(provider)
        }
        return ordered
    }

    static func provider(for harness: String) -> AgentProvider? {
        switch harness.lowercased().replacingOccurrences(of: " ", with: "") {
        case "codex": return .codex
        case "claude", "claudecode": return .claudeCode
        case "openclaw", "open-claw": return .openClaw
        case "hermes": return .hermes
        case "opencode", "open-code": return .openCode
        case "factory", "droid": return .factory
        case "cursor": return .cursor
        case "aider": return .aider
        case "cline": return .cline
        case "kilo", "kilocode": return .kiloCode
        case "roo", "roocode": return .rooCode
        case "forge", "forgedev": return .forgeDev
        case "gemini", "geminicli": return .geminiCLI
        case "goose": return .goose
        case "windsurf": return .windsurf
        case "devin": return .devin
        case "warp": return .warp
        case "kimi": return .kimi
        case "ollama": return .ollama
        case "fx": return .fx
        default:
            return AgentProvider.fromPersistedToken(harness) ?? AgentProvider.fromCatalogProviderID(harness)
        }
    }
}

private extension Substring {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}

private extension String {
    func prefixString(_ maxLength: Int) -> String {
        String(prefix(maxLength))
    }
}
