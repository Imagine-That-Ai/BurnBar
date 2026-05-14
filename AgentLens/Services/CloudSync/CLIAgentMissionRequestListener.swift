import Foundation
@preconcurrency import FirebaseFirestore
import OSLog

// MARK: - CLI Agent Mission Request Listener
//
// Mac-side remote-control listener. iOS/iPadOS/Android publish pending
// mission requests at:
//
//   users/{uid}/cli_agent_mission_requests/{requestID}
//
// The Mac claims each request, runs it through the same local ChatSessionController
// used by the desktop chat surface, and the existing CLIAgentSessionMirror writes
// Codex / Claude / OpenClaw transcripts back to `cli_sessions` for mobile viewing.

@MainActor
final class CLIAgentMissionRequestListener {

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let chatController: ChatSessionController
    private let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()
    private var lastAttachState: String?

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        chatController: ChatSessionController
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.chatController = chatController
    }

    func start() {
        logger.info("mission listener start requested")
        if attachTask == nil {
            attachTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
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
    }

    private func attachIfPossible() {
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
            .whereField("status", isEqualTo: "pending")
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

    private func processDocs(_ docs: [QueryDocumentSnapshot]) {
        for doc in docs where !processingDocs.contains(doc.documentID) {
            processingDocs.insert(doc.documentID)
            Task { @MainActor in
                defer { processingDocs.remove(doc.documentID) }
                await handle(document: doc)
            }
        }
    }

    private func handle(document: QueryDocumentSnapshot) async {
        let data = document.data()
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Insights mission"
        guard let prompt = (data["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            await fail(document: document, message: "Mission prompt was empty.")
            return
        }

        let backend = resolveBackend(
            requestedRuntime: data["requestedRuntime"] as? String,
            missionKind: data["missionKind"] as? String
        )

        let requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        let missionKind = (data["missionKind"] as? String) ?? "unknown"
        logger.info("claiming mission id=\(document.documentID, privacy: .public) kind=\(missionKind, privacy: .public) requested=\(requestedRuntime, privacy: .public) selected=\(backend.rawValue, privacy: .public)")
        do {
            try await document.reference.setData([
                "status": "running",
                "claimedBy": accountManager.deviceId,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "liveSummary": "\(backend.displayName) claimed the mission on this Mac.",
                "events": FieldValue.arrayUnion([
                    missionEvent(
                        phase: "claimed",
                        message: "\(backend.displayName) claimed the mission on this Mac.",
                        backend: backend
                    )
                ]),
                "startedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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

        logger.info("starting mission id=\(document.documentID, privacy: .public) backend=\(backend.rawValue, privacy: .public)")
        await recordEvent(
            reference: document.reference,
            phase: "starting",
            message: "Starting \(backend.displayName) with the mission prompt.",
            backend: backend
        )
        if let directResult = await runDirectCLIMissionIfNeeded(title: title, prompt: prompt, backend: backend, data: data, reference: document.reference) {
            var payload: [String: Any] = [
                "status": directResult.status,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "sessionId": directResult.sessionID,
                "resultPreview": directResult.output.prefix(600).description,
                "liveSummary": directResult.status == "completed" ? "\(backend.displayName) returned a result." : "\(backend.displayName) mission failed.",
                "events": FieldValue.arrayUnion([
                    missionEvent(
                        phase: directResult.status == "completed" ? "completed" : "failed",
                        message: directResult.status == "completed" ? resultSummary(from: directResult.output) : (directResult.errorMessage ?? "\(backend.displayName) mission failed."),
                        backend: backend
                    )
                ]),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let errorMessage = directResult.errorMessage {
                payload["errorMessage"] = errorMessage
            }
            do {
                try await document.reference.setData(payload, merge: true)
                logger.info("finished direct CLI mission id=\(document.documentID, privacy: .public) status=\(directResult.status, privacy: .public)")
            } catch {
                logger.error("direct CLI mission update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        chatController.setChatBackend(backend)
        chatController.startNewChatThread()
        let threadID = chatController.activeThreadID
        chatController.inputText = missionPrompt(title: title, prompt: prompt, backend: backend, data: data)
        await chatController.send()

        var lastStreamingEvent = Date.distantPast
        var mirroredTranscriptPieceIDs = Set<String>()
        while chatController.isStreaming {
            let assistantMessage = chatController.messages.last(where: { $0.role == .assistant })
            for piece in assistantMessage?.displayTranscript ?? [] where !mirroredTranscriptPieceIDs.contains(piece.id) {
                mirroredTranscriptPieceIDs.insert(piece.id)
                switch piece.kind {
                case .toolUse:
                    let detail = piece.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    await recordEvent(
                        reference: document.reference,
                        phase: "tool_use",
                        message: detail.map { "\(piece.value): \($0)" } ?? piece.value,
                        backend: backend
                    )
                case .text:
                    let text = piece.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    await recordEvent(
                        reference: document.reference,
                        phase: "assistant_response",
                        message: text.prefix(600).description,
                        backend: backend
                    )
                }
            }
            if Date().timeIntervalSince(lastStreamingEvent) >= 2 {
                lastStreamingEvent = Date()
                let assistantPreview = assistantMessage?
                    .content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                await recordEvent(
                    reference: document.reference,
                    phase: "streaming",
                    message: assistantPreview?.prefix(420).description.nilIfEmpty ?? "\(backend.displayName) is still working on the mission.",
                    backend: backend
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let status = chatController.streamError == nil ? "completed" : "failed"
        let finalSummary = chatController.messages.last(where: { $0.role == .assistant })?.content.prefix(600).description ?? ""
        var payload: [String: Any] = [
            "status": status,
            "selectedRuntime": backend.rawValue,
            "selectedRuntimeName": backend.displayName,
            "sessionId": threadID,
            "liveSummary": status == "completed" ? "\(backend.displayName) returned a result." : "\(backend.displayName) mission failed.",
            "events": FieldValue.arrayUnion([
                missionEvent(
                    phase: status == "completed" ? "completed" : "failed",
                    message: status == "completed" ? resultSummary(from: finalSummary) : (chatController.streamError ?? "\(backend.displayName) mission failed."),
                    backend: backend
                )
            ]),
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let streamError = chatController.streamError {
            payload["errorMessage"] = streamError
        } else {
            payload["resultPreview"] = finalSummary
        }
        do {
            try await document.reference.setData(payload, merge: true)
            logger.info("finished mission id=\(document.documentID, privacy: .public) status=\(status, privacy: .public)")
        } catch {
            logger.error("mission final update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fail(document: QueryDocumentSnapshot, message: String) async {
        do {
            try await document.reference.setData([
                "status": "failed",
                "errorMessage": message,
                "liveSummary": message,
                "events": FieldValue.arrayUnion([
                    missionEvent(phase: "failed", message: message, backend: nil)
                ]),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            logger.info("marked mission failed id=\(document.documentID, privacy: .public)")
        } catch {
            logger.error("mission failure update failed id=\(document.documentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func resolveBackend(requestedRuntime: String?, missionKind: String?) -> ChatBackendID {
        if let requestedRuntime,
           requestedRuntime != "auto",
           let direct = ChatBackendID(rawValue: requestedRuntime) {
            return direct
        }

        let enabled = settingsManager.enabledChatBackends
        func firstEnabled(_ ordered: [ChatBackendID]) -> ChatBackendID? {
            ordered.first { enabled.contains($0) }
        }

        switch missionKind {
        case "diligence":
            return firstEnabled([.claude, .codex, .hermes, .piAgent, .openclaw])
                ?? .codex
        case "creative":
            return firstEnabled([.openclaw, .codex, .hermes, .piAgent, .claude])
                ?? .hermes
        case "debt":
            return firstEnabled([.codex, .claude, .hermes, .piAgent, .openclaw])
                ?? .codex
        default:
            return enabled.first ?? .codex
        }
    }

    private func missionPrompt(title: String, prompt: String, backend: ChatBackendID, data: [String: Any]) -> String {
        let source = (data["source"] as? String) ?? "mobile-insights"
        return """
        You are OpenBurnBar Mission Control running from \(backend.displayName) on the user's Mac.

        Mission: \(title)
        Source: \(source)

        Execute this as a concrete, useful mission packet. Inspect the repo or local data before making claims. Produce actionable findings, acceptance criteria, validation commands, risks, and a mobile-readable result summary. If code changes are warranted, keep them scoped and preserve unrelated work.

        \(prompt)
        """
    }

    private struct DirectCLIMissionResult {
        let status: String
        let output: String
        let errorMessage: String?
        let sessionID: String
    }

    private func runDirectCLIMissionIfNeeded(
        title: String,
        prompt: String,
        backend: ChatBackendID,
        data: [String: Any],
        reference: DocumentReference
    ) async -> DirectCLIMissionResult? {
        switch backend {
        case .piAgent:
            let piPrompt = missionPrompt(title: title, prompt: prompt, backend: backend, data: data)
            return await runDirectCLIMission(
                executableName: "zsh",
                arguments: [
                    "-lic",
                    "pi --no-session --no-tools -p \"$OPENBURNBAR_MISSION_PROMPT\""
                ],
                backend: backend,
                extraEnvironment: ["OPENBURNBAR_MISSION_PROMPT": piPrompt],
                reference: reference
            )
        case .openclaw:
            return await runDirectCLIMission(
                executableName: "openclaude",
                arguments: [
                    "-p",
                    missionPrompt(title: title, prompt: prompt, backend: backend, data: data),
                    "--no-session-persistence",
                    "--permission-mode", "auto"
                ],
                backend: backend,
                extraEnvironment: [:],
                reference: reference
            )
        case .codex, .claude, .hermes:
            return nil
        }
    }

    private func runDirectCLIMission(
        executableName: String,
        arguments: [String],
        backend: ChatBackendID,
        extraEnvironment: [String: String],
        reference: DocumentReference
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
                phase: "process_started",
                message: "Launching \(backend.displayName) CLI process.",
                backend: backend
            )
            let output = try await runProcess(
                executable: executable,
                arguments: arguments,
                timeoutSeconds: 180,
                extraEnvironment: extraEnvironment,
                eventSink: { [weak self] phase, message in
                    Task { @MainActor [weak self] in
                        await self?.recordEvent(reference: reference, phase: phase, message: message, backend: backend)
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

    private func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        eventSink: @escaping @Sendable (String, String) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = CLIExecutableResolver.enrichedProcessEnvironment(executablePath: executable)
            environment.merge(extraEnvironment) { _, new in new }
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            eventSink("process_running", "\(URL(fileURLWithPath: executable).lastPathComponent) is running.")

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            let startedAt = Date()
            var lastProgressSecond = 0
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                if elapsed >= 5, elapsed % 5 == 0, elapsed != lastProgressSecond {
                    lastProgressSecond = elapsed
                    eventSink("process_running", "\(URL(fileURLWithPath: executable).lastPathComponent) is still running after \(elapsed)s.")
                }
            }
            if process.isRunning {
                process.terminate()
                throw NSError(
                    domain: "OpenBurnBar.DirectCLIMission",
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "Direct \(URL(fileURLWithPath: executable).lastPathComponent) mission timed out after \(Int(timeoutSeconds)) seconds."]
                )
            }

            let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

            return stdoutText.nilIfEmpty ?? stderrText
        }.value
    }

    private func recordEvent(
        reference: DocumentReference,
        phase: String,
        message: String,
        backend: ChatBackendID?
    ) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await reference.setData([
                "liveSummary": trimmed.prefix(600).description,
                "events": FieldValue.arrayUnion([
                    missionEvent(phase: phase, message: trimmed, backend: backend)
                ]),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        } catch {
            logger.warning("mission event update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func missionEvent(phase: String, message: String, backend: ChatBackendID?) -> [String: Any] {
        var event: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "phase": phase,
            "message": message.prefix(600).description,
            "source": "mac"
        ]
        if let backend {
            event["runtime"] = backend.rawValue
        }
        return event
    }

    private func resultSummary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.nilIfEmpty?.prefix(600).description ?? "Mission finished without a text result."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
