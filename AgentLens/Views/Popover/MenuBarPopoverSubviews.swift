import AppKit
import OpenBurnBarAnalytics
import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Period Cost

struct PeriodCost: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Text(value)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }
}

// MARK: - Provider List Row

struct ProviderListRow: View {
    let summary: ProviderSummary

    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var theme: ProviderTheme { ProviderTheme.theme(for: summary.provider) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                Circle()
                    .fill(theme.primaryColor.opacity(0.15))
                    .frame(width: 28, height: 28)

                ProviderLogoView(provider: summary.provider, size: 16, useFallbackColor: false)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(summary.provider.displayName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text("\(summary.sessionCount) session\(summary.sessionCount == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)

                    if summary.cacheEfficiency.hasSignal {
                        let tier = CacheHitRateTier(summary.cacheEfficiency)
                        HStack(spacing: 3) {
                            Circle()
                                .fill(tier.color)
                                .frame(width: 4, height: 4)
                            Text("\(summary.cacheEfficiency.formattedHitRate) cache")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(tier.color)
                                .monospacedDigit()
                        }
                        .help("Cache hit rate for \(summary.provider.displayName)")
                    }
                }
            }

            Spacer()

            Text(settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens))
                .font(DesignSystem.Typography.mono)
                .foregroundStyle(quotaLegibleProviderColor(theme.primaryColor, in: colorScheme))
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(isHovered
                    ? (colorScheme == .dark ? Color.white.opacity(0.045) : Color.black.opacity(0.035))
                    : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hover) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Glass Card (Glassmorphic)

/// View modifier that conditionally attaches a press-detecting drag gesture.
/// Only active when `interactive` is true, so non-interactive GlassCards inside
/// Button views don't swallow tap gestures.
private struct InteractiveGlassCardGesture: ViewModifier {
    let interactive: Bool
    @Binding var isPressed: Bool

    func body(content: Content) -> some View {
        if interactive {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        } else {
            content
        }
    }
}

/// Frosted glass card with real material blur, warm tint, and luminous border.
struct GlassCard<Content: View>: View {
    var interactive: Bool = false
    var embedded: Bool = false
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0

    @State private var isHovered = false
    @State private var isPressed = false

    init(
        interactive: Bool = false,
        embedded: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.interactive = interactive
        self.embedded = embedded
        self.content = content
    }

