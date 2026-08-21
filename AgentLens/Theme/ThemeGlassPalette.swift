import OpenBurnBarCore
import SwiftUI

// MARK: - Theme glass palette

/// The per-theme glass identity for the dashboard sidebar rail.
///
/// "Make the left glass match the aesthetic of each theme it lands on": the
/// rail is a real Liquid Glass plate that refracts the live backdrop. The
/// palette now only supplies a rim color; the plate itself stays clear so the
/// sidebar does not become a colored slab.
///
/// Colours are pulled from the shared `DesignSystem.Colors` brand tokens (so
/// they flip coherently with skin + light/dark like everything else); the
/// opacities that keep the tint subtle live in ``SidebarThemeGlass``, not here.
/// `id` is the stable layout key, which keeps the mapping unit-testable without
/// comparing `Color` values.
struct ThemeGlassPalette {
    /// Stable identity (`DashboardLayout.rawValue`) — drives tests and diffing.
    let id: String
    /// The glass body tint. Refracts the backdrop with the theme's cast.
    let tint: Color
    /// Top of the soft wash sampled behind the glass (light-hitting edge).
    let washTop: Color
    /// Bottom of the wash — fades the cast down the rail.
    let washBottom: Color
    /// The specular rim hairline that traces the plate.
    let rim: Color

    /// The signature glass for a dashboard layout. Total over every case so the
    /// rail always has an identity — `DashboardLayout.current`'s default
    /// (`atelier`) carries a neutral frosted rail by default so the sidebar
    /// reads as glass over the live substrate instead of a red brand slab.
    static func glass(for layout: DashboardLayout) -> ThemeGlassPalette {
        let c = DesignSystem.Colors.self
        switch layout {
        case .classic:
            // Ledger: a clean frosted slate, the quiet option for a dense scroll.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.textPrimary,
                washTop: c.textPrimary,
                washBottom: c.whimsy,
                rim: c.textPrimary
            )
        case .aurora:
            // Warm sun-haze over the hero swarm.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.amber,
                washTop: c.ember,
                washBottom: c.amber,
                rim: c.amber
            )
        case .nebula:
            // Violet cosmic gas lit by ember stars.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.whimsy,
                washTop: c.whimsy,
                washBottom: c.ember,
                rim: c.whimsy
            )
        case .constellation:
            // Cool starfield sparkle — the cold side of the violet.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.frost,
                washTop: c.whimsy,
                washBottom: c.frost,
                rim: c.frost
            )
        case .cockpit:
            // Amber HUD instrument glow.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.amber,
                washTop: c.blaze,
                washBottom: c.amber,
                rim: c.blaze
            )
        case .atelier:
            // Canvas: neutral Liquid Glass over the default substrate.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.frost,
                washTop: c.textPrimary,
                washBottom: c.frost,
                rim: c.frost
            )
        case .stream:
            // Stream: success-green running downward, the colour of a live tail.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.success,
                washTop: c.frost,
                washBottom: c.success,
                rim: c.success
            )
        case .atlas:
            // Atlas: ember over blaze — ranked bars read hottest at the top.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.ember,
                washTop: c.blaze,
                washBottom: c.ember,
                rim: c.ember
            )
        }
    }
}

// MARK: - Sidebar glass surface

/// The dashboard sidebar's background plate. In the aurora skin it is a real
/// Liquid Glass plate (macOS 26) that refracts the live backdrop and leans on
/// the active theme via ``ThemeGlassPalette``; on older systems the glass
/// adapter falls back to material. The editorial skin is light-locked
/// and explicitly glass-free, so it renders a crisp paper surface with a
/// hairline instead.
///
/// This rail intentionally avoids theme washes and tints: native clear glass
/// should reveal the live substrate behind the sidebar, not paint over it.
struct SidebarThemeGlass<S: InsettableShape>: View {
    let layout: DashboardLayout
    let skin: AppSkin
    let shape: S

    var body: some View {
        if skin == .editorial {
            // Paper skin: ink-on-paper, no glass — matches app.burnbar.ai.
            shape
                .fill(DesignSystem.Colors.surface)
                .overlay { shape.strokeBorder(DesignSystem.Colors.border, lineWidth: 1) }
        } else {
            let palette = ThemeGlassPalette.glass(for: layout)
            sidebarPlate
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            palette.rim.opacity(0.10),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
        }
    }

    @ViewBuilder
    private var sidebarPlate: some View {
        if #available(macOS 26, *) {
            Color.clear
                .liquidGlassEffect(.clear, in: shape)
        } else {
            shape
                .fill(.ultraThinMaterial)
                .opacity(0.55)
        }
    }
}
