import SwiftUI

// MARK: - Agent Deck (PR 1 — "Say who is answering")
//
// Spec: docs/CHAT_AGENT_SWITCHER_REDESIGN.md §3 (the Sigil), §5 (presence),
// §6 (visual spec), §9.1 (PR 1 scope).
//
// The headline defect this fixes: from message one onward the chat window
// never said which agent was answering — the only identification was a ~12pt
// logo whose name lived in an `.accessibilityLabel`. The Sigil puts the agent's
// NAME and its MODEL on screen in words at every width, in every mode
// (embedded, pop-out, single pane, tiled), with 0 / 1 / 12 agents enabled.
//
// PLACEMENT NOTE: the spec's Appendix B files these types under
// `AgentLens/Views/Chat/AgentDeck/*.swift`. They still live here; the split is
// deliberately deferred rather than blocked. (`OpenBurnBar.xcodeproj` lists
// every source file explicitly and is now regenerated in this branch, so a new
// file *does* compile — see `AgentLens/Views/Chat/AgentDeck.swift`, which holds
// the deck's injected models. Moving ~1200 lines of view code at the same time
// would bury the behavioural diff.) Every type below is still marked with its
// destination file, so the split stays a pure cut-and-paste.
//
// THE CONTAINMENT LAW (§6.1): `sigilTint` draws the Sigil plate wash + rim, the
// presence dot, the ghost ring, the composer's 3pt leading bar, the tab
// agent-mark rings and the pane focus ring — and nothing else. It never draws
// body text, never a fill wider than 3pt, and NEVER the assistant bubble
// stroke. `ChatMessageView` is untouched by this PR.

// MARK: - Agent Deck · identity  → AgentDeck/AgentIdentity.swift

extension ChatBackendID {
    /// Raw identity hex behind ``sigilTint``.
    ///
    /// Mirrors `DesignSystem.Colors.primary(for:)` exactly — **no new hexes are
    /// invented**. Hermes is the one deliberate exception: it keeps the mercury
    /// axis, because `DesignSystem.swift:59` says so verbatim ("Hermes mercury
    /// identity (chat surfaces — not provider purple)"). Its provider primary
    /// is `A855F7`, which must never reach a chat surface.
    ///
    /// The literal exists (rather than only the `Color`) so ``sigilInk`` can do
    /// real WCAG maths on it; `Color` has no portable component accessor.
    var sigilTintHex: String {
        switch self {
        // Hermes' aureate token is adaptive (light B8942E / dark D4AA3C). The
        // dark value is the one drawn on chat chrome, so the ink maths uses it.
        case .hermes: return "D4AA3C"
        case .codex: return "2563EB"
        case .claude: return "CC785C"
        case .openclaw: return "FF6B6B"
        case .openClaude: return "D97757"
        case .omp: return "EC4899"
        case .piAgent: return "7C3AED"
        case .droid: return "8B5CF6"
        case .forge: return "F97316"
        case .antigravity: return "6C63FF"
        case .cursorAgent: return "00E5FF"
        case .junie: return "48E054"
        case .fx: return "A1A1AA"
        // xAI and Moonshot, not a second copy of Junie's green: three agents
        // sharing one tint is three agents the deck cannot tell apart.
        case .grok: return "1A1A1A"
        case .kimi: return "6366F1"
        }
    }

    /// Identity tint for chat surfaces. Total over `allCases` — a fifteenth
    /// backend cannot ship colourless.
    var sigilTint: Color {
        switch self {
        case .hermes:
            return DesignSystem.Colors.hermesAureate
        default:
            guard let provider = agentProvider else { return DesignSystem.Colors.whimsy }
            return DesignSystem.Colors.primary(for: provider)
        }
    }

    /// Foreground for the one place a tint is a *fill* (the glyph-fallback mark
    /// backdrop). Picks whichever of near-black / white carries the higher WCAG
    /// contrast against this agent's own tint.
    ///
    /// The spec's "clears 4.5:1 for all 12" is unreachable without minting new
    /// hexes, which §6.1 forbids: `8B5CF6` (Droid) tops out at 4.41:1 and
    /// `6C63FF` (Antigravity) at 4.32:1 against *either* ink — they are genuine
    /// mid-tones. Both clear the 3.0:1 large-text bar, and the mark glyph is
    /// ≥14pt semibold, so the fill path stays legible. Everything else the tint
    /// touches is a rim, a dot or a ≤3pt bar over the app background, where the
    /// containment law — not the ink — carries the contrast.
    var sigilInk: Color {
        AgentDeckContrast.prefersDarkInk(overTintHex: sigilTintHex)
            ? Color(hex: "151210")
            : .white
    }

    /// Explanatory noun borrowed verbatim from the mobile twin
    /// (`OpenBurnBarMobile/Views/Hermes/AgentSwitcherSheet.swift`) — the only
    /// place in the repo that already ships this copy. Never says "engine",
    /// "backend", "runtime" or "harness"… except "Agent harness", which is
    /// mobile's own shipped wording for Hermes.
    var kindLabel: String {
        switch self {
        case .hermes: return "Agent harness"
        case .piAgent: return "Empathy agent"
        case .openclaw: return "Gateway agent"
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .openClaude, .omp, .junie, .fx,
             .grok, .kimi:
            return "CLI agent"
        }
    }

    /// The executable the deck probes to decide `.notInstalled`. Routed through
    /// `InteractiveTerminalLauncher`'s table so the deck can never drift from
    /// the names the app actually launches. `nil` for gateway agents (probed by
    /// HTTP instead) and for runtimes with no interactive invocation.
    @MainActor
    static func cliExecutableName(forRuntimeID runtimeID: String) -> String? {
        InteractiveTerminalLauncher.interactiveInvocation(
            runtimeId: runtimeID,
            modelID: nil,
            workingDirectory: nil
        )?.executableName
    }
}

/// Pure WCAG maths for the deck. Hoisted out of SwiftUI so it is unit-testable.
enum AgentDeckContrast {
    /// Near-black ink, matching `ChatBackendID.activeForeground`'s Hermes value.
    static let darkInkRGB = BackdropRGB(21, 18, 16)   // 151210
    static let lightInkRGB = BackdropRGB(255, 255, 255)

