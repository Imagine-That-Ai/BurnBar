import SwiftUI

/// Ruling Grating — faithful port of imaginethat `glyph/stage/styles/moire/ruling-grating.ts` drawBody.
///
/// The only INK / line idiom in the family: the mark is engraved as a diffraction
/// grating. Every silhouette point becomes a short oriented ink stroke at ruling
/// angle A; a SECOND ruling — the same points re-struck at angle B = A + drift — is
/// drawn over it. Where the two rulings phase-align they thicken and brighten into
/// the classic line-on-line moiré beat-bands (the product of two cosines, sharpened
/// to read as crisp ruled fringes). As `drift` breathes a couple of degrees on a
/// slow sine and a `scroll` term crawls the dark fringes, the hatch ripples like
/// watered silk. A faint FLOOR pass (single ruling at A) keeps every letter inked
/// even where the beat nears zero — bands only modulate, never erase.
///
///   • Per point: floor stroke (angle A) + two crossed beat strokes (A, B). Per-point
///     length jitter + twinkle give the hand-ruled silk shimmer.
///   • DARK → additive `.plusLighter`, ink pushed toward white as the beat strengthens
///     (crossings "glow"); LIGHT → `.normal`, ink darkened so bands read without blowing out.
///   • `reduced` → poised still ruling (drift parked at rest 7°, no scroll, twinkle = 1).
///   • `batteryThrottled` → drop the separate floor pass, fold its ink into the two
///     beat passes (2 oriented strokes/point instead of 3) — the moiré read is preserved.
///
/// Perf: ~3 short strokes × N points is the family's heaviest line load. To hold
/// 60fps we keep per-point geometry (position, jitter, beat α) but BATCH strokes into
/// one `Path` per (alpha-band, colour-bucket) and stroke each bucket once — a few
/// dozen stroke calls/frame instead of thousands, while preserving the beat (band) and
/// per-point colour (bucket). Owns the whole silhouette → suppresses the glyph pass.
public final class RulingGratingSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    /// Alpha quantization buckets per pass: separates strokes so the moiré beat reads
    /// as distinct brightness bands while keeping the stroke-call count bounded.
    private static let bands = 5

    public init() {}

    public var suppressesGlyphs: Bool { true }

    public func paint(_ frame: SwarmSubstrateFrame, into baseCtx: GraphicsContext) -> Bool {
        let dots = frame.dots
        let count = dots.count
        let radius = frame.cloudRadius
        guard count > 0, radius > 0 else { return true }

        let dark = frame.dark
        let reduced = frame.reduced
        let throttled = frame.batteryThrottled
        let t = frame.t
        let cx = frame.cx, cy = frame.cy
        let sizePx = frame.sizePx

        // ── ruling geometry ────────────────────────────────────────────────────
        // Angle A is fixed to the mark; B = A + drift breathes a couple of degrees on
        // a slow sine (no reaction kick available in the substrate frame → 0 held).
        let baseAngle = -22.0 * .pi / 180.0
        let restDrift = 7.0 * .pi / 180.0
        let breath = reduced ? 0 : sin(t * 0.55) * 3.2 * .pi / 180.0
        let drift = restDrift + breath
        let driftedAngle = baseAngle + drift
        let cosA = cos(baseAngle), sinA = sin(baseAngle)
        let cosB = cos(driftedAngle), sinB = sin(driftedAngle)
        // Grating normals (perpendicular to each line direction).
        let nAx = -sinA, nAy = cosA
        let nBx = -sinB, nBy = cosB
        // Carrier spatial frequency: ~5.5 fringe cycles across the cloud; same pitch
        // on both rulings so only the angle differs → pure line-on-line moiré.
        let kA = (TAU * 5.5) / max(40.0, radius * 2.0)
        let kB = kA
        // Band phase scroll so the dark fringes crawl even at a fixed drift.
        let scroll = reduced ? 0 : t * 0.6

        let seg = clampD(sizePx * 2.1, 2.4, 6.0)   // half stroke length (px)
        let baseW = clampD(sizePx * 0.5, 0.7, 1.4)
        // Legibility floor (matches the sibling moiré substrates) so the engraved mark
        // always reads, scaling up as it forms. armBoost is reaction-only → 1 held.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.55 + 0.45

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // ── the moiré beat: product of two crossed cosines, sharpened to bands ───
        @inline(__always) func beat(_ x: Double, _ y: Double) -> Double {
            let lx = x - cx, ly = y - cy
            let pa = (lx * nAx + ly * nAy) * kA + scroll
            let pb = (lx * nBx + ly * nBy) * kB - scroll * 0.8
            var m = 0.5 + 0.5 * cos(pa) * cos(pb)
            m = m * m * (3 - 2 * m)   // sharpen → crisp ruled fringes
            return m
        }
        // Tiny per-point shimmer so the hatch ripples like watered silk.
        @inline(__always) func twinkle(_ x: Double, _ y: Double, _ i: Int) -> Double {
            if reduced { return 1 }
            let s = shash(Double(i) * 1.27 + 0.31)
            return 0.86 + 0.14 * sin(t * 1.4 + s * TAU + x * 0.02 + y * 0.015)
        }

        // Under battery throttle the separate floor pass is dropped; its ink is folded
        // into the two beat passes so legibility holds with 2 strokes/point not 3.
        let foldedFloor = throttled ? 0.16 * form : 0

        // ── floor pass: faint single ruling at A so the mark is always inked ─────
        if !throttled {
            rulePass(into: &ctx, dots: dots, count: count, dark: dark,
                     dirCos: cosA, dirSin: sinA, seg: seg * 0.92, baseW: baseW * 0.82) { _, _, _ in
                0.16 * form
            }
        }

        // ── beat pass A (angle A) and beat pass B (angle B), sharing the beat α ──
        rulePass(into: &ctx, dots: dots, count: count, dark: dark,
                 dirCos: cosA, dirSin: sinA, seg: seg, baseW: baseW) { x, y, i in
            let a = (0.18 + 0.62 * beat(x, y)) * twinkle(x, y, i) * form + foldedFloor
            return clampD(a, 0, 1)
        }
        rulePass(into: &ctx, dots: dots, count: count, dark: dark,
                 dirCos: cosB, dirSin: sinB, seg: seg, baseW: baseW) { x, y, i in
            let a = (0.18 + 0.62 * beat(x, y)) * twinkle(x, y, i) * form + foldedFloor
            return clampD(a, 0, 1)
        }

        return true
    }

    // ── one ruling pass: a short oriented stroke per point, batched by (band, colour)
    // and stroked once per bucket. `dirCos/dirSin` is the LINE direction; strokes are
    // centred on the point with deterministic per-point length jitter.
    private func rulePass(into ctx: inout GraphicsContext,
                          dots: [SwarmSubstrateDot], count: Int, dark: Bool,
                          dirCos: Double, dirSin: Double, seg: Double, baseW: Double,
                          alpha: (Double, Double, Int) -> Double) {
        let nb = Self.bands
        var paths: [Int: Path] = [:]
        var sumA: [Int: Double] = [:]
        var counts: [Int: Int] = [:]

        for i in 0..<count {
            let d = dots[i]
            let x = d.x, y = d.y
            let a = alpha(x, y, i)
            if a < 0.012 { continue }   // skip imperceptible ink

            // Bucket = alpha band (carries the beat) × coarse colour bucket (per-point).
            let band = min(nb - 1, max(0, Int(a * Double(nb))))
            let base = d.rgba
            let qr = min(4, max(0, Int((base.r * 4).rounded())))
            let qg = min(4, max(0, Int((base.g * 4).rounded())))
            let qb = min(4, max(0, Int((base.b * 4).rounded())))
            let key = band * 125 + qr * 25 + qg * 5 + qb

            // Per-point length jitter for a hand-ruled feel (deterministic).
            let j = 0.82 + 0.36 * shash(Double(i) * 0.73 + dirSin * 3.1)
            let half = seg * j
            paths[key, default: Path()].move(to: CGPoint(x: x - dirCos * half, y: y - dirSin * half))
            paths[key, default: Path()].addLine(to: CGPoint(x: x + dirCos * half, y: y + dirSin * half))
            sumA[key, default: 0] += a
            counts[key, default: 0] += 1
        }

        // Stroke each bucket once with its average ink (colour + width + alpha).
        for (key, path) in paths {
            let n = counts[key] ?? 1
            let aAvg = (sumA[key] ?? 0) / Double(n)
            let ck = key % 125
            let base = RGBA(r: Double(ck / 25) / 4.0,
                            g: Double((ck / 5) % 5) / 4.0,
                            b: Double(ck % 5) / 4.0)
            let ink = self.ink(base, dark: dark, a: aAvg)
            // Crossings thicken: widen the stroke where the beat is strong.
            let lw = baseW * (0.85 + 0.9 * aAvg)
            // Source applied α via globalAlpha (dark dimmed to 0.95); vis = 1 here.
            let strokeA = dark ? min(1, aAvg * 0.95) : min(1, aAvg)
            ctx.stroke(path, with: .color(ink.withOpacity(strokeA).color),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
    }

    // Turn the baked per-point colour into legible ink: on dark, push toward white as
    // the beat strengthens (the crossing "glows"); on light, deepen toward ink.
    @inline(__always) private func ink(_ base: RGBA, dark: Bool, a: Double) -> RGBA {
        if dark { return base.toWhite(0.18 + 0.32 * a) }
        return base.darkened(by: 0.45 * a)   // d = lerp(1, 0.55, a) ⇒ darken by 0.45·a
    }
}
