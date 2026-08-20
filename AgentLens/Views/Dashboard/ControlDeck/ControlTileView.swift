import AppKit
import OpenBurnBarKernel
import SwiftUI

// MARK: - Control Tile View
//
// One arm per `ControlKind`. Every arm obeys the same two rules:
//
//   1. It renders at least one **live fact** read from the real store named in
//      the design. A tile that can only render a label is not shipped.
//   2. Its controls may flip a preference. They may never grant trust, egress
//      data off-device, open a network listener, or destroy a ledger. Anything
//      in that class is click-through only, and the reason is written at the
//      call site so the next engineer cannot "simplify" it back into a switch.

struct ControlTileView: View {
    let config: ControlTileConfig
    @Bindable var settingsManager: SettingsManager
    /// The live operating snapshot. The Wand reads its casts from the same
    /// place `MissionsLaneView` does, so the two cannot disagree.
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let daemonManager: OpenBurnBarDaemonManager
    let accountManager: AccountManager
    let model: ControlDeckModel
    /// Today's spend, already computed by `DashboardView` from
    /// `dataStore.usageWindowSummary(for:)`. The deck does no aggregation.
    let todaySpend: Double
    let onOpenSettings: (String?) -> Void
    let onNavigate: (DashboardMainRoute) -> Void
    /// Presents `MacWandComposerSheet`, which `DashboardView` already hosts. A
    /// cast is click-through precisely because the composer owns the approval
    /// switches that make it safe.
    let onCastWand: () -> Void

    var body: some View {
        switch config.kind {
        case .engineRoom: EngineRoomTile(daemonManager: daemonManager, onOpenSettings: onOpenSettings)
        case .aiInbox: AIInboxTile(model: model, onNavigate: onNavigate, onOpenSettings: onOpenSettings)
        case .modelRouter:
            ModelRouterTile(
                settingsManager: settingsManager,
                model: model,
                daemonManager: daemonManager,
                onOpenSettings: onOpenSettings
            )
        case .wand: TheWandTile(operatingLayer: operatingLayer, onCast: onCastWand, onNavigate: onNavigate)
        case .textExpansion: TextExpansionTile(settingsManager: settingsManager, model: model, onOpenSettings: onOpenSettings)
        case .memoryMCP: MemoryMCPTile(model: model, accountManager: accountManager, onOpenSettings: onOpenSettings)
        case .charts: ChartsTile(model: model, onNavigate: onNavigate)
        case .alerts: AlertsTile(settingsManager: settingsManager, todaySpend: todaySpend, onOpenSettings: onOpenSettings)
        case .appearance: AppearanceTile(settingsManager: settingsManager, onOpenSettings: onOpenSettings)
        case .pets: PetsTile(model: model, onOpenSettings: onOpenSettings)
        case .updates: UpdatesTile(onOpenSettings: onOpenSettings)
        case .fleet: FleetTile(onNavigate: onNavigate)
        }
    }
}

private struct FleetTile: View {
    let onNavigate: (DashboardMainRoute) -> Void
    @State private var headline = FleetTileHeadline.watching

    var body: some View {
        ControlTileShell(
            kind: .fleet,
            state: headline.tileState,
            headline: headline.label,
            accessibilityHeadline: headline.label
        ) {
            ControlLinkButton(title: "Open Fleet", help: "Watch running agents and steer the orchestrator.") {
                onNavigate(.fleet)
            }
        } ladder: {
            ControlStatusChip(
                label: headline.chipLabel,
                tint: headline.chipTint,
                help: "The daemon probes which agents are actually running. Nothing is guessed."
            )
        }
        .task {
            // Same recover as the Fleet board: peer-auth can close the
            // socket empty while fleet-snapshot.json is still current.
            do {
                let snapshot = try FleetService.fetchSnapshotWithFileFallback(
                    at: OpenBurnBarDaemonRuntimePaths.live().socketURL
                )
                headline = .resolved(fromSnapshot: snapshot)
            } catch {
                headline = .resolved(fromError: error)
            }
        }
    }
}

