import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Command Deck Toolbar
//
// A single ~52pt bar replacing the old toolbar + tab-card strip.
//
//   [navigation]    back · 🔥 OpenBurnBar · section switcher
//   [principal]     ⌘K command omnibar (search-field-shaped palette launcher
//                   carrying a live "N sessions · M providers" summary)
//   [primaryAction] range chip · BURN hero (range + unit in popover) · ⋯ overflow

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {

        // MARK: Navigation — back · brand · section switcher

        ToolbarItemGroup(placement: .navigation) {
            if canGoBack {
                Button(action: goBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .help(backButtonHelpText)
            }

            BurnRailBrandMark()

            DashboardSectionSwitcher(
                currentRoute: mainRoute,
                activeChatBackend: chatController.chatBackend,
                pendingMemoryCount: pendingMemoryReviewCount,
                onNavigate: { route in
                    withAnimation(DesignSystem.Animation.standard) {
                        navigate(to: route)
                    }
                }
            )
        }

        // MARK: Principal — command omnibar (⌘K)

        ToolbarItem(placement: .principal) {
            BurnRailCommandOmnibar(
                placeholder: commandOmnibarPlaceholder,
                contextSummary: commandOmnibarSummary,
                isLive: burnRailIsLive,
                onActivate: { showCommandPalette = true }
            )
        }

        // MARK: Primary — range chip · BURN hero · overflow

        ToolbarItemGroup(placement: .primaryAction) {
            BurnRailTimeRangeMenuChip(
                selected: Binding(
                    get: { selectedTimeRange },
                    set: { range in
                        selectedTimeRange = range
                        Analytics.shared.track(.dashboardTimeRangeChanged, ["time_range": .string(range.rawValue)])
                    }
                )
            )

            commandDeckHero

            commandDeckOverflow
        }
    }

    // MARK: - Omnibar copy

    private var commandOmnibarPlaceholder: String {
        "Search sessions, projects, models…"
    }

    private var commandOmnibarSummary: String? {
        let sessions = dashboardUsageWindow.sessionCount
        let providers = activeProviderCount
        guard sessions > 0 || providers > 0 else { return nil }
        let sessionPart = "\(sessions.formatted()) session\(sessions == 1 ? "" : "s")"
        let providerPart = "\(providers) provider\(providers == 1 ? "" : "s")"
        return "\(sessionPart) · \(providerPart)"
    }

    // MARK: - BURN hero with range + unit popover

    private var commandDeckHero: some View {
        Button {
            showHeroPopover.toggle()
        } label: {
            BurnRailTelemetryHero(
                telemetry: BurnRailTelemetry(
                    headlineValue: settingsManager.formatUsageMetric(
                        cost: totalCostForTimeRange,
                        tokens: totalTokensForTimeRange
                    ),
                    headlineSuffix: settingsManager.usageDisplayMode == .tokens ? "tok" : nil,
                    deltaPercent: burnRailDeltaPercent,
                    sparkline: burnRailSparkline,
                    isLive: burnRailIsLive
                )
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showHeroPopover, arrowEdge: .bottom) {
            commandDeckHeroPopover
                .frame(width: 240)
        }
    }

    private var commandDeckHeroPopover: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Text("Time Range")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: 2) {
                ForEach(TimeRange.allCases) { range in
                    let isSelected = selectedTimeRange == range
                    Button {
                        selectedTimeRange = range
                        Analytics.shared.track(.dashboardTimeRangeChanged, ["time_range": .string(range.rawValue)])
                    } label: {
                        HStack {
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DesignSystem.Colors.ember)
                            }
                            Text(range.displayName)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(isSelected ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? DesignSystem.Colors.ember.opacity(0.1) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().opacity(0.4)

            HStack {
                Text("Unit")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                BurnRailUnitToggle(
                    unit: Binding(
                        get: { BurnRailUnit(fromUsageMode: settingsManager.usageDisplayMode) },
                        set: {
                            settingsManager.usageDisplayMode = $0.toUsageDisplayMode
                            Analytics.shared.track(.dashboardUnitToggled, ["unit": .string($0.toUsageDisplayMode.rawValue)])
                        }
                    )
                )
            }
        }
        .padding(DesignSystem.Spacing.md)
    }

    // MARK: - Overflow menu (Appearance · Import · Recount · Settings)

    private var commandDeckOverflow: some View {
        Menu {
            Section("Appearance") {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        settingsManager.appearanceMode = mode
                    } label: {
                        if settingsManager.appearanceMode == mode {
                            Label(mode.quickMenuLabel, systemImage: "checkmark")
                        } else {
                            Text(mode.quickMenuLabel)
                        }
                    }
                }
            }

            Section("App Skin") {
                ForEach(AppSkin.allCases, id: \.self) { skin in
                    Button {
                        settingsManager.appearanceSkin = skin
                    } label: {
                        if settingsManager.appearanceSkin == skin {
                            Label(skin.quickMenuLabel, systemImage: "checkmark")
                        } else {
                            Text(skin.quickMenuLabel)
                        }
                    }
                }
            }

            Section {
                Button("Import Sessions") { runScan() }
                    .disabled(isScanning)

                Button("Recount Totals") { runRecount() }
                    .disabled(!canRunRecount)

                Divider()

                Button("Settings…") { showingSettings = true }
            }
        } label: {
            HStack(spacing: 4) {
                if isScanning {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
            .frame(width: 28, height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.4))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

// MARK: - Enum bridges (UsageDisplayMode ↔ BurnRailUnit)

private extension BurnRailUnit {
    init(fromUsageMode mode: UsageDisplayMode) {
        switch mode {
        case .currency: self = .cost
        case .tokens:   self = .tokens
        }
    }
    var toUsageDisplayMode: UsageDisplayMode {
        switch self {
        case .cost:   return .currency
        case .tokens: return .tokens
        }
    }
}
