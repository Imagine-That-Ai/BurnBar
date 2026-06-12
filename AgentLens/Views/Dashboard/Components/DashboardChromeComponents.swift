import AppKit
import Combine
import SwiftUI
import WebKit
struct StatCard: View {
    let title: String
    let value: String
    let accent: Color
    let detail: String
    var moodLabel: String?
    var moodColor: Color?
    var confidenceLabel: String?
    var confidenceColor: Color?

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Text(value)
                    .font(DesignSystem.Typography.monoLarge)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)

                if let moodLabel, let moodColor {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(moodColor)
                            .frame(width: 6, height: 6)
                        Text(moodLabel)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(moodColor)
                    }
                }

                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let confidenceLabel, let confidenceColor {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Circle()
                            .fill(confidenceColor)
                            .frame(width: 4, height: 4)
                        Text(confidenceLabel)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(confidenceColor)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(confidenceColor.opacity(0.08))
                    .overlay(
                        Capsule()
                            .stroke(confidenceColor.opacity(0.12), lineWidth: 0.5)
                    )
                    .clipShape(.capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
    }
}

// MARK: - Cycling Provider Icon

/// A compact icon that cycles through provider logos with a spring scale+fade animation.
///
/// Switched from `Timer.publish(... on: .main, in: .common)` to a
/// `TimelineView(.periodic(...))` so the tick driver auto-pauses when the
/// view is off-screen (during scrolls, or when the parent collapses to a
/// thumbnail). The `.common` runloop variant of `Timer.publish` would fire
/// straight through scroll events, costing one diff per tick per scroll
/// frame across the whole dashboard.
struct CyclingProviderIconView: View {
    let providers: [AgentProvider]
    let size: CGFloat
    let interval: TimeInterval
    let startOffset: Int

    @State private var lastTickDate: Date = .distantPast
    @State private var currentIndex: Int

    init(providers: [AgentProvider], size: CGFloat = 11, interval: TimeInterval = 2.2, startOffset: Int = 0) {
        self.providers = providers
        self.size = size
        self.interval = interval
        self.startOffset = startOffset
        self._currentIndex = State(initialValue: providers.isEmpty ? 0 : startOffset % providers.count)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: interval)) { context in
            ZStack {
                if !providers.isEmpty {
                    ProviderLogoView(provider: providers[currentIndex], size: size)
                        .id(currentIndex)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.25).combined(with: .opacity),
                                removal: .scale(scale: 1.6).combined(with: .opacity)
                            )
                        )
                }
            }
            .frame(width: size, height: size)
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: currentIndex)
            .onChange(of: context.date) { _, newDate in
                guard providers.count > 1 else { return }
                guard newDate.timeIntervalSince(lastTickDate) >= interval - 0.05 else { return }
                lastTickDate = newDate
                currentIndex = (currentIndex + 1) % providers.count
            }
        }
    }
}

// MARK: - Glass Segmented Picker

struct GlassSegmentedPicker<Option: RawRepresentable & CaseIterable & Identifiable & Hashable>: View
where Option.RawValue == String, Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option
    var icons: ((Option) -> String)?
    var iconViews: ((Option) -> AnyView)?

    init(selection: Binding<Option>, icons: ((Option) -> String)? = nil) {
        self._selection = selection
        self.icons = icons
        self.iconViews = nil
    }

    init(selection: Binding<Option>, iconViews: @escaping (Option) -> AnyView) {
        self._selection = selection
        self.icons = nil
        self.iconViews = iconViews
    }

    private var allCases: [Option] {
        Array(Option.allCases)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(allCases) { option in
                let isSelected = selection == option
                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let iconViews {
                            iconViews(option)
                                .frame(width: 11, height: 11)
                        } else if let icons {
                            Image(systemName: icons(option))
                                .font(.system(size: 10, weight: .medium))
                        }
                        Text(option.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(DesignSystem.Colors.primaryGradient) : AnyShapeStyle(.clear))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(toolbarPillSurface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm + 2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm + 2, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - Unified Toolbar Pill Chrome
//
// One shared chrome for every pill in the dashboard toolbar so they read as a
// coherent family. Values mirror `GlassSegmentedPicker` exactly — that pill is
// the visual anchor and everything else needs to match its radius, material,
// tint, and hairline.

/// Standard pill height for the dashboard toolbar (matches the segmented picker).
let toolbarPillRadius: CGFloat = DesignSystem.Radius.sm + 2  // 8pt

private struct ToolbarPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(toolbarPillSurface)
            .clipShape(.rect(cornerRadius: toolbarPillRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: toolbarPillRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

extension View {
    /// Apply the unified glass-pill chrome used across the dashboard toolbar.
    func toolbarPill() -> some View {
        modifier(ToolbarPillBackground())
    }
}

/// Shared pill plate for the segmented picker and every toolbar pill. On
/// macOS 26 a faint surface wash rides on real Liquid Glass (nothing sits
/// under glass); earlier systems keep the hand-tuned material stack.
@ViewBuilder
private var toolbarPillSurface: some View {
    let shape = RoundedRectangle(cornerRadius: toolbarPillRadius, style: .continuous)
    if #available(macOS 26, *) {
        shape
            .fill(DesignSystem.Colors.surface.opacity(0.15))
            .glassEffect(.regular, in: shape)
    } else {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(DesignSystem.Colors.surface.opacity(0.45))
        }
    }
}

// MARK: - Glass Picker

struct GlassPicker<Option: Identifiable & Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    var leadingSymbol: String? = nil

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(optionLabel(option))
                        if optionLabel(option) == selectionLabel(selection) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Text(selectionLabel(selection))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.leading, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
    }

    private func selectionLabel(_ option: Option) -> String {
        if let tr = option as? TimeRange { return tr.displayName }
        return "\(option)"
    }

    private func optionLabel(_ option: Option) -> String {
        if let tr = option as? TimeRange { return tr.displayName }
        return "\(option)"
    }
}

// MARK: - Glass Badge

struct GlassBadge<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .toolbarPill()
    }
}