    static func rgb(fromHex hex: String) -> BackdropRGB {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        guard cleaned.count == 6 else { return BackdropRGB(0, 0, 0) }
        return BackdropRGB(
            Double((value >> 16) & 0xFF),
            Double((value >> 8) & 0xFF),
            Double(value & 0xFF)
        )
    }

    static func contrastRatio(inkRGB: BackdropRGB, tintHex: String) -> Double {
        BackdropContrast.ratio(inkRGB, rgb(fromHex: tintHex))
    }

    /// True when near-black beats white on this tint.
    static func prefersDarkInk(overTintHex hex: String) -> Bool {
        contrastRatio(inkRGB: darkInkRGB, tintHex: hex)
            >= contrastRatio(inkRGB: lightInkRGB, tintHex: hex)
    }

    /// The contrast the chosen ink actually achieves.
    static func inkContrastRatio(forTintHex hex: String) -> Double {
        max(
            contrastRatio(inkRGB: darkInkRGB, tintHex: hex),
            contrastRatio(inkRGB: lightInkRGB, tintHex: hex)
        )
    }
}

// MARK: - Agent Deck · presence  → AgentDeck/AgentPresence.swift

/// Which structural gate is standing between the user and this agent.
enum AgentAuthGate: Equatable, Sendable {
    case hermesSetup
    case hermesCatalog
    case cliConsent
}

/// What an agent is doing right now. Eight states, because eight is what the
/// code actually distinguishes.
enum AgentPresence: Equatable, Sendable {
    case ready
    case thinking(since: Date)
    case streaming(since: Date)
    case exhausted
    case needsAuth(AgentAuthGate)
    case offline
    case notInstalled
    case error(String)

    /// The redundant, non-colour channel (§5): filled = the agent can work,
    /// hollow = it needs you, dashed = it is not there. Survives colourblindness
    /// *and* the Editorial skin.
    enum DotStyle: Equatable, Sendable {
        case filled
        case hollow
        case dashed
    }

    var word: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking"
        case .streaming: return "Answering"
        case .exhausted: return "Out of quota"
        case .needsAuth(.hermesSetup): return "Needs setup"
        case .needsAuth(.hermesCatalog): return "Needs sign-in"
        case .needsAuth(.cliConsent): return "Needs permission"
        case .offline: return "Not running"
        case .notInstalled: return "Not installed on this Mac"
        case .error: return "Failed"
        }
    }

    var dotStyle: DotStyle {
        switch self {
        case .ready, .thinking, .streaming, .exhausted, .error: return .filled
        case .needsAuth, .offline: return .hollow
        case .notInstalled: return .dashed
        }
    }

    /// Second redundant channel: a 5–7pt glyph beside the dot.
    var glyph: String? {
        switch self {
        case .ready: return nil
        case .thinking: return "ellipsis"
        case .streaming: return nil
        case .exhausted: return "gauge.with.dots.needle.0percent"
        case .needsAuth(.hermesSetup): return "wrench.and.screwdriver"
        case .needsAuth(.hermesCatalog): return "key.fill"
        case .needsAuth(.cliConsent): return "lock"
        case .offline: return "play.fill"
        case .notInstalled: return "arrow.down.circle"
        case .error: return "exclamationmark"
        }
    }

    var isBusy: Bool {
        switch self {
        case .thinking, .streaming: return true
        default: return false
        }
    }

    var busySince: Date? {
        switch self {
        case .thinking(let since), .streaming(let since): return since
        default: return nil
        }
    }
}

/// Everything the resolver needs, and nothing that needs SwiftUI or a live
/// controller — so the precedence order is testable in isolation.
struct AgentPresenceFacts: Equatable, Sendable {
    var isStreaming = false
    /// `sendInFlight && !isStreaming`.
    var isThinking = false
    var busySince: Date?
    /// `nil` when this agent has no local executable to probe (gateway agents,
    /// or a runtime with no interactive invocation).
    var executableResolved: Bool?
    /// `nil` when this agent is not a gateway agent.
    var gatewayReachable: Bool?
    var authGate: AgentAuthGate?
    /// `nil` for the six agents with no quota signal at all — the meter
    /// self-hides rather than fabricating a number (§5, quota honesty).
    var quotaRemainingFraction: Double?
    var streamError: String?
}

enum AgentPresenceResolver {
    /// Precedence, highest first: streaming → thinking → notInstalled → offline
    /// → needsAuth → exhausted → error → ready.
    ///
    /// Liveness beats everything because it is happening *now*; structural gates
    /// beat faults because they explain them; `exhausted` beats `error` because
    /// it is the specific diagnosis of the generic failure.
    static func resolve(_ facts: AgentPresenceFacts, now: Date = Date()) -> AgentPresence {
        if facts.isStreaming { return .streaming(since: facts.busySince ?? now) }
        if facts.isThinking { return .thinking(since: facts.busySince ?? now) }
        if facts.executableResolved == false { return .notInstalled }
        if facts.gatewayReachable == false { return .offline }
        if let gate = facts.authGate { return .needsAuth(gate) }
        if let fraction = facts.quotaRemainingFraction, fraction <= 0 { return .exhausted }
        if let error = facts.streamError, !error.isEmpty { return .error(error) }
        return .ready
    }
}

// MARK: - Agent Deck · presence model  → AgentDeck/AgentPresenceModel.swift

/// One fleet-wide `@Observable`, resolved once per render pass — never one
/// subscription per chip. Gateway probes reuse the controller's existing
/// published `*Available` flags (zero new network traffic); CLI executable
/// probes are cached behind a 60s TTL layered on `CLIExecutableResolver`'s own
/// actor cache.
@MainActor
@Observable
final class AgentPresenceModel {
    static let executableProbeTTL: TimeInterval = 60

    private(set) var presence: [ChatBackendID: AgentPresence] = [:]
    /// "Tab 2" / "this chat" — where the live turn is landing.
    private(set) var busyLocation: [ChatBackendID: String] = [:]

