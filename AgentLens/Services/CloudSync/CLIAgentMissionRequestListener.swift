import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// MARK: - Mission Device Trust

struct CLIAgentMissionDeviceTrustResult: Equatable, Sendable {
    let isTrusted: Bool
    let message: String

    static var trusted: CLIAgentMissionDeviceTrustResult {
        CLIAgentMissionDeviceTrustResult(
            isTrusted: true,
            message: "Mac is trusted for mobile mission execution."
        )
    }

    static func untrusted(_ message: String) -> CLIAgentMissionDeviceTrustResult {
        CLIAgentMissionDeviceTrustResult(isTrusted: false, message: message)
    }
}

@MainActor
protocol CLIAgentMissionDeviceTrustChecking: AnyObject {
    func prepareAndValidateTrustedExecutor(uid: String, deviceID: String) async -> CLIAgentMissionDeviceTrustResult
}

struct CLIAgentMissionBackend: Equatable, Sendable {
    let rawValue: String
    let displayName: String
    let chatBackend: ChatBackendID?

    init(chatBackend: ChatBackendID) {
        self.rawValue = chatBackend.rawValue
        self.displayName = chatBackend.displayName
        self.chatBackend = chatBackend
    }

    init(rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.chatBackend = nil
    }

    var usesDirectCLI: Bool {
        chatBackend == nil
    }
}

struct CLIAgentMissionDirectLaunchPlan: Equatable, Sendable {
    let executableName: String
    let arguments: [String]
    let extraEnvironment: [String: String]
}

