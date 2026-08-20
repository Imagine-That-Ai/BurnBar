import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

// Mission runtime planner, live device-trust checker, cancellation tracker.

enum CLIAgentMissionRuntimePlanner {
    static func resolve(
        requestedRuntime: String?,
        missionKind: String?,
        enabledBackends: [ChatBackendID]
    ) -> CLIAgentMissionBackend {
        if let requestedRuntime,
           requestedRuntime != "auto" {
            let normalizedRuntime = requestedRuntime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // The wire catalog's schema rejects aliases containing spaces, so a
            // human phrasing like "oh my pi" is folded to its hyphenated wire token
            // before lookup rather than carried as a second, GUI-only alias table.
            let wireToken = normalizedRuntime.replacingOccurrences(of: " ", with: "-")
            // One alias table, not five. `MissionRuntimeCatalog` is generated from
            // tools/schema-sync/fixtures/mission-runtime-catalog.json into Swift,
            // Kotlin, C#, TypeScript and firestore.rules, so a runtime token the GUI
            // accepts is one every other surface accepts too. Hand-maintaining the
            // aliases here is what let "vercel-fx" drift into being GUI-only.
            switch MissionRuntimeCatalog.generated.canonicalID(for: wireToken) ?? wireToken {
            case "pi":
                return CLIAgentMissionBackend(chatBackend: .piAgent)
            case "claude":
                return CLIAgentMissionBackend(chatBackend: .claude)
            case "openclaw":
                return CLIAgentMissionBackend(chatBackend: .openclaw)
            case "openclaude":
                return CLIAgentMissionBackend(chatBackend: .openClaude)
            case "omp":
                return CLIAgentMissionBackend(chatBackend: .omp)
            case "droid":
                return CLIAgentMissionBackend(chatBackend: .droid)
            case "forge":
                return CLIAgentMissionBackend(chatBackend: .forge)
            // Gemini ships to users inside Antigravity; there is no separate backend.
            case "antigravity", "gemini":
                return CLIAgentMissionBackend(chatBackend: .antigravity)
            case "cursoragent":
                return CLIAgentMissionBackend(chatBackend: .cursorAgent)
            case "fx":
                return CLIAgentMissionBackend(chatBackend: .fx)
            case "grok":
                return CLIAgentMissionBackend(chatBackend: .grok)
            case "kimi":
                return CLIAgentMissionBackend(chatBackend: .kimi)
            case "opencode":
                return CLIAgentMissionBackend(rawValue: "opencode", displayName: "OpenCode")
            case "ollama":
                return CLIAgentMissionBackend(rawValue: "ollama", displayName: "Ollama")
            default:
                if let direct = ChatBackendID(rawValue: normalizedRuntime) {
                    return CLIAgentMissionBackend(chatBackend: direct)
                }
                return CLIAgentMissionBackend(rawValue: normalizedRuntime, displayName: requestedRuntime)
            }
        }

        func firstEnabled(_ ordered: [ChatBackendID]) -> ChatBackendID? {
            ordered.first { enabledBackends.contains($0) }
        }

        switch missionKind {
        case "diligence", "security":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.claude, .codex, .hermes, .piAgent, .openclaw, .droid, .forge, .antigravity, .cursorAgent, .junie, .fx]) ?? .codex)
        case "creative", "accretive", "ui_improvement", "custom":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.openclaw, .antigravity, .cursorAgent, .codex, .hermes, .piAgent, .claude, .forge, .droid, .junie, .fx]) ?? .hermes)
        case "debt", "modernization", "provider_routing", "cost_efficiency", "project_focus":
            return CLIAgentMissionBackend(chatBackend: firstEnabled([.codex, .claude, .hermes, .piAgent, .openclaw, .droid, .forge, .antigravity, .cursorAgent, .junie, .fx]) ?? .codex)
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

        Execute this as a concrete, useful mission packet. Inspect the repo or local data before making claims when commands are allowed. Produce actionable findings, acceptance criteria, validation commands, risks, and a mobile-readable result summary. \
        If file edits are not allowed, do not modify files; return a patch plan instead. If code changes are warranted and file edits are allowed, keep them scoped and preserve unrelated work.

        \(prompt)
        """
    }

    static func presentationMode(from data: [String: Any]) -> CLIAgentChatPresentationMode {
        let raw = (data["presentationMode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return raw.flatMap(CLIAgentChatPresentationMode.init(rawValue:)) ?? .nativeChat
    }

    static func requiresMacCLIAssistantConsentForRemoteMission(
        backend: CLIAgentMissionBackend
    ) -> Bool {
        if let chatBackend = backend.chatBackend {
            switch chatBackend {
            case .hermes:
                return false
            case .codex, .claude, .openclaw, .piAgent, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx, .grok, .kimi:
                return true
            }
        }

        switch backend.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "opencode", "ollama":
            return true
        default:
            return false
        }
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
        let source = (data["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let missionKind = (data["missionKind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isInteractiveChat = source == "ios-chat" || source == "android-chat" || missionKind == "chat"
        switch backend.rawValue {
        case ChatBackendID.codex.rawValue where !isInteractiveChat, ChatBackendID.claude.rawValue where !isInteractiveChat:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: backend.rawValue,
                arguments: CLIArgumentBuilder.directMissionArguments(
                    runtime: backend.rawValue,
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    capabilityGrant: capabilityGrant(for: backend, data: data)
                ),
                extraEnvironment: [:]
            )
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
        case ChatBackendID.omp.rawValue:
            let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
            let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
            var arguments = [
                "-p",
                hostPrompt,
                "--mode",
                "json",
                "--no-session"
            ]
            if commandsAllowed || fileEditsAllowed {
                var tools = ["read", "grep", "glob", "lsp"]
                if commandsAllowed {
                    tools.append("bash")
                }
                if fileEditsAllowed {
                    tools += ["edit", "write"]
                }
                let dedupedTools = (Array(NSOrderedSet(array: tools)) as? [String] ?? tools)
                    .joined(separator: ",")
                arguments += ["--tools", dedupedTools]
            } else {
                arguments.append("--no-tools")
            }
            if let requestedModelID {
                arguments += ["--model", requestedModelID]
            }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "omp",
                arguments: arguments,
                extraEnvironment: [:]
            )
        case ChatBackendID.openClaude.rawValue:
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
                var allowedTools: [String] = []
                if commandsAllowed {
                    allowedTools.append("Bash")
                }
                if fileEditsAllowed {
                    allowedTools += ["Edit", "MultiEdit", "Write", "NotebookEdit"]
                }
                if !allowedTools.isEmpty {
                    arguments += ["--allowedTools", allowedTools.joined(separator: ",")]
                }
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
                if fileEditsAllowed {
                    arguments += ["--permission-mode", "acceptEdits"]
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
        case ChatBackendID.cursorAgent.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "cursor-agent",
                arguments: CLIArgumentBuilder.cursorAgentArguments(prompt: hostPrompt, model: requestedModelID ?? ""),
                extraEnvironment: [:]
            )
        case ChatBackendID.fx.rawValue:
            // fx has enforceable permission flags: `--auto` only under the full
            // desktop grant, never `--yolo`; default mode exits before running
            // unresolved sensitive calls (fail closed).
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "fx",
                arguments: CLIArgumentBuilder.fxArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    capabilityGrant: capabilityGrant(for: backend, data: data)
                ),
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
        case ChatBackendID.hermes.rawValue:
            var arguments = [
                "chat",
                "--query",
                hostPrompt,
                "--source",
                "openburnbar-mobile-cli",
                "--accept-hooks"
            ]
            if let requestedModelID {
                arguments += ["--model", requestedModelID]
            }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "hermes",
                arguments: arguments,
                extraEnvironment: [:]
            )
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
        case ChatBackendID.codex.rawValue, ChatBackendID.claude.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: backend.rawValue,
                arguments: CLIArgumentBuilder.directMissionArguments(
                    runtime: backend.rawValue,
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
        case ChatBackendID.junie.rawValue:
            guard CLIAgentJunieMissionPolicy.hasFullDesktopCapabilities(grant) else { return nil }
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "junie",
                arguments: CLIArgumentBuilder.junieArguments(
                    prompt: hostPrompt,
                    model: requestedModelID ?? "",
                    workspaceDirectory: workingDirectory,
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.fx.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "fx",
                arguments: CLIArgumentBuilder.fxArguments(
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
        case ChatBackendID.cursorAgent.rawValue:
            return CLIAgentMissionDirectLaunchPlan(
                executableName: "cursor-agent",
                arguments: CLIArgumentBuilder.cursorAgentArguments(
                    prompt: hostPrompt, model: requestedModelID ?? "",
                    workspaceDirectory: workingDirectory,
                    capabilityGrant: grant
                ),
                extraEnvironment: [:]
            )
        case ChatBackendID.openClaude.rawValue,
            ChatBackendID.omp.rawValue,
            ChatBackendID.hermes.rawValue,
            ChatBackendID.piAgent.rawValue,
            "opencode",
            "ollama":
            return directLaunchPlan(title: title, prompt: prompt, backend: backend, data: data)
        default:
            return nil
        }
    }
    static func capabilityGrant(
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
            runtimeID: assistantRuntimeID(for: backend) ?? .hermes,
            threadID: (data["clientThreadID"] as? String)?.nilIfEmpty ?? "visible-terminal-\(UUID().uuidString)",
            capabilities: capabilities,
            trustMode: .manual,
            workspaceRootPath: workingDirectoryPath(from: data),
            duration: 60 * 60
        )
    }

    static func assistantRuntimeID(for backend: CLIAgentMissionBackend) -> AssistantRuntimeID? {
        if let chatBackend = backend.chatBackend {
            switch chatBackend {
            case .codex: return .codex
            case .claude: return .claude
            case .openclaw: return .openClaw
            case .openClaude: return .openClaude
            case .omp: return .omp
            case .droid: return .droid
            case .forge: return .forge
            case .antigravity: return .antigravity
            case .cursorAgent: return .cursorAgent
            case .hermes: return .hermes
            case .piAgent: return .pi
            case .junie: return .junie
            case .fx: return .fx
            case .grok: return .grok
            // Kimi has no AssistantRuntimeID of its own yet, so its missions are
            // reported under Grok's runtime identity. Giving Kimi a first-class
            // runtime cascades through 40+ exhaustive switches across macOS and
            // iOS and is tracked separately; this fold is the honest status quo,
            // not the intended end state.
            case .kimi: return .grok
            }
        }
        // Same generated catalog as `resolve`, for the same reason: the raw token may
        // be any wire alias, and every canonical id but these two already equals its
        // AssistantRuntimeID raw value.
        let canonical = MissionRuntimeCatalog.generated
            .canonicalID(for: backend.rawValue.replacingOccurrences(of: " ", with: "-"))
            ?? backend.rawValue
        switch canonical {
        case "cursoragent": return .cursorAgent
        case "gemini": return .antigravity
        default: return AssistantRuntimeID(rawValue: canonical)
        }
    }

    static func workingDirectoryPath(from data: [String: Any]) -> String? {
        guard let rawPath = (data["targetProject"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        else { return nil }
        return NSString(string: rawPath).expandingTildeInPath
    }
}
@MainActor
final class LiveCLIAgentMissionDeviceTrustChecker: CLIAgentMissionDeviceTrustChecking {
    let db: Firestore
    var preparedDeviceIDs = Set<String>()

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
            return .untrusted(
                "This Mac is registered but not approved for mobile mission execution. Approve it in OpenBurnBar Devices and Sync, then launch the mission again.",
                rawTrustState: EscrowDeviceTrustState.pending.rawValue)
        } catch {
            // rawTrustState defaults to unknown (fail closed).
            return .untrusted("Mac trust could not be verified before mission execution: \(error.localizedDescription)")
        }
    }

    func validate(snapshot: DocumentSnapshot, deviceID: String) -> CLIAgentMissionDeviceTrustResult {
        guard let data = snapshot.data() else {
            return .untrusted("This Mac is not registered for trusted device execution.")
        }
        let trustState = (data["trustState"] as? String) ?? EscrowDeviceTrustState.pending.rawValue
        guard trustState == EscrowDeviceTrustState.trusted.rawValue else {
            if !preparedDeviceIDs.contains(deviceID) {
                Task { @MainActor in
                    // Best-effort metadata refresh; the untrusted verdict above is fixed, and failures are logged.
                    do {
                        try await self.registerPendingMac(
                            deviceRef: snapshot.reference,
                            deviceID: deviceID,
                            mergeOnly: true
                        )
                    } catch {
                        AppLogger.sync.error(
                            "mission_pending_mac_refresh_failed",
                            metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                        )
                    }
                }
            }
            // Forward the RAW escrow state (pending/revoked → typed daemon denial;
            // unrecognized → fail closed as unknown).
            return .untrusted(
                "This Mac is not approved for mobile mission execution. Approve it in OpenBurnBar Devices and Sync, then launch the mission again.",
                rawTrustState: EscrowDeviceTrustState(rawValue: trustState)?.rawValue ?? MissionRemoteExecutorTrustState.unknown)
        }

        let platform = (data["platform"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard platform?.contains("mac") == true || platform == nil else {
            // Trusted escrow record but not a macOS executor → fail closed (unknown).
            return .untrusted("The trusted executor record for this device is not a macOS device.")
        }
        return .trusted
    }

    func registerPendingMac(
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
//
// Mac-side remote-control listener. iOS/iPadOS/Android publish pending
// mission requests at:
//
//   users/{uid}/cli_agent_mission_requests/{requestID}
//
// The Mac claims each request, runs it through the same local ChatSessionController
// used by the desktop chat surface, and the existing CLIAgentSessionMirror writes
// Codex / Claude / OpenClaw transcripts back to `cli_sessions` for mobile viewing.
final class MissionCancellationTracker: Sendable {
    let _isCancelled = Locked(false)
    var isCancelled: Bool { _isCancelled.read() }
    func cancel() { _isCancelled.write(true) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
