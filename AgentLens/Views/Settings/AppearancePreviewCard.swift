import SwiftUI
import OpenBurnBarCore

// MARK: - AppearancePreviewCard

/// A miniature dashboard mockup that previews the *current* appearance
/// configuration before the user hits Apply & Restart. It renders a tiny
/// toolbar strip, a live mini sparkline, two provider cards, and the correct
/// backdrop (flat color, paper tint for Editorial, or a small SwarmCanvasView
/// for Aurora swarm). Respects `appearanceMode`, `appearanceSkin`,
/// `useWebsiteBackground`, `useConstellationBackground`, and the Liquid Glass
/// transparency slider so every toggle/sliders in the Appearance page is
/// reflected here in real time.
struct AppearancePreviewCard: View {
    @Bindable var settingsManager: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0
    @AppStorage(LiquidGlassTransparency.contentSurfacesEnabledKey) private var contentSurfacesEnabled: Bool = LiquidGlassTransparency.defaultContentSurfacesEnabled
    @StateObject private var substrateBox = SwarmSubstrateBox()
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = OpenBurnBarUI.SubstrateCatalog.plainID
    @AppStorage(SwarmSubstratePreferences.backdropKernelKey) private var backdropKernel: String = SwarmSubstratePreferences.defaultKernelID

    private let previewProviders: [AgentProvider] = [.claudeCode, .codex, .factory]

