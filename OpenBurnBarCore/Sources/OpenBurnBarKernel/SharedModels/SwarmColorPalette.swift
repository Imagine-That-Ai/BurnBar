import Foundation

/// A high-fidelity, luxury color palette preset for the token ember swarm.
/// Coordinated directly with the selected macOS desktop wallpaper backdrop.
public enum SwarmColorPalette: String, CaseIterable, Codable, Sendable {
    /// Classic warm embers, amber sparks, and blazing orange tones.
    case defaultEmber
    /// An ethereal teal, cyan, and northern lights violet wash.
    case auroraTeal
    /// A premium velvet burgundy, twilight purple, and crimson sunset.
    case sunsetCrimson
    /// A futuristic cybernetic grid with neon violet, magenta, and electric blue.
    case cyberpunkViolet
    /// A quiet morning mist, pine green, sage, and autumn gold.
    case forestMoss
    /// A blazing solar corona, golden plasma, and white-hot solar flare.
    case solarFlare
}