    @ObservationIgnored private var busySince: [ChatBackendID: Date] = [:]
    @ObservationIgnored private var executableResolved: [ChatBackendID: Bool] = [:]
    @ObservationIgnored private var executableProbedAt: [ChatBackendID: Date] = [:]
    @ObservationIgnored private var executableProbeInFlight: Set<ChatBackendID> = []

    func presence(for backend: ChatBackendID) -> AgentPresence {
        presence[backend] ?? .ready
    }

    func busyLocation(for backend: ChatBackendID) -> String? {
        busyLocation[backend]
    }

    /// Recompute every backend's presence from state that already exists.
    /// O(panes × backends); no I/O.
    func refresh(
        backends: [ChatBackendID],
        controllers: [ChatSessionController],
        locations: [ObjectIdentifier: String] = [:],
        settingsManager: SettingsManager,
        quotaService: ProviderQuotaService,
        now: Date = Date()
    ) {
        var next: [ChatBackendID: AgentPresence] = [:]
        var nextLocation: [ChatBackendID: String] = [:]

        for backend in backends {
            let driving = controllers.filter { $0.chatBackend == backend }
            let busyController = driving.first { $0.isSendBusy }
            let isStreaming = driving.contains { $0.isStreaming }
            let isThinking = busyController != nil && !isStreaming

            if busyController != nil {
                if busySince[backend] == nil { busySince[backend] = now }
            } else {
                busySince[backend] = nil
            }
            if let busyController, let where_ = locations[ObjectIdentifier(busyController)] {
                nextLocation[backend] = where_
            }

            // Availability is read off whichever controller is nearest: the one
            // driving this agent, else the first one (every controller mirrors
            // the same gateway probe flags).
            let probe = driving.first ?? controllers.first

            next[backend] = AgentPresenceResolver.resolve(
                AgentPresenceFacts(
                    isStreaming: isStreaming,
                    isThinking: isThinking,
                    busySince: busySince[backend],
                    executableResolved: executableResolved[backend],
                    gatewayReachable: Self.gatewayReachable(backend, controller: probe, settingsManager: settingsManager),
                    authGate: Self.authGate(backend, controller: probe, settingsManager: settingsManager),
                    quotaRemainingFraction: Self.quotaFraction(
                        backend,
                        service: quotaService,
                        cumulative: settingsManager.cumulativeAcrossAccounts
                    ),
                    streamError: driving.compactMap(\.streamError).first
                ),
                now: now
            )
        }

        presence = next
        busyLocation = nextLocation
    }

    /// Probe the local executables behind the CLI agents, at most once per agent
    /// per TTL window. Gateway agents never reach the filesystem here.
    func refreshExecutables(
        backends: [ChatBackendID],
        runtimeIDs: [ChatBackendID: String],
        now: Date = Date()
    ) async {
        for backend in backends where backend.requiresCLIAssistantConsent {
            if let probedAt = executableProbedAt[backend],
               now.timeIntervalSince(probedAt) < Self.executableProbeTTL {
                continue
            }
            guard !executableProbeInFlight.contains(backend) else { continue }
            guard let runtimeID = runtimeIDs[backend],
                  let name = ChatBackendID.cliExecutableName(forRuntimeID: runtimeID)
            else {
                // No interactive invocation is registered for this runtime, so
                // "installed?" is unknowable — stay silent instead of claiming
                // the agent is missing.
                executableProbedAt[backend] = now
                executableResolved[backend] = nil
                continue
            }
            executableProbeInFlight.insert(backend)
            let resolved = await CLIExecutableResolver().resolveExecutable(named: name)
            executableProbeInFlight.remove(backend)
            executableProbedAt[backend] = now
            executableResolved[backend] = (resolved != nil)
        }
    }

    // MARK: Fact extraction

    private static func gatewayReachable(
        _ backend: ChatBackendID,
        controller: ChatSessionController?,
        settingsManager: SettingsManager
    ) -> Bool? {
        guard let controller else { return nil }
        switch backend {
        case .hermes:
            // Before the wizard runs, "not running" is not the honest word —
            // `needsAuth(.hermesSetup)` is, and it outranks nothing it should.
            guard settingsManager.hermesSetupWizardCompleted else { return nil }
            return controller.hermesAvailable
        case .openclaw: return controller.openClawAvailable
        case .piAgent: return controller.piAgentAvailable
        default: return nil
        }
    }

    private static func authGate(
        _ backend: ChatBackendID,
        controller: ChatSessionController?,
        settingsManager: SettingsManager
    ) -> AgentAuthGate? {
        if backend == .hermes {
            if !settingsManager.hermesSetupWizardCompleted { return .hermesSetup }
            if controller?.hermesCatalogAuthRejected == true { return .hermesCatalog }
        }
        // The exact predicate `ChatInputRow.shouldRequestCLIAssistantPermission`
        // reads, so the dot and the composer's permission strip never disagree.
        if backend.requiresCLIAssistantConsent, !settingsManager.cliAssistantAllowed {
            return .cliConsent
        }
        return nil
    }

    /// Only 6 of the 12 agents have a quota signal at all
    /// (`AgentProvider.quotaSignalProviders`). For the other six this returns
    /// `nil`, `.exhausted` is unreachable, and the meter self-hides rather than
    /// rendering an empty bar.
    ///
    /// `cumulative` is threaded through rather than defaulted so the Agent Deck
    /// presence dot reads the same bucket the Quota tab and the chip do. With
    /// the setting off those are per-account numbers; defaulting here would
    /// have put a summed-across-accounts fraction behind a per-account UI.
    private static func quotaFraction(
        _ backend: ChatBackendID,
        service: ProviderQuotaService,
        cumulative: Bool
    ) -> Double? {
        guard let provider = backend.agentProvider else { return nil }
        return ProviderQuotaChip.resolve(
            provider: provider,
            style: .full,
            displayName: backend.displayName,
            service: service,
            cumulative: cumulative
        )?.remainingFraction
    }

