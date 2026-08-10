import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Control Deck · the four asynchronous tiles
//
// Model Router, The Wand, Memory MCP, and AI Inbox — the four features the
// owner named that PR1 could not ship, because each one's live fact lives
// behind something you have to *await*: a Unix socket, a loopback HTTP GET, an
// operating-layer snapshot, and a cloud roster.
//
// They live in their own file rather than in `ControlTileView.swift` for one
// reason worth writing down: these four are the tiles with a cost. Keeping them
// together keeps their cost discipline together, and makes it obvious when a
// fifth expensive tile joins them.
//
// Every arm here obeys the same two rules as PR1's seven:
//
//   1. It renders at least one **live fact** read from the real store named in
//      the design. Not one of these four is a labelled link.
//   2. Its controls may flip a preference. They may never grant trust, egress
//      data off-device, open a network listener, or destroy a ledger. Each arm
//      names the control it deliberately refuses, and why, at the call site.

// MARK: - R-1 / R-3 / R-4 · Model Router
//
// Live facts, all three read from the real gateway rather than from settings:
//
//   * how many models it is actually serving right now — one loopback
//     `GET /v1/models/catalog`, exactly the request `ConnectionsViewModel`
//     makes, counted by the `advertised` + `route_eligible` flags the gateway
//     itself sets;
//   * the endpoint a client has to be pointed at, composed from the live
//     `GatewaySettings.gatewayHost` / `.gatewayPort`;
//   * whether the gateway is fail-closed — token enforced, or loopback open.
//
// **NEVER on the deck (R-3): the gateway enable switch.** This is the sharpest
// refusal on the whole page, so it is written out. `GatewaySettings.gatewayEnabled`
// has a `didSet` that only persists (`Stores/GatewaySettings.swift:12-14`), and
// its sole reader is the daemon launch path at
// `OpenBurnBarDaemonManager+Lifecycle.swift:452`. A switch here would paint
// itself "off" while the gateway kept serving the user's provider credentials
// to every process on this Mac until the next daemon restart — a lie with a
// credential behind it. It stays click-through until a service-level observer
// lands. The same reasoning bars the auth token and `allowUnauthenticatedLoopback`
// (R-4): the token is never rendered, echoed, or copied, only *used* as a
// request header, and the loopback flag is CT because turning it on lets any
// same-host process spend the user's money.
//
// **Direct, and the only direct control here: copy.** Copying a loopback URL
// grants nothing.
struct ModelRouterTile: View {
    @Bindable var settingsManager: SettingsManager
    let model: ControlDeckModel
    let daemonManager: OpenBurnBarDaemonManager
    let onOpenSettings: (String?) -> Void

    @State private var copiedAt: Date?

    private var gateway: ControlDeckModel.RouterGatewayEndpoint {
        ControlDeckModel.RouterGatewayEndpoint(
            enabled: settingsManager.gatewayEnabled,
            host: settingsManager.gatewayHost,
            port: settingsManager.gatewayPort,
            authToken: settingsManager.gatewayAuthToken
        )
    }

    private var facts: RouterDeckFacts {
        RouterDeckFacts(
            enabled: settingsManager.gatewayEnabled,
            host: settingsManager.gatewayHost,
            port: settingsManager.gatewayPort,
            tokenConfigured: settingsManager.gatewayAuthToken.isEmpty == false,
            allowsUnauthenticatedLoopback: settingsManager.gatewayAllowUnauthenticatedLoopback,
            probe: model.routerProbe
        )
    }

    private var daemonIsHealthy: Bool {
        if case .healthy = daemonManager.status { return true }
        return false
    }

    private var state: ControlTileState {
        guard facts.isEnabled else { return .off }
        if case .failed(let reason) = model.routerProbe {
            // The repair is almost always "start the daemon", so say that
            // rather than making the user infer it from a socket error.
            return .unavailable(daemonIsHealthy ? reason : "The daemon is not running, so nothing is serving that port.")
        }
        if facts.posture.isAlarming {
            return .degraded("Loopback is open — any app on this Mac can spend your provider credits")
        }
        return .on
    }

