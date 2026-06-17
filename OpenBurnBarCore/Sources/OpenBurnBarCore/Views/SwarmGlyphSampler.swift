import Foundation
import CoreGraphics

// remediation(core-swarm-decomp): relocated verbatim from SwarmCanvasView.swift to
// shrink that 3,926-line god-file. Behavior-preserving move only. The companion
// `extension SwarmSimulation` (normalizedGlyphOutlinePoints) intentionally REMAINS
// in SwarmCanvasView.swift because it relies on same-file access to SwarmSimulation's
// private members (ShapePoint, logoPoints, fallbackLogoPoints, evenlyDownsample).

// MARK: - Glyph Sampler Facade

/// One dot of a provider glyph formation: a normalized position plus the
/// logo's sampled brand color at that spot (nil for synthesized fallbacks).
public struct SwarmGlyphPoint: Sendable {
    public let position: CGPoint
    public let brandColor: RGBA?

    public init(position: CGPoint, brandColor: RGBA?) {
        self.position = position
        self.brandColor = brandColor
    }
}

/// Mini swarm surfaces (e.g. the chat thinking indicator) form the same
/// provider brand glyphs as the backdrop murmuration through this facade.
public enum SwarmGlyphSampler {
    @MainActor private static var cache: [String: [SwarmGlyphPoint]] = [:]

    /// Centered point cloud of the provider's brand glyph, normalized to
    /// roughly [-1, 1] on the longer axis with y growing downward (SwiftUI
    /// Canvas space). Render targets as `center + position * radius`, exactly
    /// like the backdrop's logo formations.
    ///
    /// At thinking-indicator scale a fill-sampled logo collapses into an
    /// unreadable blob, so this prefers the glyph's OUTLINE: from the dense
    /// fill cloud it keeps boundary points (few same-grid neighbors) and only
    /// falls back to the fill when a mark is already stroke-like. Sampling
    /// rasterizes the bundled logo once per provider and caches the result.
    @MainActor
    public static func glyphPoints(for provider: AgentProvider, maxPoints: Int = 120) -> [SwarmGlyphPoint] {
        let key = "\(provider.rawValue)#\(maxPoints)"
        if let cached = cache[key] { return cached }
        let sampled = SwarmSimulation.normalizedGlyphOutlinePoints(for: provider, maxPoints: maxPoints)
        cache[key] = sampled
        return sampled
    }

    /// Solid (filled) version of `glyphPoints(for:)`. Returns the full sampled
    /// brand mark rather than just its outline, so surfaces that render the
    /// glyph large (the launch hero) read it as the actual logo instead of a
    /// hollow ring. Same normalized space and brand colors as the outline
    /// variant; use a higher `maxPoints` so the fill looks solid.
    @MainActor
    public static func filledGlyphPoints(for provider: AgentProvider, maxPoints: Int = 220) -> [SwarmGlyphPoint] {
        let key = "fill:\(provider.rawValue)#\(maxPoints)"
        if let cached = cache[key] { return cached }
        let sampled = SwarmSimulation.normalizedGlyphFillPoints(for: provider, maxPoints: maxPoints)
        cache[key] = sampled
        return sampled
    }

    /// The BurnBar mark (flame + rising bars) from the backdrop's vector
    /// shape, ember-brand-tinted per stroke role. Same normalized space as
    /// `glyphPoints(for:)`.
    @MainActor
    public static func burnBarGlyphPoints(maxPoints: Int = 120) -> [SwarmGlyphPoint] {
        let key = "burnbar#\(maxPoints)"
        if let cached = cache[key] { return cached }
        let all = SwarmLogoShape.generatePoints().map { point -> SwarmGlyphPoint in
            let brand: RGBA
            switch point.role {
            case "logo-flame-outer": brand = RGBA(r: 0.93, g: 0.36, b: 0.16)
            case "logo-flame-inner": brand = RGBA(r: 0.98, g: 0.58, b: 0.20)
            case "logo-flame-spark": brand = RGBA(r: 1.00, g: 0.78, b: 0.36)
            default:                 brand = RGBA(r: 0.96, g: 0.62, b: 0.22) // bars
            }
            return SwarmGlyphPoint(position: point.point, brandColor: brand)
        }
        let sampled: [SwarmGlyphPoint]
        if all.count > maxPoints {
            sampled = (0..<maxPoints).map { index in
                let t = Double(index) / Double(max(maxPoints - 1, 1))
                return all[min(all.count - 1, Int((Double(all.count - 1) * t).rounded()))]
            }
        } else {
            sampled = all
        }
        cache[key] = sampled
        return sampled
    }
}