    /// Light mode: ember + Spanish orange sheen instead of neutral white.
    private var glassSheenGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F45B69").opacity(0.07),
                    Color.clear,
                    Color(hex: "E86100").opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear,
                    DesignSystem.Colors.ember.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var glassEdgeGradient: LinearGradient {
        if colorScheme == .light {
            LinearGradient(
                colors: [
                    Color(hex: "F45B69").opacity(0.22),
                    DesignSystem.Colors.border.opacity(0.55),
                    Color(hex: "E86100").opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.18),
                    DesignSystem.Colors.border.opacity(0.45),
                    DesignSystem.Colors.border.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
        content()
            .padding(DesignSystem.Spacing.xs)
            .background { backgroundLayer }
            .clipShape(shape, style: FillStyle(antialiased: true))
            .overlay(
                shape
                    .strokeBorder(
                        glassEdgeGradient,
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
            .scaleEffect(interactive ? (isPressed ? 0.98 : isHovered ? 1.015 : 1.0) : 1.0)
            .animation(isPressed ? DesignSystem.Animation.snappy : DesignSystem.Animation.hover, value: isHovered)
            .animation(DesignSystem.Animation.snappy, value: isPressed)
            .onHover { if interactive { isHovered = $0 } }
            .modifier(InteractiveGlassCardGesture(interactive: interactive, isPressed: $isPressed))
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
        if embedded {
            shape.fill(
                colorScheme == .dark
                    ? Color.white.opacity(isHovered ? 0.085 : 0.055)
                    : Color.black.opacity(isHovered ? 0.065 : 0.035)
            )
        } else if reduceTransparency {
            shape.fill(DesignSystem.Colors.surface)
        } else if #available(macOS 26, *) {
            // Native Liquid Glass samples the content BEHIND it — a material
            // fill underneath would block the refraction and read as frosted
            // plastic. The warm sheen survives as a faint wash riding on top
            // of pure glass.
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            shape
                .fill(glassSheenGradient)
                .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                .liquidGlassEffect(
                    interactive ? .regular.interactive() : .regular,
                    in: shape
                )
        } else {
            // Pre-26 plate honors the glass transparency preference the same
            // way the shared adapters do: the material fades toward the raw
            // backdrop for "clearer", a thick frost scrim rises for "frostier".
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            ZStack {
                shape.fill(.ultraThinMaterial)
                    .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                shape.fill(DesignSystem.Colors.surface.opacity(0.55 * LiquidGlassTransparency.fallbackPlateOpacity(t)))
                shape.fill(.thickMaterial)
                    .opacity(LiquidGlassTransparency.frostScrimOpacity(t))
                shape.fill(glassSheenGradient)
            }
        }
    }
}

// MARK: - Glass Button

struct GlassButton: View {
    enum Style {
        /// Dashboard — warm ember, the app running hot.
        case prominent
        /// Settings — neutral glass.
        case regular
        /// Quit — the ember logo cooling to ice and draining away.
        case cool
    }

    let title: String
    let icon: String
    let style: Style
    let action: () -> Void

    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var isHovered = false
    @State private var isPressed = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs + 1) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm + 1)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .background(background)
            .clipShape(shape)
            .overlay(border)
            .shadow(color: glowColor.opacity(isHovered ? 0.35 : 0), radius: isHovered ? 9 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .scaleEffect(isPressed ? 0.97 : (isHovered ? 1.025 : 1.0))
        .animation(isPressed ? DesignSystem.Animation.snappy : DesignSystem.Animation.hover, value: isHovered)
        .animation(DesignSystem.Animation.snappy, value: isPressed)
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    // MARK: - Per-style theming

    private var foreground: AnyShapeStyle {
        switch style {
        case .prominent: return AnyShapeStyle(DesignSystem.Colors.primaryGradient)
        case .regular:   return AnyShapeStyle(DesignSystem.Colors.textSecondary)
        case .cool:      return AnyShapeStyle(DesignSystem.Colors.coolDownGradient)
        }
    }

    @ViewBuilder
    private var background: some View {
        if #available(macOS 26, *) {
            // Style wash rides on interactive glass; the material + neutral
            // surface base fills stay pre-26 only (nothing sits under glass).
            styleWash.liquidGlassEffect(.regular.interactive(), in: shape)
        } else {
            let t = LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency)
            ZStack {
                shape.fill(.ultraThinMaterial)
                    .opacity(LiquidGlassTransparency.fallbackPlateOpacity(t))
                shape.fill(.thickMaterial)
                    .opacity(LiquidGlassTransparency.frostScrimOpacity(t))
                switch style {
                case .prominent:
                    shape.fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                case .regular, .cool:
                    shape.fill(DesignSystem.Colors.surface.opacity(0.5))
                }
                styleWash
            }
        }
    }