    var body: some View {
        ControlTileShell(
            kind: .modelRouter,
            state: state,
            headline: facts.headline,
            accessibilityHeadline: facts.headline
        ) {
            control
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Text(facts.endpoint)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Point Cursor, VS Code, or any OpenAI-compatible client at this base URL.")

                ControlStatusChip(
                    label: facts.posture.label,
                    tint: facts.posture.isAlarming
                        ? DesignSystem.Colors.warning
                        : DesignSystem.Colors.success,
                    help: facts.posture.isAlarming
                        ? "The gateway is bound on loopback without a bearer token, so any process on this Mac can POST to it and spend your provider credits. Turn it back on in Settings → Daemon."
                        : "The gateway requires a bearer token. The token itself is never shown here."
                )

                Spacer(minLength: 0)

                if model.routerIsProbing {
                    ProgressView().controlSize(.small)
                } else {
                    ControlLinkButton(
                        title: facts.isEnabled ? "Re-check" : "Check",
                        help: "Ask the gateway for its model catalog again."
                    ) {
                        Task { await model.refreshRouter(gateway) }
                    }
                }

                ControlLinkButton(
                    title: "Router",
                    help: "Open Settings → Model Router, where the gateway switch, the auth token, and per-provider advertising live. Turning the gateway on or off needs a daemon restart, which is why it is not a switch here."
                ) {
                    onOpenSettings(ControlKind.modelRouter.settingsItemID)
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if copiedFlashIsShowing {
            ControlPrimaryButton(
                kind: .modelRouter,
                title: "Copied",
                glyph: "checkmark",
                tint: DesignSystem.Colors.success,
                help: "The endpoint is on your clipboard."
            ) {}
        } else {
            ControlPrimaryButton(
                kind: .modelRouter,
                title: "Copy endpoint",
                glyph: "doc.on.doc",
                help: "Copy \(facts.endpoint) so you can paste it into a client. Copying a loopback URL grants nothing — the bearer token is not included and is never shown."
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(facts.endpoint, forType: .string)
                copiedAt = Date()
            }
        }
    }

    /// A 1.5s acknowledgement, lifted from the shipped `ModelProxySettingsView`
    /// hero. Derived from a timestamp rather than a timer so a re-render cannot
    /// leave the button stuck on "Copied".
    private var copiedFlashIsShowing: Bool {
        guard let copiedAt else { return false }
        return Date().timeIntervalSince(copiedAt) < 1.5
    }
}

// MARK: - C-1 / C-2 · The Wand
//
// The Wand is the fan-out caster: one prompt, N parallel workers, keep the
// best. It is a **different feature** from the Elder Wand (the multi-model
// analysis bench under Chat), and this tile is the one the owner named.
//
// Live facts:
//
//   * the parallel ceiling this membership actually buys, from
//     `WandFanOut.maxParallel(for:)` against the *already-started*
//     `MacCloudEntitlementStore.shared` — read, never `.start()`ed, because
//     starting it opens five Firestore listeners and a StoreKit task;
//   * how many casts are in the air right now, from the live operating-layer
//     snapshot `MissionsLaneView` reads (`operatingLayer.snapshot.controllerRuntime`)
//     — the same source, so the two surfaces cannot disagree;
//   * what those casts have burned.
//
// **No fan-out width control here, deliberately.** The design sketches a
// 1·3·8·16 capsule writing a new `wand.defaultWorkerCount` preference, but
// `MacWandComposerSheet` seeds its width from `@State private var workerCount = 1`
// and reads no such key — so the capsule would persist a number nothing obeys.
// The ladder renders the tier ceiling read-only until the composer reads it,
// which is honest and one line to upgrade.
//
// **CT (C-2): Cast.** A cast spends provider credits and can edit files, so it
// goes through `MacWandComposerSheet`'s own `commandsAllowed` /
// `fileEditsAllowed` / `requireApproval` gates rather than firing from a tile.
struct TheWandTile: View {
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let onCast: () -> Void
    let onNavigate: (DashboardMainRoute) -> Void

    @StateObject private var entitlement = MacCloudEntitlementStore.shared

    private var missions: [OpenBurnBarControllerMissionRecord] {
        operatingLayer.snapshot.controllerRuntime.missions
    }

    private var facts: WandDeckFacts {
        WandDeckFacts(
            tier: entitlement.cloudTier,
            casting: missions.filter { $0.state == .running || $0.state == .partial }.count,
            awaitingApproval: missions.filter { $0.approval == .pending }.count,
            blocked: missions.filter { $0.state == .blocked }.count,
            totalMissions: missions.count,
            burnUSD: missions.reduce(0) { $0 + $1.burnCostUSD }
        )
    }

    private var state: ControlTileState {
        let facts = facts
        if facts.blocked > 0 {
            return .degraded("\(facts.blocked) cast\(facts.blocked == 1 ? "" : "s") blocked")
        }
        if facts.awaitingApproval > 0 {
            return .degraded("\(facts.awaitingApproval) waiting for your approval")
        }
        return facts.casting > 0 ? .on : .off
    }

    var body: some View {
        let facts = facts
        ControlTileShell(
            kind: .wand,
            state: state,
            headline: facts.headline,
            accessibilityHeadline: facts.headline
        ) {
            ControlPrimaryButton(
                kind: .wand,
                title: "Cast…",
                glyph: "wand.and.stars",
                help: "Open the composer. A cast spends provider credits and can run commands or edit files, so it stays behind the composer's own approval switches."
            ) {
                onCast()
            }
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlTierLadder(
                    accent: ControlKind.wand.accent,
                    ceiling: facts.ceiling
                )
                .help("Parallel workers per cast: Free 1 · Cloud 3 · Pro 8 · Ultra 16. Yours is \(facts.ceiling) on \(facts.tierLabel).")

                ControlStatusChip(
                    label: facts.burnLabel,
                    tint: facts.burnLabel == "No cast spend"
                        ? DesignSystem.Colors.textMuted.opacity(0.5)
                        : ControlKind.wand.accent,
                    help: "What every mission on the board has burned so far."
                )

                Spacer(minLength: 0)

                ControlLinkButton(
                    title: "Missions",
                    help: "Open the Missions lane — the flight board for everything you have cast."
                ) {
                    onNavigate(.missions)
                }
            }
        }
    }
}

/// The Wand's tier ladder, read-only: 1 · 3 · 8 · 16 with the rung this
/// membership actually reaches lit. Read-only on purpose — see `TheWandTile`.
private struct ControlTierLadder: View {
    let accent: Color
    let ceiling: Int