enum CLIAgentMissionRuntimePlanner {
    static func resolve(
        requestedRuntime: String?,
        missionKind: String?,
        enabledBackends: [ChatBackendID]
    ) -> CLIAgentMissionBackend {
        if let requestedRuntime,
           requestedRuntime != "auto" {
            let normalizedRuntime = requestedRuntime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalizedRuntime {
            case "pi", "piagent", "pi-agent":
                return CLIAgentMissionBackend(chatBackend: .piAgent)
            case "claude-code", "claudecode":
                return CLIAgentMissionBackend(chatBackend: .claude)
            case "open-claw":
                return CLIAgentMissionBackend(chatBackend: .openclaw)
            case "droid", "factory", "factory-droid", "factorydroid":
                return CLIAgentMissionBackend(chatBackend: .droid)
            case "forge", "forge-dev", "forgedev":
                return CLIAgentMissionBackend(chatBackend: .forge)
            case "antigravity", "agy", "google-antigravity", "googleantigravity":
                return CLIAgentMissionBackend(chatBackend: .antigravity)
            case "grok", "grok-build", "xai", "grok-agent":
                return CLIAgentMissionBackend(rawValue: "grok", displayName: "Grok Build")
            case "opencode":
                return CLIAgentMissionBackend(rawValue: "opencode", displayName: "OpenCode")
            case "ollama":
                return CLIAgentMissionBackend(rawValue: "ollama", displayName: "Ollama")
            default:
                if let direct = ChatBackendID(rawValue: normalizedRuntime) {
                    return CLIAgentMissionBackend(chatBackend: direct)
                }
            }
        }

        func firstEnabled(_ ordered: [ChatBackendID]) -> ChatBackendID? {
            ordered.first { enabledBackends.contains($0) }
        }

        switch missionKind {
        case "diligence", "security":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.claude, .codex, .hermes, .piAgent, .openclaw, .droid, .forge, .antigravity]) ?? .codex)
        case "creative", "accretive", "ui_improvement", "custom":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.openclaw, .antigravity, .codex, .hermes, .piAgent, .claude, .forge, .droid]) ?? .hermes)
        case "debt", "modernization", "provider_routing", "cost_efficiency", "project_focus":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.codex, .claude, .hermes, .piAgent, .openclaw, .droid, .forge, .antigravity]) ?? .codex)
        default:
            return CLIAgentMissionBackend(chatBackend: enabledBackends.first ?? .codex)
        }
    }

    static func prompt(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: [String: Any]
    ) -> String {
        let source = (data["source"] as? String) ?? "mobile-insights"
        let targetProject = (data["targetProject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Mac current workspace"
        let depth = (data["depth"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "standard"
        let approvalMode = (data["approvalMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "existing_policy"
        let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
        let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
        let missionKind = (data["missionKind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if source == "ios-chat" || missionKind == "chat" {
            return """
            You are \(backend.displayName), continuing a normal chat that the user started from OpenBurnBar mobile.

            Source: \(source)
            Target project: \(targetProject)
            Commands allowed: \(commandsAllowed ? "yes" : "no")
            File edits allowed: \(fileEditsAllowed ? "yes" : "no")

            Reply directly to the user's message. Use available local context when the granted permissions allow it; ask for the specific missing context when they do not. Keep the filesystem unchanged unless file edits are granted.

            \(prompt)
            """
        }
        return """
        You are OpenBurnBar Mission Control running from \(backend.displayName) on the user's Mac.

        Mission: \(title)
        Source: \(source)
        Target project: \(targetProject)
        Depth: \(depth)
        Approval mode: \(approvalMode)
        Commands allowed: \(commandsAllowed ? "yes" : "no")
        File edits allowed: \(fileEditsAllowed ? "yes" : "no")

        Execute this as a concrete, useful mission packet. Inspect the repo or local data before making claims when commands are allowed. Produce actionable findings, acceptance criteria, validation commands, risks, and a mobile-readable result summary. If file edits are not allowed, do not modify files; return a patch plan instead. If code changes are warranted and file edits are allowed, keep them scoped and preserve unrelated work.

        \(prompt)
        """
    }

    static func presentationMode(from data: [String: Any]) -> CLIAgentChatPresentationMode {
        let raw = (data["presentationMode"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        return raw.flatMap(CLIAgentChatPresentationMode.init(rawValue:)) ?? .nativeChat
    }

    static func mobileChatClientThreadID(from data: [String: Any]) -> String? {
        let source = ((data["source"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let missionKind = ((data["missionKind"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard source == "ios-chat" || source == "android-chat" || missionKind == "chat" else {
            return nil
        }
        guard let raw = (data["clientThreadID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty,
            raw.count <= 512
        else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return raw
    }

    static func directLaunchPlan(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: [String: Any]
    ) -> CLIAgentMissionDirectLaunchPlan? {
        let hostPrompt = Self.prompt(title: title, prompt: prompt, backend: backend, data: data)
        let requestedModelID = (data["requestedModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch backend.rawValue {
        case ChatBackendID.piAgent.rawValue:
            let modelCommand = """
            model_args=()
            if [ -n "${OPENBURNBAR_MISSION_MODEL:-}" ]; then
              model_args=(--model "$OPENBURNBAR_MISSION_MODEL")
            fi
            pi --no-session --no-tools --mode json "${model_args[@]}" -p "$OPENBURNBAR_MISSION_PROMPT"
            """
            var env = ["OPENBURNBAR_MISSION_PROMPT": hostPrompt]
            if let requestedModelID {
                env["OPENBURNBAR_MISSION_MODEL"] = requestedModelID
            }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "zsh",
                arguments: [
                    "-lc",
                    modelCommand
                ],
                extraEnvironment: env
            )
        case ChatBackendID.openclaw.rawValue:
            let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
            let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
            var arguments = [
                "-p",
                hostPrompt,
                "--no-session-persistence",
                "--output-format",
                "stream-json",
                "--include-partial-messages",
                "--verbose"
            ]
            if commandsAllowed || fileEditsAllowed {
                arguments += ["--permission-mode", "auto"]
                var disallowedTools: [String] = []
                if !commandsAllowed {
                    disallowedTools.append("Bash")
                }
                if !fileEditsAllowed {
                    disallowedTools += ["Edit", "MultiEdit", "Write", "NotebookEdit"]
                }
                if !disallowedTools.isEmpty {
                    arguments += ["--disallowedTools", disallowedTools.joined(separator: ",")]
                }
            } else {
                arguments += ["--permission-mode", "plan", "--tools", ""]
            }
            if let requestedModelID {
                arguments += ["--model", requestedModelID]
            }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "openclaude",
                arguments: arguments,
                extraEnvironment: [:]
            )
        case ChatBackendID.droid.rawValue:
            let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
            let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
            var arguments = [
                "exec",
                "--output-format",
                "json"
            ]
            if let requestedModelID {
                arguments += ["--model", requestedModelID]
            }
            if commandsAllowed {
                arguments += ["--auto", "medium"]
            } else if fileEditsAllowed {
                arguments += ["--auto", "low", "--disabled-tools", "execute-cli"]
            }
            arguments.append(hostPrompt)
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "droid",
                arguments: arguments,
                extraEnvironment: [:]
            )
        case ChatBackendID.forge.rawValue:
            var arguments = ["--prompt", hostPrompt]
            if let requestedModelID,
               ["forge", "muse", "sage"].contains(requestedModelID.lowercased()) {
                arguments = ["--agent", requestedModelID] + arguments
            }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "forge",
                arguments: arguments,
                extraEnvironment: [:]
            )
        case ChatBackendID.antigravity.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "agy",
                arguments: CLIArgumentBuilder.antigravityArguments(prompt: hostPrompt),
                extraEnvironment: [:]
            )
        case "opencode":
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "zsh",
                arguments: [
                    "-lc",
                    "opencode run \"$OPENBURNBAR_MISSION_PROMPT\""
                ],
                extraEnvironment: ["OPENBURNBAR_MISSION_PROMPT": hostPrompt]
            )
        case "ollama":
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "zsh",
                arguments: [
                    "-lc",
                    """
                    model="${OPENBURNBAR_OLLAMA_MODEL:-$(ollama list | awk 'NR==2 { print $1 }')}"
                    if [ -z "$model" ]; then
                      echo "No local Ollama model is installed. Pull a model or set OPENBURNBAR_OLLAMA_MODEL." >&2
                      exit 66
                    fi
                    printf "%s" "$OPENBURNBAR_MISSION_PROMPT" | ollama run "$model"
                    """
                ],
                extraEnvironment: ["OPENBURNBAR_MISSION_PROMPT": hostPrompt]
            )
        case ChatBackendID.codex.rawValue, ChatBackendID.claude.rawValue, ChatBackendID.hermes.rawValue:
            return nil
        default:
            return nil
        }
    }

    static func visibleTerminalLaunchPlan(
        title: String,
        prompt: String,
        backend: CLIAgentMissionBackend,
        data: [String: Any]
    ) -> CLIAgentMissionDirectLaunchPlan? {
        let hostPrompt = Self.prompt(title: title, prompt: prompt, backend: backend, data: data)
        let requestedModelID = (data["requestedModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let grant = capabilityGrant(for: backend, data: data)
        let workingDirectory = workingDirectoryPath(from: data).map { URL(fileURLWithPath: $0, isDirectory: true) }

        switch backend.rawValue {
        case ChatBackendID.codex.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "codex",
                arguments: CLIArgumentBuilder.codexArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.claude.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "claude",
                arguments: CLIArgumentBuilder.claudeArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.droid.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "droid",
                arguments: CLIArgumentBuilder.droidArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    workspaceDirectory: workingDirectory,
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.forge.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "forge",
                arguments: CLIArgumentBuilder.forgeArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    workspaceDirectory: workingDirectory,
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.antigravity.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "agy",
                arguments: CLIArgumentBuilder.antigravityArguments(
                    prompt: hostPrompt,
                    workspaceDirectory: workingDirectory,
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.openclaw.rawValue,
            ChatBackendID.piAgent.rawValue,
            "opencode",
            "ollama":
            return directLaunchPlan(title: title, prompt: prompt, backend: backend, data: data)
        default:
            return nil
        }
    }

    private static func capabilityGrant(
        for backend: CLIAgentMissionBackend,
        data: [String: Any]
    ) -> AgentCapabilityGrant {
        let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
        let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
        var capabilities: Set<AgentDesktopCapability> = [.workspaceRead]
        if commandsAllowed {
            capabilities.insert(.shell)
        }
        if fileEditsAllowed {
            capabilities.insert(.workspaceWrite)
        }
        return AgentCapabilityGrant.sessionGrant(
            runtimeID: assistantRuntimeID(for: backend),
            threadID: (data["clientThreadID"] as? String)?.nilIfEmpty ?? "visible-terminal-\(UUID().uuidString)",
            capabilities: capabilities,
            trustMode: .manual,
            workspaceRootPath: workingDirectoryPath(from: data),
            duration: 60 * 60
        )
    }

    private static func assistantRuntimeID(for backend: CLIAgentMissionBackend) -> AssistantRuntimeID {
        if let chatBackend = backend.chatBackend {
            switch chatBackend {
            case .codex: return .codex
            case .claude: return .claude
            case .openclaw: return .openClaw
            case .droid: return .droid
            case .forge: return .forge
            case .antigravity: return .antigravity
            case .hermes: return .hermes
            case .piAgent: return .pi
            }
        }
        switch backend.rawValue {
        case "openclaw", "open-claw": return .openClaw
        case "droid", "factory": return .droid
        case "forge": return .forge
        case "antigravity", "agy", "google-antigravity": return .antigravity
        case "grok", "grok-build", "xai", "grok-agent": return .grok
        case "pi", "piagent", "pi-agent": return .pi
        default: return .codex
        }
    }

    private static func workingDirectoryPath(from data: [String: Any]) -> String? {
        guard let rawPath = (data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }
        return NSString(string: rawPath).expandingTildeInPath
    }
}

@MainActor
final class LiveCLIAgentMissionDeviceTrustChecker: CLIAgentMissionDeviceTrustChecking {
    private let db: Firestore
    private var preparedDeviceIDs = Set<String>()

    init(db: Firestore = Firestore.firestore()) {
        self.db = db
    }

    func prepareAndValidateTrustedExecutor(uid: String, deviceID: String) async -> CLIAgentMissionDeviceTrustResult {
        let deviceRef = db.collection("users").document(uid)
            .collection("escrow_devices")
            .document(deviceID)
        do {
            let snapshot = try await deviceRef.getDocument()
            if snapshot.exists {
                return validate(snapshot: snapshot, deviceID: deviceID)
            }

            try await registerPendingMac(deviceRef: deviceRef, deviceID: deviceID)
            preparedDeviceIDs.insert(deviceID)
            return .untrusted("This Mac is registered but not approved for mobile mission execution. Approve it in OpenBurnBar Devices and Sync, then launch the mission again.")
        } catch {
            return .untrusted("Mac trust could not be verified before mission execution: \(error.localizedDescription)")
        }
    }

    private func validate(snapshot: DocumentSnapshot, deviceID: String) -> CLIAgentMissionDeviceTrustResult {
        guard let data = snapshot.data() else {
            return .untrusted("This Mac is not registered for trusted device execution.")
        }
        let trustState = (data["trustState"] as? String) ?? EscrowDeviceTrustState.pending.rawValue
        guard trustState == EscrowDeviceTrustState.trusted.rawValue else {
            if !preparedDeviceIDs.contains(deviceID) {
                Task { @MainActor in
                    try? await self.registerPendingMac(deviceRef: snapshot.reference, deviceID: deviceID, mergeOnly: true)
                }
            }
            return .untrusted("This Mac is not approved for mobile mission execution. Approve it in OpenBurnBar Devices and Sync, then launch the mission again.")
        }

        let platform = (data["platform"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard platform?.contains("mac") == true || platform == nil else {
            return .untrusted("The trusted executor record for this device is not a macOS device.")
        }
        return .trusted
    }

    private func registerPendingMac(
        deviceRef: DocumentReference,
        deviceID: String,
        mergeOnly: Bool = false
    ) async throws {
        let now = FieldValue.serverTimestamp()
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "platform": "macOS",
            "deviceName": Host.current().localizedName ?? "OpenBurnBar Mac",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "updatedAt": now
        ]
        if !mergeOnly {
            payload["trustState"] = EscrowDeviceTrustState.pending.rawValue
            payload["createdAt"] = now
        }
        try await deviceRef.setData(payload, merge: true)
    }
}

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

final class MissionCancellationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return _isCancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }; _isCancelled = true
    }
}

@MainActor
final class CLIAgentMissionRequestListener {

    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let chatController: ChatSessionController
    private let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    private let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()
    private var lastAttachState: String?
    private var missionEventSequences: [String: Int] = [:]

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
        missionEventSequences.removeAll()
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
        let cancellationTracker = MissionCancellationTracker()
        let logger = self.logger
        let docID = document.documentID
        let cancellationListener = document.reference.addSnapshotListener { snapshot, _ in
            guard let snapshot = snapshot, snapshot.exists else { return }
            let status = snapshot.data()?["status"] as? String
            if status == "cancelled" || status == "canceled" {
                logger.warning("cancellation signal received for mission id=\(docID, privacy: .public)")
                cancellationTracker.cancel()
            }
        }
        defer { cancellationListener.remove() }

        let data = document.data()
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Insights mission"
        guard let prompt = (data["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else {
            await fail(document: document, message: "Mission prompt was empty.")
            return
        }

        let requestedRuntime = (data["requestedRuntime"] as? String) ?? "auto"
        let requestedModelID = (data["requestedModelID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let missionKind = (data["missionKind"] as? String) ?? "unknown"
        missionEventSequences[document.documentID] = max(
            data["lastEventSequence"] as? Int ?? 1,
            ((data["events"] as? [Any])?.count ?? 1)
        )

        guard let uid = accountManager.currentUID else {
            logger.warning("mission id=\(document.documentID, privacy: .public) ignored because this Mac is not signed in")
            return
        }
        let trustResult = await deviceTrustChecker.prepareAndValidateTrustedExecutor(
            uid: uid,
            deviceID: accountManager.deviceId
        )
        guard trustResult.isTrusted else {
            logger.warning("mission id=\(document.documentID, privacy: .public) refused for untrusted Mac device=\(self.accountManager.deviceId, privacy: .public)")
            return
        }

        let backend = resolveBackend(
            requestedRuntime: requestedRuntime,
            missionKind: data["missionKind"] as? String
        )
        if await shouldPauseForApproval(document: document, data: data, backend: backend) {
            return
        }

        if cancellationTracker.isCancelled {
            await handleCancellation(document: document, backend: backend)
            return
        }

        logger.info("claiming mission id=\(document.documentID, privacy: .public) kind=\(missionKind, privacy: .public) requested=\(requestedRuntime, privacy: .public) selected=\(backend.rawValue, privacy: .public) model=\(requestedModelID ?? "auto", privacy: .public)")
        do {
            var claimPayload: [String: Any] = [
                "status": "accepted",
                "claimedBy": accountManager.deviceId,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "liveSummary": requestedModelID.map { "\(backend.displayName) claimed the mission on this Mac with model \($0)." }
                    ?? "\(backend.displayName) claimed the mission on this Mac.",
                "lastEventSequence": FieldValue.increment(Int64(1)),
                "startedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let requestedModelID {
                claimPayload["selectedModelID"] = requestedModelID
            }
            try await document.reference.setData(claimPayload, merge: true)
            await recordEvent(
                reference: document.reference,
                requestID: document.documentID,
                phase: "accepted",
                kind: "status",
                title: "Accepted",
                message: requestedModelID.map { "\(backend.displayName) claimed the mission on this Mac with model \($0)." }
                    ?? "\(backend.displayName) claimed the mission on this Mac.",
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
            try await document.reference.setData([
                "status": "starting",
                "liveSummary": requestedModelID.map { "Starting \(backend.displayName) with model \($0)." }
                    ?? "Starting \(backend.displayName) with the mission prompt.",
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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
            try await document.reference.setData([
                "status": "running",
                "liveSummary": requestedModelID.map { "\(backend.displayName) is running \($0) on this Mac." }
                    ?? "\(backend.displayName) is running on this Mac.",
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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
                "resultPreview": safeDirectOutput,
                "liveSummary": directResult.status == "completed"
                    ? modelAwareSuccessMessage(backend: backend, requestedModelID: requestedModelID, fallback: safeDirectOutput)
                    : directFailure ?? modelAwareFailureMessage(backend: backend, requestedModelID: requestedModelID, errorMessage: nil),
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let requestedModelID {
                payload["selectedModelID"] = requestedModelID
            }
            if let errorMessage = directResult.errorMessage {
                payload["errorMessage"] = CLIAgentMissionEventFactory.mobileSafeText(
                    modelAwareFailureMessage(
                        backend: backend,
                        requestedModelID: requestedModelID,
                        errorMessage: errorMessage
                    )
                )
            }
            do {
                try await document.reference.setData(payload, merge: true)
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
                let streamingMessage = deriveStreamingStatusMessage(
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
            try? await Task.sleep(nanoseconds: 500_000_000)
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
            "liveSummary": liveSummary,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let requestedModelID {
            payload["selectedModelID"] = requestedModelID
        }
        if let streamError = chatController.streamError {
            payload["errorMessage"] = CLIAgentMissionEventFactory.mobileSafeText(
                modelAwareFailureMessage(
                    backend: backend,
                    requestedModelID: requestedModelID,
                    errorMessage: streamError
                )
            )
        } else {
            payload["resultPreview"] = safeFinalSummary
        }
        do {
            try await document.reference.setData(payload, merge: true)
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

    private func handleCancellation(document: QueryDocumentSnapshot, backend: CLIAgentMissionBackend) async {
        logger.warning("handling cancellation for mission id=\(document.documentID, privacy: .public)")
        do {
            try await document.reference.setData([
                "status": "cancelled",
                "liveSummary": "Mission cancelled by user.",
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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

    private func modelAwareSuccessMessage(
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

    private func modelAwareFailureMessage(
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

    private func fail(document: QueryDocumentSnapshot, message: String) async {
        let safeMessage = CLIAgentMissionEventFactory.mobileSafeText(message, limit: 2048)
        do {
            try await document.reference.setData([
                "status": "failed",
                "errorMessage": safeMessage,
                "liveSummary": safeMessage,
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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

    private func shouldPauseForApproval(
        document: QueryDocumentSnapshot,
        data: [String: Any],
        backend: CLIAgentMissionBackend
    ) async -> Bool {
        let approvalStatus = ((data["approvalStatus"] as? String) ?? "none").lowercased()
        let status = ((data["status"] as? String) ?? "pending").lowercased()
        if approvalStatus == "approved" {
            return false
        }
        if approvalStatus == "rejected" || approvalStatus == "canceled" || approvalStatus == "cancelled" {
            await cancelAfterApprovalDecision(document: document, approvalStatus: approvalStatus)
            return true
        }
        guard missionRequiresApproval(data: data) else {
            return false
        }
        if status == "waiting_for_approval" {
            return true
        }
        await requestApproval(document: document, data: data, backend: backend)
        return true
    }

    private func missionRequiresApproval(data: [String: Any]) -> Bool {
        InsightMissionApprovalPolicy.requiresPreDispatchApproval(
            approvalMode: data["approvalMode"] as? String,
            commandsAllowed: (data["commandsAllowed"] as? Bool) ?? false,
            fileEditsAllowed: (data["fileEditsAllowed"] as? Bool) ?? false
        )
    }

    private func requestApproval(
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
            try await document.reference.setData([
                "status": "waiting_for_approval",
                "claimedBy": accountManager.deviceId,
                "approvalRequestId": approvalID,
                "approvalStatus": "pending",
                "approvalRequestedAt": ISO8601DateFormatter().string(from: Date()),
                "approvalTitle": "Approve \(title)",
                "approvalMessage": message,
                "selectedRuntime": backend.rawValue,
                "selectedRuntimeName": backend.displayName,
                "liveSummary": message,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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

    private func cancelAfterApprovalDecision(document: QueryDocumentSnapshot, approvalStatus: String) async {
        let message = approvalStatus == "rejected"
            ? "Mission approval was rejected from mobile."
            : "Mission approval was canceled from mobile."
        do {
            try await document.reference.setData([
                "status": "canceled",
                "liveSummary": message,
                "errorMessage": message,
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
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

    private func resolveBackend(requestedRuntime: String?, missionKind: String?) -> CLIAgentMissionBackend {
        CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: requestedRuntime,
            missionKind: missionKind,
            enabledBackends: settingsManager.enabledChatBackends
        )
    }

    private func missionPrompt(title: String, prompt: String, backend: CLIAgentMissionBackend, data: [String: Any]) -> String {
        CLIAgentMissionRuntimePlanner.prompt(
            title: title,
            prompt: prompt,
            backend: backend,
            data: data
        )
    }

    private struct DirectCLIMissionResult {
        let status: String
        let output: String
        let errorMessage: String?
        let sessionID: String
    }

    fileprivate struct DirectCLIStreamEvent: Sendable {
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

    private func runDirectCLIMissionIfNeeded(
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
        // phone attached. Decoded once; nil-safe so missions without a
        // scope keep using the plan's env verbatim.
        let personaOverrides = (try? CLIAgentMissionPersonaScopeApplier.overrides(from: data))
            ?? .empty
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

    private func workingDirectoryURL(from data: [String: Any]) -> URL? {
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

    private func gitChangedFiles(in workingDirectoryURL: URL?) async -> Set<String> {
        let directoryURL = workingDirectoryURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let gitPath = "/usr/bin/git"
        guard FileManager.default.fileExists(atPath: gitPath) else { return [] }

        return await Task.detached(priority: .utility) {
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
        }.value
    }

    private func recordChangedFileEvents(
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

    private func mirrorTranscriptPieces(
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
            }
        }
    }

    private func runVisibleTerminalMission(
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

    private func runVisibleTerminalProcess(
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
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let rootURL = fileManager.temporaryDirectory
                .appendingPathComponent("OpenBurnBarVisibleCLI", isDirectory: true)
            let sessionURL = rootURL.appendingPathComponent(sessionID, isDirectory: true)
            try fileManager.createDirectory(at: sessionURL, withIntermediateDirectories: true)

            let scriptURL = sessionURL.appendingPathComponent("run.command")
            let logURL = sessionURL.appendingPathComponent("terminal.log")
            let exitURL = sessionURL.appendingPathComponent("exit.status")
            let pidURL = sessionURL.appendingPathComponent("terminal.pid")
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

                try await Task.sleep(nanoseconds: 250_000_000)
            }

            Self.killVisibleTerminalSession(pidURL: pidURL)
            throw NSError(
                domain: "OpenBurnBar.VisibleTerminalMission",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "Visible \(backendDisplayName) CLI session timed out after \(Int(timeoutSeconds)) seconds."]
            )
        }.value
    }

    private func runDirectCLIMission(
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

    private func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        extraEnvironment: [String: String],
        workingDirectoryURL: URL?,
        cancellationTracker: MissionCancellationTracker,
        eventSink: @escaping @Sendable (DirectCLIStreamEvent) -> Void
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
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
                    try? killTask.run()
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
                try? killTask.run()
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
        }.value
    }

    private func recordEvent(
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
            try await reference.setData([
                "liveSummary": trimmed.prefix(600).description,
                "lastEventSequence": nextSequence,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
            let eventID = CLIAgentMissionEventFactory.eventID(for: nextSequence)
            try await reference.collection("events").document(eventID).setData(event, merge: false)
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
              let handle = try? FileHandle(forReadingFrom: logURL)
        else { return "" }
        defer { try? handle.close() }
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
        try? process.run()
        process.waitUntilExit()
    }

    private func deriveStreamingStatusMessage(
        assistantMessage: ChatMessageRecord?,
        backend: CLIAgentMissionBackend
    ) -> String {
        let assistantPreview = assistantMessage?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let preview = assistantPreview, !preview.isEmpty {
            let clipped = preview.prefix(420).description
            return clipped
        }
        let latestTool = assistantMessage?.displayTranscript.last(where: { $0.kind == .toolUse })
        if let tool = latestTool {
            let detail = tool.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return detail.map { "\(tool.value): \($0)" } ?? tool.value
        }
        return "\(backend.displayName) is composing a response…"
    }

    private func resultSummary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.nilIfEmpty ?? "Mission finished without a text result."
    }
}

struct CLIAgentMissionEventFactory {
    static func eventID(for sequence: Int) -> String {
        String(format: "%06d", sequence)
    }

    static func event(
        sequence: Int,
        phase: String,
        kind: String,
        title: String?,
        message: String,
        runtime: String?,
        toolName: String?,
        artifactPath: String?,
        changedFilePath: String?,
        isError: Bool
    ) -> [String: Any] {
        let fullMessage = mobileSafeText(message, limit: 24_000)
        let shortMessage = mobileSafeText(message, limit: 600)
        var event: [String: Any] = [
            "sequence": sequence,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "kind": kind,
            "phase": phase,
            "title": title ?? phase.replacingOccurrences(of: "_", with: " ").capitalized,
            "message": shortMessage,
            "fullMessage": fullMessage,
            "messageLength": fullMessage.count,
            "messageTruncated": fullMessage.count < message.count,
            "source": "mac",
            "isError": isError
        ]
        if let runtime {
            event["runtime"] = runtime
        }
        if let toolName { event["toolName"] = toolName.prefix(120).description }
        if let artifactPath { event["artifactPath"] = artifactPath.prefix(512).description }
        if let changedFilePath { event["changedFilePath"] = changedFilePath.prefix(512).description }
        return event
    }

    static func redactSecrets(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"(?i)(api[_-]?key|token|secret|password|authorization)\s*[:=]\s*['"]?[^'"\s]{8,}"#,
            #"(?i)bearer\s+[a-z0-9._\-]{12,}"#,
            #"[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "[REDACTED]",
                options: [.regularExpression]
            )
        }
        return redacted
    }

    static func mobileSafeText(_ text: String, limit: Int = 600) -> String {
        redactSecrets(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .prefix(limit)
            .description
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private final class DirectCLIStreamMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var assistantDeltaBuffer = ""
    private var assistantDeltaTranscript = ""
    private var latestAssistantMessage = ""
    private var latestResultText = ""
    private var lastReasoningEventCount = 0
    private let assistantDeltaFlushThreshold = 480
    private let reasoningEventStep = 500

    func consumeStdout(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: &stdoutBuffer, eventSink: eventSink)
    }

    func consumeStderr(
        _ text: String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        consume(text, buffer: &stderrBuffer, eventSink: eventSink)
    }

    private func consume(
        _ text: String,
        buffer: inout String,
        eventSink: @escaping @Sendable (CLIAgentMissionRequestListener.DirectCLIStreamEvent) -> Void
    ) -> Bool {
        let incomingLooksStructured = text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
        lock.lock()
        buffer += text
        let lines = buffer.components(separatedBy: .newlines)
        buffer = lines.last ?? ""
        let bufferedLooksStructured = buffer.trimmingCharacters(in: .whitespacesAndNewlines).first == "{"
        let completeLines = lines.dropLast()
        lock.unlock()

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

    private func parseJSONLine(_ line: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        guard line.first == "{",
              let data = line.data(using: .utf8),
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

    private func parseOpenClaude(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
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

    private func parsePi(object: [String: Any], type: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
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
                    lastReasoningEventCount = 0
                    return .toolResult("Reasoning stream started.", title: "Reasoning")
                }
                if updateType == "thinking_end" {
                    lastReasoningEventCount = count
                    return .toolResult("Reasoning stream completed (\(count) chars available from runtime).", title: "Reasoning")
                }
                guard count >= lastReasoningEventCount + reasoningEventStep else {
                    return nil
                }
                lastReasoningEventCount = count
                return .toolResult("Reasoning stream updated (\(count) chars available from runtime).", title: "Reasoning")
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

    private func appendAssistantDelta(_ text: String) -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        assistantDeltaTranscript += text
        assistantDeltaBuffer += text
        let shouldFlush = assistantDeltaBuffer.count >= assistantDeltaFlushThreshold
            || text.contains("\n")
            || text.contains(". ")
            || text.contains(": ")
        guard shouldFlush else { return nil }
        return flushAssistantDelta()
    }

    private func flushAssistantDelta() -> CLIAgentMissionRequestListener.DirectCLIStreamEvent? {
        let text = assistantDeltaBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        assistantDeltaBuffer = ""
        return text.nilIfEmpty.map { .assistant($0, title: "Assistant delta") }
    }

    private func parseAssistantMessage(
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

    private func formatUsage(_ usage: [String: Any]) -> String {
        usage.keys.sorted().map { key in
            "\(key)=\(usage[key] ?? "")"
        }.joined(separator: "\n")
    }

    private func storeAssistantMessage(_ text: String) {
        latestAssistantMessage = text
    }

    private func storeResultText(_ text: String) {
        latestResultText = text
    }

    func finalOutputSnapshot(fallback: String?) -> String {
        _ = flushAssistantDelta()
        let candidates = [
            latestResultText,
            latestAssistantMessage,
            assistantDeltaTranscript,
            fallback ?? ""
        ]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutStorage = ""
    private var stderrStorage = ""

    func appendStdout(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        stdoutStorage += text
    }

    func appendStderr(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        stderrStorage += text
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutStorage, stderrStorage)
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
    private let accountManager: AccountManaging
    private let settingsManager: SettingsManager
    private let dataStore: DataStore
    private let cloudSyncService: CloudSyncService?
    private let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    private let firestoreProvider: () -> Firestore
    private let parserFactory: (AgentProvider) -> (any LogParser)?
    private let logger = Logger(subsystem: "com.openburnbar.app", category: "AgentHarnessImportJobListener")

    private var listener: ListenerRegistration?
    private var listenerUID: String?
    private var attachTask: Task<Void, Never>?
    private var processingDocs = Set<String>()

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        dataStore: DataStore,
        cloudSyncService: CloudSyncService?,
        deviceTrustChecker: CLIAgentMissionDeviceTrustChecking = LiveCLIAgentMissionDeviceTrustChecker(),
        firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() },
        parserFactory: @escaping (AgentProvider) -> (any LogParser)? = { ParserRegistry.defaultParsers()[$0] }
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
                try dataStore.insertChunked(allUsages)
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
            try? await document.reference.setData([
                "status": "failed",
                "errorMessage": "Import failed after scanning: \(error.localizedDescription)".prefixString(2048),
                "progressMessage": "Import failed after scanning.",
                "completedAt": ISO8601DateFormatter().string(from: Date()),
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    private func claimImportJob(reference: DocumentReference, providers: [AgentProvider]) async throws -> Bool {
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

    private static func provider(for harness: String) -> AgentProvider? {
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
