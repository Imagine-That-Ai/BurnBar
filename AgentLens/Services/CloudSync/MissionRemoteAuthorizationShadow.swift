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

    /// Authorization mode, resolved from `OBB_MISSION_AUTHORIZE_SHADOW`:
    ///   - `.enforce` (DEFAULT): the daemon's `daemon.mission.authorizeRemote`
    ///     verdict is the SOLE authority. `.authorized` proceeds, `.requiresApproval`
    ///     drives the approval flow, `.denied` refuses with the daemon's reason,
    ///     and a daemon-unreachable/error FAILS CLOSED (deny). Split-brain M4.
    ///   - `.shadow`: the M3 observe-only path — ask the daemon, telemeter
    ///     divergence, but the GUI decision governs. (Rollback lever.)
    ///   - `.off`: disable the daemon call entirely. Because M4 deleted the GUI's
    ///     own decision code, `.off` means remote missions do NOT run (fail
    ///     closed). (Deepest rollback lever short of `git revert`.)
    enum Mode: String, Equatable, Sendable {
        case off
        case shadow
        case enforce
    }

    /// Ships defaulting to `.enforce` (M4): the daemon is the single mission
    /// authorization authority. `OBB_MISSION_AUTHORIZE_SHADOW=shadow` reverts to
    /// M3 observe-only; `=off`/`0`/`false`/`disabled` disables the daemon call
    /// (remote missions fail closed). `nonisolated(unsafe)` is safe here: this is
    /// a set-once-at-launch reversal flag, resolved from the environment on first
    /// access and only ever read afterward on the main actor or from tests.
    nonisolated(unsafe) static var mode: Mode = {
        switch ProcessInfo.processInfo.environment["OBB_MISSION_AUTHORIZE_SHADOW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "off", "0", "false", "disabled":
            return .off
        case "shadow", "observe", "observe_only", "observe-only":
            return .shadow
        default:
            return .enforce
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

    /// Build the authoritative-decision inputs from the decoded mission
    /// document. Carries ONLY a prompt summary + SHA-256, never the sealed
    /// payload or the full prompt.
    static func makeRequest(
        missionID: String,
        data: [String: Any],
        prompt: String,
        executorTrustState: String,
        requestedRuntime: String?,
        requestedModelID: String?,
        requestedFanOutCount: Int,
        trustedFanOutCap: Int? = nil
    ) -> BurnBarRemoteMissionAuthorizeRequest {
        let commandsAllowed = (data["commandsAllowed"] as? Bool) ?? false
        let fileEditsAllowed = (data["fileEditsAllowed"] as? Bool) ?? false
        let grant = BurnBarRemoteMissionCapabilityGrantRequest(
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )

        return BurnBarRemoteMissionAuthorizeRequest(
            missionID: missionID,
            originDeviceID: stringField(data, "originDeviceID")
                ?? stringField(data, "createdBy")
                ?? "unknown",
            originPlatform: stringField(data, "originPlatform")
                ?? stringField(data, "source")
                ?? "unknown",
            executorTrustState: executorTrustState,
            promptSummary: promptSummary(from: prompt),
            promptSHA256: sha256Hex(prompt),
            requestedRuntime: requestedRuntime?.nilIfBlank,
            requestedModelID: requestedModelID?.nilIfBlank,
            requestedGrant: grant,
            personaScope: personaScope(from: data),
            approvalMode: stringField(data, "approvalMode"),
            approvalStatus: stringField(data, "approvalStatus"),
            approverDeviceID: stringField(data, "approverDeviceID"),
            entitlementTier: stringField(data, "entitlementTier") ?? "none",
            requestedFanOutCount: max(1, requestedFanOutCount),
            trustedFanOutCap: trustedFanOutCap,
            workingDirectory: stringField(data, "workingDirectory")
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

    private static func personaScope(from data: [String: Any]) -> PersonaScopeEnvelope? {
        guard let json = stringField(data, "personaScopeJSON"),
              let payload = json.data(using: .utf8) else {
            return nil
        }
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
            // Pre-format into one non-sensitive string so the OSLog literal stays
            // short (line-length) and type-checks fast (a `+`-concatenated OSLog
            // interpolation is pathologically slow to type-check here).
            let daemonVerdict = signal.daemonVerdict?.rawValue ?? "nil"
            let daemonReason = signal.daemonDeniedReason?.rawValue ?? "none"
            let detail = "kind=\(signal.kind.rawValue) gui=\(signal.guiDecision.rawValue) "
                + "daemon=\(daemonVerdict) daemonReason=\(daemonReason)"
            logger.warning(
                "mission_authorize_shadow DIVERGENCE \(detail, privacy: .public) mission=\(signal.missionID, privacy: .public) sha=\(signal.promptSHA256, privacy: .public)"
            )
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
        missionID: String,
        data: [String: Any],
        prompt: String,
        guiDecision: GUIMissionAuthorizationDecision,
        executorTrustState: String,
        requestedRuntime: String?,
        requestedModelID: String?,
        requestedFanOutCount: Int,
        trustedFanOutCap: Int? = nil,
        manager: OpenBurnBarDaemonManager = .shared
    ) async {
        guard mode == .shadow else { return }

        let request = makeRequest(
            missionID: missionID,
            data: data,
            prompt: prompt,
            executorTrustState: executorTrustState,
            requestedRuntime: requestedRuntime,
            requestedModelID: requestedModelID,
            requestedFanOutCount: requestedFanOutCount,
            trustedFanOutCap: trustedFanOutCap
        )
        let promptSHA = request.promptSHA256

        // Only reach for the daemon when it is healthy; otherwise classify as
        // unreachable (fail-safe) without a socket attempt.
        guard case .healthy = manager.status else {
            emit(compare(
                missionID: missionID,
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
            missionID: missionID,
            gui: guiDecision,
            daemon: daemonResponse,
            promptSHA256: promptSHA,
            unreachableDetail: unreachableDetail
        ))
    }

    // MARK: Enforcement (M4 — the daemon verdict governs)

    /// The daemon's authoritative outcome for a remote mission, as the GUI call
    /// site consumes it under `.enforce`. Fail-closed by construction: the only
    /// way to `.authorized` / `.requiresApproval` is a live daemon verdict; any
    /// unreachability collapses to `.denied` with a `daemonUnreachable` reason.
    enum AuthorizationOutcome: Equatable, Sendable {
        /// The daemon authorized execution.
        case authorized
        /// The daemon requires pre-dispatch operator approval before execution.
        case requiresApproval
        /// The daemon refused; carries the daemon's typed reason when present.
        case denied(reason: BurnBarRemoteMissionDenialReason?, detail: String?)
        /// The daemon could not be reached / errored — FAIL CLOSED. The GUI must
        /// surface the "daemon required for remote missions" state and not run.
        case daemonUnreachable(detail: String)

        var isDaemonUnreachable: Bool {
            if case .daemonUnreachable = self { return true }
            return false
        }
    }

    /// ENFORCE-mode authorization. Asks the daemon for its authoritative verdict
    /// over the decoded mission and returns it as an `AuthorizationOutcome` the
    /// GUI call site obeys. FAILS CLOSED: an unhealthy daemon, a socket error,
    /// or a non-enforcing mode all resolve to `.daemonUnreachable` (the caller
    /// then refuses the mission and surfaces the needs-repair state). Never
    /// throws. Mirrors `observe`'s daemon-reach logic so shadow and enforce use
    /// one code path to talk to the daemon.
    @MainActor
    static func authorize(
        missionID: String,
        data: [String: Any],
        prompt: String,
        executorTrustState: String,
        requestedRuntime: String?,
        requestedModelID: String?,
        requestedFanOutCount: Int,
        trustedFanOutCap: Int? = nil,
        manager: OpenBurnBarDaemonManager = .shared
    ) async -> AuthorizationOutcome {
        let request = makeRequest(
            missionID: missionID,
            data: data,
            prompt: prompt,
            executorTrustState: executorTrustState,
            requestedRuntime: requestedRuntime,
            requestedModelID: requestedModelID,
            requestedFanOutCount: requestedFanOutCount,
            trustedFanOutCap: trustedFanOutCap
        )

        // Only reach for the daemon when it is healthy; otherwise fail closed.
        guard case .healthy = manager.status else {
            logger.warning(
                "mission_authorize enforce fail_closed mission=\(missionID, privacy: .public) reason=daemon_not_healthy sha=\(request.promptSHA256, privacy: .public)"
            )
            return .daemonUnreachable(detail: "daemon not healthy")
        }

        let socketURL = manager.paths.socketURL
        let response: BurnBarRemoteMissionAuthorizeResponse
        do {
            response = try await manager.daemonRPC {
                try OpenBurnBarDaemonSocketClient.authorizeRemoteMission(request, at: socketURL)
            }
        } catch {
            logger.warning(
                "mission_authorize enforce fail_closed mission=\(missionID, privacy: .public) reason=rpc_error detail=\(error.localizedDescription, privacy: .public) sha=\(request.promptSHA256, privacy: .public)"
            )
            return .daemonUnreachable(detail: error.localizedDescription)
        }

        switch response.verdict {
        case .authorized:
            logger.info(
                "mission_authorize enforce authorized mission=\(missionID, privacy: .public) sha=\(request.promptSHA256, privacy: .public)"
            )
            return .authorized
        case .requiresApproval:
            logger.info(
                "mission_authorize enforce requires_approval mission=\(missionID, privacy: .public) sha=\(request.promptSHA256, privacy: .public)"
            )
            return .requiresApproval
        case .denied:
            let reason = response.deniedReason?.rawValue ?? "none"
            logger.warning(
                "mission_authorize enforce denied mission=\(missionID, privacy: .public) reason=\(reason, privacy: .public) sha=\(request.promptSHA256, privacy: .public)"
            )
            return .denied(reason: response.deniedReason, detail: response.detail)
        }
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
        data: [String: Any],
        willPauseForApproval: Bool,
        isTerminalDenial: Bool = false
    ) -> GUIMissionAuthorizationDecision {
        let approvalStatus = ((data["approvalStatus"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if approvalStatus == "rejected" || approvalStatus == "canceled" || approvalStatus == "cancelled" {
            return .deny
        }
        if isTerminalDenial {
            return .deny
        }
        return willPauseForApproval ? .requiresApproval : .allow
    }

    // MARK: Field helpers

    private static func stringField(_ data: [String: Any], _ key: String) -> String? {
        // `String.nilIfBlank` is the shared AgentLens trim-or-nil helper
        // (AgentLens/Utilities/AgentLensStringNilIfBlank.swift).
        (data[key] as? String)?.nilIfBlank
    }
}