// MARK: - W-5 · Engine Room
//
// Live fact: `daemonManager.status` — the real `OpenBurnBarDaemonStatus`,
// including `daemonVersion` and the `protocolVersion` mismatch flag.
//
// Direct: Refresh (a pure health read) and Repair/Install
// (`installAndStart()` / `repair()`, both idempotent and fail-safe — they run
// the same install→bootstrap→kickstart→health lifecycle whatever state the
// daemon is in). Repair is offered only when the daemon is *not* healthy, so
// the control is always a repair and never a fresh capability grant.
//
// **NEVER on the deck (W-6): the HTTP gateway enable.** It opens a network
// listener that serves provider credentials, and `GatewaySettings.gatewayEnabled`
// only persists — its sole reader is the daemon launch path — so a deck switch
// would show "off" while the gateway kept serving. It stays in Settings, where
// the restart requirement is stated.
private struct EngineRoomTile: View {
    let daemonManager: OpenBurnBarDaemonManager
    let onOpenSettings: (String?) -> Void

    private var health: OpenBurnBarDaemonHealthSnapshot? {
        if case .healthy(let snapshot) = daemonManager.status { return snapshot }
        return nil
    }

    private var state: ControlTileState {
        switch daemonManager.status {
        case .healthy(let snapshot):
            return snapshot.versionMismatch
                ? .degraded("Protocol \(snapshot.protocolVersion) vs \(BurnBarProtocolVersion.current)")
                : .on
        case .checking:
            return .unavailable("Checking daemon…")
        case .notInstalled:
            return .unavailable("Not installed")
        case .unhealthy(let message):
            return .unavailable(message)
        }
    }

    private var headline: String {
        switch daemonManager.status {
        case .healthy(let snapshot): return "Healthy · v\(snapshot.daemonVersion)"
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .unhealthy: return "Needs repair"
        }
    }

    var body: some View {
        ControlTileShell(
            kind: .engineRoom,
            state: state,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            control
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                if let health {
                    ControlStatusChip(
                        label: "Protocol \(health.protocolVersion)",
                        tint: health.versionMismatch
                            ? DesignSystem.Colors.warning
                            : DesignSystem.Colors.success,
                        help: health.versionMismatch
                            ? "The installed daemon speaks protocol \(health.protocolVersion); this app expects \(BurnBarProtocolVersion.current). Repair reinstalls the matching binary."
                            : "App and daemon speak the same protocol."
                    )
                } else if let error = daemonManager.lastError {
                    ControlStatusChip(
                        label: String(error.prefix(40)),
                        tint: DesignSystem.Colors.warning,
                        help: error
                    )
                }

                Spacer(minLength: 0)

                ControlLinkButton(
                    title: "Daemon settings",
                    help: "Open Settings → Daemon, where the HTTP gateway, the auth token, and the controller runtime live."
                ) {
                    onOpenSettings(ControlKind.engineRoom.settingsItemID)
                }
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        if daemonManager.isBusy {
            ProgressView()
                .controlSize(.small)
                .help("Working on the daemon…")
        } else if case .healthy = daemonManager.status {
            ControlPrimaryButton(
                kind: .engineRoom,
                title: "Refresh",
                glyph: "arrow.clockwise",
                help: "Re-read the daemon's health. Nothing is installed or restarted."
            ) {
                Task { await daemonManager.refreshHealth() }
            }
        } else {
            ControlPrimaryButton(
                kind: .engineRoom,
                title: daemonManager.isInstalled ? "Repair" : "Install",
                glyph: "wrench.and.screwdriver",
                tint: DesignSystem.Colors.warning,
                help: "Reinstall the daemon binary, rewrite the LaunchAgent, and wait for it to report healthy. Safe to run at any time."
            ) {
                Task {
                    if daemonManager.isInstalled {
                        await daemonManager.repair()
                    } else {
                        await daemonManager.installAndStart()
                    }
                }
            }
        }
    }
}

// MARK: - K-7 / K-8 · Text Expansion
//
// Live facts: the real snippet counts from `dataStore.fetchTextExpansionSnippets()`
// (cached on `ControlDeckModel`, refreshed on `.textExpansionSnippetsDidChange`),
// and `AXIsProcessTrusted()` for the reach state.
//
// Direct: both expansion switches. No extra call is needed —
// `TextExpansionSettings.macGlobalExpansionEnabled.didSet` posts
// `.textExpansionMacGlobalExpansionEnabledDidChange` and
// `TextExpansionRuntimeController` installs or tears down the CGEvent tap, so
// the switch is true the moment it moves.
//
// Direct-but-a-request: "Grant Accessibility…". The switch **does not flip** —
// macOS makes the real decision. It calls
// `MacAccessibilityPermissionRequester.promptAndOpenSettings()` and the tile
// re-polls on `didBecomeActive`, because System Settings never notifies the app.
//
// **CT (K-9): snippet CRUD.** The master–detail editor with trigger validation
// and the live sandbox stays single-homed in Settings.
private struct TextExpansionTile: View {
    @Bindable var settingsManager: SettingsManager
    let model: ControlDeckModel
    let onOpenSettings: (String?) -> Void

