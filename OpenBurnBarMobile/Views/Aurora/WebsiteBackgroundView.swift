import SwiftUI
import OpenBurnBarCore

/// Shared app.burnbar.ai-inspired backdrop surface for iPhone and iPad.
///
/// Aurora/editorial skins keep their existing specialized paths, while the
/// dark Website Background mode dispatches through the mobile kernel picker.
/// Power, scene, visibility, and Reduce Motion policy still decide whether the
/// active kernel renders live, static, or falls back to the native aurora.
struct WebsiteBackgroundView: View {
    let accent: Color
    var colorDriver: SwarmColorDriver?
    var visibility: MobileBackgroundVisibility = .prominent

    @AppStorage("appThemePalette") private var themePalette: AppThemePalette = .system
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var prefsJSON: String = SwarmBackgroundPreferences.defaultJSON
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mobileBackgroundVisibility) private var inheritedVisibility
    @Environment(\.hermesStreamingActive) private var hermesStreamingActive
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var envMonitor = SwarmEnvironmentMonitor.shared
    @StateObject private var substrateBox = SwarmSubstrateBox()
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = OpenBurnBarUI.SubstrateCatalog.plainID
    @AppStorage(MobileBackdropKernel.storageKey) private var mobileBackdropKernel: String = MobileBackdropKernel.defaultKernel.rawValue

    private var substrate: SwarmSubstrate {
        substrateBox.resolve(kernelID: mobileBackdropKernel, selectedID: substrateID, enabled: substrateEnabled)
    }

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
                    // Empty selection (the "None" glyph choice) is meaningful:
                    // provider logos stay hidden while the non-provider cycle can
                    // still run when brand shapes are enabled.
                    enabledProviderGlyphs: prefs.selectedGlyphs,
                    isAvatarEnabled: prefs.isAvatarEnabled,
                    isBrandTextEnabled: prefs.isBrandTextEnabled,
                    enableSwarmSparkles: false,
                    excludeBrandShapesFromSwarm: prefs.excludeBrandShapes || !prefs.selectedGlyphs.isEmpty,
                    maxFrameRate: streamingThrottledFrameRate(30),
                    rendersAsynchronously: true,
                    substrate: substrate
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
        let selectedKernel = MobileBackdropKernel.resolved(mobileBackdropKernel)
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
            liveBackdrop(for: selectedKernel, prefs: prefs, plan: plan, visibility: effectiveVisibility)
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

    /// The live kernel backdrop. Every kernel now renders through the WebGL
    /// host (`MobileWebGLKernelBackdropView`) — the SAME offline bundle macOS
    /// and the website use — as the BASE layer. When the substrate picker is
    /// enabled we layer the transparent SwarmCanvasView + substrate OVER the
    /// kernel, mirroring macOS `DashboardBackdrop` (kernel base, then optional
    /// `kernelSubstrateOverlay`). This retires the old procedural
    /// `MobileKernelBackdropView`/`ConstellationBackgroundView` live renderers
    /// in favour of the real WebGL kernels, for parity across platforms.
    @ViewBuilder
    private func liveBackdrop(
        for kernel: MobileBackdropKernel,
        prefs: SwarmBackgroundPreferences,
        plan: SwarmBackgroundRenderPlan,
        visibility: MobileBackgroundVisibility
    ) -> some View {
        // Dark by default; light for the editorial/paper skin or a light scheme.
        let theme = (appSkin == .editorial || colorScheme == .light) ? "light" : "dark"
        let providerGlyphsSelected = !prefs.selectedGlyphs.isEmpty
        let substrateSelected = substrateEnabled && substrateID != OpenBurnBarUI.SubstrateCatalog.plainID

        ZStack {
            // WebGL kernel base — same `KernelBackdrop` bundle as macOS/web,
            // driven by the raw kernel id (e.g. "constellation", "fluid-aurora").
            MobileWebGLKernelBackdropView(kernelID: kernel.rawValue, theme: theme)
                .ignoresSafeArea()

            // Transparent swarm over the kernel only for an explicit substrate.
            // Provider glyphs default to the full roster; they must not mount a
            // second particle simulator on the living WebGL kernel.
            if KernelSwarmOverlayPolicy.shouldMountCanvas(
                substrateEnabled: substrateEnabled,
                substrateID: substrateID
            ) {
                SwarmCanvasView(
                    accent: accent,
                    pace: .cinematic,
                    particleCount: editorialParticleCount(for: visibility),
                    colorDriver: providerGlyphsSelected ? nil : colorDriver,
                    isTransparent: true,
                    colorPalette: themePalette.swarmPalette,
                    motionSpeedMultiplier: 0.6,
                    isAutoCyclingEnabled: true,
                    enabledProviderGlyphs: prefs.selectedGlyphs,
                    isAvatarEnabled: providerGlyphsSelected ? false : prefs.isAvatarEnabled,
                    isBrandTextEnabled: providerGlyphsSelected ? false : prefs.isBrandTextEnabled,
                    enableSwarmSparkles: false,
                    excludeBrandShapesFromSwarm: prefs.excludeBrandShapes || providerGlyphsSelected,
                    maxFrameRate: streamingThrottledFrameRate(plan.maxFrameRate),
                    rendersAsynchronously: true,
                    substrate: substrateSelected ? substrate : nil
                )
                .ignoresSafeArea()
                .opacity(providerGlyphsSelected ? 0.62 : 0.58)
                .allowsHitTesting(false)
            }
        }
    }

    private func resolvedParticleCount(scale: Double) -> Int {
        max(96, Int(Double(SwarmCanvasView.adaptiveParticleCount) * scale))
    }

    /// While a Hermes reply is streaming, cap the swarm at ~20 fps so its
    /// per-frame particle advance stops competing with the chat's streaming
    /// text for the frame budget. Editorial wallpaper is cinematic (30 fps);
    /// a nil plan rate means "use the canvas default".
    private func streamingThrottledFrameRate(_ planRate: Double?) -> Double? {
        Self.throttledFrameRate(planRate: planRate, streamingActive: hermesStreamingActive)
    }

    /// Pure policy so the swarm-throttle behavior is unit-testable: while a
    /// Hermes reply streams, cap at 20 fps; never raise an already-slower
    /// plan; pass the plan through untouched when not streaming.
    nonisolated static func throttledFrameRate(planRate: Double?, streamingActive: Bool) -> Double? {
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
