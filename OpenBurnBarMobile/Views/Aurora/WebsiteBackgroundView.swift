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
    @Environment(\.hermesStreamingActive) private var hermesStreamingActive
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var envMonitor = SwarmEnvironmentMonitor.shared
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        // Editorial / Paper skin renders the light "dot-crest" — provider logos
        // drifting and reconverging from coloured dots on paper, exactly like the
        // app.burnbar.ai console — instead of the dark ember murmuration.
        if appSkin == .editorial {
            editorialDotCrest
        } else {
            swarmBody
        }
    }

    /// Light dot-crest: paper field with a transparent, subtle, slow swarm on top
    /// that resolves the full provider roster (logos render in their real brand
    /// colours, so they read crisply on paper). Falls back to calm paper when
    /// motion/power/visibility says so.
    @ViewBuilder
    private var editorialDotCrest: some View {
        let prefs = SwarmBackgroundPreferences.from(jsonString: prefsJSON)
        let effectiveVisibility = visibility.constrained(by: inheritedVisibility)
        let calm = reduceMotion
            || isLowPowerModeEnabled
            || scenePhase != .active
            || effectiveVisibility == .hidden
            || effectiveVisibility == .obscured

        ZStack {
            MobileTheme.background
                .ignoresSafeArea()

            if !calm {
                SwarmCanvasView(
                    accent: MobileTheme.ember,
                    pace: .cinematic,
                    particleCount: editorialParticleCount(for: effectiveVisibility),
                    // No live color driver: an *active* driver pins the swarm to
                    // the drifting data-coloured state (see SwarmSimulation.advance
                    // — cycling is gated on `colorDriver?.mode != .active`), so the
                    // logos never reconverge. The editorial dot-crest is all about
                    // logos forming and dissolving, like app.burnbar.ai, so it
                    // always auto-cycles. Logo dots still use their real brand
                    // colours (sampled `logoColor`), independent of the driver.
                    colorDriver: nil,
                    isTransparent: true,
                    colorPalette: themePalette.swarmPalette,
                    motionSpeedMultiplier: 0.7,
                    isAutoCyclingEnabled: true,
                    // Empty selection (the "None" glyph choice) would yield a cycle
                    // with no provider logos — fall back to the full roster so the
                    // dot-crest always has logos to form.
                    enabledProviderGlyphs: prefs.selectedGlyphs.isEmpty ? nil : prefs.selectedGlyphs,
                    isAvatarEnabled: prefs.isAvatarEnabled,
                    isBrandTextEnabled: prefs.isBrandTextEnabled,
                    enableSwarmSparkles: false,
                    excludeBrandShapesFromSwarm: prefs.excludeBrandShapes,
                    maxFrameRate: streamingThrottledFrameRate(nil),
                    rendersAsynchronously: true
                )
                .ignoresSafeArea()
                .opacity(editorialOpacity(for: effectiveVisibility))
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                    isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                }
            }
        }
    }

    private func editorialParticleCount(for visibility: MobileBackgroundVisibility) -> Int {
        let base = Double(SwarmCanvasView.adaptiveParticleCount)
        switch visibility {
        case .prominent: return max(96, Int(base * 0.7))
        case .subtle:    return max(64, Int(base * 0.42))
        default:         return 48
        }
    }

    private func editorialOpacity(for visibility: MobileBackgroundVisibility) -> Double {
        switch visibility {
        case .prominent: return 0.9
        case .subtle:    return 0.6
        default:         return 0.4
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
                maxFrameRate: streamingThrottledFrameRate(plan.maxFrameRate),
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

    /// While a Hermes reply is streaming, cap the swarm at ~20 fps so its
    /// per-frame particle advance stops competing with the chat's streaming
    /// text for the frame budget. A nil plan rate means "use the canvas
    /// default" (60 fps), so streaming substitutes the cap directly.
    private func streamingThrottledFrameRate(_ planRate: Double?) -> Double? {
        Self.throttledFrameRate(planRate: planRate, streamingActive: hermesStreamingActive)
    }

    /// Pure policy so the swarm-throttle behavior is unit-testable: while a
    /// Hermes reply streams, cap at 20 fps; never raise an already-slower
    /// plan; pass the plan through untouched when not streaming.
    static func throttledFrameRate(planRate: Double?, streamingActive: Bool) -> Double? {
        guard streamingActive else { return planRate }
        return min(planRate ?? 20, 20)
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
