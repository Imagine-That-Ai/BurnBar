import SwiftUI
import CoreGraphics

// MARK: - Substrate integration for the swarm simulation
//
// Threads a pluggable `SwarmSubstrate` into the existing draw loop without
// touching the simulation. The substrate is built once by the host and assigned;
// `draw()` calls `paintSubstrateIfNeeded` at the very top and returns early when
// the substrate fully handles the frame.

extension SwarmSimulation {

    /// Build the per-frame substrate context from the live particle field.
    /// Skips glyph particles (they keep their `Text` path). One `map` per frame
    /// over ~520–1080 dots — measured cheap; called only when a substrate is set.
    func makeSubstrateFrame(size: CGSize, isBatteryThrottled: Bool, uiMode: UIMode) -> SwarmSubstrateFrame {
        let dark = renderScheme == .dark
        let isShapeMode = mode != .swarm

        var dots: [SwarmSubstrateDot] = []
        dots.reserveCapacity(particles.count)
        var sumX = 0.0, sumY = 0.0
        var radii: [Double] = []
        radii.reserveCapacity(particles.count)

        for (index, p) in particles.enumerated() where !p.isGlyph {
            let inShape = (isShapeMode && p.tx != nil)
            let r = max(0.4, p.size * (inShape ? 1.2 : 0.85))
            let rgba = resolvedRGBA(for: p, at: index, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
            dots.append(SwarmSubstrateDot(
                x: p.x, y: p.y, vx: p.vx, vy: p.vy, radius: r, baseSize: p.size,
                rgba: rgba, opacity: p.opacity, inShape: inShape,
                role: p.role, slotIndex: p.slotIndex,
                colorIndex: p.colorIndex, flowProgress: p.flowProgress))
            sumX += p.x; sumY += p.y; radii.append(r)
        }

        let n = max(1, dots.count)
        let cx = sumX / Double(n)
        let cy = sumY / Double(n)
        // Representative cloud radius: mean distance from centroid.
        var distSum = 0.0
        for d in dots { distSum += hypot(d.x - cx, d.y - cy) }
        let cloudRadius = dots.isEmpty ? min(size.width, size.height) * 0.3 : distSum / Double(n)
        let sizePx = radii.isEmpty ? 1.6 : radii.sorted()[radii.count / 2]

        let accentRGBA = RGBA(substrateAccent, fallback: RGBA(r: 0.96, g: 0.31, b: 0.36))
        let stage = SubstrateStage(
            accent: accentRGBA,
            accent2: accentRGBA.toWhite(0.28).mix(with: RGBA(r: 0.55, g: 0.78, b: 1.0), amount: 0.35),
            ink: dark ? RGBA(r: 0.90, g: 0.93, b: 1.0) : RGBA(r: 0.10, g: 0.10, b: 0.14),
            dark: dark)

        let backdrop = substrateBackdrop.map { RGBA($0) }

        // Continuous settle progress (0…1) from the close-fraction heuristic.
        let settle = currentShapeCloseFraction()
        let now = flowTime
        let dt = lastSubstrateT == 0 ? 1.0 : ((now - lastSubstrateT) * 60.0).clamped(to: 0.0...4.0)
        lastSubstrateT = now

        return SwarmSubstrateFrame(
            size: size, dark: dark, reduced: substrateReduceMotion,
            batteryThrottled: isBatteryThrottled, uiMode: uiMode,
            isShapeMode: isShapeMode, formed: shapeSettledAt != nil, settleProgress: settle,
            t: now, dt: dt, stage: stage, backdrop: backdrop, dots: dots,
            cx: cx, cy: cy, cloudRadius: cloudRadius, sizePx: sizePx, structure: substrateStructure)
    }

    /// Continuous 0…1 analog of `currentShapeIsSettled()` — the fraction of
    /// targeted particles within the settle threshold. 1.0 when not in a shape.
    func currentShapeCloseFraction() -> Double {
        guard mode != .swarm else { return 1.0 }
        let baseThreshold = max(22.0, Double(min(bounds.width, bounds.height)) * 0.022)
        let threshold = baseThreshold * motionSpeedMultiplier.clamped(to: 0.5...1.0)
        var targeted = 0, close = 0
        for p in particles {
            guard let tx = p.tx, let ty = p.ty else { continue }
            targeted += 1
            if hypot(tx - p.x, ty - p.y) <= threshold { close += 1 }
        }
        guard targeted > 0 else { return 1.0 }
        return Double(close) / Double(targeted)
    }

    /// Called at the top of `draw()`. Returns true when the substrate fully
    /// painted the field (engine then skips its dot loop; glyphs handled by the
    /// caller per `suppressesGlyphs`).
    func paintSubstrate(into ctx: GraphicsContext, size: CGSize, isBatteryThrottled: Bool, uiMode: UIMode) -> (handled: Bool, suppressesGlyphs: Bool) {
        guard let substrate, !(substrate is PlainDotsSubstrate) else { return (false, false) }
        let frame = makeSubstrateFrame(size: size, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
        let handled = substrate.paint(frame, into: ctx)
        return (handled, handled && substrate.suppressesGlyphs)
    }
}
