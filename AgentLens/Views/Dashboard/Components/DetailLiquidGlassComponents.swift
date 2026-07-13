import SwiftUI
import OpenBurnBarCore

struct DetailHeroMetric: Identifiable, Equatable {
    let label: String
    let value: String

    var id: String { label }
}

struct DetailLiquidGlassBackdrop: View {
    let accent: Color
    let secondaryAccent: Color

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            (colorScheme == .dark ? Color.black.opacity(0.46) : Color.white.opacity(0.42))

            if !reduceTransparency {
                RadialGradient(
                    colors: [accent.opacity(colorScheme == .dark ? 0.14 : 0.09), .clear],
                    center: .topLeading,
                    startRadius: 20,
                    endRadius: 620
                )

                RadialGradient(
                    colors: [secondaryAccent.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear],
                    center: .bottomTrailing,
                    startRadius: 30,
                    endRadius: 720
                )
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.01),
                    Color.black.opacity(colorScheme == .dark ? 0.24 : 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DetailLiquidGlassSurface<Content: View>: View {
    let accent: Color
    var cornerRadius: CGFloat = 26
    var contentPadding: CGFloat = UnifiedDesignSystem.Spacing.xl
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content()
            .padding(contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(reduceTransparency ? opaqueSurface : Color.clear)

                    if !reduceTransparency {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)

                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.055 : 0.34),
                                        accent.opacity(colorScheme == .dark ? 0.035 : 0.025),
                                        Color.black.opacity(colorScheme == .dark ? 0.13 : 0.015)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.58),
                                accent.opacity(0.16),
                                Color.white.opacity(colorScheme == .dark ? 0.035 : 0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08), radius: 28, y: 14)
    }

    private var opaqueSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.08, blue: 0.105)
            : Color(red: 0.95, green: 0.95, blue: 0.97)
    }
}

struct DetailEntityHero<Icon: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let accent: Color
    let secondaryAccent: Color
    let metrics: [DetailHeroMetric]
    @ViewBuilder let icon: () -> Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        DetailLiquidGlassSurface(accent: accent, cornerRadius: 30, contentPadding: 0) {
            ZStack(alignment: .bottomTrailing) {
                ambientArtwork

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 40) {
                        identity
                        Spacer(minLength: 28)
                        metricRail
                            .frame(maxWidth: 600)
                    }

                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xl) {
                        identity
                        metricRail
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible ? 0 : (reduceMotion ? 0 : 12))
        .onAppear {
            if reduceMotion {
                isVisible = true
            } else {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.88)) {
                    isVisible = true
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.25), secondaryAccent.opacity(0.08)],
                            center: .topLeading,
                            startRadius: 2,
                            endRadius: 48
                        )
                    )
                    .frame(width: 88, height: 88)

                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.75)
                    .frame(width: 88, height: 88)

                icon()
            }
            .shadow(color: accent.opacity(0.22), radius: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(accent)

                Text(title)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.interpolate)

                Text(subtitle)
                    .font(UnifiedDesignSystem.Typography.body)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private var metricRail: some View {
        HStack(spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1, height: 40)
                        .padding(.horizontal, 18)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.label.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.25)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                    Text(metric.value)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(index == 0 ? accent : UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }

    private var ambientArtwork: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [secondaryAccent.opacity(0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 80, y: 86)

            icon()
                .scaleEffect(4.4)
                .opacity(0.025)
                .offset(x: 56, y: 34)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DetailSectionHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let accent: Color
    var trailingText: String?

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(accent)

                Text(title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)

                Text(subtitle)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: UnifiedDesignSystem.Spacing.md)

            if let trailingText {
                Text(trailingText.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    .padding(.top, 3)
            }
        }
    }
}

struct DetailGlassActionButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(configuration.isPressed ? Color.white.opacity(0.72) : Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.34 : 0.22))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.12 : 0.22), lineWidth: 0.75)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
