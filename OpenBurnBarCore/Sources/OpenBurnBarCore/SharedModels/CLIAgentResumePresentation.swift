import Foundation

// MARK: - CLI Agent Resume / Handoff presentation layer
//
// Pure-Foundation presentation helpers shared by the macOS app (AgentLens)
// and the iOS/iPadOS app (OpenBurnBarMobile) so the cross-provider CLI
// session restart / handoff UI shows identical target lists, capability
// badges, and outcome copy on every surface. Rendering (colors, logos,
// motion) lives in the app targets; identity, capability, and human copy
// live here so they stay in sync and are unit-tested.
//
// Source of truth: the daemon's `BurnBarResumeService`. The capability
// table below mirrors `BurnBarResumeService.providerSupport(_:)` and the
// canonical ids mirror `BurnBarResumeService.normalizeProvider(_:)`. The
// daemon remains the executor and the relay/daemon response is always the
// source of truth for what actually happened — these helpers only describe
// it.

// MARK: Native-resume capability

/// Whether a provider supports a true in-place *native* resume (continuing
/// the underlying provider session) versus only a Mac-local *handoff*
/// package (a rendered briefing the target CLI is launched with).
///
/// - Parameter wireID: A daemon-canonical provider id, i.e. a value already
///   normalized by `BurnBarResumeService.normalizeProvider`.
///
/// This MUST mirror `BurnBarResumeService.providerSupport(_:).supportsNativeResume`.
/// Only Claude Code and Codex can natively resume today; every other
/// provider receives a handoff package. Keep this in sync if the daemon
/// table changes — `HermesRelayContractTests` pins the expected set.
public func cliAgentProviderSupportsNativeResume(canonicalWireID wireID: String) -> Bool {
    switch wireID {
    case "claude_code", "codex":
        return true
    default:
        return false
    }
}

/// The capability badge shown next to a provider in the "Resume in…" picker.
public enum CLIAgentResumeCapability: String, Hashable, Sendable, CaseIterable {
    /// The provider can continue its own session in place.
    case native
    /// The provider receives a Mac-local handoff package (rendered briefing).
    case handoff

    /// Short, calm label shown on the capability chip.
    public var label: String {
        switch self {
        case .native:  return "Native"
        case .handoff: return "Handoff"
        }
    }

    /// One-line explanation used as secondary copy / accessibility hint.
    public var explanation: String {
        switch self {
        case .native:  return "Continues the original session in place."
        case .handoff: return "Opens a Mac-local handoff package."
        }
    }

    public var systemImageName: String {
        switch self {
        case .native:  return "bolt.fill"
        case .handoff: return "shippingbox.fill"
        }
    }
}

// MARK: Resume targets

/// A provider a mirrored CLI session can be restarted into via "Resume in…".
///
/// Broader than `CLIAgentRuntime` because the Mac can hand a session off to
/// providers the mobile apps don't natively chat with (OpenCode, Gemini
/// CLI). The `rawValue`/`wireID` is the daemon-canonical id that
/// `BurnBarResumeService.normalizeProvider` resolves to itself, so it is
/// safe to send verbatim as `CLIAgentSessionActionRequest.targetRuntime`.
public enum CLIAgentResumeTarget: String, CaseIterable, Hashable, Sendable, Identifiable {
    case claudeCode = "claude_code"
    case codex
    case droid
    case forge
    case antigravity
    case grok
    case cursorAgent = "cursor_agent"
    case opencode
    case gemini

    public var id: String { rawValue }

    /// Canonical identifier sent as `targetRuntime`. Mirrors the daemon's
    /// `normalizeProvider` canonical output so it round-trips unchanged.
    public var wireID: String { rawValue }

    /// Short, product-facing provider name (matches the launch brief).
    public var displayName: String {
        switch self {
        case .claudeCode:  return "Claude Code"
        case .codex:       return "Codex"
        case .droid:       return "Droid"
        case .forge:       return "Forge"
        case .antigravity: return "Antigravity"
        case .grok:        return "Grok"
        case .cursorAgent: return "Cursor Agent"
        case .opencode:    return "OpenCode"
        case .gemini:      return "Gemini CLI"
        }
    }

    public var supportsNativeResume: Bool {
        cliAgentProviderSupportsNativeResume(canonicalWireID: wireID)
    }

    public var capability: CLIAgentResumeCapability {
        supportsNativeResume ? .native : .handoff
    }

    /// Brand identity used to resolve a logo + color on each platform.
    public var agentProvider: AgentProvider {
        switch self {
        case .claudeCode:  return .claudeCode
        case .codex:       return .codex
        case .droid:       return .factory
        case .forge:       return .forgeDev
        case .antigravity: return .antigravity
        case .grok:        return .xAI
        case .cursorAgent: return .cursorAgent
        case .opencode:    return .openCode
        case .gemini:      return .geminiCLI
        }
    }

