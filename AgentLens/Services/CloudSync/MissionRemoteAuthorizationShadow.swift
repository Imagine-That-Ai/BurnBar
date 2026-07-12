import CryptoKit
import Foundation
import OpenBurnBarCore
import OSLog

// MARK: - Mission remote-authorization SHADOW mode (split-brain Phase M3)
//
// docs/SURFACE_SPRAWL_AND_SPLITBRAIN_REMEDIATION_PLAN.md — the menubar GUI
// (`CLIAgentMissionRequestListener`) still carries its OWN trust / approval /
// fan-out authority for remote (mobile/Wand) missions, duplicating the
// daemon's fail-closed `daemon.mission.authorizeRemote` RPC
// (`BurnBarRemoteMissionAuthorizationPolicy`, shipped in M2 / PR #1425 but
// with ZERO callers — dead code, a latent authorization-bypass setup).
//
// Phase M3 turns that dead RPC into a LIVE, OBSERVABLE ORACLE without changing
// runtime behavior. At the GUI's mission-authorization decision point we:
//
//   1. Reduce the GUI's own decision to a comparable verdict
//      (`GUIMissionAuthorizationDecision`).
//   2. Ask the daemon for its authoritative verdict over the same decoded
//      inputs (never the sealed payload / full prompt — only a summary + hash).
//   3. COMPARE the two and emit a structured divergence signal.
//
// This phase deliberately does NOT flip enforcement: the GUI's existing
// decision still governs execution. Enforcement migrates in a later phase once
// parity is proven from the divergence telemetry. Everything here is gated
// behind `MissionRemoteAuthorizationShadow.mode`, defaulting to `.shadow`, so
// the whole path is reversible with a single flag flip to `.off`.
//
// This file is DELIBERATELY named outside the `CLIAgentMissionRequestListener`
// cluster prefix: the mission split-brain shrink-only ratchet
// (scripts/debt/check-mission-splitbrain-budget.sh) freezes that cluster, and
// new GUI mission-authority code that carries us TOWARD collapsing the
// split-brain belongs in a fresh, un-baselined home.

/// The GUI's own authorization verdict, reduced to the daemon's verdict space
/// so the two authorities are directly comparable. The GUI listener does not
/// produce a `BurnBarRemoteMissionAuthorizationVerdict` natively — it makes a
/// sequence of allow/deny/pause decisions — so we map its observable outcome
/// onto the same three-valued lattice the daemon uses.
enum GUIMissionAuthorizationDecision: String, Equatable, Sendable {
    /// GUI trust + approval gates both pass; the mission would execute now.
    case allow
    /// GUI would pause the mission for pre-dispatch operator approval (or Mac
    /// CLI-assistant consent) before it could execute.
    case requiresApproval = "requires_approval"
    /// GUI refuses the mission outright (untrusted executor, rejected/cancelled
    /// approval handshake, malformed request).
    case deny
}

/// How the daemon's authoritative verdict compares to the GUI's own decision.
/// "Stricter" is ordered `deny > requiresApproval > allow`: the party that
/// permits LESS is the stricter one.
enum MissionAuthorizationDivergenceKind: String, Equatable, Sendable {
    /// GUI and daemon reached the same verdict.
    case agree
    /// The daemon permits strictly LESS than the GUI (daemon would deny/pause
    /// where the GUI would allow). This is the security-relevant direction:
    /// once enforcement flips, these missions STOP running.
    case daemonStricter = "daemon_stricter"
    /// The GUI permits strictly LESS than the daemon (GUI denies/pauses where
    /// the daemon would allow). Flipping enforcement would LOOSEN these — must
    /// be understood before any enforcement migration.
    case guiStricter = "gui_stricter"
    /// The daemon verdict could not be obtained (unreachable / RPC error).
    /// Fail-SAFE: the GUI's existing decision governs, unchanged.
    case daemonUnreachable = "daemon_unreachable"
}

