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

    @AppStorage("appThemePalette") private var themePalette: AppThemePalette = .system
    @AppStorage(SwarmBackgroundPreferences.userDefaultsKey) private var prefsJSON: String = SwarmBackgroundPreferences.defaultJSON
    @StateObject private var envMonitor = SwarmEnvironmentMonitor.shared

    var body: some View {
        let prefs = SwarmBackgroundPreferences.from(jsonString: prefsJSON)

        if prefs.location != .disabled && envMonitor.meetsCondition(prefs.condition) {
            SwarmCanvasView(
                accent: accent,
                pace: .cinematic,
                colorDriver: colorDriver,
                backdropColors: themePalette.backdropColors,
                colorPalette: themePalette.swarmPalette,
                enabledProviderGlyphs: prefs.selectedGlyphs,
                isAvatarEnabled: prefs.isAvatarEnabled,
                isBrandTextEnabled: prefs.isBrandTextEnabled,
                excludeBrandShapesFromSwarm: prefs.excludeBrandShapes
            )
            .ignoresSafeArea()
        } else {
            AuroraBackdrop().ignoresSafeArea()
        }
    }
}

#Preview {
    WebsiteBackgroundView(accent: .orange)
}
