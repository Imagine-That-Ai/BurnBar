import CryptoKit
import Foundation
import OpenBurnBarCore
import OSLog

// MARK: - Mission remote authorization (split-brain cutover)
//
// The GUI reduces its legacy trust and approval decision to the daemon's
// verdict space, then sends the same decoded authorization inputs to
// `daemon.mission.authorizeRemote`. Shadow mode only records divergence and
// leaves the GUI policy unchanged. Enforce mode awaits the daemon response and
// permits execution only for `.authorized`, after retaining local fail-closed
// security guards and applying the daemon's capability ceiling.
//
// The request carries a prompt summary and hash, never the sealed payload or
// full prompt. Structured divergence telemetry remains available in every mode
// that contacts the daemon, and `.off` remains the rollback path.
//
// This file remains outside the frozen `CLIAgentMissionRequestListener` cluster
// so the split-brain shrink-only ratchet does not grow that legacy surface.

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
    /// where the GUI would allow). This is security-relevant divergence.
    case daemonStricter = "daemon_stricter"
    /// The GUI permits strictly LESS than the daemon (GUI denies/pauses where
    /// the daemon would allow). Local fail-closed security inputs can produce
    /// this intentionally during enforce mode.
    case guiStricter = "gui_stricter"
    /// The daemon verdict could not be obtained (unreachable / RPC error).
    /// Shadow mode preserves the GUI decision; enforce mode denies.
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

/// The compatibility verdict returned by the enforce reducer. Only an
/// `.authorized` daemon verdict allows; `.requiresApproval`, `.denied`, and an
/// unreachable daemon all deny.
enum MissionAuthorizationEnforcementVerdict: String, Equatable, Sendable {
    case allow
    case deny
}

/// The trusted-decision result consumed by the listener. Enforce mode carries
/// the complete authorized daemon response so the listener can apply its
/// capability ceiling before any claim or launch.
enum MissionAuthorizationTrustedDecisionOutcome: Equatable, Sendable {
    /// Off/shadow mode permits the mission under the GUI's existing policy.
    case proceed
    /// Enforce mode received the daemon's complete authorized response. The
    /// listener must apply its grant ceiling before any claim or launch.
    case authorized(BurnBarRemoteMissionAuthorizeResponse)
    /// The GUI wants to pause for pre-dispatch operator approval (off/shadow
    /// only — never returned in enforce mode, where the daemon governs).
    case pauseForApproval
    /// The mission must be denied with the given user-visible message.
    case deny(String)
}

/// Pure comparator and request/verdict reducers shared by shadow observation
/// and enforce-mode authorization.
enum MissionRemoteAuthorizationShadow {

    /// Reversal flag. `.shadow` (default) observes and telemeters divergence
    /// while the GUI decision remains authoritative; `.off` disables the daemon
    /// call. `.enforce` permits only a full `.authorized` daemon response and
    /// still retains local fail-closed security inputs. An unavailable daemon
    /// always denies in enforce mode.
    enum Mode: String, Equatable, Sendable {
        case off
        case shadow
        case enforce
    }