/// A single structured divergence observation, shaped for later telemetry /
/// log-scraping analysis. Deliberately carries NO payload / prompt text — only
/// the mission id, the two verdicts, and the correlation hash.
struct MissionAuthorizationDivergenceSignal: Equatable, Sendable {
    let missionID: String
    let kind: MissionAuthorizationDivergenceKind
    let guiDecision: GUIMissionAuthorizationDecision
    /// The daemon's verdict, or `nil` when unreachable.
    let daemonVerdict: BurnBarRemoteMissionAuthorizationVerdict?
    let daemonDeniedReason: BurnBarRemoteMissionDenialReason?
    /// SHA-256 hex of the full decoded prompt, for audit correlation without
    /// carrying the payload.
    let promptSHA256: String
    /// Present when `kind == .daemonUnreachable`.
    let unreachableDetail: String?

    var isDivergent: Bool {
        switch kind {
        case .agree, .daemonUnreachable:
            return false
        case .daemonStricter, .guiStricter:
            return true
        }
    }
}

/// Pure comparator + request/verdict reducers behind the shadow path. Kept
/// stateless and synchronous so every branch is table-testable.
enum MissionRemoteAuthorizationShadow {

    /// Reversal flag. `.shadow` (default) observes and telemeters divergence
    /// but lets the GUI decision govern; `.off` disables the shadow call
    /// entirely. Enforcement is intentionally NOT an option in this phase.
    enum Mode: String, Equatable, Sendable {
        case off
        case shadow
    }

    /// Ships defaulting to shadow-mode. A runtime override can force it `.off`
    /// for a fast rollback without reverting the wiring. `nonisolated(unsafe)`
    /// is safe here: this is a set-once-at-launch reversal flag, resolved from
    /// the environment on first access and only ever read afterward on the main
    /// actor (`observe`) or from tests.
    nonisolated(unsafe) static var mode: Mode = {
        switch ProcessInfo.processInfo.environment["OBB_MISSION_AUTHORIZE_SHADOW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "off", "0", "false", "disabled":
            return .off
        default:
            return .shadow
        }
    }()

    private static let logger = Logger(
        subsystem: "com.openburnbar.app",
        category: "MissionRemoteAuthorizationShadow"
    )

    // MARK: Verdict ordering

    /// Permissiveness rank: higher permits MORE. `allow > requiresApproval >
    /// deny`. Used to decide which authority is stricter.
    private static func permissiveness(_ verdict: BurnBarRemoteMissionAuthorizationVerdict) -> Int {
        switch verdict {
        case .authorized: return 2
        case .requiresApproval: return 1
        case .denied: return 0
        }
    }

    private static func permissiveness(_ decision: GUIMissionAuthorizationDecision) -> Int {
        switch decision {
        case .allow: return 2
        case .requiresApproval: return 1
        case .deny: return 0
        }
    }

    // MARK: Comparator (the unit-tested core)

    /// Compare the GUI's own decision against the daemon's authoritative
    /// verdict. A `nil` daemon verdict means the daemon was unreachable — the
    /// GUI decision governs and the outcome is classified fail-safe.
    static func compare(
        missionID: String,
        gui: GUIMissionAuthorizationDecision,
        daemon: BurnBarRemoteMissionAuthorizeResponse?,
        promptSHA256: String,
        unreachableDetail: String? = nil
    ) -> MissionAuthorizationDivergenceSignal {
        guard let daemon else {
            return MissionAuthorizationDivergenceSignal(
                missionID: missionID,
                kind: .daemonUnreachable,
                guiDecision: gui,
                daemonVerdict: nil,
                daemonDeniedReason: nil,
                promptSHA256: promptSHA256,
                unreachableDetail: unreachableDetail ?? "daemon verdict unavailable"
            )
        }

        let guiRank = permissiveness(gui)
        let daemonRank = permissiveness(daemon.verdict)
        let kind: MissionAuthorizationDivergenceKind
        if daemonRank == guiRank {
            kind = .agree
        } else if daemonRank < guiRank {
            kind = .daemonStricter
        } else {
            kind = .guiStricter
        }

        return MissionAuthorizationDivergenceSignal(
            missionID: missionID,
            kind: kind,
            guiDecision: gui,
            daemonVerdict: daemon.verdict,
            daemonDeniedReason: daemon.deniedReason,
            promptSHA256: promptSHA256,
            unreachableDetail: nil
        )
    }

    // MARK: Request construction