    /// Every input `refresh` reads, folded into one value. `.task(id:)` re-runs
    /// the refresh when this changes, so an input missing here is an input the
    /// presence dot never reacts to.
    ///
    /// `cumulativeAcrossAccounts` belongs here because `quotaFraction` above
    /// classifies `.exhausted` off the cumulative-or-per-account fraction. For a
    /// provider whose two fractions straddle zero, leaving it out froze the dot
    /// on its previous status — while the quota chip right beside it had already
    /// flipped — until some unrelated input happened to change.
    static func presenceRefreshKey(
        fleet: String,
        enabledBackends: String,
        gatewayAvailability: String,
        authGates: String,
        usagesVersion: Int,
        cumulativeAcrossAccounts: Bool
    ) -> String {
        [
            fleet,
            enabledBackends,
            gatewayAvailability,
            authGates,
            "\(usagesVersion)",
            cumulativeAcrossAccounts ? "cumulative" : "per-account"
        ].joined(separator: "#")
    }
}

// MARK: - Agent Deck · switching  → AgentDeck/AgentDeckSwitcher.swift

/// The one place a click becomes a switch. Preserves today's three-way
/// asymmetry byte-for-byte (`ChatEngineBackendStrip.handleBackendTap`): Hermes
/// with an incomplete wizard opens the wizard and does **not** switch;
/// unavailable Hermes switches first then launches; unavailable Pi launches
/// first and only switches if the re-probe succeeds.
@MainActor
@Observable
final class AgentDeckSwitcher {
    @ObservationIgnored private let hermesRuntimeLauncher = HermesRuntimeLauncher()
    @ObservationIgnored private let piAgentRuntimeAdapter = PiAgentRuntimeAdapter()

    func select(
        _ backend: ChatBackendID,
        controller: ChatSessionController,
        settingsManager: SettingsManager
    ) {
        if backend == .hermes && !settingsManager.hermesSetupWizardCompleted {
            WindowManager.shared.openHermesSetupWizard(
                settingsManager: settingsManager,
                chatController: controller
            )
            return
        }
        if backend == .hermes && controller.hermesAvailable == false {
            controller.setChatBackend(.hermes)
            Task {
                _ = await hermesRuntimeLauncher.openHermesAndGateway(
                    baseURL: Self.hermesGatewayBaseURL(settingsManager),
                    bearerToken: Self.hermesBearerToken(settingsManager)
                )
                await controller.probeHermesAvailability()
            }
            return
        }
        if backend == .piAgent && controller.piAgentAvailable == false {
            Task {
                syncPiAgentAdapterPreferences(settingsManager)
                _ = await piAgentRuntimeAdapter.openManagedRuntime(
                    baseURL: Self.piAgentGatewayBaseURL(settingsManager),
                    bearerToken: Self.piAgentBearerToken(settingsManager)
                )
                await controller.probePiAgentAvailability()
                if controller.piAgentAvailable {
                    controller.setChatBackend(.piAgent)
                }
            }
            return
        }
        controller.setChatBackend(backend)
    }

    private func syncPiAgentAdapterPreferences(_ settingsManager: SettingsManager) {
        let preferred = settingsManager.piAgentSelectedInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.preferredInstanceID = preferred.isEmpty ? nil : preferred
        let redisRaw = settingsManager.piAgentRedisURL.trimmingCharacters(in: .whitespacesAndNewlines)
        piAgentRuntimeAdapter.redisURL = redisRaw.isEmpty ? nil : URL(string: redisRaw)
    }