    private var expansion: TextExpansionSettings { settingsManager.textExpansion }

    private var globalWantsAccessibility: Bool {
        expansion.macGlobalExpansionEnabled && !model.accessibilityTrusted
    }

    private var state: ControlTileState {
        if globalWantsAccessibility { return .needsPermission("Accessibility permission") }
        if expansion.inAppExpansionEnabled || expansion.macGlobalExpansionEnabled { return .on }
        return .off
    }

    /// Never blanked when off — the value the switch *would* control is the
    /// reason to turn it back on.
    private var headline: String {
        guard let total = model.snippetCount else { return "Counting snippets…" }
        let enabled = model.enabledSnippetCount ?? total
        return "\(total) snippet\(total == 1 ? "" : "s") · \(enabled) enabled"
    }

    var body: some View {
        ControlTileShell(
            kind: .textExpansion,
            state: state,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            control
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(
                    label: expansion.inAppExpansionEnabled ? "In OpenBurnBar" : "OpenBurnBar off",
                    tint: expansion.inAppExpansionEnabled
                        ? DesignSystem.Colors.success
                        : ControlDeckInk.inactive,
                    help: "Expands triggers inside OpenBurnBar's own chat and composer."
                )

                if OpenBurnBarBuildGates.globalTextExpansionAvailable {
                    reachControl
                }

                Spacer(minLength: 0)

                ControlLinkButton(
                    title: "Edit snippets",
                    help: "Open the snippet editor, where triggers are validated and previewed in a live sandbox."
                ) {
                    onOpenSettings(ControlKind.textExpansion.settingsItemID)
                }
            }
        }
    }

    /// The reach picker is a secondary, non-glass control: a tile may carry at
    /// most one nested real-glass element, and that budget is spent on the
    /// primary switch (glass cannot sample glass).
    @ViewBuilder
    private var reachControl: some View {
        ControlSegmentedPicker(
            accent: ControlKind.textExpansion.accent,
            options: [(value: false, label: "IN APP"), (value: true, label: "EVERYWHERE")],
            selection: expansion.macGlobalExpansionEnabled
        ) { everywhere in
            expansion.macGlobalExpansionEnabled = everywhere
            if everywhere, !model.accessibilityTrusted {
                // Asking is not granting. macOS owns the decision; we only open
                // the door and re-poll when the app comes back to the front.
                // Routed through the ladder so a dashboard toggle cannot be the
                // first thing a user hears about screen control.
                Task { @MainActor in
                    await FirstRunPermissionLadder.shared.request(.accessibility)
                    model.refreshSynchronousFacts()
                }
            }
            model.refreshSynchronousFacts()
            Analytics.shared.track(.settingsChanged, [
                "setting_key": "text_expansion_global",
                "new_value": .bool(everywhere),
                "source": "control_deck"
            ])
        }
        .help(
            expansion.macGlobalExpansionEnabled
                ? "Triggers expand in any Mac app. Needs Accessibility."
                : "Triggers expand only inside OpenBurnBar."
        )
    }