    private var substrate: SwarmSubstrate {
        substrateBox.resolve(kernelID: backdropKernel, selectedID: substrateID, enabled: substrateEnabled)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 0) {
                previewHeader
                Divider().background(DesignSystem.Colors.border.opacity(0.5))
                previewBody
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        }
    }

    // MARK: Header

    private var previewHeader: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            // Mini brand mark
            Image(systemName: "flame.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.ember)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text("OpenBurnBar")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Preview")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer(minLength: 8)

            // Mini telemetry
            miniSparkline

            VStack(alignment: .trailing, spacing: 1) {
                Text("$24.18")
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("+12%")
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            // Mini settings gear to show it sits independently
            Image(systemName: "gearshape")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 18, height: 18)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 8)
        .background(headerSurface)
    }

    @ViewBuilder
    private var headerSurface: some View {
        if #available(macOS 26, *) {
            Rectangle()
                .fill(.clear)
                .liquidGlassEffect(.regular, in: .rect)
                .opacity(glassHeaderOpacity)
        } else {
            Rectangle()
                .fill(DesignSystem.Colors.surface.opacity(0.5 * glassHeaderOpacity))
        }
    }

    private var glassHeaderOpacity: Double {
        let clarity = max(0, LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: false))
        return 0.7 + 0.3 * clarity
    }

    private var miniSparkline: some View {
        Canvas { context, size in
            let samples: [Double] = [0.2, 0.35, 0.28, 0.5, 0.42, 0.65, 0.55, 0.78]
            let path = sparklinePath(samples: samples, in: size)
            context.stroke(
                path,
                with: .color(DesignSystem.Colors.ember),
                lineWidth: 1.2
            )
        }
        .frame(width: 48, height: 18)
    }

    private func sparklinePath(samples: [Double], in size: CGSize) -> Path {
        guard samples.count > 1 else { return Path() }
        let stepX = size.width / CGFloat(samples.count - 1)
        var path = Path()
        for (i, value) in samples.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * CGFloat(1 - value)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    // MARK: Body

    private var previewBody: some View {
        ZStack {
            previewBackdrop

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                // Provider card row
                HStack(spacing: 6) {
                    ForEach(previewProviders, id: \.self) { provider in
                        previewProviderCard(provider)
                    }
                }
                Spacer(minLength: 4)
            }
            .padding(DesignSystem.Spacing.sm)
        }
        .frame(height: 76)
    }

    private func previewProviderCard(_ provider: AgentProvider) -> some View {
        let providerColor = DesignSystemColors.primary(for: provider)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                ProviderLogoView(provider: provider, size: 14, useFallbackColor: false)
                Text(provider.displayName)
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
            }
            // Mini bar
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(providerColor.opacity(0.2))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(providerColor)
                            .frame(width: geo.size.width * barFillFraction(for: provider))
                    }
            }
            .frame(height: 4)
            Text(fakeCost(for: provider))
                .font(.system(size: 8, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private var cardFill: Color {
        if #available(macOS 26, *), contentSurfacesEnabled {
            return Color.clear
        }
        return DesignSystem.Colors.surfaceElevated
    }

    // MARK: Backdrop

    @ViewBuilder
    private var previewBackdrop: some View {
        let skin = settingsManager.appearanceSkin
        if skin == .editorial {
            // Paper field, light cream tint
            DesignSystem.Colors.background
        } else if settingsManager.useWebsiteBackground {
            if settingsManager.useConstellationBackground {
                DesignSystem.Colors.background
                    .overlay(
                        // Static constellation dots as a cheap preview
                        ZStack {
                            ForEach(0..<6, id: \.self) { i in
                                Circle()
                                    .fill(DesignSystem.Colors.ember.opacity(0.18))
                                    .frame(width: 3, height: 3)
                                    .offset(
                                        x: CGFloat.random(in: -40...40, seed: i),
                                        y: CGFloat.random(in: -12...12, seed: i + 10)
                                    )
                            }
                        }
                    )
            } else {
                // Mini swarm preview using actual SwarmCanvasView
                SwarmCanvasView(
                    accent: DesignSystem.Colors.ember,
                    pace: .cinematic,
                    motionSpeedMultiplier: 0.8,
                    enabledProviderGlyphs: settingsManager.desktopWallpaperProviderGlyphs,
                    enableSwarmSparkles: settingsManager.enableSwarmSparkles,
                    excludeBrandShapesFromSwarm: !settingsManager.desktopWallpaperProviderGlyphs.isEmpty || settingsManager.excludeBrandShapesFromSwarm,
                    rendersAsynchronously: true,
                    substrate: substrate
                )
                .opacity(0.55)
            }
        } else {
            DesignSystem.Colors.background
                .overlay(
                    // Subtle diagonal wash matching the static fallback
                    DesignSystem.Colors.ember
                        .opacity(0.04)
                        .rotationEffect(.degrees(-13))
                        .offset(x: -40)
                )
        }
    }

    private func barFillFraction(for provider: AgentProvider) -> CGFloat {
        switch provider {
        case .claudeCode: return 0.82
        case .codex: return 0.58
        case .factory: return 0.41
        default: return 0.5
        }
    }

    private func fakeCost(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "$14.20"
        case .codex: return "$6.84"
        case .factory: return "$3.14"
        default: return "$0.00"
        }
    }
}

// MARK: - Seeded random helper

private extension CGFloat {
    static func random(in range: ClosedRange<CGFloat>, seed: Int) -> CGFloat {
        let normalized = abs(sin(Double(seed) * 12.9898) * 43758.5453)
        let fraction = normalized - floor(normalized)
        return range.lowerBound + CGFloat(fraction) * (range.upperBound - range.lowerBound)
    }
}

#if DEBUG
#Preview("Appearance Preview — Aurora Dark") {
    let settings = SettingsManager()
    settings.appearanceMode = .dark
    settings.appearanceSkin = .aurora
    settings.useWebsiteBackground = true
    return AppearancePreviewCard(settingsManager: settings)
        .environment(settings)
        .frame(width: 360)
        .padding()
}

#Preview("Appearance Preview — Editorial Light") {
    let settings = SettingsManager()
    settings.appearanceMode = .light
    settings.appearanceSkin = .editorial
    settings.useWebsiteBackground = false
    return AppearancePreviewCard(settingsManager: settings)
        .environment(settings)
        .frame(width: 360)
        .padding()
}
#endif
