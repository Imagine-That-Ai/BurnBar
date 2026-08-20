import AppKit
import OpenBurnBarCore
import SwiftUI
import WebKit

enum DashboardLiveBackdropVisibility {
    static func exposesContentBackdrop(
        appearanceSkin: AppSkin,
        useWebsiteBackground: Bool,
        useKernelBackdrop: Bool
    ) -> Bool {
        appearanceSkin == .editorial
            || useWebsiteBackground
            || useKernelBackdrop
    }
}

private struct DashboardLiveBackdropActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dashboardLiveBackdropActive: Bool {
        get { self[DashboardLiveBackdropActiveKey.self] }
        set { self[DashboardLiveBackdropActiveKey.self] = newValue }
    }
}

struct UsageModeToolbarPicker: View {
    @Binding var selection: UsageDisplayMode

    var body: some View {
        Menu {
            ForEach(UsageDisplayMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    HStack {
                        Text(mode.label)
                        if selection == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: leadingSymbol(for: selection))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(selection.label)
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
        .help("Show totals in USD or token volume")
    }

    private func leadingSymbol(for mode: UsageDisplayMode) -> String {
        switch mode.label.lowercased() {
        case let l where l.contains("usd") || l.contains("$") || l.contains("cost"):
            return "dollarsign"
        default:
            return "number"
        }
    }
}

struct DashboardBackdrop: View {
    let moodBand: MoodBand
    var kernelColorScheme: ColorScheme?
    var onReadabilityChange: ((BackdropReadabilityProfile) -> Void)?
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0
    @AppStorage(KernelBackdropPreferences.enabledKey) private var useKernelBackdrop: Bool = false
    @StateObject private var substrateBox = SwarmSubstrateBox()
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = OpenBurnBarUI.SubstrateCatalog.plainID
    @AppStorage(SwarmSubstratePreferences.backdropKernelKey) private var backdropKernel: String = KernelCatalog.defaultID

    /// Clear-side adjustment (0…1). Toward 1 the window's own plates fade so
    /// the blurred desktop shows through — the felt payoff of the preference
    /// on a window whose content is otherwise dark-on-dark.
    private var clarity: Double {
        max(0, LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency))
    }

    private var dynamicBackdropEnabled: Bool {
        DashboardLiveBackdropVisibility.exposesContentBackdrop(
            appearanceSkin: settingsManager.appearanceSkin,
            useWebsiteBackground: settingsManager.useWebsiteBackground,
            useKernelBackdrop: shouldUseKernelBackdrop
        )
    }

    /// CI launches with an ephemeral preferences home. Mount the actual
    /// backdrop deterministically instead of relying on `@AppStorage` to
    /// consume the argument domain before this view is first constructed.
    private var shouldUseKernelBackdrop: Bool {
        useKernelBackdrop || OpenBurnBarRuntime.performanceGateBackdropKernelOverride(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch,
            arguments: ProcessInfo.processInfo.arguments
        ) != nil
    }

    private var substrate: SwarmSubstrate {
        substrateBox.resolve(kernelID: backdropKernel, selectedID: substrateID, enabled: substrateEnabled)
    }

    init(
        moodBand: MoodBand,
        kernelColorScheme: ColorScheme? = nil,
        onReadabilityChange: ((BackdropReadabilityProfile) -> Void)? = nil
    ) {
        self.moodBand = moodBand
        self.kernelColorScheme = kernelColorScheme
        self.onReadabilityChange = onReadabilityChange
    }

    private var nativeReadabilityProfile: BackdropReadabilityProfile {
        BackdropReadabilityProfile.nativeFallback(
            colorScheme: kernelColorScheme ?? colorScheme,
            appearanceSkin: settingsManager.appearanceSkin,
            liveBackdropActive: dynamicBackdropEnabled
        )
    }

    private var readabilityContextID: String {
        [
            settingsManager.appearanceSkin.rawValue,
            dynamicBackdropEnabled.description,
            useKernelBackdrop.description,
            (kernelColorScheme ?? colorScheme) == .dark ? "dark" : "light"
        ].joined(separator: ":")
    }

    var body: some View {
        ZStack {
            // cov:ignore-start -- decorative background composition is smoke-tested but not line-attributed by ViewInspector
            if clarity > 0 {
                LiquidGlassWindowBlend()
                    .ignoresSafeArea()
            }
            if settingsManager.appearanceSkin == .editorial {
                // Editorial / Paper skin: the light dot-crest (provider logos
                // drifting from coloured dots on paper), like app.burnbar.ai.
                WebsiteBackgroundView(accent: DesignSystem.Colors.ember)
            } else if dynamicBackdropEnabled {
                Group {
                    if shouldUseKernelBackdrop {
                        // Full-window WebGL2 kernel field (the living backdrop).
                        // Native swarm mounts only for an explicit substrate — see
                        // `KernelSwarmOverlayPolicy`. Provider glyphs tint the kernel;
                        // they do not spawn a second particle simulator.
                        staticKernelFallback
                        KernelBackdropView(
                            colorSchemeOverride: kernelColorScheme,
                            onReadabilityChange: { profile in
                                onReadabilityChange?(profile)
                            },
                            wantsOpaqueLayer: KernelWebViewOpacityPolicy.isOpaque(clarity: clarity)
                        )
                            .ignoresSafeArea()
                        kernelSubstrateOverlay
                    } else if settingsManager.useConstellationBackground {
                        ConstellationBackgroundView(
                            accent: DesignSystem.Colors.ember,
                            enabledProviderGlyphs: settingsManager.desktopWallpaperProviderGlyphs
                        )
                    } else {
                        WebsiteBackgroundView(accent: DesignSystem.Colors.ember)
                    }
                }
                .opacity(1 - 0.82 * clarity)
            } else {
                staticDashboardFallback
                    .opacity(1 - 0.82 * clarity)
            }
            // cov:ignore-end
        }
        .task(id: readabilityContextID) {
            onReadabilityChange?(nativeReadabilityProfile)
        }
    }

    @ViewBuilder
    private var kernelSubstrateOverlay: some View {
        let enabledProviderGlyphs = settingsManager.desktopWallpaperProviderGlyphs
        if KernelSwarmOverlayPolicy.shouldMountCanvas(
            substrateEnabled: substrateEnabled,
            substrateID: substrateID
        ) {
            SwarmCanvasView(
                accent: DesignSystem.Colors.ember,
                pace: .cinematic,
                particleCount: max(96, SwarmCanvasView.adaptiveParticleCount / 3),
                isTransparent: true,
                motionSpeedMultiplier: 0.6,
                enabledProviderGlyphs: enabledProviderGlyphs,
                enableSwarmSparkles: false,
                excludeBrandShapesFromSwarm: !enabledProviderGlyphs.isEmpty || settingsManager.excludeBrandShapesFromSwarm,
                maxFrameRate: 15,
                rendersAsynchronously: true,
                substrate: substrate
            )
            .ignoresSafeArea()
            .opacity(0.58)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var staticDashboardFallback: some View {
        ZStack {
            DesignSystem.Colors.background
                .ignoresSafeArea()

            DesignSystem.Colors.ember
                .opacity(0.035)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .topLeading) {
                    Rectangle()
                        .frame(width: 520)
                        .rotationEffect(.degrees(-11))
                        .offset(x: -260, y: -80)
                }

            DesignSystem.Colors.whimsy
                .opacity(0.025)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(alignment: .bottomTrailing) {
                    Rectangle()
                        .frame(width: 460)
                        .rotationEffect(.degrees(15))
                        .offset(x: 220, y: 110)
                }
        }
    }

    private var staticKernelFallback: some View {
        staticDashboardFallback
    }
}

/// A breathtakingly premium replication of the official OpenBurnBar website background for macOS.
/// Renders a deep space canvas, shifting organic cosmic mesh gradients, and a highly
/// precise technical 3D perspective grid fading out toward a high horizon vanishing point.
/// Active, reconverging token-ember swarm pulled directly from burnbar.ai.
///
/// Hundreds of particles murmurate across the screen, periodically
/// reconverging into "$", "</>", concentric quota rings, and a router
/// failover S-curve — then breaking apart again. Reduce Motion locks the
/// pace and pauses the shape cycle.
struct WebsiteBackgroundView: View {
    let accent: Color
    @Environment(SettingsManager.self) private var settingsManager
    @StateObject private var substrateBox = SwarmSubstrateBox()
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = OpenBurnBarUI.SubstrateCatalog.plainID
    @AppStorage(KernelBackdropPreferences.kernelKey) private var backdropKernel: String = KernelCatalog.defaultID

    /// The resolved substrate for the active backdrop theme + persisted pick.
    /// Plain (no-op) unless enabled and the pick belongs to the theme's family.
    private var substrate: SwarmSubstrate {
        substrateBox.resolve(kernelID: backdropKernel, selectedID: substrateID, enabled: substrateEnabled)
    }

    var body: some View {
        // cov:ignore-start -- decorative background composition is smoke-tested but not line-attributed by ViewInspector
        if settingsManager.appearanceSkin == .editorial {
            // Light dot-crest: paper field with a transparent, slow, sparkle-free
            // swarm on top. Provider logos render in their real brand colours, so
            // they read crisply on paper (no glyph filter → the full roster).
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()
                SwarmCanvasView(
                    accent: accent,
                    pace: .cinematic,
                    isTransparent: true,
                    motionSpeedMultiplier: 0.7,
                    enabledProviderGlyphs: settingsManager.desktopWallpaperProviderGlyphs,
                    enableSwarmSparkles: false,
                    excludeBrandShapesFromSwarm: !settingsManager.desktopWallpaperProviderGlyphs.isEmpty || settingsManager.excludeBrandShapesFromSwarm,
                    rendersAsynchronously: true,
                    substrate: substrate
                )
                .ignoresSafeArea()
                .opacity(0.85)
            }
        } else {
            SwarmCanvasView(
                accent: accent,
                pace: .energetic,
                enabledProviderGlyphs: settingsManager.desktopWallpaperProviderGlyphs,
                excludeBrandShapesFromSwarm: settingsManager.excludeBrandShapesFromSwarm,
                rendersAsynchronously: true,
                substrate: substrate
            )
                .ignoresSafeArea()
        }
        // cov:ignore-end
    }
}
