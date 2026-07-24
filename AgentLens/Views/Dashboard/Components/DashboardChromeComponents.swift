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
@MainActor
@ViewBuilder
private var toolbarPillSurface: some View {
    let shape = RoundedRectangle(cornerRadius: toolbarPillRadius, style: .continuous)
    if #available(macOS 26, *) {
        shape
            .fill(DesignSystem.Colors.surface.opacity(0.15))
            .liquidGlassEffect(.regular, in: shape)
    } else {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(DesignSystem.Colors.surface.opacity(0.45))
        }
    }
}

// MARK: - Glass Picker

// MARK: - Glass Badge

// MARK: - Toolbar Metric Badge
//
// The live "tokens / cost" readout. Uses the shared pill chrome but earns
// presence through its content: a softly pulsing gradient dot and the value
// itself rendered in monospaced gradient text with numeric content transitions.

// MARK: - Project Navigation Pill
//
// Replaces the bare `< Back` button + loose project name with one cohesive
// navigation atom: chevron back, hairline divider, gradient project tile,
// project name. Reads as a single object instead of three orphaned controls.

// MARK: - Toolbar Action Cluster
//
// Groups the trailing icon buttons (scan / recount / settings) into one
// segmented-style pill — the quieter sibling of the Agents/Models picker.
// Hairline dividers between buttons read as one coherent control rather than
// three orphans floating in the toolbar.

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
    var onTap: (() -> Void)?

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
        .liquidGlassSurface(
            in: RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous),
            fallback: .ultraThinMaterial
        )
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.4))
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