    /// The mobile CLI runtime this target corresponds to, when the mobile
    /// app hosts a first-class chat surface for it. `nil` for handoff-only
    /// targets the mobile app doesn't natively host (OpenCode, Gemini CLI).
    public var cliRuntime: CLIAgentRuntime? {
        switch self {
        case .claudeCode:  return .claude
        case .codex:       return .codex
        case .droid:       return .droid
        case .forge:       return .forge
        case .antigravity: return .antigravity
        case .grok:        return .grok
        case .cursorAgent: return .cursorAgent
        case .opencode, .gemini: return nil
        }
    }

    /// A stable, readable brand hex (no leading `#`) so both Swift platforms
    /// can tint chips consistently. Greys for monochrome brands are lifted
    /// for legibility on dark surfaces.
    public var brandHex: String {
        switch self {
        case .claudeCode:  return "CC785C"
        case .codex:       return "2563EB"
        case .droid:       return "8B5CF6"
        case .forge:       return "F97316"
        case .antigravity: return "6C63FF"
        case .grok:        return "71767B"
        case .cursorAgent: return "00B8D4"
        case .opencode:    return "0EA5E9"
        case .gemini:      return "4285F4"
        }
    }

    /// The resume target matching a mobile runtime, if one exists.
    public static func forRuntime(_ runtime: CLIAgentRuntime) -> CLIAgentResumeTarget? {
        CLIAgentResumeTarget(rawValue: runtime.canonicalProviderID)
    }
}

// MARK: CLIAgentRuntime canonical identity

extension CLIAgentRuntime {
    /// The daemon-canonical provider id for this runtime, matching
    /// `BurnBarResumeService.normalizeProvider`. Use this (not `rawValue`)
    /// when sending `targetRuntime` so handoff targets resolve correctly —
    /// `rawValue` for `.cursorAgent` is `"cursoragent"`, which the daemon
    /// does **not** canonicalize to `"cursor_agent"`.
    public var canonicalProviderID: String {
        switch self {
        case .codex:       return "codex"
        case .claude:      return "claude_code"
        case .openClaw:    return "openclaw"
        case .droid:       return "droid"
        case .forge:       return "forge"
        case .antigravity: return "antigravity"
        case .grok:        return "grok"
        case .cursorAgent: return "cursor_agent"
        }
    }

    /// Whether this runtime can natively resume its own session in place.
    public var supportsNativeResume: Bool {
        cliAgentProviderSupportsNativeResume(canonicalWireID: canonicalProviderID)
    }

    /// The matching resume target, when this runtime is also a first-class
    /// "Resume in…" destination (`.openClaw` has no target — handoff only).
    public var resumeTarget: CLIAgentResumeTarget? {
        CLIAgentResumeTarget(rawValue: canonicalProviderID)
    }
}

// MARK: Status presentation

/// How to present a single `CLIAgentSessionActionStatus` outcome — the
/// confident title, the compact pill label, an icon, and whether it is a
/// success. Copy follows the launch brief.
public struct CLIAgentSessionActionStatusPresentation: Hashable, Sendable {
    public let title: String
    public let shortLabel: String
    public let systemImageName: String
    public let isSuccess: Bool

    public init(title: String, shortLabel: String, systemImageName: String, isSuccess: Bool) {
        self.title = title
        self.shortLabel = shortLabel
        self.systemImageName = systemImageName
        self.isSuccess = isSuccess
    }
}

extension CLIAgentSessionActionStatus {
    public var presentation: CLIAgentSessionActionStatusPresentation {
        switch self {
        case .nativeResume:
            return .init(title: "Native resume", shortLabel: "Native",
                         systemImageName: "bolt.fill", isSuccess: true)
        case .handoff:
            return .init(title: "Handoff package started", shortLabel: "Handoff",
                         systemImageName: "shippingbox.fill", isSuccess: true)
        case .packageOnly:
            return .init(title: "Package ready", shortLabel: "Package",
                         systemImageName: "doc.zipper", isSuccess: true)
        case .spawned:
            return .init(title: "Opened on Mac", shortLabel: "Opened",
                         systemImageName: "macwindow", isSuccess: true)
        case .error:
            return .init(title: "Couldn’t restart", shortLabel: "Error",
                         systemImageName: "exclamationmark.triangle.fill", isSuccess: false)
        }
    }

    public var isSuccess: Bool { presentation.isSuccess }
}

// MARK: Outcome model

/// A fully-resolved, display-ready summary of a completed session action.
/// Built from the relay/daemon response (the source of truth) plus the
/// target the user requested. Platforms render `headline` / `detail` /
/// `recovery` directly so copy is identical everywhere.
public struct CLIAgentResumeOutcome: Hashable, Sendable {
    public let status: CLIAgentSessionActionStatus
    public let isSuccess: Bool
    /// Confident one-line headline, e.g. "Native resume · Claude Code".
    public let headline: String
    /// Optional secondary line: PID, package file, command, or working dir.
    public let detail: String?
    /// Calm recovery copy, present only for the error outcome.
    public let recovery: String?
    /// Resolved target display name, when known.
    public let targetDisplayName: String?

