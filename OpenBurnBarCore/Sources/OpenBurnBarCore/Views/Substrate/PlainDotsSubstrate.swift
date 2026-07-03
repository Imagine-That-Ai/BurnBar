#if canImport(SwiftUI)
import SwiftUI

/// The shared "Plain · DOTS" substrate — the family default for all six families.
///
/// It deliberately does **nothing** and returns `false`, so the engine's existing
/// dot + twinkle + glyph render runs unchanged. This guarantees pixel-parity with
/// the pre-substrate renderer whenever `plain` is selected (the default), and is
/// also the graceful fallback any unfilled bespoke stub degrades to.
public final class PlainDotsSubstrate: SwarmSubstrate {
    public init() {}
    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool { false }
}

#endif