// MARK: - Toolbar Metric Badge
//
// The live "tokens / cost" readout. Uses the shared pill chrome but earns
// presence through its content: a softly pulsing gradient dot and the value
// itself rendered in monospaced gradient text with numeric content transitions.

struct ToolbarMetricBadge: View {
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DesignSystem.Colors.primaryGradient)
                .frame(width: 5, height: 5)
                .shadow(color: DesignSystem.Colors.ember.opacity(0.35), radius: 2.5, x: 0, y: 0)
                .opacity(0.9)

            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)
                .contentTransition(.numericText())
                .animation(DesignSystem.Animation.gentle, value: value)
                .monospacedDigit()
                .kerning(0.3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .toolbarPill()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Total \(value)"))
    }
}

// MARK: - Project Navigation Pill
//
// Replaces the bare `< Back` button + loose project name with one cohesive
// navigation atom: chevron back, hairline divider, gradient project tile,
// project name. Reads as a single object instead of three orphaned controls.

struct ProjectNavigationPill: View {
    let canGoBack: Bool
    let projectName: String
    let backHelp: String
    let onBack: () -> Void

    @State private var hoveringBack = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard canGoBack else { return }
                withAnimation(DesignSystem.Animation.standard) { onBack() }
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(canGoBack ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textMuted)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hoveringBack && canGoBack ? Color.white.opacity(0.07) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .keyboardShortcut("[", modifiers: [.command])
            .help(canGoBack ? backHelp : "Back")
            .accessibilityLabel(canGoBack ? backHelp : "Back")
            .onHover { hoveringBack = $0 }
            .padding(.leading, 2)

            Rectangle()
                .fill(DesignSystem.Colors.border.opacity(canGoBack ? 0.32 : 0.18))
                .frame(width: 0.5, height: 14)
                .padding(.horizontal, 6)

            HStack(spacing: 6) {
                AppLogoView(size: 14)
                    .shadow(color: DesignSystem.Colors.ember.opacity(0.32), radius: 4, x: 0, y: 1)

                Text(projectName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.trailing, 10)
            .padding(.vertical, 4)
        }
        .toolbarPill()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(projectName) project")
    }
}

// MARK: - Toolbar Action Cluster
//
// Groups the trailing icon buttons (scan / recount / settings) into one
// segmented-style pill — the quieter sibling of the Agents/Models picker.
// Hairline dividers between buttons read as one coherent control rather than
// three orphans floating in the toolbar.

struct ToolbarActionCluster<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .toolbarPill()
    }
}

struct ToolbarActionDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.22))
            .frame(width: 0.5, height: 14)
            .padding(.horizontal, 1)
    }
}

struct ToolbarPillButton<Label: View>: View {
    let action: () -> Void
    let help: String
    let accessibilityLabel: String
    var isDisabled: Bool = false
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && !isDisabled ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .onHover { hovering = $0 }
        .animation(DesignSystem.Animation.snappy, value: hovering)
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    let settingsManager = SettingsManager()
    let controller = ChatSessionController(dataStore: store, settingsManager: settingsManager)
    DashboardView(
        dataStore: store,
        aggregator: nil,
        chatController: controller,
        operatingLayer: OpenBurnBarOperatingLayer(
            dataStore: store,
            settingsManager: settingsManager,
            chatController: controller
        ),
        settingsManager: settingsManager
    )
}

struct SessionPreviewRow: View {
    let usage: TokenUsage
    @Bindable var settingsManager: SettingsManager
    var onTap: (() -> Void)? = nil

    private var theme: ProviderTheme { .theme(for: usage.provider) }

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                rowContent
            }
            .buttonStyle(.plain)
            .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            .accessibilityLabel("Open \(usage.projectName) session")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(theme.primaryColor.opacity(0.14))
                    .frame(width: 32, height: 32)

                ProviderLogoView(provider: usage.provider, size: 20, useFallbackColor: false)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(usage.projectName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)

                Text("\(usage.provider.displayName) • \(usage.model)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatTime(usage.startTime))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(theme.primaryColor)

                Text(settingsManager.formatUsageMetric(cost: usage.cost, tokens: usage.totalTokens))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: usage.id)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
            }
        }
        .clipShape(.rect(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.1), DesignSystem.Colors.border.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        )
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Summarizing Status Strip

// MARK: - Mining Pick Animation

/// Renders the animated_mining_pick.svg using WKWebView so CSS @keyframes play natively.
