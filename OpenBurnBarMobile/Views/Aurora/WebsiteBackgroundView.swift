import SwiftUI
import OpenBurnBarCore

/// Active, reconverging token-ember swarm pulled directly from burnbar.ai.
///
/// Hundreds of particles murmurate across the screen, periodically
/// reconverging into "$", "</>", concentric quota rings, and a router
/// failover S-curve — then breaking apart again. Reduce Motion locks the
/// pace and pauses the shape cycle.
///
/// When a `colorDriver` is provided, the swarm's palette shifts from its
/// default ember/amber/blaze to data-driven provider brand colors —
/// reflecting which providers are actively working or most heavily used.
struct WebsiteBackgroundView: View {
    let accent: Color
    var colorDriver: SwarmColorDriver?
    var visibility: MobileBackgroundVisibility = .prominent

    @AppStorage("appThemePalette") private var themePalette: AppThemePalette = .system
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var prefsJSON: String = SwarmBackgroundPreferences.defaultJSON
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mobileBackgroundVisibility) private var inheritedVisibility
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var envMonitor = SwarmEnvironmentMonitor.shared
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        // Editorial / Paper skin replaces the energetic swarm with a flat paper
        // field so every surface that drops this view in as its backdrop reads
        // as clean editorial paper instead of the dark murmuration.
        if appSkin == .editorial {
            MobileTheme.background
                .ignoresSafeArea()
        } else {
            swarmBody
        }
    }

    @ViewBuilder
    private var swarmBody: some View {
        let prefs = SwarmBackgroundPreferences.from(jsonString: prefsJSON)
        let effectiveVisibility = visibility.constrained(by: inheritedVisibility)
        let plan = SwarmBackgroundPowerPolicy.resolve(
            location: prefs.location,
            conditionMet: envMonitor.meetsCondition(prefs.condition),
            requestedVisibility: effectiveVisibility,
            scenePhaseActive: scenePhase == .active,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            reduceMotion: reduceMotion
        )

        switch plan.mode {
        case .live:
            SwarmCanvasView(
                accent: accent,
                pace: .cinematic,
                particleCount: resolvedParticleCount(scale: plan.particleScale),
                colorDriver: colorDriver,
                isBatteryThrottled: plan.isBatteryThrottled,
                backdropColors: themePalette.backdropColors,
                colorPalette: themePalette.swarmPalette,
                motionSpeedMultiplier: plan.motionSpeedMultiplierScale,
                isAutoCyclingEnabled: plan.allowsAutoCycling,
                enabledProviderGlyphs: prefs.selectedGlyphs,
                isAvatarEnabled: prefs.isAvatarEnabled,
                isBrandTextEnabled: prefs.isBrandTextEnabled,
                enableSwarmSparkles: plan.allowsSparkles,
                excludeBrandShapesFromSwarm: prefs.excludeBrandShapes,
                maxFrameRate: plan.maxFrameRate,
                rendersAsynchronously: true
            )
            .ignoresSafeArea()
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        case .staticBackdrop:
            staticBackdrop
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                    isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
        case .disabledFallback:
            AuroraBackdrop(
                density: effectiveVisibility == .prominent ? .full : .subtle,
                colorDriver: colorDriver,
                visibility: effectiveVisibility,
                allowsWebsiteBackground: false
            )
            .ignoresSafeArea()
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    private func resolvedParticleCount(scale: Double) -> Int {
        max(96, Int(Double(SwarmCanvasView.adaptiveParticleCount) * scale))
    }

    private var staticBackdrop: some View {
        LinearGradient(
            colors: themePalette.backdropColors ?? [
                MobileTheme.background,
                MobileTheme.surface
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(accent.opacity(0.08))
        .ignoresSafeArea()
    }
}

#Preview {
    WebsiteBackgroundView(accent: .orange)
}
