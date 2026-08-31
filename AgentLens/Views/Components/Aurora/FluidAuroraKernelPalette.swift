import SwiftUI

// MARK: - The aurora kernel's palette
//
// The consent sheet used to open on a flat `Circle()` behind a `brain.head.profile`
// glyph — a logo asking permission. The brief: a living fluid aurora kernel in
// BurnBar's colours with a cool mint-and-lavender cast, so the permission moment
// reads as the app's own weather, not clip art.
//
// The palette follows `BurnBarKernelMath`'s split: every number the view renders
// is produced by a pure, `Sendable`, view-free value type, so "which colours is
// the kernel showing?" is answerable from one struct and one test file rather
// than by reading a view body. The brand accents come from `DesignSystem.Colors`
// (adaptive, so the kernel follows the system appearance and the Editorial skin
// for free); the mint and lavender stops are house-authored additions declared
// with the same `Color.adaptive` dialect as the rest of the theme.

/// One colour stop of the aurora kernel's ramp.
struct FluidAuroraStop: Equatable, Sendable {
    let id: String
    /// The stop's colour, already resolved for the current appearance.
    let color: Color
    /// Where the stop sits in the ramp, `0…1`.
    let position: Double
}

/// The kernel's full palette: BurnBar brand accents meeting a mint-lavender cool
/// span, plus the rendering knobs that differ between light and dark surfaces.
///
/// The order is the story the kernel tells: **whimsy → mint → lavender → ember**.
/// Whimsy is the house's cool contrast accent; mint and lavender are the "cool
/// mint mixed with lavender" ask; ember is the brand ember arriving last, so the
/// warm brand colour stays the horizon the cool colours drain into rather than a
/// sticker on top.
struct FluidAuroraKernelPalette: Equatable, Sendable {
    var stops: [FluidAuroraStop]

    /// How strongly the luminous ribbons emit on their ground. A wide, soft glow
    /// that reads as *light* on a dark sheet reads as a smudge on a cream one —
    /// the same lesson `PlasmaShade.halo` encodes for the persona orbs, applied
    /// to the whole kernel.
    var emission: Double
    /// How much of the ground survives the composite. Light paper needs more of
    /// its own ground than a dark sheet does.
    var groundVisibility: Double
    /// Extra brightness allowed at the kernel's specular core.
    var coreLift: Double

    /// The palette for a given appearance, modulated for accessibility.
    ///
    /// The stops resolve through `DesignSystem.Colors` (so the kernel inherits
    /// the app's adaptive tokens and the Editorial skin), while `emission` /
    /// `groundVisibility` / `coreLift` modulate against the appearance — the
    /// same dark/light split the usage-field shader re-derives from the page
    /// colour's own luma.
    static func palette(
        colorScheme: ColorScheme,
        reduceTransparency: Bool = false
    ) -> FluidAuroraKernelPalette {
        var palette = FluidAuroraKernelPalette(
            stops: [
                FluidAuroraStop(id: "whimsy", color: DesignSystem.Colors.whimsy, position: 0.00),
                FluidAuroraStop(id: "mint", color: .auroraMint, position: 0.38),
                FluidAuroraStop(id: "lavender", color: .auroraLavender, position: 0.72),
                FluidAuroraStop(id: "ember", color: DesignSystem.Colors.ember, position: 1.00)
            ],
            emission: 0.62,
            groundVisibility: 0.38,
            coreLift: 0.32
        )

        if colorScheme == .light {
            // Cream paper has no headroom above the background for a glow to
            // bloom into, so the ribbons become a pearl watermark: quieter, and
            // carrying more of the paper itself.
            palette.emission *= 0.62
            palette.groundVisibility = max(palette.groundVisibility, 0.68)
            palette.coreLift *= 0.58
        }

        if reduceTransparency {
            // Reduce Transparency's ask is less layering under content, not
            // less colour: the kernel keeps its ramp but sinks into a
            // near-opaque ground so the sheet reads as a printed tint, not a
            // glowing pane.
            palette.groundVisibility = max(palette.groundVisibility, 0.85)
            palette.emission *= 0.7
        }

        return palette
    }
}

// MARK: - The aurora's own colour tokens
//
// Mint and lavender are new stops on the house ramp — not new independent brand
// colours. They are declared with the same `Color.adaptive(light:dark:)` dialect
// as every other accent so they resolve per appearance, and they stay out of the
// provider identity table (`DesignSystem.Colors.primary(for:)`), which keeps
// coming from the brand tokens alone.

extension Color {
    /// Cool mint — the fresh end of the aurora's cool span. Light mode keeps a
    /// sage-forward mint (Botanical Cream's own green undertone); dark mode runs
    /// a brighter seafoam that reads as glowing vapour on charcoal.
    static let auroraMint = Color.adaptive(light: "6FBF9F", dark: "5EE8C0")

    /// Soft lavender — the bridge between whimsy and mint. Light mode keeps a
    /// dusky lavender that sits on paper; dark mode runs the lighter, airier
    /// sibling so the ribbons stay legible against `#0D1117`.
    static let auroraLavender = Color.adaptive(light: "A08BD1", dark: "B9A7E8")
}
