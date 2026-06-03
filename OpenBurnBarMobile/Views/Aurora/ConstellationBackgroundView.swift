import SwiftUI
import OpenBurnBarCore

/// Calm, slow ambient "Constellation" background.
///
/// A thin OpenBurnBarMobile-local wrapper around the shared
/// ``SwarmCanvasView`` engine, tuned for a single, serene rhythm: one
/// BurnBar crest / provider logo at a time resolves into fine, full-colour
/// dots somewhere on screen, holds while it shimmers (per-dot twinkle + the
/// engine's diagonal iridescent sheen), then its dots scatter apart and
/// dissolve — and a *different* logo resolves into being somewhere else.
///
/// It reuses the engine with a constellation-tuned config instead of adding
/// a second pixel-sampling pipeline:
/// - `.cinematic` pace → slow, elegant resolve / admire-hold / scatter beats.
/// - a *single* enabled provider glyph → exactly one logo on screen at a
///   time (the engine places a lone logo and alternates swarm ↔ logo).
/// - `excludeBrandShapesFromSwarm: true` → only logos cycle (no `$` / `</>`
///   glyph shapes), keeping the field calm and brand-forward.
/// - `colorDriver: nil` → purely ambient; the engine's own auto-cycle drives
///   the rhythm and each dot still carries the logo's real sampled colour.
/// - a slow local timer rotates *which* provider is enabled and re-randomises
///   the logo's on-screen position, so every materialisation is a new logo in
///   a new place.
///
/// Reduce Motion → the engine pauses (calm static frame) and the rotation
/// timer is suspended, so the field holds a single quiet logo.
struct ConstellationBackgroundView: View {
    let accent: Color
    var visibility: MobileBackgroundVisibility = .prominent

    /// Seconds a logo holds before the field rotates to the next provider +
    /// position. Mirrors the web canvas's ~9.5s period.
    private static let rotationPeriod: TimeInterval = 9.5

    /// Providers the constellation cycles through — the engine's curated
    /// showcase set (BurnBar surfaces + provider logos), all of which ship
    /// sampled-colour glyph assets.
    private static let providers: [AgentProvider] = SwarmProviderGlyphSelection.allProviders

    @AppStorage("appThemePalette") private var themePalette: AppThemePalette = .system
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var prefsJSON: String = SwarmBackgroundPreferences.defaultJSON
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mobileBackgroundVisibility) private var inheritedVisibility
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var envMonitor = SwarmEnvironmentMonitor.shared
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Index into ``providers`` for the logo currently materialising.
    @State private var providerIndex = Int.random(in: 0..<max(1, ConstellationBackgroundView.providers.count))
    /// Per-cycle pan offset so each logo resolves somewhere new.
    @State private var logoOffset: CGSize = ConstellationBackgroundView.randomOffset()

    var body: some View {
        let effectiveVisibility = visibility.constrained(by: inheritedVisibility)
        let prefs = SwarmBackgroundPreferences.from(jsonString: prefsJSON)
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
            liveCanvas(plan: plan)
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
                colorDriver: nil,
                visibility: effectiveVisibility,
                allowsWebsiteBackground: false
            )
            .ignoresSafeArea()
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
                isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    @ViewBuilder
    private func liveCanvas(plan: SwarmBackgroundRenderPlan) -> some View {
        SwarmCanvasView(
            accent: accent,
            pace: .cinematic,
            particleCount: resolvedParticleCount(scale: plan.particleScale),
            // Ambient only — no data-driven pinning; the engine's own
            // auto-cycle drives the resolve / hold / scatter rhythm and each
            // dot still carries the logo's real sampled colour.
            colorDriver: nil,
            isBatteryThrottled: plan.isBatteryThrottled,
            backdropColors: themePalette.backdropColors,
            colorPalette: themePalette.swarmPalette,
            motionSpeedMultiplier: plan.motionSpeedMultiplierScale,
            isAutoCyclingEnabled: plan.allowsAutoCycling,
            // A single enabled provider → exactly one logo on screen at a time.
            enabledProviderGlyphs: [Self.providers[currentProviderIndex]],
            isAvatarEnabled: false,
            isBrandTextEnabled: false,
            enableSwarmSparkles: plan.allowsSparkles,
            // Only logos cycle — keep the field calm and brand-forward.
            excludeBrandShapesFromSwarm: true,
            maxFrameRate: plan.maxFrameRate,
            rendersAsynchronously: true,
            // Re-place the lone logo somewhere new each materialisation.
            logoOffsets: [logoOffset, .zero, .zero]
        )
        .ignoresSafeArea()
        .overlay(rotationDriver(plan: plan))
    }

    /// Invisible ticker that rotates which provider logo is showing and where,
    /// so each materialisation is a different crest/logo somewhere new. Held
    /// still under Reduce Motion / when auto-cycling is suppressed by power
    /// policy, leaving a single calm logo.
    @ViewBuilder
    private func rotationDriver(plan: SwarmBackgroundRenderPlan) -> some View {
        if !reduceMotion, plan.allowsAutoCycling {
            TimelineView(.periodic(from: .now, by: Self.rotationPeriod)) { context in
                Color.clear
                    .onChange(of: context.date) {
                        advanceToNextLogo()
                    }
            }
            .allowsHitTesting(false)
        }
    }

    private func advanceToNextLogo() {
        guard Self.providers.count > 1 else { return }
        // Step a random distance forward so consecutive logos never repeat and
        // the order feels organic rather than a fixed marching list.
        providerIndex = (providerIndex + Int.random(in: 1..<Self.providers.count)) % Self.providers.count
        logoOffset = Self.randomOffset()
    }

    private var currentProviderIndex: Int {
        guard !Self.providers.isEmpty else { return 0 }
        return providerIndex % Self.providers.count
    }

    private func resolvedParticleCount(scale: Double) -> Int {
        max(96, Int(Double(SwarmCanvasView.adaptiveParticleCount) * scale))
    }

    /// A gentle, screen-relative random pan so the lone logo lands in a fresh
    /// spot each cycle without ever clipping the edges.
    private static func randomOffset() -> CGSize {
        CGSize(
            width: CGFloat.random(in: -150...150),
            height: CGFloat.random(in: -110...170)
        )
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
    ConstellationBackgroundView(accent: .orange)
}