    @ViewBuilder
    private var control: some View {
        if globalWantsAccessibility {
            ControlPrimaryButton(
                kind: .textExpansion,
                title: "Grant Accessibility…",
                glyph: "hand.raised",
                tint: DesignSystem.Colors.warning,
                help: "Opens System Settings → Privacy & Security → Accessibility. macOS grants the permission, not OpenBurnBar."
            ) {
                Task { @MainActor in
                    await FirstRunPermissionLadder.shared.request(.accessibility)
                    model.refreshSynchronousFacts()
                }
            }
        } else {
            ControlSwitch(
                kind: .textExpansion,
                label: "Expansion",
                glyph: "text.append",
                isOn: expansion.inAppExpansionEnabled,
                onHelp: "Expanding triggers inside OpenBurnBar.",
                offHelp: "Turn on to expand your triggers inside OpenBurnBar."
            ) {
                expansion.inAppExpansionEnabled.toggle()
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "text_expansion_in_app",
                    "new_value": .bool(expansion.inAppExpansionEnabled),
                    "source": "control_deck"
                ])
            }
        }
    }
}

// MARK: - S-1 · Charts
//
// Live fact: how many charts the gallery is currently showing, read from the
// same `chartsPageLayout.v1` payload `ChartsPageView` persists — so hiding a
// chart on the Charts page changes this number.
//
// Direct: the AI-insights switch. It is the one Charts control that spends
// money, so it belongs where you can see that it is on. It writes the identical
// `@AppStorage("chartsPage.llmInsightsEnabled")` key and fires the identical
// `setting_key: "charts_ai_insights"` analytics event the Charts page fires,
// with a `source` dimension — one setting, one key, two surfaces.
private struct ChartsTile: View {
    let model: ControlDeckModel
    let onNavigate: (DashboardMainRoute) -> Void

    @AppStorage(ChartsPageView.aiToggleKey) private var aiInsightsEnabled = false

    private var total: Int { ChartKind.allCases.count }

    var body: some View {
        ControlTileShell(
            kind: .charts,
            state: aiInsightsEnabled ? .on : .off,
            headline: "\(model.visibleChartCount) of \(total) charts shown",
            accessibilityHeadline: "\(model.visibleChartCount) of \(total) charts shown"
        ) {
            ControlSwitch(
                kind: .charts,
                label: "AI Insights",
                glyph: "sparkles",
                isOn: aiInsightsEnabled,
                onHelp: "AI insights on — aggregate numbers only are shared with your connected LLM.",
                offHelp: "Turn on AI insights: your connected LLM reads aggregate spend numbers (never conversation content) and surfaces what matters."
            ) {
                aiInsightsEnabled.toggle()
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "charts_ai_insights",
                    "new_value": .string(String(aiInsightsEnabled)),
                    "source": "control_deck"
                ])
            }
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(
                    label: aiInsightsEnabled ? "Insights on" : "Insights off",
                    tint: aiInsightsEnabled
                        ? DesignSystem.Colors.success
                        : ControlDeckInk.inactive,
                    help: "Whether the gallery asks your connected LLM to read the aggregate numbers."
                )
                Spacer(minLength: 0)
                ControlLinkButton(title: "Open Charts", help: "Go to the Charts gallery.") {
                    onNavigate(.charts)
                }
            }
        }
    }
}