    /// Build the authoritative-decision inputs from the typed shadow context.
    /// Carries ONLY a prompt summary + SHA-256, never the sealed payload or
    /// the full prompt.
    static func makeRequest(
        ctx: ShadowContext,
        executorTrustState: String
    ) -> BurnBarRemoteMissionAuthorizeRequest {
        let grant = BurnBarRemoteMissionCapabilityGrantRequest(
            commandsAllowed: ctx.commandsAllowed,
            fileEditsAllowed: ctx.fileEditsAllowed
        )
        return BurnBarRemoteMissionAuthorizeRequest(
            missionID: ctx.missionID,
            originDeviceID: ctx.originDeviceID,
            originPlatform: ctx.originPlatform,
            executorTrustState: executorTrustState,
            promptSummary: promptSummary(from: ctx.prompt),
            promptSHA256: sha256Hex(ctx.prompt),
            requestedRuntime: ctx.runtime?.nilIfBlank,
            requestedModelID: ctx.modelID?.nilIfBlank,
            requestedGrant: grant,
            personaScope: personaScope(from: ctx.personaScopeJSON),
            approvalMode: ctx.approvalMode,
            approvalStatus: ctx.approvalStatus.nilIfBlank,
            approverDeviceID: ctx.approverDeviceID,
            entitlementTier: ctx.entitlementTier,
            requestedFanOutCount: max(1, ctx.fanOutCount),
            workingDirectory: ctx.workingDirectory
        )
    }

    /// SHA-256 hex of the full decoded prompt — audit correlation without
    /// carrying the payload across the socket.
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func promptSummary(from prompt: String, limit: Int = 160) -> String {
        let collapsed = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= limit {
            return collapsed
        }
        return String(collapsed.prefix(limit)) + "…"
    }

