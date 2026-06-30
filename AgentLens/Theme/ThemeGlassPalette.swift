import OpenBurnBarCore
import SwiftUI

// MARK: - Theme glass palette

/// The per-theme glass identity for the dashboard sidebar rail.
///
/// "Make the left glass match the aesthetic of each theme it lands on": the
/// rail is a real Liquid Glass plate that refracts the live backdrop, and this
/// palette leans that glass toward the active ``DashboardLayout``'s signature
/// colour so the rail reads as part of that world instead of fixed chrome.
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
    /// (`atelier`) carries the ember substrate look shown by default.
    static func glass(for layout: DashboardLayout) -> ThemeGlassPalette {
        let c = DesignSystem.Colors.self
        switch layout {
        case .classic:
            // Information-dense neutral: a clean frosted slate, the quiet option.
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
            // The keeper: ember substrate, the default backdrop.
            return ThemeGlassPalette(
                id: layout.rawValue,
                tint: c.ember,
                washTop: c.ember,
                washBottom: c.blaze,
                rim: c.ember
            )
        }
    }
}

// MARK: - Sidebar glass surface

/// The dashboard sidebar's background plate. In the aurora skin it is a real
/// Liquid Glass plate (macOS 26) that refracts the live backdrop and leans on
/// the active theme via ``ThemeGlassPalette``; on older systems the glass
/// adapter falls back to a tinted material. The editorial skin is light-locked
/// and explicitly glass-free, so it renders a crisp paper surface with a
/// hairline instead.
///
/// Sampling order matters: the wash and the glass are *siblings* in a `ZStack`
/// (glass cannot sample its own background), so the later glass child samples
/// the wash plus the window backdrop behind the rail.
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
            ZStack {
                LinearGradient(
                    colors: [
                        palette.washTop.opacity(0.18),
                        .clear,
                        palette.washBottom.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(shape)

                // The glass plate. Sits in front of the wash so it samples it.
                // Tint is present enough to read the theme, light enough to stay
                // glass (the plate still refracts the live backdrop).
                Color.clear
                    .liquidGlassSurface(tint: palette.tint.opacity(0.32), in: shape)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [palette.rim.opacity(0.40), palette.rim.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
    }
}