// MARK: - S-3 / S-4 · Alerts & Digest
//
// Live facts: today's real spend from `dataStore.usageWindowSummary(for:)`
// against the real `AlertSettings.costAlertThreshold`.
//
// Direct: the spend threshold, bound through `SettingsBindings` — the same
// adapter `AlertsSettingsView` uses, so the two surfaces cannot disagree about
// what "off" means or which amount a re-enable restores.
//
// **Read-only: the daily digest.**
// `DailyDigestManager.activate(from:isEnabled:hour:)` registers a cadence at
// launch that re-arms the pending notification every 15 minutes, reading
// `dailyDigestEnabled` / `dailyDigestHour` on each tick. Both this tile and
// Settings therefore take effect on their own, so neither surface needs a
// reschedule call — the tile just renders the resulting state.
private struct AlertsTile: View {
    @Environment(\.backdropInk) private var ink
    @Bindable var settingsManager: SettingsManager
    let todaySpend: Double
    let onOpenSettings: (String?) -> Void

    private var threshold: Double? { settingsManager.costAlertThreshold }

    private var state: ControlTileState {
        threshold == nil ? .off : .on
    }

    private var headline: String {
        guard let threshold else { return "\(todaySpend.formatAsCost()) today" }
        return "\(todaySpend.formatAsCost()) / \(threshold.formatAsCost())"
    }

    private var digestLabel: String {
        settingsManager.dailyDigestEnabled
            ? String(format: "Digest %02d:00", settingsManager.dailyDigestHour)
            : "Digest off"
    }

    var body: some View {
        ControlTileShell(
            kind: .alerts,
            state: state,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            ControlSwitch(
                kind: .alerts,
                label: "Spend alert",
                glyph: "bell.badge",
                isOn: threshold != nil,
                onHelp: "Warns when estimated daily burn crosses your amount. Evaluated on this Mac; nothing is sent to a server.",
                offHelp: "Turn on to be warned before a day gets expensive."
            ) {
                SettingsBindings.costAlertEnabled(settingsManager).wrappedValue.toggle()
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "cost_threshold_alert",
                    "new_value": .bool(settingsManager.costAlertThreshold != nil),
                    "source": "control_deck"
                ])
            }
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                if let threshold, threshold > 0 {
                    ControlMeterBar(
                        fraction: todaySpend / threshold,
                        accent: ControlKind.alerts.accent
                    )
                    .frame(maxWidth: 88)

                    amountStepper(threshold)
                } else {
                    ControlStatusChip(
                        label: "No spend alert set",
                        help: "Turn the switch on to set a daily threshold."
                    )
                }

                ControlStatusChip(
                    label: digestLabel,
                    tint: settingsManager.dailyDigestEnabled
                        ? DesignSystem.Colors.warning
                        : ControlDeckInk.inactive,
                    help: settingsManager.dailyDigestEnabled
                        ? "The digest is scheduled at launch, so a time change here would not take effect until you relaunch. Change it in Settings."
                        : "The daily digest is off."
                )

                Spacer(minLength: 0)

