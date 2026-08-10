import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Control Deck
//
// The operator home: every shipped feature as a live tile, one click deep.
//
// The page shell is the shipped `ChartsPageView` template — same scroll, same
// 24pt page padding, same 1180pt content clamp, same 16pt stack — because the
// deck should look like it has always been part of this app.
//
// What this page is *not*: a Settings mirror. Every tile renders a fact read
// from the real store behind that feature. A tile that could only render a
// label was cut rather than shipped as a link.
//
// What this page must never be: a place where one click grants trust. A deck
// control may flip a preference; it may never grant trust, egress data
// off-device, open a network listener, or destroy a ledger. Each tile arm in
// `ControlTileView` names the controls it deliberately refuses, and why.

struct ControlDeckView: View {
    @Bindable var settingsManager: SettingsManager
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    let dataStore: DataStore
    let daemonManager: OpenBurnBarDaemonManager
    let accountManager: AccountManager
    let model: ControlDeckModel
    /// Today's spend, already summarised by the dashboard. The deck aggregates
    /// nothing of its own.
    let todaySpend: Double
    let onOpenSettings: (String?) -> Void
    let onNavigate: (DashboardMainRoute) -> Void
    let onCastWand: () -> Void

    @State private var layout: ControlDeckLayout = .default
    /// The measured width of the content column — the page width clamped to
    /// 1180pt, minus its 24pt padding on each side. The grid divides this into
    /// columns, so it has to be the *content* width and not the window width.
    @State private var contentWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Live reads the header summary needs. Held here (rather than only inside
    // the tiles) so the summary re-renders the moment a tile's value changes.
    @AppStorage(ChartsPageView.aiToggleKey) private var chartsAIInsights = false
    @AppStorage(PetCompanionFeature.DefaultsKey.enabled) private var petCompanionEnabled = false
    #if !DISTRIBUTION_MAS
    @AppStorage(DirectDownloadUpdateChecker.automaticChecksKey) private var updatesAutomaticChecks = true
    #endif

    private var columns: Int {
        ControlDeckMetrics.columns(
            for: contentWidth > 0 ? contentWidth : ControlDeckMetrics.contentMaxWidth
        )
    }

    private var readout: ControlDeckReadout {
        var inputs = ControlDeckReadout.Inputs(
            daemonIsHealthy: daemonIsHealthy,
            textExpansionInApp: settingsManager.textExpansion.inAppExpansionEnabled,
            textExpansionEverywhere: settingsManager.textExpansion.macGlobalExpansionEnabled,
            chartsAIInsights: chartsAIInsights,
            spendAlertThreshold: settingsManager.costAlertThreshold,
            petCompanionEnabled: petCompanionEnabled,
            aiInboxEnabled: model.inboxConfig?.enabled ?? false,
            modelRouterEnabled: settingsManager.gatewayEnabled,
            wandCastsRunning: castsRunning,
            memoryMCPConnectedCount: model.mcpReading?.activeCount
        )
        #if !DISTRIBUTION_MAS
        inputs.updatesAutomaticChecks = updatesAutomaticChecks
        #endif
        return ControlDeckReadout(inputs: inputs)
    }

    private var daemonIsHealthy: Bool {
        if case .healthy(let snapshot) = daemonManager.status { return !snapshot.versionMismatch }
        return false
    }

    private var castsRunning: Int {
        operatingLayer.snapshot.controllerRuntime.missions
            .filter { $0.state == .running || $0.state == .partial }
            .count
    }

    /// Host, port, and credential for the one loopback probe the deck makes.
    /// Assembled here, where the settings facade already lives, so
    /// `ControlDeckModel` never holds a reference to `SettingsManager`.
    private var routerGateway: ControlDeckModel.RouterGatewayEndpoint {
        ControlDeckModel.RouterGatewayEndpoint(
            enabled: settingsManager.gatewayEnabled,
            host: settingsManager.gatewayHost,
            port: settingsManager.gatewayPort,
            authToken: settingsManager.gatewayAuthToken
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header

                ForEach(layout.populatedGroups, id: \.self) { group in
                    groupBlock(group)
                }
            }
            // Measured *inside* the padding and the 1180pt clamp, so this is
            // the width the grid actually has to divide. The header fills the
            // proposed width on its own, so there is no circular dependency
            // between the measurement and the tiles it sizes.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in contentWidth = width }
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: ControlDeckMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { restoreLayout() }
        .task { model.start(dataStore: dataStore, gateway: routerGateway) }
        // The snippet store posts this whenever a snippet is created, edited or
        // deleted, so the Text Expansion headline is never stale.
        .onReceive(NotificationCenter.default.publisher(for: .textExpansionSnippetsDidChange)) { _ in
            model.refreshSnippetCountsSoon()
        }
        // The shared background cadence posts this after each inbox pass, so
        // the unread count tracks daemon-written rows without the deck owning a
        // second timer.
        .onReceive(NotificationCenter.default.publisher(for: DashboardView.inboxBadgeRefreshNotification)) { _ in
            model.refreshInboxUnreadCountSoon()
        }
        // System Settings never notifies the app when the user grants or
        // revokes Accessibility, so the only honest moment to re-poll is when
        // the app comes back to the front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshSynchronousFacts()
        }
        .accessibilityIdentifier(OBBAccessibilityID.controlDeck)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Control Deck")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            editMenu
        }
    }

    /// Three live facts, none of them decorative: how much of the deck is
    /// switched on, what today has cost, and whether the daemon everything
    /// else depends on is healthy.
    private var headerSubtitle: String {
        let visible = layout.visibleConfigs.map(\.kind)
        let onCount = visible.filter { readout.isOn($0) }.count
        return "\(onCount) of \(visible.count) on · "
            + "\(todaySpend.formatAsCost()) today · "
            + "daemon \(daemonManager.status.label.lowercased())"
    }

    private var editMenu: some View {
        Menu {
            if !layout.hiddenConfigs.isEmpty {
                Section("Hidden Tiles") {
                    ForEach(layout.hiddenConfigs) { config in
                        Button {
                            layout.setVisible(config.kind, true)
                            persistLayout()
                        } label: {
                            Label(config.kind.title, systemImage: config.kind.systemImage)
                        }
                    }
                }
            }
            Section {
                Button("Reset Arrangement") {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                        layout.reset()
                        persistLayout()
                    }
                }
                Button("Open Settings…") { onOpenSettings(nil) }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liquidGlassInteractive(in: Circle())
        .help("Show hidden tiles, reset the arrangement, or open Settings")
        .accessibilityLabel("Edit deck")
        .accessibilityIdentifier(OBBAccessibilityID.controlDeckEditMenu)
    }

    // MARK: Bands

    @ViewBuilder
    private func groupBlock(_ group: ControlGroup) -> some View {
        let configs = layout.visibleConfigs(in: group)
        let kinds = configs.map(\.kind)
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            ControlDeckGroupHeader(
                group: group,
                tileCount: configs.count,
                onCount: readout.onCount(in: group, among: kinds)
            )

            ControlDeckGrid(
                configs: configs,
                columns: columns,
                contentWidth: contentWidth,
                accent: group.accent,
                onMove: { dragged, target in
                    layout.move(dragged, toPositionOf: target)
                    persistLayout()
                },
                onHide: { kind in
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                        layout.setVisible(kind, false)
                        persistLayout()
                    }
                },
                onToggleSpan: { kind in
                    let current = layout.configs.first { $0.kind == kind }?.span ?? 1
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                        layout.setSpan(kind, current >= ControlDeckLayout.maxSpan ? 1 : ControlDeckLayout.maxSpan)
                        persistLayout()
                    }
                },
                tile: { config in
                    ControlTileView(
                        config: config,
                        settingsManager: settingsManager,
                        operatingLayer: operatingLayer,
                        daemonManager: daemonManager,
                        accountManager: accountManager,
                        model: model,
                        todaySpend: todaySpend,
                        onOpenSettings: onOpenSettings,
                        onNavigate: onNavigate,
                        onCastWand: onCastWand
                    )
                }
            )
        }
    }

    // MARK: Persistence

    private func restoreLayout() {
        guard let data = UserDefaults.standard.data(forKey: ControlDeckLayout.storageKey) else {
            layout = .default
            return
        }
        layout = ControlDeckLayout.decode(from: data)
    }

    private func persistLayout() {
        guard let data = layout.encoded() else { return }
        UserDefaults.standard.set(data, forKey: ControlDeckLayout.storageKey)
    }
}