    @ViewBuilder
    private var styleWash: some View {
        switch style {
        case .prominent:
            shape.fill(DesignSystem.Colors.ember.opacity(isHovered ? 0.12 : 0.06))
        case .regular:
            shape.fill(Color.white.opacity(isHovered ? 0.05 : 0))
        case .cool:
            // The cool wash drains downward — frost at the top fading to navy below.
            shape.fill(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.frost.opacity(isHovered ? 0.18 : 0.09),
                        DesignSystem.Colors.abyss.opacity(isHovered ? 0.22 : 0.11)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .prominent:
            shape.strokeBorder(
                LinearGradient(
                    colors: [DesignSystem.Colors.ember.opacity(0.4), DesignSystem.Colors.amber.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
        case .regular:
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.12), DesignSystem.Colors.border.opacity(0.35)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
        case .cool:
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.frost.opacity(isHovered ? 0.7 : 0.5),
                        DesignSystem.Colors.abyss.opacity(0.35)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        }
    }

    private var glowColor: Color {
        switch style {
        case .prominent: return DesignSystem.Colors.ember
        case .regular:   return Color.white
        case .cool:      return DesignSystem.Colors.glacier
        }
    }
}

// MARK: - Glass Icon Button

struct GlassIconButton<Label: View>: View {
    var isLoading: Bool = false
    let action: () -> Void
    @ViewBuilder private var label: () -> Label

    init(isLoading: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.isLoading = isLoading
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if isLoading {
                    AnimatedMiningPickView()
                        .frame(width: 20, height: 20)
                        .clipShape(.circle)
                } else {
                    label()
                }
            }
            .frame(width: 28, height: 28)
            .liquidGlassInteractive(in: .circle, fallback: .ultraThinMaterial)
            .clipShape(.circle)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.15), DesignSystem.Colors.border.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

enum PopoverTraySection: String, CaseIterable, Identifiable {
    case insights
    case summary
    case providers
    case mercury
    case chat
    case quickSwitch

    var id: String { rawValue }

    var accessibilityLabel: String {
        switch self {
        case .insights:
            return "Insights"
        case .summary:
            return "Summary"
        case .providers:
            return "Providers"
        case .mercury:
            return "Mercury"
        case .chat:
            return "Chat"
        case .quickSwitch:
            return "Quick Switch"
        }
    }
}

struct ResizableTraySectionDivider: View {
    var showsLine: Bool
    var hasCustomHeight: Bool
    var sectionLabel: String
    var onResizeChanged: (CGFloat) -> Void
    var onResizeEnded: () -> Void
    var onReset: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var isDragging = false
    @State private var cursorPushed = false

    var body: some View {
        ZStack {
            // Visual elements
            ZStack {
                if showsLine {
                    Rectangle()
                        .fill(
                            isHovered || isDragging
                                ? DesignSystem.Colors.ember.opacity(0.35)
                                : (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09))
                        )
                        .frame(height: 0.5)
                        .padding(.horizontal, 12)
                }
                if isHovered || isDragging {
                    Capsule()
                        .fill(handleColor)
                        .frame(width: 36, height: 3)
                        .overlay(
                            Capsule()
                                .strokeBorder(DesignSystem.Colors.ember.opacity(isDragging ? 0.55 : 0.28), lineWidth: 0.5)
                        )
                        .transition(.opacity)
                }
            }
            .frame(height: 8)

            // Taller, invisible interactive hit zone
            Color.clear
                .frame(height: 24) // 24 points is generous and very easy to target
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(DesignSystem.Animation.hover) {
                        isHovered = hovering
                    }
                    updateCursor(showResize: hovering)
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                updateCursor(showResize: true)
                            }
                            onResizeChanged(value.translation.height)
                        }
                        .onEnded { _ in
                            isDragging = false
                            onResizeEnded()
                            if !isHovered {
                                updateCursor(showResize: false)
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        if hasCustomHeight {
                            onReset()
                        }
                    }
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8) // Layout height remains exactly 8
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resize \(sectionLabel) section")
        .accessibilityHint(hasCustomHeight
            ? "Drag to resize. Double-tap to reset to natural height."
            : "Drag to resize.")
        .popoverTooltip(hasCustomHeight
            ? "Drag to resize • Double-click to reset"
            : "Drag to resize")
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }

    private var handleColor: Color {
        isDragging
            ? DesignSystem.Colors.ember.opacity(0.85)
            : DesignSystem.Colors.ember.opacity(0.55)
    }

    private func updateCursor(showResize: Bool) {
        if showResize {
            if !cursorPushed {
                NSCursor.resizeUpDown.push()
                cursorPushed = true
            }
        } else {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
    }
}

#Preview {
    let store = (try? DataStore()) ?? {
        preconditionFailure("Preview requires a valid DataStore - ensure app support directory is writable")
    }()
    let settingsManager = SettingsManager()
    MenuBarPopoverView(
        dataStore: store,
        aggregator: nil,
        quotaService: ProviderQuotaService.shared,
        settingsManager: settingsManager,
        operatingLayer: OpenBurnBarOperatingLayer(dataStore: store),
        onOpenDashboard: {},
        onOpenSettings: {}
    )
}