    /// Ships defaulting to enforce-mode for the M4 cutover. A runtime override
    /// can force it `.shadow` for telemetry-only rollback or `.off` for a hard
    /// fail-closed stop. Only the explicit string `"shadow"` selects observation;
    /// boolean-like values remain fail-closed in `.enforce`. `nonisolated(unsafe)`
    /// is safe here: this is a set-once-at-launch reversal flag, resolved from
    /// the environment on first access and only ever read afterward on the main
    /// actor (`observe` / `enforce`) or from tests.
    nonisolated(unsafe) static var mode: Mode = {
        switch ProcessInfo.processInfo.environment["OBB_MISSION_AUTHORIZE_SHADOW"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "off", "0", "false", "disabled":
            return .off
        case "enforce":
            return .enforce
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

    /// Compare the GUI decision against the daemon response for telemetry. A
    /// `nil` response is classified as unreachable; the active mode determines
    /// whether that observation preserves the GUI decision or denies.
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
            trustedFanOutCap: ctx.trustedFanOutCap,
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
        // Best-effort request shaping. The local persona-scope resolver rejects
        // every malformed present value before launch, including in enforce
        // mode, so dropping an undecodable envelope here cannot widen access.
        return try? decoder.decode(PersonaScopeEnvelope.self, from: payload) // try?-ok(request shaping; local resolver remains fail-closed)
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

    // MARK: Enforce verdict (P-ARCH-2)

    /// The authoritative enforcement verdict derived from a divergence signal.
    /// Pure and synchronous so every branch is table-testable.
    ///
    /// In enforce mode the daemon's **actual verdict** governs — not the
    /// divergence kind. The mission may proceed only when the daemon's verdict
    /// is `.authorized`; `.requiresApproval` and `.denied` both stop the
    /// mission (the daemon did not authorize execution). An unreachable daemon
    /// (nil verdict) is fail-closed `.deny`.
    static func enforce(
        signal: MissionAuthorizationDivergenceSignal
    ) -> MissionAuthorizationEnforcementVerdict {
        guard let daemonVerdict = signal.daemonVerdict else {
            return .deny
        }
        return daemonVerdict == .authorized ? .allow : .deny
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

    // MARK: Enforce orchestration (P-ARCH-2 — called from the GUI decision point)

    /// Shared enforce-mode transport. It emits the existing divergence signal
    /// and returns the complete daemon response. An unhealthy daemon or RPC
    /// failure returns `nil`; callers treat every result other than
    /// `.authorized` as a denial.
    @MainActor
    private static func requestDaemonAuthorization(
        ctx: ShadowContext,
        guiDecision: GUIMissionAuthorizationDecision,
        executorTrustState: String,
        manager: OpenBurnBarDaemonManager
    ) async -> BurnBarRemoteMissionAuthorizeResponse? {
        let request = makeRequest(ctx: ctx, executorTrustState: executorTrustState)
        let promptSHA = request.promptSHA256

        guard case .healthy = manager.status else {
            emit(compare(
                missionID: ctx.missionID,
                gui: guiDecision,
                daemon: nil,
                promptSHA256: promptSHA,
                unreachableDetail: "daemon not healthy"
            ))
            return nil
        }

        let socketURL = manager.paths.socketURL
        let response: BurnBarRemoteMissionAuthorizeResponse?
        var unreachableDetail: String?
        do {
            response = try await manager.daemonRPC {
                try OpenBurnBarDaemonSocketClient.authorizeRemoteMission(request, at: socketURL)
            }
        } catch {
            response = nil
            unreachableDetail = error.localizedDescription
        }

        emit(compare(
            missionID: ctx.missionID,
            gui: guiDecision,
            daemon: response,
            promptSHA256: promptSHA,
            unreachableDetail: unreachableDetail
        ))
        return response
    }

    @MainActor
    static func enforce(
        ctx: ShadowContext,
        guiDecision: GUIMissionAuthorizationDecision,
        executorTrustState: String,
        manager: OpenBurnBarDaemonManager = .shared
    ) async -> MissionAuthorizationEnforcementVerdict {
        switch mode {
        case .off:
            return .allow
        case .shadow:
            await observe(
                ctx: ctx,
                guiDecision: guiDecision,
                executorTrustState: executorTrustState,
                manager: manager
            )
            return .allow
        case .enforce:
            let response = await requestDaemonAuthorization(
                ctx: ctx,
                guiDecision: guiDecision,
                executorTrustState: executorTrustState,
                manager: manager
            )
            return response?.verdict == .authorized ? .allow : .deny
        }
    }

    /// Explicit daemon-authority result consumed by the M4 listener path.
    /// Every outcome other than `.authorized` is non-executable; transport
    /// failure remains distinct so the shared mission can stay pending for a
    /// different healthy executor.
    enum AuthorizationOutcome: Equatable, Sendable {
        case authorized(grantCeiling: BurnBarRemoteMissionCapabilityGrantRequest?)
        case requiresApproval
        case denied(reason: BurnBarRemoteMissionDenialReason?, detail: String?)
        case daemonUnreachable(detail: String)
    }

    /// Ask the daemon for the authoritative mission verdict. This is the
    /// typed M4 entry point; it never throws and fails closed on an unhealthy
    /// daemon or malformed RPC response.
    @MainActor
    static func authorize(
        ctx: ShadowContext,
        executorTrustState: String,
        manager: OpenBurnBarDaemonManager = .shared
    ) async -> AuthorizationOutcome {
        let request = makeRequest(ctx: ctx, executorTrustState: executorTrustState)
        guard case .healthy = manager.status else {
            logger.warning("mission_authorize enforce fail_closed mission=\(ctx.missionID, privacy: .public) reason=daemon_not_healthy sha=\(request.promptSHA256, privacy: .public)")
            return .daemonUnreachable(detail: "daemon not healthy")
        }

        do {
            let response = try await manager.daemonRPC {
                try OpenBurnBarDaemonSocketClient.authorizeRemoteMission(request, at: manager.paths.socketURL)
            }
            switch response.verdict {
            case .authorized:
                return .authorized(grantCeiling: response.grantCeiling)
            case .requiresApproval:
                return .requiresApproval
            case .denied:
                return .denied(reason: response.deniedReason, detail: response.detail)
            }
        } catch {
            logger.warning("mission_authorize enforce fail_closed mission=\(ctx.missionID, privacy: .public) reason=rpc_error detail=\(error.localizedDescription, privacy: .public) sha=\(request.promptSHA256, privacy: .public)")
            return .daemonUnreachable(detail: error.localizedDescription)
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
        let trustedFanOutCap: Int?

        init(
            missionID: String,
            prompt: String,
            runtime: String?,
            modelID: String?,
            commandsAllowed: Bool,
            fileEditsAllowed: Bool,
            originDeviceID: String,
            originPlatform: String,
            personaScopeJSON: String?,
            approvalMode: String?,
            approvalStatus: String,
            approverDeviceID: String?,
            entitlementTier: String,
            workingDirectory: String?,
            fanOutCount: Int,
            trustedFanOutCap: Int? = nil
        ) {
            self.missionID = missionID
            self.prompt = prompt
            self.runtime = runtime
            self.modelID = modelID
            self.commandsAllowed = commandsAllowed
            self.fileEditsAllowed = fileEditsAllowed
            self.originDeviceID = originDeviceID
            self.originPlatform = originPlatform
            self.personaScopeJSON = personaScopeJSON
            self.approvalMode = approvalMode
            self.approvalStatus = approvalStatus
            self.approverDeviceID = approverDeviceID
            self.entitlementTier = entitlementTier
            self.workingDirectory = workingDirectory
            self.fanOutCount = fanOutCount
            self.trustedFanOutCap = trustedFanOutCap
        }
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

    /// Resolve the trusted-path authorization decision. Encodes the full
    /// outcome so the listener call site is a minimal switch — keeping the
    /// split-brain frozen cluster from growing.
    ///
    /// In `.off`/`.shadow` mode: observes (fire-and-forget telemetry) and
    /// returns the GUI's own decision (pause/persona-deny/proceed) — the GUI
    /// governs unchanged. In `.enforce` mode: queries the daemon, emits
    /// telemetry, and returns the authoritative outcome — the mission proceeds
    /// only when the daemon's actual verdict is `.authorized`; `.requiresApproval`
    /// and `.denied` both stop the mission before claim. An unreachable daemon
    /// is fail-closed `.deny`. When the daemon authorizes, GUI-only pauses and
    /// persona denials are bypassed (the guiStricter-loosen path).
    @MainActor
    static func resolveTrustedDecision(
        ctx: ShadowContext,
        isTerminalDenial: Bool,
        personaScopeMalformed: Bool,
        willPauseForApproval: Bool,
        manager: OpenBurnBarDaemonManager = .shared
    ) async -> MissionAuthorizationTrustedDecisionOutcome {
        if mode == .enforce {
            let guiDecision: GUIMissionAuthorizationDecision = personaScopeMalformed
                ? .deny
                : reduceGUIDecision(
                    approvalStatus: ctx.approvalStatus,
                    willPauseForApproval: willPauseForApproval,
                    isTerminalDenial: isTerminalDenial
                )
            guard let response = await requestDaemonAuthorization(
                ctx: ctx,
                guiDecision: guiDecision,
                executorTrustState: "trusted",
                manager: manager
            ), response.verdict == .authorized else {
                return .deny("This remote mission was not authorized by the Mac daemon and will not run. Re-send the mission from your device.")
            }
            if personaScopeMalformed {
                return .deny("The persona scope attached to this mission could not be read, so it was rejected instead of running with broader permissions. Re-send the mission from your device.")
            }
            if isTerminalDenial {
                return .deny("Mac CLI assistants are off. Enable Mac CLI assistants in Settings -> Privacy & Indexing before this Mac can run remote agent missions.")
            }
            return .authorized(response)
        }

        // Off/shadow mode observes without changing the GUI's existing policy.
        observeTrustedDecision(
            ctx: ctx,
            isTerminalDenial: isTerminalDenial,
            personaScopeMalformed: personaScopeMalformed,
            willPauseForApproval: willPauseForApproval
        )
        if willPauseForApproval {
            return .pauseForApproval
        }
        if personaScopeMalformed {
            return .deny("The persona scope attached to this mission could not be read, so it was rejected instead of running with broader permissions. Re-send the mission from your device.")
        }
        return .proceed
    }
}
