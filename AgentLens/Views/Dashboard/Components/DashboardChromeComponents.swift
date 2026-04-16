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
struct CyclingProviderIconView: View {
    let providers: [AgentProvider]
    let size: CGFloat
    let interval: TimeInterval

    @State private var currentIndex: Int

    private let timer: Publishers.Autoconnect<Timer.TimerPublisher>

    init(providers: [AgentProvider], size: CGFloat = 11, interval: TimeInterval = 2.2, startOffset: Int = 0) {
        self.providers = providers
        self.size = size
        self.interval = interval
        self.timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
        self._currentIndex = State(initialValue: providers.isEmpty ? 0 : startOffset % providers.count)
    }

    var body: some View {
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
        .onReceive(timer) { _ in
            guard providers.count > 1 else { return }
            currentIndex = (currentIndex + 1) % providers.count
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
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm + 2, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm + 2, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.45))
            }
        )
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

// MARK: - Glass Picker

struct GlassPicker<Option: Identifiable & Hashable>: View {
    @Binding var selection: Option
    let options: [Option]

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
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(selectionLabel(selection))
                    .font(DesignSystem.Typography.caption)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.5))
                }
            }
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
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
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
                }
            }
            .clipShape(.rect(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
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

    private var theme: ProviderTheme { .theme(for: usage.provider) }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
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

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatTime(usage.startTime))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(theme.primaryColor)

                Text(settingsManager.formatUsageMetric(cost: usage.cost, tokens: usage.totalTokens))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .contentTransition(.numericText())
                    .animation(DesignSystem.Animation.gentle, value: usage.id)
            }
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