    private static func hermesGatewayBaseURL(_ settingsManager: SettingsManager) -> URL {
        URL(string: settingsManager.hermesGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8642")!
    }

    private static func hermesBearerToken(_ settingsManager: SettingsManager) -> String? {
        let token = settingsManager.hermesBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private static func piAgentGatewayBaseURL(_ settingsManager: SettingsManager) -> URL {
        URL(string: settingsManager.piAgentGatewayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://127.0.0.1:8765")!
    }

    private static func piAgentBearerToken(_ settingsManager: SettingsManager) -> String? {
        let token = settingsManager.piAgentBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

// MARK: - Agent Deck · atoms  → AgentDeck/AgentDeckAtoms.swift

/// The app-wide agent mark: a `ProviderLogoView` squircle, never a circle,
/// never a monogram. Falls back to the agent's glyph on its own tint only when
/// no provider mapping exists at all.
struct AgentMark: View {
    var backend: ChatBackendID
    var size: CGFloat

    var body: some View {
        Group {
            if let provider = backend.agentProvider {
                ProviderLogoView(provider: provider, size: size, useFallbackColor: false)
            } else {
                Text(backend.glyph)
                    .font(.system(size: size * 0.68, weight: .semibold, design: .rounded))
                    .foregroundStyle(backend.sigilInk)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                            .fill(backend.sigilTint)
                    )
            }
        }
        .frame(width: size, height: size)
    }
}

/// 6pt (Sigil) / 5pt (ghost). Filled, hollow, or dashed per §5 — colour is
/// never the only signal.
struct AgentPresenceDot: View {
    var presence: AgentPresence
    var tint: Color
    var size: CGFloat = 6
    /// Colour for the inert states (`.offline`, `.notInstalled`).
    ///
    /// Defaults to the historical `textMuted` so every existing call site is
    /// unchanged. Hosts drawn over the dashboard's live backdrop must pass
    /// `backdropInk.icon` instead: `textMuted` measures 3.77:1 against the
    /// app's own surface — it is the exact token
    /// `BackdropLegiblePlateTests.testInactiveDotTintClearsNonTextContrast`
    /// pins as a failure, and over a live backdrop the dot simply vanishes.
    var inactiveTint: Color = DesignSystem.Colors.textMuted

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Group {
            switch presence.dotStyle {
            case .filled:
                Circle().fill(color)
            case .hollow:
                Circle().strokeBorder(color, lineWidth: 1.25)
            case .dashed:
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size, height: size)
        .opacity(shouldPulse && pulsing ? 0.45 : 1)
        .animation(shouldPulse ? DesignSystem.Animation.mercuryPulse : nil, value: pulsing)
        .onAppear { pulsing = shouldPulse }
        .onChange(of: shouldPulse) { _, active in pulsing = active }
        .accessibilityHidden(true)
    }

    /// `.thinking` pulses; Reduce Motion makes it a static filled dot (the
    /// ellipsis glyph beside it still carries the meaning).
    private var shouldPulse: Bool {
        if reduceMotion { return false }
        if case .thinking = presence { return true }
        return false
    }

    private var color: Color {
        switch presence {
        case .ready: return DesignSystem.Colors.success
        case .thinking, .streaming: return tint
        case .exhausted: return DesignSystem.Colors.amber
        case .needsAuth: return DesignSystem.Colors.warning
        case .offline, .notInstalled: return inactiveTint
        case .error: return DesignSystem.Colors.error
        }
    }
}

// MARK: - Agent Deck · the Sigil  → AgentDeck/AgentSigil.swift

/// Always-on identity control: **presence dot · logo · agent name │ model ⌄**.
///
/// Two segments in one plate. The agent segment names who is answering; the
/// model segment is the *existing* `ChatEngineModelMenu` rows, absorbed rather
/// than replaced — the model never vanishes from this window again.
struct AgentSigil: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    /// Fleet source for presence. `nil` before the workspace is built.
    var workspace: PaneWorkspaceModel?
    /// Tier 6 swaps `displayName` for `shortLabel`; nothing below that.
    var usesShortLabel = false
    /// Tier 5 drops the elapsed suffix and narrows the model segment.
    var showsElapsed = true
    var modelWidth: CGFloat = 132
    /// Tiled: the focused pane's chip colour, prefixed so a window-level control
    /// visibly belongs to the pane it drives.
    var paneChipColor: Color?
    var paneTitle: String?
    /// The pane header renders a lower-profile plate (the header already has a
    /// background and a focus ring).
    var isCompact = false

    @State private var quotaService = ProviderQuotaService.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fleet models, injected on the controller (see `AgentDeck.swift`).
    private var presenceModel: AgentPresenceModel { controller.agentDeck.presence }
    private var switcher: AgentDeckSwitcher { controller.agentDeck.switcher }

    private var backend: ChatBackendID { controller.chatBackend }
    private var enabled: [ChatBackendID] { settingsManager.enabledChatBackends }
    private var hasAgents: Bool { !enabled.isEmpty }
    private var tint: Color { hasAgents ? backend.sigilTint : DesignSystem.Colors.warning }
    private var presence: AgentPresence { presenceModel.presence(for: backend) }

    private var nameText: String {
        guard hasAgents else { return "No agents enabled" }
        return usesShortLabel ? backend.shortLabel : backend.displayName
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            agentSegment
            Divider()
                .frame(height: 12)
                .opacity(0.35)
            modelSegment
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .frame(height: isCompact ? 22 : 26)
        .background { plate }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(rimStyle, style: StrokeStyle(lineWidth: rimWidth, dash: rimDash))
        }
        .clipShape(Capsule(style: .continuous))
        .mercuryShimmer(active: isStreamingNow && !reduceMotion)
        .contextMenu { sigilContextMenu }
        .animation(DesignSystem.Animation.standard, value: backend)
        .task(id: presenceRefreshKey) {
            refreshPresence()
            await presenceModel.refreshExecutables(
                backends: ChatBackendID.allCases,
                runtimeIDs: runtimeIDs
            )
            refreshPresence()
        }
    }

    // MARK: Segments

    @ViewBuilder
    private var agentSegment: some View {
        Menu {
            agentMenuContent
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                if let paneChipColor {
                    Circle()
                        .fill(paneChipColor)
                        .frame(width: 6, height: 6)
                }
                AgentPresenceDot(presence: presence, tint: tint, size: 6)
                if hasAgents {
                    AgentMark(backend: backend, size: 14)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.warning)
                }
                Text(nameText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(hasAgents ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.warning)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if controller.isElderWandActive {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                }
                // Second redundant channel beside the dot — colour is never the
                // only signal.
                if hasAgents, let glyph = presence.glyph {
                    Image(systemName: glyph)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agentAccessibilityLabel)
        .accessibilityHint("Opens the agent list")
        .accessibilityAddTraits(.isButton)
        .popoverTooltip(agentTooltip)
    }

    @ViewBuilder
    private var modelSegment: some View {
        Menu {
            ChatEngineModelMenu.modelRows(controller: controller)
        } label: {
            HStack(spacing: 3) {
                Text(modelLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: modelWidth, alignment: .leading)
                if showsElapsed, let since = presence.busySince {
                    elapsedSuffix(since: since)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Model: \(modelLabel)")
        .accessibilityAddTraits(.isButton)
        .popoverTooltip("Model for \(backend.displayName). Each agent remembers its own choice.")
        .task(id: backend) {
            await controller.agentDeck.modelCatalog.refreshIfNeeded(
                runtime: ChatEngineModelMenu.cliRuntime(for: backend),
                settingsManager: controller.settingsManager
            )
        }
    }

    /// The model never yields to a timer: elapsed time is a separate suffix that
    /// drops out first under width pressure (§3.3 rule 3).
    @ViewBuilder
    private func elapsedSuffix(since: Date) -> some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.elapsedText(since: since, now: context.date))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .monospacedDigit()
        }
    }

    static func elapsedText(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: Menus

    /// Tiled: the menu names the pane this window-level control drives.
    private var agentSectionHeader: String {
        guard let paneTitle else { return "Agents" }
        return "Focused pane · \(paneTitle)"
    }

    @ViewBuilder
    private var agentMenuContent: some View {
        if enabled.isEmpty {
            // The destination is reachable now, not merely named — the old
            // "Settings → Chat: enable engines" was dead 9pt text (§1.1e).
            Button("Enable agents in Settings → Chat") {
                AppCommandRouter.shared.openSettings?()
            }
        } else {
            Section(agentSectionHeader) {
                ForEach(enabled) { candidate in
                    Button {
                        switcher.select(candidate, controller: controller, settingsManager: settingsManager)
                    } label: {
                        Text(menuRowTitle(for: candidate))
                    }
                }
            }
            let others = ChatBackendID.allCases.filter { !enabled.contains($0) }
            if !others.isEmpty {
                Section("Not enabled") {
                    Button("\(others.count) more agents — Settings → Chat") {
                        AppCommandRouter.shared.openSettings?()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sigilContextMenu: some View {
        ChatEngineModelMenu.modelRows(controller: controller)
        Divider()
        Button("Agent settings…") { AppCommandRouter.shared.openSettings?() }
        if backend == .hermes, !settingsManager.hermesSetupWizardCompleted {
            Button("Set up Hermes…") {
                WindowManager.shared.openHermesSetupWizard(
                    settingsManager: settingsManager,
                    chatController: controller
                )
            }
        }
    }

    private func menuRowTitle(for candidate: ChatBackendID) -> String {
        let mark = candidate == backend ? "✓ " : "  "
        let state = presenceModel.presence(for: candidate)
        var line = "\(mark)\(candidate.displayName) — \(candidate.kindLabel) · \(state.word)"
        if let location = presenceModel.busyLocation(for: candidate), state.isBusy {
            line += " in \(location)"
        }
        return line
    }

    // MARK: Model label (§3.3 — never lies, never vanishes)

    var modelLabel: String {
        Self.modelLabel(
            backend: backend,
            effectiveModel: controller.effectiveChatModel(for: backend),
            selectedHermesFamily: settingsManager.selectedHermesModel,
            isElderWandActive: controller.isElderWandActive
        )
    }

    /// Three rules, enforced in one pure function:
    ///
    /// 1. **Alias never leaks.** The Hermes gateway's self alias (`"hermes"`)
    ///    renders as `Auto (gateway picks)`; a bare family token renders as
    ///    `Auto → Claude`. The picker never reads "Hermes · hermes" again.
    /// 2. **Route is shown, not hidden.** A concrete Hermes model reads
    ///    `claude-sonnet-4-6 · via Claude`.
    /// 3. The model never yields to a timer (enforced in the view).
    static func modelLabel(
        backend: ChatBackendID,
        effectiveModel: String,
        selectedHermesFamily: HermesModelID?,
        isElderWandActive: Bool
    ) -> String {
        let model = effectiveModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if isElderWandActive {
            // The pill stops lying: Elder Wand re-targets the send to the
            // BurnBar daemon fusion gateway with a different catalog.
            let judge = model.isEmpty ? "Automatic" : ChatSessionController.abbreviateChatModelName(model)
            return "Fusion → BurnBar gateway · \(judge)"
        }

        guard backend == .hermes else {
            return model.isEmpty ? "Default model" : ChatSessionController.abbreviateChatModelName(model)
        }

        if model == ChatSessionController.hermesCanonicalModelAlias {
            return "Auto (gateway picks)"
        }
        if let family = HermesModelID(rawValue: model) {
            return "Auto → \(family.displayName)"
        }
        if model.isEmpty { return "Auto (gateway picks)" }

        let short = ChatSessionController.abbreviateChatModelName(model)
        if let family = ChatSessionController.hermesFamilyHint(for: model) ?? selectedHermesFamily {
            return "\(short) · via \(family.displayName)"
        }
        return short
    }

    // MARK: Presence plumbing

    private var isStreamingNow: Bool {
        if case .streaming = presence { return true }
        return false
    }

    private var runtimeIDs: [ChatBackendID: String] {
        Dictionary(uniqueKeysWithValues: ChatBackendID.allCases.map {
            ($0, controller.assistantRuntimeID(for: $0).rawValue)
        })
    }

    /// Reading every input here is what registers the observation dependencies
    /// that re-run the refresh task.
    private var presenceRefreshKey: String {
        let fleet = fleetControllers
            .map { "\($0.chatBackend.rawValue):\($0.isStreaming ? 1 : 0)\($0.isSendBusy ? 1 : 0)\($0.streamError == nil ? 0 : 1)" }
            .joined(separator: "|")
        return AgentPresenceModel.presenceRefreshKey(
            fleet: fleet,
            enabledBackends: enabled.map(\.rawValue).joined(separator: ","),
            gatewayAvailability: "\(controller.hermesAvailable)\(controller.openClawAvailable)\(controller.piAgentAvailable)",
            authGates: "\(controller.hermesCatalogAuthRejected)\(settingsManager.hermesSetupWizardCompleted)\(settingsManager.cliAssistantAllowed)",
            usagesVersion: controller.dataStore.usagesVersion,
            cumulativeAcrossAccounts: settingsManager.cumulativeAcrossAccounts
        )
    }

    private var fleetControllers: [ChatSessionController] {
        guard let workspace else { return [controller] }
        let leaves = workspace.allLeaves.map(\.controller)
        return leaves.isEmpty ? [controller] : leaves
    }

    private func refreshPresence() {
        var locations: [ObjectIdentifier: String] = [:]
        if let workspace {
            for (index, tab) in workspace.tabs.enumerated() {
                let label = workspace.displayTitle(for: tab)
                let name = label.isEmpty ? "Tab \(index + 1)" : label
                for leaf in tab.leaves {
                    locations[ObjectIdentifier(leaf.controller)] = name
                }
            }
        }
        presenceModel.refresh(
            backends: ChatBackendID.allCases,
            controllers: fleetControllers,
            locations: locations,
            settingsManager: settingsManager,
            quotaService: quotaService
        )
    }

    // MARK: Chrome

    @ViewBuilder
    private var plate: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26, *) {
            shape
                .fill(tint.opacity(washAlpha))
                .liquidGlassInteractive(in: shape)
        } else {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
                shape.fill(tint.opacity(washAlpha))
            }
        }
    }

    /// One step above the plate law (`ChartCardView.swift:50-72`: wash
    /// 0.08 / 0.04, rim 0.22 @ 0.75pt) because the Sigil is the window's
    /// identity *control*, not a plate.
    private var washAlpha: Double { colorScheme == .dark ? 0.10 : 0.06 }

    private var rimWidth: CGFloat {
        // Editorial gets no `Color.adaptive` variant from
        // `DesignSystem.Colors.primary(for:)` — it returns a raw hex — so the
        // light skin gets the raised rim instead of a free variant.
        colorScheme == .dark ? 0.75 : 1.0
    }

    /// Dashed = "it is not there", the same third channel the presence dot uses.
    private var rimDash: [CGFloat] {
        if case .notInstalled = presence { return [2.5, 2.5] }
        return hasAgents ? [] : [2.5, 2.5]
    }

    private var rimStyle: AnyShapeStyle {
        if case .notInstalled = presence {
            return AnyShapeStyle(DesignSystem.Colors.textMuted.opacity(0.4))
        }
        if case .error = presence {
            return AnyShapeStyle(DesignSystem.Colors.error.opacity(0.7))
        }
        if !hasAgents {
            return AnyShapeStyle(DesignSystem.Colors.warning.opacity(0.7))
        }
        return AnyShapeStyle(tint.opacity(colorScheme == .dark ? 0.35 : 0.55))
    }

    // MARK: Accessibility

    private var agentAccessibilityLabel: String {
        guard hasAgents else { return "No agents enabled. Opens Settings to enable one." }
        var parts = ["Agent: \(backend.displayName)", backend.kindLabel, presence.word.lowercased()]
        if let since = presence.busySince {
            parts.append(Self.elapsedText(since: since, now: Date()))
        }
        parts.append("model \(modelLabel)")
        if let provider = backend.agentProvider,
           let quota = ProviderQuotaChip.resolve(
            provider: provider,
            style: .full,
            displayName: backend.displayName,
            service: quotaService,
            cumulative: settingsManager.cumulativeAcrossAccounts
           ) {
            parts.append("\(quota.accessibilityLabel)")
        }
        return parts.joined(separator: ", ")
    }

    private var agentTooltip: String {
        guard hasAgents else { return "No agents enabled — open Settings → Chat" }
        var text = "\(backend.displayName) — \(backend.kindLabel) — \(presence.word)"
        if let location = presenceModel.busyLocation(for: backend), presence.isBusy {
            text += " in \(location)"
        }
        return text
    }
}

// MARK: - Agent Deck · ghosts  → AgentDeck/AgentGhostRow.swift

/// The mouse path, protected. Every *other* enabled agent as a one-click 18pt
/// button with its own live presence dot. Collapses to a single `+N ⌄` chip
/// under width pressure but **never** to nothing — dropping it would make
/// one-click switching disappear exactly where the roster matters most.
struct AgentGhostRow: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    /// 0 collapses every ghost into the overflow chip.
    var limit: Int = 5

    @State private var hovered: ChatBackendID?

    /// Fleet models, injected on the controller (see `AgentDeck.swift`).
    private var presenceModel: AgentPresenceModel { controller.agentDeck.presence }
    private var switcher: AgentDeckSwitcher { controller.agentDeck.switcher }

    private var others: [ChatBackendID] {
        settingsManager.enabledChatBackends.filter { $0 != controller.chatBackend }
    }

    private var visible: [ChatBackendID] { Array(others.prefix(max(0, limit))) }
    private var hidden: [ChatBackendID] { Array(others.dropFirst(max(0, limit))) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(visible) { backend in
                ghost(backend)
            }
            if !hidden.isEmpty {
                overflowChip
            }
        }
        .animation(DesignSystem.Animation.snappy, value: others)
    }

    @ViewBuilder
    private func ghost(_ backend: ChatBackendID) -> some View {
        let presence = presenceModel.presence(for: backend)
        Button {
            switcher.select(backend, controller: controller, settingsManager: settingsManager)
        } label: {
            HStack(spacing: 2) {
                AgentPresenceDot(presence: presence, tint: backend.sigilTint, size: 5)
                AgentMark(backend: backend, size: 18)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(
                        backend.sigilTint.opacity(hovered == backend ? 0.45 : 0),
                        lineWidth: 0.75
                    )
            )
            .opacity(hovered == backend ? 1 : 0.62)
            .saturation(hovered == backend ? 1 : 0.55)
            .scaleEffect(hovered == backend ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(DesignSystem.Animation.hover) {
                hovered = inside ? backend : (hovered == backend ? nil : hovered)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(backend.displayName), \(backend.kindLabel), \(presence.word.lowercased())")
        .accessibilityHint("Switches this chat to \(backend.displayName)")
        .accessibilityAddTraits(.isButton)
        .popoverTooltip("\(backend.displayName) — \(backend.kindLabel) — \(presence.word)")
    }

    @ViewBuilder
    private var overflowChip: some View {
        Menu {
            ForEach(hidden) { backend in
                Button {
                    switcher.select(backend, controller: controller, settingsManager: settingsManager)
                } label: {
                    Text("\(backend.displayName) — \(backend.kindLabel) · \(presenceModel.presence(for: backend).word)")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text("+\(hidden.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.75)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("\(hidden.count) more agents")
        .popoverTooltip("\(hidden.count) more agents")
    }
}

// MARK: - Agent Deck · the bar  → AgentDeck/AgentSigilBar.swift

/// Sigil + ghosts, grouped so macOS 26 samples them as one glass region (glass
/// cannot sample glass and they sit 4pt apart).
struct AgentSigilBar: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    var workspace: PaneWorkspaceModel?
    var ghostLimit: Int = 5
    var usesShortLabel = false
    var showsElapsed = true
    var modelWidth: CGFloat = 132

    var body: some View {
        LiquidGlassGroup(spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                AgentSigil(
                    controller: controller,
                    settingsManager: settingsManager,
                    workspace: workspace,
                    usesShortLabel: usesShortLabel,
                    showsElapsed: showsElapsed,
                    modelWidth: modelWidth,
                    paneChipColor: focusedPaneChipColor,
                    paneTitle: focusedPaneTitle
                )
                AgentGhostRow(
                    controller: controller,
                    settingsManager: settingsManager,
                    limit: ghostLimit
                )
            }
        }
    }

    /// Tiled only: the Sigil's plate tint and the focused pane's ring are the
    /// same colour, which is what ties a window-level control to the pane it
    /// drives.
    private var focusedPaneChipColor: Color? {
        guard let workspace, workspace.isTiled else { return nil }
        return workspace.leaf(workspace.activeLeafID)?.colorToken?.color
            ?? DesignSystem.Colors.border.opacity(0.7)
    }

    private var focusedPaneTitle: String? {
        guard let workspace, workspace.isTiled else { return nil }
        let title = workspace.displayTitle(for: workspace.selectedTab)
        return title.isEmpty ? nil : title
    }
}

// MARK: - Toolbar

/// Slim toolbar shown at the top of `DashboardChatWorkspaceView`.
///
/// Leads with the always-on `AgentSigilBar` (who is answering, on what model,
/// doing what) and exposes a "New chat" affordance, the consolidated
/// `ChatMenuPopover`, optional Pop-out / Restore window buttons, and (in the
/// pop-out window) a Close.
///
/// The old `showsEnginePickers: !workspace.isTiled` gate is **deleted**: the top
/// of the window never goes anonymous again, tiled or not.
struct DashboardChatWorkspaceToolbar: View {
    @Bindable var controller: ChatSessionController
    var settingsManager: SettingsManager
    /// Mode controls which buttons are shown.
    var mode: DashboardChatWorkspaceView.Mode
    /// Fleet source for presence + the focused-pane chip. `nil` before the
    /// workspace is built.
    var workspace: PaneWorkspaceModel?

    /// Visibility of the thread rail. Collapsed by default so the chat route
    /// reads as a single vertical column; `nil` when the host has no rail.
    var threadRailVisible: Binding<Bool>?

    var onNewChat: () -> Void
    var onShowClearChatPrompt: () -> Void
    var onPopOut: (() -> Void)?
    var onRestoreFloating: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var showChatMenu = false

    private var accent: Color {
        controller.chatBackend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : DesignSystem.Colors.whimsy
    }

    /// Order of sacrifice, widest first (§3.6). The floor — presence dot, logo,
    /// short label, a ≥40pt model segment, the `+N ⌄` chip, desktop control,
    /// new chat and the ellipsis menu — is never crossed.
    enum Tier: Int, CaseIterable {
        /// Everything.
        case full = 1
        /// Drops folder, "Pop out", "Restore floating chat" — all three already
        /// duplicated in `ChatMenuPopover`.
        case dropWindowExtras
        /// Drops the view-mode picker and the quota chip — both already
        /// duplicated in `ChatMenuPopover`.
        case dropModeAndQuota
        /// Ghost row collapses to a single `+N ⌄` chip.
        case collapseGhosts
        /// Drops the elapsed suffix; the model segment narrows to 60pt.
        case dropElapsed
        /// `displayName` → `shortLabel`.
        case shortLabel

        var showsWindowExtras: Bool { self == .full }
        var showsModeAndQuota: Bool { rawValue <= Tier.dropWindowExtras.rawValue }
        var ghostLimit: Int { rawValue <= Tier.dropModeAndQuota.rawValue ? 5 : 0 }
        var showsElapsed: Bool { rawValue <= Tier.collapseGhosts.rawValue }
        var modelWidth: CGFloat { rawValue <= Tier.collapseGhosts.rawValue ? 132 : 60 }
        var usesShortLabel: Bool { self == .shortLabel }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(.full)
            controlRow(.dropWindowExtras)
            controlRow(.dropModeAndQuota)
            controlRow(.collapseGhosts)
            controlRow(.dropElapsed)
            controlRow(.shortLabel)
        }
        .animation(DesignSystem.Animation.gentle, value: controller.chatBackend)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        // An Apple toolbar is a *material*, not a fill: it takes its colour
        // from whatever scrolls under it. A flat 60% surface reads as a grey
        // band bolted to the top of the window in both themes.
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func controlRow(_ tier: Tier) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let threadRailVisible {
                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        threadRailVisible.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            threadRailVisible.wrappedValue
                                ? accent
                                : DesignSystem.Colors.textSecondary
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("l", modifiers: [.command, .control])
                .help(threadRailVisible.wrappedValue ? "Hide chat history (⌃⌘L)" : "Show chat history (⌃⌘L)")
                .accessibilityIdentifier(OBBAccessibilityID.dashboardChatRailToggle)
            }

            AgentSigilBar(
                controller: controller,
                settingsManager: settingsManager,
                workspace: workspace,
                ghostLimit: tier.ghostLimit,
                usesShortLabel: tier.usesShortLabel,
                showsElapsed: tier.showsElapsed,
                modelWidth: tier.modelWidth
            )
            .layoutPriority(1)

            if tier.showsModeAndQuota {
                ChatViewModePicker(controller: controller)

                if let quotaChip = ProviderQuotaChip(backend: controller.chatBackend) {
                    quotaChip
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }

            if tier.showsWindowExtras {
                Button {
                    controller.revealChatWorkspaceInFinder()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Show this chat's workspace in Finder")
            }

            ChatDesktopControlButton(controller: controller, tint: accent)

            Spacer(minLength: 0)

            Button(action: onNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            // Owns ⌘N because it is always on screen; the thread rail's own
            // New chat button is only present while the rail is expanded.
            .keyboardShortcut("n", modifiers: [.command])
            .help("New chat (⌘N)")

            Button {
                showChatMenu.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .help("Chat options")
            .popover(isPresented: $showChatMenu, arrowEdge: .top) {
                ChatMenuPopover(
                    controller: controller,
                    onShowClearChatPrompt: onShowClearChatPrompt,
                    onNewChat: onNewChat,
                    onPopOut: mode == .embedded ? onPopOut : nil,
                    onRestoreFloating: mode == .embedded ? onRestoreFloating : nil,
                    onRevealWorkspace: controller.revealChatWorkspaceInFinder
                )
            }

            if tier.showsWindowExtras, mode == .embedded, let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Pop out chat into its own window")
            }

            if tier.showsWindowExtras, mode == .embedded, let onRestoreFloating {
                Button(action: onRestoreFloating) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .help("Restore floating chat window")
            }

            if mode == .popOut, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
    }
}