    public init(
        response: CLIAgentSessionActionResponse,
        requestedTargetDisplayName: String? = nil
    ) {
        let status = response.status
        self.status = status
        self.isSuccess = status.isSuccess

        let resolvedTarget = requestedTargetDisplayName
            ?? response.targetRuntime.flatMap(CLIAgentResumeOutcome.displayName(forWireID:))
        self.targetDisplayName = resolvedTarget

        let base = status.presentation.title
        if status != .error, let resolvedTarget, !resolvedTarget.isEmpty {
            self.headline = "\(base) · \(resolvedTarget)"
        } else {
            self.headline = base
        }

        switch status {
        case .error:
            self.detail = nil
            self.recovery = CLIAgentResumeOutcome.nonEmpty(response.errorRecovery)
                ?? CLIAgentResumeOutcome.nonEmpty(response.errorCode.map { "Error: \($0)" })
                ?? "Update or restart OpenBurnBar on your Mac"
        default:
            self.detail = CLIAgentResumeOutcome.successDetail(from: response)
            self.recovery = nil
        }
    }

    /// Compose the most useful single secondary line from the response.
    private static func successDetail(from response: CLIAgentSessionActionResponse) -> String? {
        var parts: [String] = []
        if let pid = response.pid {
            parts.append("PID \(pid)")
        }
        if let package = nonEmpty(response.briefingPath).map(lastPathComponent) {
            parts.append(package)
        } else if response.pid == nil, let command = commandPreview(response.argv) {
            parts.append(command)
        }
        if let cwd = nonEmpty(response.workingDirectory).map(abbreviatePath) {
            parts.append(cwd)
        }
        if let note = nonEmpty(response.note), parts.isEmpty {
            parts.append(note.replacingOccurrences(of: "_", with: " "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func commandPreview(_ argv: [String]) -> String? {
        let trimmed = argv.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return nil }
        let joined = trimmed.joined(separator: " ")
        if joined.count <= 48 { return joined }
        return String(joined.prefix(47)) + "…"
    }

    private static func lastPathComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if !home.isEmpty, path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Best-effort display name for a canonical wire id returned by the Mac.
    public static func displayName(forWireID wireID: String) -> String? {
        if let target = CLIAgentResumeTarget(rawValue: wireID) {
            return target.displayName
        }
        switch wireID {
        case "openclaw": return "OpenClaw"
        case "goose":    return "Goose"
        case "cursor":   return "Cursor"
        case "windsurf": return "Windsurf"
        default:         return nil
        }
    }
}

// MARK: Daemon → relay status mapping

extension CLIAgentSessionActionResponse {
    /// Map a daemon `run.resume` response into the relay-layer action
    /// response shown to mobile + Mac clients. Centralizes the outcome
    /// classification so every surface renders identical pills.
    ///
    /// Behavior MUST match `CLIAgentSessionActionDaemonDispatcher.perform`
    /// in AgentLens — `HermesRelayContractTests` pins the mapping.
    public init(
        daemonResponse response: BurnBarRunResumeResponse,
        requestedAction: CLIAgentSessionActionKind
    ) {
        let status: CLIAgentSessionActionStatus
        switch response.kind {
        case "native":
            status = .nativeResume
        case "spawned":
            if response.argv != nil {
                status = .nativeResume
            } else if response.targetArgv != nil {
                status = .handoff
            } else {
                status = .spawned
            }
        case "ported":
            status = requestedAction == .packageOnly ? .packageOnly : .handoff
        case "error":
            status = .error
        default:
            status = .handoff
        }
        self.init(
            status: status,
            targetRuntime: response.targetHarness,
            argv: response.argv ?? response.targetArgv ?? [],
            briefingPath: response.briefingPath,
            workingDirectory: response.workingDirectory,
            pid: response.pid,
            cleanupAfterSeconds: response.cleanupAfterSeconds,
            note: response.note,
            errorCode: response.errorCode,
            errorRecovery: response.errorRecovery
        )
    }
}

// MARK: Resume lookup id

extension CLIAgentSessionRecord {
    /// The session id to send to the daemon for a resume/handoff action.
    /// Archived-log rows carry an `archive:{agent}:` prefix (the agent token
    /// is the runtime raw value, already lower-cased) that must be stripped
    /// first; live rows are sent verbatim. Mirrors the Android
    /// `CLIAgentSessionRecord.resumeLookupID`.
    public var resumeLookupID: String {
        let prefix = "archive:\(agent.rawValue):"
        if sourceKind == .archivedLog, id.hasPrefix(prefix) {
            return String(id.dropFirst(prefix.count))
        }
        return id
    }
}