                ControlLinkButton(title: "Alerts", help: "Open Settings → Alerts, where the digest and its hour live.") {
                    onOpenSettings(ControlKind.alerts.settingsItemID)
                }
            }
        }
    }

    /// Numeric entry, deck style: a visible increment, never a silent rewrite.
    private func amountStepper(_ threshold: Double) -> some View {
        HStack(spacing: 4) {
            stepButton("minus", help: "Lower the daily threshold by $5.") {
                settingsManager.costAlertThreshold = max(1, threshold - 5)
            }
            Text(threshold.formatAsCost())
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(ink.secondary)
            stepButton("plus", help: "Raise the daily threshold by $5.") {
                settingsManager.costAlertThreshold = threshold + 5
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily threshold")
        .accessibilityValue(threshold.formatAsCost())
    }

    private func stepButton(_ glyph: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(ink.secondary)
                .frame(width: 16, height: 16)
                .background(Circle().fill(ControlKind.alerts.accent.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - H-1 · Appearance
//
// Live facts: the real `settingsManager.dashboardLayout` and
// `.appearanceSkin`, plus the live `liquidGlassTransparency` value.
//
// Direct, and deliberately zero new logic: the tile embeds the shipped
// `BurnRailAppearanceQuickMenu` and `DashboardLayoutSwitcher` as-is. Appearance
// does not need a new control surface; it needs to stop being hidden in a
// status rail.
private struct AppearanceTile: View {
    @Bindable var settingsManager: SettingsManager
    let onOpenSettings: (String?) -> Void

    @AppStorage(LiquidGlassTransparency.storageKey) private var glassTransparency: Double = 0

    private var glassLabel: String {
        let rounded = (glassTransparency * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "Glass default" }
        return rounded > 0
            ? "Glass +\(rounded.formatted(.number.precision(.fractionLength(1))))"
            : "Glass \(rounded.formatted(.number.precision(.fractionLength(1))))"
    }

    private var headline: String {
        "\(settingsManager.dashboardLayout.displayName) · \(settingsManager.appearanceSkin.displayName) skin"
    }

    var body: some View {
        ControlTileShell(
            kind: .appearance,
            state: .on,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            BurnRailAppearanceQuickMenu(
                settingsManager: settingsManager,
                onOpenAppearanceSettings: { onOpenSettings(ControlKind.appearance.settingsItemID) },
                scale: 0.9
            )
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                DashboardLayoutSwitcher(
                    selection: Binding(
                        get: { settingsManager.dashboardLayout },
                        set: { settingsManager.dashboardLayout = $0 }
                    ),
                    scale: 0.82
                )

                ControlStatusChip(
                    label: glassLabel,
                    tint: ControlKind.appearance.accent,
                    help: "How much light the glass lets through. Reduce Transparency always wins."
                )

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - H-2 / H-3 · Pets
//
// Live facts: the active pet's real display name (from its bundled definition),
// the persisted chat backend behind it, and the real summon hotkey.
//
// Direct: the companion switch, routed through
// `PetCompanionFeature.toggleCompanion()` — which pairs the persisted flag with
// `showCompanion()` / `hide()`. A bare `@AppStorage` write is inert, so the
// deck must not do one.
//
// **The hotkey chip is read-only and decoded from `pet.hotkey.combo`, never
// from `PetCompanionFeature.runtime`.** `runtime` is a `static let` whose first
// touch builds the controller, the Carbon global hotkey, and the system
// observers. Rendering a chip must not boot a subsystem.
private struct PetsTile: View {
    let model: ControlDeckModel
    let onOpenSettings: (String?) -> Void

    @AppStorage(PetCompanionFeature.DefaultsKey.enabled) private var companionEnabled = false
    @AppStorage(PetCompanionFeature.DefaultsKey.activeAgent) private var activeAgentRaw = ChatBackendID.codex.rawValue

    private var backend: ChatBackendID { ChatBackendID(rawValue: activeAgentRaw) ?? .codex }

    private var headline: String {
        let name = model.activePetName.isEmpty ? "No pet" : model.activePetName
        return "\(name) · \(backend.shortLabel)"
    }

    var body: some View {
        ControlTileShell(
            kind: .pets,
            state: companionEnabled ? .on : .off,
            headline: headline,
            accessibilityHeadline: headline
        ) {
            ControlSwitch(
                kind: .pets,
                label: "Companion",
                glyph: "pawprint",
                isOn: companionEnabled,
                onHelp: "Your companion is on the desktop. Press \(model.petHotkeyLabel) to summon its bubble.",
                offHelp: "Turn on to put your companion back on the desktop."
            ) {
                // Pairs the flag with the window, which a bare @AppStorage
                // write would not.
                PetCompanionFeature.toggleCompanion()
            }
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(
                    label: model.petHotkeyLabel,
                    tint: ControlKind.pets.accent,
                    help: "Global summon hotkey. Rebind it in Settings → Pets."
                )
                Spacer(minLength: 0)
                ControlLinkButton(title: "Pet & brain", help: "Choose the pet, its form, and the model behind it.") {
                    onOpenSettings(ControlKind.pets.settingsItemID)
                }
            }
        }
    }
}

// MARK: - H-4 · Updates
//
// Live facts: the installed version, the resolved install channel, and the
// checker's real `UpdatePhase`.
//
// Direct: the automatic-check switch — and it calls
// `setAutomaticChecksEnabled(_:)` rather than writing the key, so the scheduler
// actually starts or stops now, exactly as `UpdatesSettingsView.onChange` does.
// A bare `@AppStorage` write would be a latency lie.
//
// The whole kind is **absent** on the Mac App Store build (`visibleKinds`), not
// greyed: a disabled row is still an advertisement.
private struct UpdatesTile: View {
    let onOpenSettings: (String?) -> Void

    #if !DISTRIBUTION_MAS
    @AppStorage(DirectDownloadUpdateChecker.automaticChecksKey) private var automaticChecks = true
    #endif

    var body: some View {
        #if DISTRIBUTION_MAS
        EmptyView()
        #else
        let checker = DirectDownloadUpdateChecker.shared
        ControlTileShell(
            kind: .updates,
            state: state(for: checker.phase),
            headline: headline(for: checker.phase),
            accessibilityHeadline: headline(for: checker.phase)
        ) {
            ControlSwitch(
                kind: .updates,
                label: "Auto-check",
                glyph: "clock.arrow.circlepath",
                isOn: automaticChecks,
                onHelp: "Checks shortly after launch and once a day.",
                offHelp: "Turn on to check for new versions automatically."
            ) {
                automaticChecks.toggle()
                // Start/stop the scheduler now, not next launch.
                checker.setAutomaticChecksEnabled(automaticChecks)
                Analytics.shared.track(.settingsChanged, [
                    "setting_key": "updates_automatic_checks",
                    "new_value": .bool(automaticChecks),
                    "source": "control_deck"
                ])
            }
        } ladder: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ControlStatusChip(
                    label: channelLabel(checker.channel),
                    tint: ControlKind.updates.accent,
                    help: "How this copy was installed — it decides what \"update\" means."
                )
                Spacer(minLength: 0)
                if checker.isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    ControlLinkButton(title: "Check now", help: "Ask the release feed whether a newer build exists.") {
                        checker.checkForUpdatesNow()
                    }
                }
                ControlLinkButton(title: "Updates", help: "Open Settings → Updates.") {
                    onOpenSettings(ControlKind.updates.settingsItemID)
                }
            }
        }
        #endif
    }

    #if !DISTRIBUTION_MAS
    private var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private func headline(for phase: UpdatePhase) -> String {
        switch phase {
        case .idle: return installedVersion
        case .checking: return "\(installedVersion) · checking…"
        case .upToDate: return "\(installedVersion) · up to date"
        case .available(let offer): return "\(offer.pillText) available"
        case .downloading(let progress):
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .verifying: return "Verifying…"
        case .installing: return "Installing…"
        case .relaunching: return "Relaunching…"
        case .failed: return "\(installedVersion) · check failed"
        }
    }

    private func state(for phase: UpdatePhase) -> ControlTileState {
        switch phase {
        case .idle, .checking, .upToDate:
            return automaticChecks ? .on : .off
        case .available, .downloading, .verifying, .installing, .relaunching:
            return .degraded("A newer version is ready")
        case .failed(let message):
            return .unavailable(message)
        }
    }

    private func channelLabel(_ channel: UpdateChannel) -> String {
        switch channel {
        case .dmg: return "Direct download"
        case .homebrew: return "Homebrew"
        case .source: return "Source build"
        case .unknown: return "Unmanaged build"
        }
    }
    #endif
}