    @Environment(\.colorScheme) private var colorScheme

    private var rungs: [Int] { CloudTier.allCases.map { WandFanOut.maxParallel(for: $0) } }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(rungs, id: \.self) { rung in
                let reached = rung <= ceiling
                Text("\(rung)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(
                        reached ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if rung == ceiling {
                            Capsule().fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10))
                        }
                    }
            }
        }
        .padding(2)
        .background(Capsule().fill(accent.opacity(colorScheme == .dark ? 0.05 : 0.03)))
        .overlay(Capsule().stroke(accent.opacity(0.18), lineWidth: 0.75))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan-out ceiling")
        .accessibilityValue("\(ceiling) parallel workers")
    }
}

// MARK: - K-5 / K-6 · Memory MCP
//
// The agents allowed to search your encrypted session memory over Remote MCP.
//
// Live facts, and every unavailable branch written out because this is the tile
// with the most ways to be honestly empty:
//
//   * whether Firebase is configured on this Mac at all;
//   * whether anyone is signed in (`AccountManager`, already `@Observable`);
//   * whether the membership reaches Hosted MCP's `cloud_pro` gate, read from
//     the already-started entitlement store;
//   * and, once asked, how many clients are actually connected and when one
//     last used the endpoint — from `users/{uid}/remote_mcp_clients`, the same
//     collection `MacRemoteMCPClientStore` reads.
//
// **The roster read is one-shot and never happens on appear.**
// `MacRemoteMCPClientStore.startListening()` opens a live Firestore snapshot
// listener; a deck that opened one per visit would leave a cloud subscription
// running behind a page you glance at. So the tile reads once, when asked, and
// stamps the number with when it was read — a count that admits its own age
// beats a live number that costs a subscription.
//
// **NEVER on the deck (K-6): revoke a client.** Revocation is a high-risk owner
// callable (`ComputerUseSecurityCallableClient.callHighRiskOwnerAction`). It
// stays in `MacRemoteMCPConnectedClientsSection` behind its own confirmation.
struct MemoryMCPTile: View {
    let model: ControlDeckModel
    let accountManager: AccountManager
    let onOpenSettings: (String?) -> Void

