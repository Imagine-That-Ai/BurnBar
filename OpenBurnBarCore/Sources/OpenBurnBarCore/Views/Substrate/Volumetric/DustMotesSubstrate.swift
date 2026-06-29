import SwiftUI

/// Dust Motes — "Motes In The Beam", faithful port of imaginethat
/// `glyph/stage/styles/volumetric/dust-motes.ts` `drawBody`.
///
/// The mark rendered as suspended dust drifting in still air, made visible only
/// where one wide diagonal GAUSSIAN BEAM rakes across the cloud. Each point is a
/// tiny soft radial MOTE: a single baked white sprite tinted across a 24-step
/// accent→accent2 altitude ramp (biased 0.12 toward white so motes read
/// sun-caught). A mote's brightness is its dim ambient base PLUS a flare wherever
/// the swept beam volume passes over its projected diagonal axis, so a band of
/// glittering dust drifts through the mark and motes light up in sequence.
///
/// LEGIBLE — ~38% of motes are spring-locked cores that DON'T drift and hold a
/// floored alpha (lifted above the beam falloff) so the silhouette never
/// dissolves outside the current beam. Free dust drifts on a 2-octave value-noise
/// flow field + per-seed Brownian micro-wander, leashed to radius*0.05. At small radii
/// (radius < 70) a hard 0.7px source-over dot per core guarantees the read.
///
/// ALIVE — beamCenter sweeps on sin(t*0.045); a 1.8s breath inhales the beam
/// width; per-mote twinkle on sin(t*1.2+seed); ~10% "lit specks" inside the beam
/// catch a thin additive 4-point cross glint. DARK: soft ink radial backing field
/// (source-over) then motes additive (`.plusLighter`). LIGHT: no ink, lower-alpha
/// cooler motes (`.normal`) reading as caustic light not smear. `reduced` freezes
/// a poised raked still frame (static lit band, no drift); `batteryThrottled`
/// locks drift + drops the cross sparkles. Death hooks (dissolve/melt/armed) are
/// the held-look identity here, so they're omitted. Exact alpha constants ARE the
/// look.
public final class DustMotesSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    private static let hueSteps = 24

    // Altitude ramp bucket colors (accent→accent2, white-biased), rebuilt only on
    // palette change. Sprite tints are opaque; per-mote alpha is applied at draw.
    private var bucket: [RGBA] = []
    private var rampKey: UInt64 = .max

    // Per-point static attributes, rebuilt only on count/geometry change.
    private var attrCount = -1
    private var attrCx = 0.0, attrCy = 0.0, attrR = 0.0
    private var hueIdx: [Int] = []
    private var seedA: [Double] = []
    private var driftA: [Double] = []
    private var dim: [Double] = []
    private var isCore: [Bool] = []
    private var isSpeck: [Bool] = []
    private var bx: [Double] = []

    public init() {}

    /// Deterministic 2-octave value-noise-ish flow field (~[-0.9, 0.9]); smooth,
    /// time-advanced, never strobes (no Date/random). Drifts the free motes.
    @inline(__always) private func fbm(_ x: Double, _ y: Double, _ tz: Double) -> Double {
        var amp = 0.6, freq = 1.0, sum = 0.0
        for o in 0..<2 {
            let nx = x * freq + tz * (0.5 + Double(o) * 0.27)
            let ny = y * freq - tz * 0.31
            sum += amp * sin(nx + 1.7 * cos(ny)) * cos(ny - 1.3 * sin(nx))
            freq *= 2.03; amp *= 0.5
        }
        return sum
    }

    /// (Re)bake the 24-step accent→accent2 altitude ramp on palette change.
    /// Bucket 0 is pure accent; buckets 1…23 mix toward accent2 then bias 0.12
    /// toward white (motes catch sun a touch hot) — matching the source bake.
    private func ensureRamp(_ stage: SubstrateStage) {
        var h = Hasher(); h.combine(stage.accent.bucketKey); h.combine(stage.accent2.bucketKey)
        let key = UInt64(bitPattern: Int64(h.finalize()))
        if key == rampKey && bucket.count == Self.hueSteps { return }
        rampKey = key
        bucket = (0..<Self.hueSteps).map { i in
            if i == 0 { return stage.accent }
            let tt = Double(i) / Double(Self.hueSteps - 1)
            return stage.accent.mix(with: stage.accent2, amount: tt).toWhite(0.12)
        }
    }

    /// (Re)compute per-point altitude hue / seeds / core+speck subsets / beam axis
    /// when the cloud changes. Cheap; never per-frame.
    private func ensureAttrs(_ frame: SwarmSubstrateFrame) {
        let count = frame.dots.count
        if count == attrCount && frame.cx == attrCx && frame.cy == attrCy && frame.cloudRadius == attrR { return }
        attrCount = count; attrCx = frame.cx; attrCy = frame.cy; attrR = frame.cloudRadius
        hueIdx = [Int](repeating: 0, count: count)
        seedA = [Double](repeating: 0, count: count)
        driftA = [Double](repeating: 0, count: count)
        dim = [Double](repeating: 0, count: count)
        isCore = [Bool](repeating: false, count: count)
        isSpeck = [Bool](repeating: false, count: count)
        bx = [Double](repeating: 0, count: count)
        let invR = frame.cloudRadius > 0 ? 1 / frame.cloudRadius : 0
        let steps = Self.hueSteps
        for i in 0..<count {
            let di = Double(i)
            let dx = (frame.dots[i].x - frame.cx) * invR
            let dy = (frame.dots[i].y - frame.cy) * invR
            // altitude hue: bottom (dy>0) cool accent; top (dy<0) warm accent2.
            let tt = clampD(0.5 - dy * 0.5, 0, 1)
            hueIdx[i] = min(steps - 1, max(0, Int(tt * Double(steps - 1) + 0.5)))
            seedA[i] = shash(di * 1.37 + 0.5) * TAU
            driftA[i] = shash(di * 2.71 + 9.1) * TAU
            dim[i] = 0.5 + 0.5 * shash(di * 3.13 + 4.4)   // faint dust varies in mass
            isCore[i] = shash(di * 0.917 + 3.3) < 0.38     // ~38% locked legibility cores
            isSpeck[i] = shash(di * 5.21 + 1.7) < 0.1      // ~10% lit-speck sparkles
            // project onto the ~-38° diagonal beam axis (coherent front, not noise).
            bx[i] = dx * 0.788 + dy * 0.616
        }
    }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let count = frame.dots.count
        guard count > 0 else { return true }
        ensureRamp(frame.stage)
        ensureAttrs(frame)

        let dark = frame.dark
        let reduced = frame.reduced
        let throttle = frame.batteryThrottled
        let sizePx = frame.sizePx
        let t = frame.t
        let radius = frame.cloudRadius, cx = frame.cx, cy = frame.cy
        let invR = radius > 0 ? 1 / radius : 0

        // assembly gate: the dust ignites as the mark forms.
        let env = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        // the sweeping diagonal beam: a wide gaussian band whose center rakes on a
        // slow sin; a 1.8s breath inhales its width.
        let beamCenter = reduced ? -0.12 : sin(t * 0.045) * 0.95
        let widthBreath = reduced ? 0.85 : 0.7 + 0.3 * smoothstep(0, 1, 0.5 + 0.5 * sin(t * (TAU / 1.8)))
        let beamSigma = 0.42 * widthBreath
        let invBeam2 = 1 / (2 * beamSigma * beamSigma)
        let leash = radius * 0.05
        let tFlow = reduced ? 0 : t * 0.06

        // ── dark page: soft centered ink field so additive 'lighter' has somewhere
        // to sum. Light page skips it (motes read as caustic light, not smear).
        if dark {
            var ink = baseCtx
            ink.blendMode = .normal
            let ic = RGBA(r: 7.0 / 255, g: 10.0 / 255, b: 20.0 / 255, a: 1)
            let halo = ink.resolve(sprites.radial(diameter: 128, stops: [
                (0.0, ic.withOpacity(0.55)),
                (0.12, ic.withOpacity(0.55)),
                (0.7, ic.withOpacity(0.2)),
                (1.0, ic.withOpacity(0.0))
            ]))
            let rr = max(radius * 1.8, 1)
            ink.opacity = clampD(0.5 * env, 0, 0.55)
            ink.draw(halo, in: CGRect(x: cx - rr, y: cy - rr, width: rr * 2, height: rr * 2))
        }

        // ── motes: additive on dark, source-over on light. Resolve the 24 tinted
        // mote sprites ONCE per frame (cached by palette), then draw many.
        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal
        let resolved: [GraphicsContext.ResolvedImage] = bucket.map { col in
            ctx.resolve(sprites.radial(diameter: 32, stops: [
                (0.0, col.withOpacity(1.0)),
                (0.3, col.withOpacity(0.5)),
                (0.62, col.withOpacity(0.12)),
                (1.0, col.withOpacity(0.0))
            ]))
        }

        let baseA = dark ? 0.16 : 0.085   // dim ambient dust alpha
        let flareA = dark ? 0.62 : 0.34   // extra alpha when the beam passes over
        let coreFloor = dark ? 0.34 : 0.22 // held-core minimum (above beam falloff)
        let aCap = dark ? 0.9 : 0.55
        let moteD = max(2.4, sizePx * 2.6)
        // drift is the only nontrivial CPU cost; lock it under reduced/throttle.
        let drift = !reduced && !throttle

        // ── PASS 1: the MOTES.
        for i in 0..<count {
            let ox = frame.dots[i].x, oy = frame.dots[i].y
            let core = isCore[i]
            var x = ox, y = oy
            var axis = bx[i]
            if drift && !core {
                let ph = driftA[i]
                let fx = fbm(ox * 0.012, oy * 0.012, tFlow)
                let fy = fbm(ox * 0.012 + 31.7, oy * 0.012 + 11.3, tFlow)
                let wob = 0.4 + 0.6 * sin(t * 0.5 + ph)
                let dxo = (fx + 0.35 * cos(t * 0.23 + ph)) * leash * wob
                let dyo = (fy + 0.35 * sin(t * 0.19 + ph * 1.3)) * leash * wob
                x = ox + dxo; y = oy + dyo
                // drifting shifts where the beam catches it (radius-normalized axis).
                axis += (dxo * 0.788 + dyo * 0.616) * invR
            }

            // gaussian beam intensity for this mote's axis position.
            let d = axis - beamCenter
            let beam = exp(-(d * d) * invBeam2)
            // per-mote twinkle on its own phase.
            let tw = reduced ? 0.6 + 0.4 * sin(seedA[i]) : 0.55 + 0.45 * sin(t * 1.2 + seedA[i])

            var a = baseA * dim[i] * (0.7 + 0.3 * tw) + flareA * beam * (0.6 + 0.4 * tw)
            if core { a = max(a, coreFloor * (0.85 + 0.15 * tw)) }
            a = clampD(a * env, 0, aCap)
            if a <= 0.004 { continue }

            let sz = moteD * (core ? 0.92 : 0.8 + 0.5 * beam)
            let r2 = sz / 2
            var g = ctx
            g.opacity = a
            g.draw(resolved[hueIdx[i]], in: CGRect(x: x - r2, y: y - r2, width: sz, height: sz))

            // sparse "lit specks" inside the beam catch a thin 4-point cross glint.
            if isSpeck[i] && beam > 0.45 && !throttle {
                let gg = clampD((beam - 0.45) / 0.55, 0, 1) * (0.6 + 0.4 * tw)
                let len = sz * (0.7 + 0.9 * gg)
                let sa = clampD((dark ? 0.5 : 0.3) * gg * env, 0, 0.7)
                let aSp = seedA[i] * 0.5
                let c1 = cos(aSp), s1 = sin(aSp)
                var p = Path()
                p.move(to: CGPoint(x: x - c1 * len, y: y - s1 * len))
                p.addLine(to: CGPoint(x: x + c1 * len, y: y + s1 * len))
                p.move(to: CGPoint(x: x + s1 * len, y: y - c1 * len))
                p.addLine(to: CGPoint(x: x - s1 * len, y: y + c1 * len))
                let sc = dark ? RGBA(r: 1, g: 1, b: 1, a: sa)
                              : RGBA(r: frame.dots[i].rgba.r, g: frame.dots[i].rgba.g,
                                     b: frame.dots[i].rgba.b, a: sa)
                ctx.stroke(p, with: .color(sc.color),
                           style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
            }
        }

        // ── PASS 2: small-radius crispening — a hard 0.7px source-over dot on each
        // locked core so the silhouette reads even when the bloom is too soft.
        if radius < 70 {
            var crisp = baseCtx
            crisp.blendMode = .normal
            let ca = clampD((dark ? 0.8 : 0.7) * env, 0, 1)
            for i in 0..<count where isCore[i] {
                let c = frame.dots[i].rgba
                let col = RGBA(r: c.r, g: c.g, b: c.b, a: ca).color
                let x = frame.dots[i].x, y = frame.dots[i].y
                crisp.fill(Path(ellipseIn: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)),
                           with: .color(col))
            }
        }

        return true
    }
}
