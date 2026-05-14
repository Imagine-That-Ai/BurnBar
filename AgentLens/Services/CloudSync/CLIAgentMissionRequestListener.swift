import Foundation
@preconcurrency import FirebaseFirestore

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
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()

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
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingDocs.removeAll()
    }

    private func attachIfPossible() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            listener?.remove()
            listener = nil
            listenerUID = nil
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        listener = Firestore.firestore().collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .whereField("status", isEqualTo: "pending")
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil, let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
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

        try? await document.reference.setData([
            "status": "running",
            "claimedBy": accountManager.deviceId,
            "selectedRuntime": backend.rawValue,
            "selectedRuntimeName": backend.displayName,
            "startedAt": ISO8601DateFormatter().string(from: Date())
        ], merge: true)

        if chatController.isStreaming {
            await fail(document: document, message: "Mac chat controller is already running another mission.")
            return
        }

        chatController.setChatBackend(backend)
        chatController.startNewChatThread()
        let threadID = chatController.activeThreadID
        chatController.inputText = missionPrompt(title: title, prompt: prompt, backend: backend, data: data)
        await chatController.send()

        while chatController.isStreaming {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let status = chatController.streamError == nil ? "completed" : "failed"
        var payload: [String: Any] = [
            "status": status,
            "selectedRuntime": backend.rawValue,
            "selectedRuntimeName": backend.displayName,
            "sessionId": threadID,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let streamError = chatController.streamError {
            payload["errorMessage"] = streamError
        } else {
            payload["resultPreview"] = chatController.messages.last(where: { $0.role == .assistant })?.content.prefix(600).description ?? ""
        }
        try? await document.reference.setData(payload, merge: true)
    }

    private func fail(document: QueryDocumentSnapshot, message: String) async {
        try? await document.reference.setData([
            "status": "failed",
            "errorMessage": message,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    private func resolveBackend(requestedRuntime: String?, missionKind: String?) -> ChatBackendID {
        if let requestedRuntime,
           requestedRuntime != "auto",
           let direct = ChatBackendID(rawValue: requestedRuntime) {
            return direct
        }

        switch missionKind {
        case "diligence":
            return settingsManager.enabledChatBackends.contains(.claude) ? .claude : .codex
        case "creative":
            if settingsManager.enabledChatBackends.contains(.openclaw) { return .openclaw }
            return settingsManager.enabledChatBackends.contains(.codex) ? .codex : .hermes
        case "debt":
            return settingsManager.enabledChatBackends.contains(.codex) ? .codex : .claude
        default:
            return settingsManager.enabledChatBackends.first ?? .codex
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
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