    @StateObject private var entitlement = MacCloudEntitlementStore.shared
    @State private var copiedAt: Date?

    private var facts: MCPDeckFacts {
        MCPDeckFacts(
            cloudConfigured: accountManager.isFirebaseAvailable,
            signedIn: accountManager.isSignedIn,
            tierUnlocked: entitlement.cloudTier.satisfies(
                GatedFeature.gatedFeature(.hostedMCP).requiredTier
            ),
            reading: model.mcpReading,
            errorMessage: model.mcpErrorMessage
        )
    }

    private var state: ControlTileState {
        let facts = facts
        switch facts.availability {
        case .cloudNotConfigured, .signedOut, .failed:
            return .unavailable(facts.availability.reason ?? "Unavailable")
        case .tierLocked:
            return .locked(.hostedMCP)
        case .ready:
            return (facts.connectedCount ?? 0) > 0 ? .on : .off
        }
    }

    var body: some View {
        let facts = facts
        ControlTileShell(
            kind: .memoryMCP,
            state: state,
            headline: facts.headline,
            accessibilityHeadline: facts.headline
        ) {
            control(facts)
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                Text(facts.endpoint)
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("The hosted Remote MCP endpoint. Paste it into Codex, Claude Code, Droid, Kimi, or any MCP client.")

                if facts.checkedLabel.isEmpty == false {
                    ControlStatusChip(
                        label: "Read \(facts.checkedLabel)",
                        help: "This tile reads the roster once, when you ask. It never leaves a cloud listener running behind the page."
                    )
                }

                Spacer(minLength: 0)

                copyButton(facts)

                ControlLinkButton(
                    title: "Cloud",
                    help: "Open Settings → Cloud, where the client roster lives and where a client can be revoked behind its confirmation."
                ) {
                    onOpenSettings(ControlKind.memoryMCP.settingsItemID)
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ facts: MCPDeckFacts) -> some View {
        if model.mcpIsChecking {
            ProgressView().controlSize(.small).help("Reading the client roster…")
        } else {
            switch facts.availability {
            case .ready, .failed:
                ControlPrimaryButton(
                    kind: .memoryMCP,
                    title: model.mcpReading == nil ? "Check clients" : "Re-check",
                    glyph: "arrow.clockwise",
                    help: "Read the connected-client roster once. Nothing is granted, revoked, or subscribed to."
                ) {
                    Task { await model.checkMCPClients() }
                }
            case .signedOut:
                ControlPrimaryButton(
                    kind: .memoryMCP,
                    title: "Sign in…",
                    glyph: "person.crop.circle",
                    tint: DesignSystem.Colors.warning,
                    help: "Opens Settings → Account. Signing in is an account action, so it happens where the account lives."
                ) {
                    onOpenSettings("account.signIn")
                }
            case .cloudNotConfigured:
                // No control at all: there is nothing this Mac can do about a
                // build without Firebase configured, and a dead button would be
                // worse than none.
                EmptyView()
            case .tierLocked:
                ControlPrimaryButton(
                    kind: .memoryMCP,
                    title: "See Cloud Pro",
                    glyph: "sparkles",
                    help: "Hosted Remote MCP needs Cloud Pro. Opens Settings → Cloud, where the upgrade sheet lives."
                ) {
                    onOpenSettings(ControlKind.memoryMCP.settingsItemID)
                }
            }
        }
    }

    @ViewBuilder
    private func copyButton(_ facts: MCPDeckFacts) -> some View {
        ControlLinkButton(
            title: copiedFlashIsShowing ? "Copied" : "Copy endpoint",
            help: "Copy \(facts.endpoint). The endpoint is public; the credential that authorises a client is issued during setup and is never shown here."
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(facts.endpoint, forType: .string)
            copiedAt = Date()
        }
    }

    private var copiedFlashIsShowing: Bool {
        guard let copiedAt else { return false }
        return Date().timeIntervalSince(copiedAt) < 1.5
    }
}

// MARK: - S-5 / S-6 / S-7 · AI Inbox
//
// The background analyst: it reads your work on a cadence and tells you what
// needs you. Four live facts, three of them from the daemon that owns the loop:
//
//   * unread items, a local `COUNT` that survives a dead daemon;
//   * today's spend against today's budget, from `daemon.inbox.runs.recent` —
//     the daemon's usage ledger, not the app's lagging mirror;
//   * how often the loop found nothing to do, which is the honest answer to
//     "is this thing burning money in the background?";
//   * and **whether the last tick actually reached a model.**
//
// That last one is the reason this tile earns its place. A tick that cannot
// reach its analyst still writes items and still renders a brief — from the
// deterministic rule engine — and looks identical to a real one. The signature
// is `llmCalls == 0` while the egress mode allows model calls, and until now it
// was visible nowhere. `InboxDeckFacts.Analyst.couldNotRun` names it, and the
// tile wears the attention plate when it happens.
//
// **Direct: the run switch.** It is a daemon round trip
// (`daemon.inbox.config.update`) and the tile renders the config the daemon
// *stored* after re-clamping, never the optimistic one.
//
// **CT (S-6): the egress mode.** Moving *to* cloud models changes what leaves
// this Mac and belongs behind the confirmation dialog in Settings that names
// exactly what is sent. Every downgrade is one tap — there.
//
// **CT (S-7): phone sync.** Off-device consequence.
struct AIInboxTile: View {
    let model: ControlDeckModel
    let onNavigate: (DashboardMainRoute) -> Void
    let onOpenSettings: (String?) -> Void

    private var facts: InboxDeckFacts {
        InboxDeckFacts(
            unreadCount: model.inboxUnreadCount,
            config: model.inboxConfig,
            runs: model.inboxRuns,
            todaySpendUSD: model.inboxTodaySpendUSD,
            unavailableReason: model.inboxUnavailableReason
        )
    }

    private var state: ControlTileState {
        let facts = facts
        if let reason = model.inboxUnavailableReason {
            return .unavailable(reason)
        }
        if let error = model.inboxActionError {
            return .degraded(error)
        }
        if facts.analyst.isAlarming {
            return .degraded(analystExplanation(facts.analyst))
        }
        guard model.inboxConfig != nil else { return .unavailable("Reading the daemon…") }
        return facts.isEnabled ? .on : .off
    }

    /// The degraded note is the *consequence*, not the mechanism: "the brief you
    /// are reading was written by rules" is what a user needs, not "llmCalls
    /// was zero".
    private func analystExplanation(_ analyst: InboxDeckFacts.Analyst) -> String {
        switch analyst {
        case .couldNotRun:
            return "The analyst model did not run — that brief came from the rule engine"
        case .failed(let reason):
            return "The last check failed — \(reason.prefix(60))"
        default:
            return analyst.label
        }
    }

    var body: some View {
        let facts = facts
        ControlTileShell(
            kind: .aiInbox,
            state: state,
            headline: facts.headline,
            accessibilityHeadline: facts.headline
        ) {
            control(facts)
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(
                    label: facts.analyst.label,
                    tint: analystTint(facts.analyst),
                    help: analystHelp(facts.analyst)
                )

                if facts.skipSummary.isEmpty == false {
                    ControlStatusChip(
                        label: facts.skipSummary,
                        help: "Ticks that found nothing changed cost nothing. A high number here is the loop working correctly, not failing."
                    )
                }

                ControlStatusChip(
                    label: facts.egressLabel,
                    tint: facts.egressLabel == "Cloud models"
                        ? DesignSystem.Colors.warning
                        : DesignSystem.Colors.textMuted.opacity(0.5),
                    help: "What the analyst is allowed to send off this Mac. Changing it is a confirmed action and lives in Settings, where the dialog names exactly what leaves."
                )

                Spacer(minLength: 0)

                if model.inboxIsRunningNow {
                    ProgressView().controlSize(.small)
                } else if facts.isReachable {
                    ControlLinkButton(
                        title: "Analyze now",
                        help: "Force one tick. The daemon still applies its own budget, egress, and approval gates and will refuse with a reason."
                    ) {
                        Task { await model.runInboxNow() }
                    }
                }

                ControlLinkButton(title: "Inbox", help: "Open the AI Inbox.") {
                    onNavigate(.inbox)
                }
            }
        }
    }

    @ViewBuilder
    private func control(_ facts: InboxDeckFacts) -> some View {
        if model.inboxIsSaving || model.inboxIsLoading {
            ProgressView().controlSize(.small).help("Talking to the daemon…")
        } else if model.inboxUnavailableReason != nil {
            ControlPrimaryButton(
                kind: .aiInbox,
                title: "Retry",
                glyph: "arrow.clockwise",
                tint: DesignSystem.Colors.warning,
                help: "Drop the cached daemon token and ask again."
            ) {
                Task { await model.loadInbox(forceTokenRefresh: true) }
            }
        } else if model.inboxConfig == nil {
            ControlPrimaryButton(
                kind: .aiInbox,
                title: "Load",
                glyph: "arrow.clockwise",
                help: "Read the inbox configuration from the daemon."
            ) {
                Task { await model.loadInbox() }
            }
        } else {
            ControlSwitch(
                kind: .aiInbox,
                label: "Run",
                glyph: "tray.full",
                isOn: facts.isEnabled,
                onHelp: "The analyst is running on its cadence. It obeys the egress mode and the daily budget shown here.",
                offHelp: "Turn on the background analyst. It starts in whatever egress mode is already set — turning it on does not widen what leaves this Mac."
            ) {
                let next = !facts.isEnabled
                Task { await model.setInboxEnabled(next) }
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "ai_inbox_enabled",
                    "new_value": .bool(next),
                    "source": "control_deck"
                ])
            }
        }
    }

    private func analystTint(_ analyst: InboxDeckFacts.Analyst) -> Color {
        switch analyst {
        case .couldNotRun, .failed: return DesignSystem.Colors.warning
        case .healthy: return DesignSystem.Colors.success
        case .ruleBasedByDesign, .idle, .neverRan: return DesignSystem.Colors.textMuted.opacity(0.5)
        }
    }

    private func analystHelp(_ analyst: InboxDeckFacts.Analyst) -> String {
        switch analyst {
        case .neverRan:
            return "The loop has not produced a substantive tick yet."
        case .idle:
            return "Recent ticks all found nothing changed, so none of them spent anything."
        case .healthy(let calls):
            return "The last substantive tick made \(calls) model call\(calls == 1 ? "" : "s"). The brief you are reading was written by the analyst."
        case .ruleBasedByDesign:
            return "Egress is off, so briefs are written by the deterministic rule engine. That is the setting working, not a fault."
        case .couldNotRun:
            return "The last substantive tick made zero model calls even though egress allows them — the brief came from the rule engine instead. Usually the daily budget is spent or the analyst provider is unreachable. Settings → AI Inbox shows which."
        case .failed(let reason):
            return "The last tick failed: \(reason)"
        }
    }
}