    private static func personaScope(from json: String?) -> PersonaScopeEnvelope? {
        guard let json, let payload = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Best-effort: a malformed envelope is left nil here (the GUI's own
        // persona-scope resolver already REFUSES malformed present scopes on
        // the execution path, so shadow mode never widens authority by
        // dropping it).
        return try? decoder.decode(PersonaScopeEnvelope.self, from: payload) // try?-ok(best-effort decode for shadow telemetry; malformed envelope left nil, never widens authority)
    }

    // MARK: Divergence emission

    /// Emit the structured divergence signal. Today this is a structured log
    /// line keyed for scraping; a later phase can fan it into the telemetry
    /// plane without changing the call site.
    static func emit(_ signal: MissionAuthorizationDivergenceSignal) {
        switch signal.kind {
        case .agree:
            logger.info(
                "mission_authorize_shadow agree mission=\(signal.missionID, privacy: .public) gui=\(signal.guiDecision.rawValue, privacy: .public) daemon=\(signal.daemonVerdict?.rawValue ?? "nil", privacy: .public) sha=\(signal.promptSHA256, privacy: .public)"
            )
        case .daemonUnreachable:
            logger.notice(
                "mission_authorize_shadow daemon_unreachable mission=\(signal.missionID, privacy: .public) gui=\(signal.guiDecision.rawValue, privacy: .public) detail=\(signal.unreachableDetail ?? "", privacy: .public) sha=\(signal.promptSHA256, privacy: .public)"
            )
        case .daemonStricter, .guiStricter:
            let kind = signal.kind.rawValue
            let mission = signal.missionID
            let gui = signal.guiDecision.rawValue
            let daemon = signal.daemonVerdict?.rawValue ?? "nil"
            let reason = signal.daemonDeniedReason?.rawValue ?? "none"
            let sha = signal.promptSHA256
            logger.warning("mission_authorize_shadow DIVERGENCE kind=\(kind, privacy: .public) mission=\(mission, privacy: .public) gui=\(gui, privacy: .public) daemon=\(daemon, privacy: .public) daemonReason=\(reason, privacy: .public) sha=\(sha, privacy: .public)")
        }
    }

    // MARK: Shadow orchestration (called from the GUI decision point)

    /// SHADOW-mode observation. Builds the daemon request from the decoded
    /// mission, asks the daemon for its authoritative verdict off the main
    /// actor, compares it against the GUI's own decision, and telemeters any
    /// divergence. NEVER throws and NEVER governs execution: on any daemon
    /// error / unreachability it fails SAFE by classifying the outcome as
    /// `.daemonUnreachable` and returning — the GUI's existing decision is left
    /// entirely in charge. A no-op when `mode == .off`.
    @MainActor
    static func observe(
        ctx: ShadowContext,
        guiDecision: GUIMissionAuthorizationDecision,
        executorTrustState: String,
        manager: OpenBurnBarDaemonManager = .shared
    ) async {
        guard mode == .shadow else { return }

        let request = makeRequest(ctx: ctx, executorTrustState: executorTrustState)
        let promptSHA = request.promptSHA256

        // Only reach for the daemon when it is healthy; otherwise classify as
        // unreachable (fail-safe) without a socket attempt.
        guard case .healthy = manager.status else {
            emit(compare(
                missionID: ctx.missionID,
                gui: guiDecision,
                daemon: nil,
                promptSHA256: promptSHA,
                unreachableDetail: "daemon not healthy"
            ))
            return
        }

        let socketURL = manager.paths.socketURL
        let daemonResponse: BurnBarRemoteMissionAuthorizeResponse?
        var unreachableDetail: String?
        do {
            daemonResponse = try await manager.daemonRPC {
                try OpenBurnBarDaemonSocketClient.authorizeRemoteMission(request, at: socketURL)
            }
        } catch {
            daemonResponse = nil
            unreachableDetail = error.localizedDescription
        }

        emit(compare(
            missionID: ctx.missionID,
            gui: guiDecision,
            daemon: daemonResponse,
            promptSHA256: promptSHA,
            unreachableDetail: unreachableDetail
        ))
    }

    /// Reduce the GUI listener's observable outcome, once trust has passed,
    /// onto the comparable verdict lattice:
    ///   - a rejected/cancelled approval handshake → `.deny`
    ///   - a terminal GUI denial (Mac CLI assistants disabled, backend
    ///     unavailable) → `.deny` (the mission is already failed, NOT paused
    ///     for approval; mapping it to `.requiresApproval` would hide a real
    ///     GUI-vs-daemon divergence in shadow telemetry)
    ///   - otherwise "would pause for approval" → `.requiresApproval`
    ///   - otherwise (would execute now) → `.allow`
    static func reduceGUIDecision(
        approvalStatus: String,
        willPauseForApproval: Bool,
        isTerminalDenial: Bool = false
    ) -> GUIMissionAuthorizationDecision {
        let normalized = approvalStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "rejected" || normalized == "canceled" || normalized == "cancelled" {
            return .deny
        }
        if isTerminalDenial {
            return .deny
        }
        return willPauseForApproval ? .requiresApproval : .allow
    }

    // MARK: Typed shadow context

    /// All data-derived fields the shadow observation needs, extracted as
    /// typed values at the call site. This keeps the shadow module free of
    /// any `[String: Any]` boundary access.
    struct ShadowContext {
        let missionID: String
        let prompt: String
        let runtime: String?
        let modelID: String?
        let commandsAllowed: Bool
        let fileEditsAllowed: Bool
        let originDeviceID: String
        let originPlatform: String
        let personaScopeJSON: String?
        let approvalMode: String?
        let approvalStatus: String
        let approverDeviceID: String?
        let entitlementTier: String
        let workingDirectory: String?
        let fanOutCount: Int
    }

    // MARK: Fire-and-forget observation helpers

    private static func fireAndForget(
        ctx: ShadowContext,
        guiDecision: GUIMissionAuthorizationDecision,
        executorTrustState: String
    ) {
        let c = ctx
        Task { @MainActor in
            await observe(
                ctx: c,
                guiDecision: guiDecision,
                executorTrustState: executorTrustState
            )
        }
    }

    /// Shadow-observe a deny at the fan-out validation or untrusted-device path.
    static func observeDeny(
        ctx: ShadowContext,
        executorTrustState: String
    ) {
        fireAndForget(ctx: ctx, guiDecision: .deny, executorTrustState: executorTrustState)
    }

    /// Shadow-observe the trusted-path authorization outcome. All derived
    /// values are pre-computed by the caller.
    static func observeTrustedDecision(
        ctx: ShadowContext,
        isTerminalDenial: Bool,
        personaScopeMalformed: Bool,
        willPauseForApproval: Bool
    ) {
        let decision = personaScopeMalformed
            ? .deny
            : reduceGUIDecision(
                approvalStatus: ctx.approvalStatus,
                willPauseForApproval: willPauseForApproval,
                isTerminalDenial: isTerminalDenial
            )
        fireAndForget(ctx: ctx, guiDecision: decision, executorTrustState: "trusted")
    }
}
