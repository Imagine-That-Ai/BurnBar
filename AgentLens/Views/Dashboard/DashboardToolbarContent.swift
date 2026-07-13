import AppKit
import OpenBurnBarCore
import SwiftUI

// MARK: - Command Deck Toolbar
//
// A single ~52pt bar replacing the old toolbar + tab-card strip.
//
//   [navigation]    back · 🔥 OpenBurnBar · section switcher · ⌘K hint
//   [principal]     (empty — the section menu already names the route)
//   [primaryAction] BURN hero (range + unit in popover) · ⋯ overflow

extension DashboardView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {

        // MARK: Navigation — back · brand · section switcher · ⌘K hint

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

            Button {
                showCommandPalette = true
            } label: {
                CommandPaletteToolbarLabel()
            }
            .buttonStyle(.plain)
            .help("Command Palette (\u{2318}K)")
            .accessibilityLabel("Open Command Palette")
            .accessibilityHint("Shows navigation, sessions, and workspace commands")
        }

        // MARK: Primary — BURN hero (with range/unit popover) · overflow

        ToolbarItemGroup(placement: .primaryAction) {
            commandDeckHero

            commandDeckOverflow
        }
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
                    .accessibilityIdentifier(OBBAccessibilityID.dashboardSettingsButton)
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
            .accessibilityIdentifier(OBBAccessibilityID.dashboardOverflowButton)
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

private struct CommandPaletteToolbarLabel: View {
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "command")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(isHovering ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)

            Text("Commands")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            ShortcutChip(keys: ["\u{2318}", "K"])
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: 28)
        .background {
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(isHovering ? 0.72 : 0.48))
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    isHovering
                        ? DesignSystem.Colors.ember.opacity(0.38)
                        : DesignSystem.Colors.border.opacity(0.55),
                    lineWidth: 0.6
                )
        }
        .shadow(
            color: isHovering ? DesignSystem.Colors.ember.opacity(0.12) : Color.black.opacity(0.08),
            radius: isHovering ? 8 : 4,
            y: 2
        )
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.snappy) {
                isHovering = hovering
            }
        }
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
