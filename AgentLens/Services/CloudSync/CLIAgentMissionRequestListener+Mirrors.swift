import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Direct CLI stream mirror and locked process output.
// Extracted from CLIAgentMissionRequestListener.swift (god-file decomposition) — same module, verbatim.

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

final class DirectCLIStreamMirror: Sendable {
    struct State {
        var stdoutBuffer = ""
        var stderrBuffer = ""
        var assistantDeltaBuffer = ""
        var assistantDeltaTranscript = ""
        var latestAssistantMessage = ""
        var latestResultText = ""
        var lastReasoningEventCount = 0
    }

    let state = Locked(State())
    let assistantDeltaFlushThreshold = 480
    let reasoningEventStep = 500

    func consumeStdout(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: \.stdoutBuffer, eventSink: eventSink)
    }

    func consumeStderr(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: \.stderrBuffer, eventSink: eventSink)
    }

    func consume(
        _ text: String,
        buffer: WritableKeyPath<State, String>,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        let incomingLooksStructured = text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
        let (bufferedLooksStructured, completeLines) = state.withLock { state -> (Bool, [String]) in
            state[keyPath: buffer] += text
            let lines = state[keyPath: buffer].components(separatedBy: .newlines)
            state[keyPath: buffer] = lines.last ?? ""
            let bufferedLooksStructured = state[keyPath: buffer].trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
            return (bufferedLooksStructured, Array(lines.dropLast()))
        }

        var emitted = incomingLooksStructured || bufferedLooksStructured
        for rawLine in completeLines {
            guard let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                continue
            }
            if line.first == "{" {
                emitted = true
            }
            if let event = parseJSONLine(line) {
                eventSink(event)
                emitted = true
            }
        }
        return emitted
    }

    func parseJSONLine(_ line: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
              // try?-ok(optional jsonline parse)
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        if let event = parseOpenClaude(object: object, type: type) {
            return event
        }
        if let event = parsePi(object: object, type: type) {
            return event
        }
        return nil
    }

    func parseOpenClaude(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        if type == "system",
           let subtype = object["subtype"] as? String,
           subtype == "init" {
            let model = object["model"] as? String
            let sessionID = object["session_id"] as? String
            return .toolResult(
                ["OpenClaude session initialized", model.map { "model=\($0)" }, sessionID.map { "session=\($0)" }]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                title: "LLM call started"
            )
        }

        if type == "stream_event",
           let event = object["event"] as? [String: Any],
           let streamType = event["type"] as? String {
            if streamType == "content_block_delta",
               let delta = event["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = (delta["text"] as? String)?.nilIfEmpty {
                return appendAssistantDelta(text)
            }
            if streamType == "content_block_stop" || streamType == "message_stop" {
                return flushAssistantDelta()
            }
            if streamType == "message_delta",
               let usage = event["usage"] as? [String: Any] {
                return .toolResult(formatUsage(usage), title: "LLM usage")
            }
        }

        if type == "assistant",
           let message = object["message"] as? [String: Any] {
            _ = flushAssistantDelta()
            return parseAssistantMessage(message, title: "Assistant", captureAsFinal: true)
        }

        if type == "result" {
            if let flushed = flushAssistantDelta() {
                return flushed
            }
            let result = (object["result"] as? String)?.nilIfEmpty
            if let result {
                storeResultText(result)
            }
            let stopReason = object["stop_reason"] as? String
            let duration = object["duration_ms"] as? Int
            let cost = object["total_cost_usd"] as? Double
            let summary = [
                result.map { "result=\($0)" },
                stopReason.map { "stopReason=\($0)" },
                duration.map { "durationMs=\($0)" },
                cost.map { "costUsd=\($0)" }
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            return summary.nilIfEmpty.map { .toolResult($0, title: "LLM result") }
        }
        return nil
    }

    func parsePi(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        if type == "session",
           let id = object["id"] as? String {
            return .toolResult("Pi session initialized\nsession=\(id)", title: "LLM call started")
        }

        if type == "message_start",
           let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            let api = message["api"] as? String
            let provider = message["provider"] as? String
            let model = message["model"] as? String
            return .toolResult(
                ["Pi assistant message started", api.map { "api=\($0)" }, provider.map { "provider=\($0)" }, model.map { "model=\($0)" }]
                    .compactMap { $0 }
                    .joined(separator: "\n"),
                title: "LLM call started"
            )
        }

        if type == "message_update",
           let update = object["assistantMessageEvent"] as? [String: Any],
           let updateType = update["type"] as? String {
            if updateType == "text_delta",
               let text = (update["delta"] as? String)?.nilIfEmpty {
                return appendAssistantDelta(text)
            }
            if updateType == "text_start",
               let partial = update["partial"] as? [String: Any] {
                return parseAssistantMessage(partial, title: "Assistant", captureAsFinal: false)
            }
            if updateType == "thinking_start" || updateType == "thinking_delta" || updateType == "thinking_end" {
                let count = ((update["partial"] as? [String: Any])?["content"] as? [[String: Any]])?
                    .compactMap { item -> String? in
                        guard (item["type"] as? String) == "thinking" else { return nil }
                        return item["thinking"] as? String
                    }
                    .joined(separator: "\n")
                    .count ?? 0
                if updateType == "thinking_start" {
                    state.withLock { $0.lastReasoningEventCount = 0 }
                    return .toolResult("Reasoning stream started.", title: "Reasoning")
                }
                if updateType == "thinking_end" {
                    state.withLock { $0.lastReasoningEventCount = count }
                    return .toolResult("Reasoning stream completed (\(count) chars available from runtime).", title: "Reasoning")
                }
                return state.withLock { state -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? in
                    guard count >= state.lastReasoningEventCount + reasoningEventStep else {
                        return nil
                    }
                    state.lastReasoningEventCount = count
                    return .toolResult("Reasoning stream updated (\(count) chars available from runtime).", title: "Reasoning")
                }
            }
        }

        if type == "message_end",
           let message = object["message"] as? [String: Any],
           (message["role"] as? String) == "assistant" {
            if let flushed = flushAssistantDelta() {
                return flushed
            }
            let assistantEvent = parseAssistantMessage(message, title: "Assistant", captureAsFinal: true)
            if let usage = message["usage"] as? [String: Any] {
                return .toolResult(formatUsage(usage), title: "LLM usage")
            }
            return assistantEvent
        }

        if type == "turn_end",
           let results = object["toolResults"] as? [[String: Any]],
           !results.isEmpty {
            let rendered = results.compactMap { result -> String? in
                if let name = result["toolName"] as? String {
                    return "\(name): \(result)"
                }
                return "\(result)"
            }.joined(separator: "\n\n")
            return rendered.nilIfEmpty.map { .toolResult($0, title: "Tool results") }
        }
        return nil
    }

    func appendAssistantDelta(_ text: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        state.withLock { state in
            state.assistantDeltaTranscript += text
            state.assistantDeltaBuffer += text
            let shouldFlush = state.assistantDeltaBuffer.count >= assistantDeltaFlushThreshold
                || text.contains("\n")
                || text.contains(". ")
                || text.contains(": ")
            guard shouldFlush else { return nil }
            return Self.flushAssistantDelta(&state)
        }
    }

    func flushAssistantDelta() -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        state.withLock { Self.flushAssistantDelta(&$0) }
    }

    static func flushAssistantDelta(_ state: inout State) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        let text = state.assistantDeltaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        state.assistantDeltaBuffer = ""
        return text.nilIfEmpty.map { .assistant($0, title: "Assistant delta") }
    }

    func parseAssistantMessage(
        _ message: [String: Any],
        title: String,
        captureAsFinal: Bool
    ) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        var textParts: [String] = []
        var toolEvents: [CLIAgentMissionRequestListener.DirectCLIStreamEvent] = []
        for item in content {
            guard let itemType = item["type"] as? String else { continue }
            switch itemType {
            case "text":
                if let text = (item["text"] as? String)?.nilIfEmpty {
                    textParts.append(text)
                }
            case "tool_use":
                let name = (item["name"] as? String) ?? "Tool"
                let input = item["input"].map { "\($0)" } ?? ""
                toolEvents.append(.toolCall("\(name): \(input)", title: name, toolName: name))
            default:
                continue
            }
        }
        if let toolEvent = toolEvents.first {
            return toolEvent
        }
        let text = textParts.joined(separator: "\n")
        if captureAsFinal, let finalText = text.nilIfEmpty {
            storeAssistantMessage(finalText)
        }
        return text.nilIfEmpty.map { .assistant($0, title: title) }
    }

    func formatUsage(_ usage: [String: Any]) -> String {
        usage.keys.sorted().map { key in
            "\(key)=\(usage[key] ?? "")"
        }.joined(separator: "\n")
    }

    func storeAssistantMessage(_ text: String) {
        state.withLock { $0.latestAssistantMessage = text }
    }

    func storeResultText(_ text: String) {
        state.withLock { $0.latestResultText = text }
    }

    func finalOutputSnapshot(fallback: String?) -> String {
        _ = flushAssistantDelta()
        let candidates = state.withLock { state in
            [
                state.latestResultText,
                state.latestAssistantMessage,
                state.assistantDeltaTranscript,
                fallback ?? ""
            ]
        }
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

final class LockedProcessOutput: Sendable {
    struct State {
        var stdout = ""
        var stderr = ""
    }

    let state = Locked(State())

    func appendStdout(_ text: String) { state.withLock { $0.stdout += text } }
    func appendStderr(_ text: String) { state.withLock { $0.stderr += text } }
    func snapshot() -> (stdout: String, stderr: String) {
        state.withLock { ($0.stdout, $0.stderr) }
    }
}

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
        case "warp": return .warp
        case "kimi": return .kimi
        case "ollama": return .ollama
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
