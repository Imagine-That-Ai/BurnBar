import SwiftUI
import OpenBurnBarKernel

/// Ruling Grating — premium port of imaginethat `glyph/stage/styles/moire/ruling-grating.ts` drawBody.
///
/// The only INK / line idiom in the family: the mark is engraved as a diffraction
/// grating. Every silhouette point becomes a short oriented ink stroke at ruling
/// angle A; a SECOND ruling — the same points re-struck at angle B = A + drift — is
/// drawn over it. Where the two rulings phase-align they thicken and brighten into
/// the classic line-on-line moiré beat-bands (the product of two crossed cosines,
/// sharpened to read as crisp ruled fringes). As `drift` breathes a couple of
/// degrees on a slow sine and a `scroll` term crawls the dark fringes, the hatch
/// ripples like watered silk and the bright beat-bands glide across the lettering.
///
/// PREMIUM DEPTH (the fix for the flat blind port): the beat is no longer a faint
/// wash — the crossing fringes now read as luminous BANDS OF LIGHT gliding through
/// the hatch:
///   • DARK → three layers of light. (1) a TRUE GAUSSIAN BLOOM: the bright crossing
///     strokes are re-laid fat into a blurred `.plusLighter` layer, tinted toward
///     the iris accent then pushed to white, so the beat-bands actually glow. (2) the
///     saturated body ruling itself, crossings pushed toward white. (3) a hot
///     near-white CORE riding the brightest crossings on top. Soft glow under →
///     saturated body → hot core.
///   • LIGHT → crisp opaque ink (`.normal`), crossings deepened toward ink so the
///     beat-bands read with real contrast and never blow out.
///   • A faint FLOOR ruling keeps every letter inked even where the beat nears zero —
///     bands only modulate, never erase — and the trough alpha floor keeps presence.
///   • `reduced` → poised still ruling (drift parked at rest 7°, no scroll, twinkle = 1)
///     with the same static layered glow.
///   • `batteryThrottled` → drop only the heaviest extra pass (the Gaussian bloom
///     layer); fold the floor ink into the beat passes and keep the body + core so it
///     still reads boldly.
///
/// Perf: ~3 short strokes × N points is the family's heaviest line load. We keep
/// per-point geometry (position, jitter, beat α) but BATCH strokes into one `Path`
/// per (brightness-band, colour-bucket) and stroke each bucket once — a few dozen
/// stroke calls/frame instead of thousands — while preserving the beat (band) and
/// per-point colour (bucket). The bloom layer re-strokes only the bright crossing
/// buckets (a small subset), so glow stays cheap. Owns the whole silhouette →
/// suppresses the glyph pass.
public final class RulingGratingSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    /// Brightness quantization buckets per pass: separates strokes so the moiré beat
    /// reads as distinct luminosity bands while keeping the stroke-call count bounded.
    private static let bands = 6
    /// Colour buckets per channel-cube face (5³ = 125 quantized colours).
    private static let colorBuckets = 125

    public init() {}

    public var suppressesGlyphs: Bool { true }

    // Per-frame stroke accumulators (built once, drawn in layers). Bucketed so the
    // whole field collapses to a few dozen stroke calls while preserving beat + hue.
    private struct Buckets {
        var body: [Int: Path] = [:]
        var bodySumA: [Int: Double] = [:]
        var bodyN: [Int: Int] = [:]
        var bodyColor: [Int: RGBA] = [:]
        var bloom: [Int: Path] = [:]
        var bloomSumS: [Int: Double] = [:]
        var bloomN: [Int: Int] = [:]
        var bloomColor: [Int: RGBA] = [:]
        var core = Path()
        var hasCore = false
    }

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
        let accent = frame.stage.accent
        let accent2 = frame.stage.accent2
        let ink = frame.stage.ink
        let white = RGBA(r: 1, g: 1, b: 1)

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
        // Ruling pitch (line spacing) in ABSOLUTE screen px — never scaled from
        // cloudRadius (that balloons the carrier on a wide sparse field). Drives both
        // the full-field gratings and the per-point carrier frequency identically.
        let pitch = clampD(sizePx * 5.5, 9.0, 15.0)
        // Carrier spatial frequency in px (one cosine cycle per pitch); same pitch on
        // both rulings so only the angle differs → pure line-on-line moiré whose beat
        // wavelength = pitch / sin(drift) spans the whole screen.
        let kA = TAU / pitch
        let kB = kA
        // Band phase scroll so the bright fringes crawl even at a fixed drift.
        let scroll = reduced ? 0 : t * 0.6

        let seg = clampD(sizePx * 2.2, 2.6, 6.4)   // half stroke length (px)
        let baseW = clampD(sizePx * 0.55, 0.8, 1.6)
        // Legibility / presence floor (matches the sibling moiré substrates) so the
        // engraved mark always reads boldly, scaling up as it forms.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1) * 0.5 + 0.5

        // ── sparse-field vs dense-silhouette regime ──────────────────────────────
        // The Atelier backdrop runs a SPARSE free-swarm (isShapeMode == false): a
        // per-point ruling alone is just crossed confetti with no visible beat. So we
        // ALSO lay two continuous ruling families across the WHOLE canvas — their
        // real line-on-line crossing IS the moiré field — feathered to the swarm and
        // brightened locally by the per-point engraving below. As the mark forms we
        // fade the full field out and let the per-point rulings tessellate the
        // silhouette exactly as before (the dense look is preserved untouched).
        var inShapeN = 0
        for d in dots where d.inShape { inShapeN += 1 }
        let shapeFrac = Double(inShapeN) / Double(count)
        let fieldW: Double = frame.isShapeMode ? 0.0
            : 1.0 - clampD((shapeFrac - 0.25) / 0.45, 0, 1)

        var ctx = baseCtx
        ctx.blendMode = dark ? .plusLighter : .normal

        // ── the moiré beat: product of two crossed cosines, sharpened twice into
        // crisp bright bands so the interference reads as luminous fringes (not a wash).
        @inline(__always) func beat(_ x: Double, _ y: Double) -> Double {
            let lx = x - cx, ly = y - cy
            let pa = (lx * nAx + ly * nAy) * kA + scroll
            let pb = (lx * nBx + ly * nBy) * kB - scroll * 0.8
            let m0 = 0.5 + 0.5 * cos(pa) * cos(pb)
            let m1 = m0 * m0 * (3 - 2 * m0)         // first sharpen
            return smoothstep(0.22, 0.96, m1)        // widen + crisp the bright bands
        }
        // Tiny per-point shimmer so the hatch ripples like watered silk.
        @inline(__always) func twinkle(_ x: Double, _ y: Double, _ i: Int) -> Double {
            if reduced { return 1 }
            let s = shash(Double(i) * 1.27 + 0.31)
            return 0.86 + 0.14 * sin(t * 1.4 + s * TAU + x * 0.02 + y * 0.015)
        }

        // Presence: a richer trough floor + a strong crossing amplitude so the bands
        // pop hard against an always-inked field.
        let troughFloor = 0.16
        let beatAmp = 0.80
        // Under battery throttle the separate floor pass is dropped; its ink is folded
        // into the two beat passes so legibility holds with 2 strokes/point not 3.
        let foldedFloor = throttled ? 0.16 * form : 0
        // Bloom + core are dark-only luminous layers; bloom is the heaviest pass.
        let wantBloom = dark && !throttled

        var b = Buckets()

        // ── floor pass: faint single ruling at A so the mark is always inked ─────
        if !throttled {
            collect(into: &b, dots: dots, count: count, dark: dark, wantBloom: false,
                    dirCos: cosA, dirSin: sinA, seg: seg * 0.92) { _, _, _ in
                (clampD(0.16 * form, 0, 1), 0.0)
            }
        }

        // ── beat pass A (angle A) and beat pass B (angle B), sharing the beat α ──
        @inline(__always) func beatAlpha(_ x: Double, _ y: Double, _ i: Int) -> (Double, Double) {
            let mb = beat(x, y)
            let a = (troughFloor + beatAmp * mb) * twinkle(x, y, i) * form + foldedFloor
            return (clampD(a, 0, 1), mb)
        }
        collect(into: &b, dots: dots, count: count, dark: dark, wantBloom: wantBloom,
                dirCos: cosA, dirSin: sinA, seg: seg, alpha: beatAlpha)
        collect(into: &b, dots: dots, count: count, dark: dark, wantBloom: wantBloom,
                dirCos: cosB, dirSin: sinB, seg: seg, alpha: beatAlpha)

        // ── FULL-FIELD MOIRÉ ──────────────────────────────────────────────────────
        // Two continuous ruling families struck edge-to-edge across the canvas. Drawn
        // additively (dark) / subtractively (light), their crossing produces genuine
        // line-on-line moiré beat-bands as a real FIELD — not a per-point sample. A
        // radial `.destinationIn` mask feathers the field into the swarm (intensify
        // where the cloud sits, fade gently to nothing where empty — never a hard
        // rectangle). The per-point engraving above then rides on top and lights the
        // gratings locally, so a denser swarm = a brighter local beat.
        if fieldW > 0.004 {
            let w = Double(frame.size.width), h = Double(frame.size.height)
            if w > 1, h > 1 {
                let ctr = CGPoint(x: w * 0.5, y: h * 0.5)
                // Crawl the fringes by sliding each family along its own normal.
                let shiftA = reduced ? 0 : pitch * frac(scroll / TAU)
                let shiftB = reduced ? 0 : pitch * frac(-scroll * 0.8 / TAU)
                var famA = Path(), famB = Path()
                buildFamily(dirCos: cosA, dirSin: sinA, normalOffset: shiftA,
                            pitch: pitch, w: w, h: h, center: ctr, into: &famA)
                buildFamily(dirCos: cosB, dirSin: sinB, normalOffset: shiftB,
                            pitch: pitch, w: w, h: h, center: ctr, into: &famB)

                // FREE-SWARM = the Atelier full-bleed backdrop. The ruling field is a
                // continuous MATERIAL that must fill the whole canvas edge to edge, so
                // its presence is a BRIGHTNESS FLOOR independent of local particle
                // density. Only the forming/dense transition (shapeFrac climbing) uses
                // the old cloud-centred falloff so the field retreats into the mark.
                let freeSwarm = !frame.isShapeMode
                let halfDiag = hypot(w, h) * 0.5
                @inline(__always) func feather(_ layer: inout GraphicsContext) {
                    var m = layer
                    m.blendMode = .destinationIn
                    if freeSwarm {
                        // No cloud-centred gate — full presence across the interior,
                        // only a soft screen-edge vignette so it never reads as a hard
                        // rectangle. Canvas-centred, density-independent.
                        m.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                               with: .radialGradient(
                                Gradient(stops: [
                                    .init(color: white.color, location: 0.0),
                                    .init(color: white.color, location: 0.80),
                                    .init(color: Color.clear, location: 1.0)]),
                                center: ctr,
                                startRadius: 0, endRadius: halfDiag * 1.12))
                    } else {
                        // Forming/dense: falloff rides the cloud extent so the field
                        // collapses softly into the engraved silhouette.
                        let mInner = max(24.0, radius * 0.18)
                        let mOuter = max(mInner + 64.0, radius * 1.32)
                        m.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                               with: .radialGradient(
                                Gradient(colors: [white.color, Color.clear]),
                                center: CGPoint(x: cx, y: cy),
                                startRadius: mInner, endRadius: mOuter))
                    }
                }

                // Bold px-bounded line width (sizePx-derived, NEVER cloudRadius) and a
                // GENEROUS alpha floor in free-swarm so the two crossed rulings + their
                // moiré beat read boldly edge-to-edge like sibling lattice-facet. The
                // per-point engraving (collected above) then ADDS local brightness on
                // top of this floor — it never gates the field toward zero.
                let lwF = baseW * (freeSwarm ? 1.28 : 1.0) * (dark ? 1.0 : 0.95)
                let floorMul = freeSwarm ? 1.0 : fieldW
                let aF = clampD((dark ? 0.46 : 0.34) * floorMul * form, 0, 1)
                let col1 = dark ? accent : ink
                let col2 = dark ? accent2 : ink

                // GLOW · blurred copy of both families so the bright beat-bands bloom
                // (dark only; the heaviest pass → dropped under battery throttle).
                if dark && !throttled {
                    let bloomR = clampD(pitch * 0.85, 4, 10)
                    var gctx = baseCtx
                    gctx.blendMode = .plusLighter
                    gctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: bloomR))
                        layer.blendMode = .plusLighter
                        let g1 = col1.mix(with: accent, amount: 0.30).toWhite(0.26)
                        let g2 = col2.mix(with: accent, amount: 0.30).toWhite(0.26)
                        layer.stroke(famA, with: .color(g1.withOpacity(aF * 0.72).color),
                                     style: StrokeStyle(lineWidth: lwF * 1.9, lineCap: .round))
                        layer.stroke(famB, with: .color(g2.withOpacity(aF * 0.72).color),
                                     style: StrokeStyle(lineWidth: lwF * 1.9, lineCap: .round))
                        feather(&layer)
                    }
                }

                // BODY · the crisp ruling lines themselves — the moiré field proper.
                var fctx = baseCtx
                fctx.blendMode = dark ? .plusLighter : .normal
                fctx.drawLayer { layer in
                    layer.blendMode = dark ? .plusLighter : .normal
                    layer.stroke(famA, with: .color(col1.withOpacity(aF).color),
                                 style: StrokeStyle(lineWidth: lwF, lineCap: .round))
                    layer.stroke(famB, with: .color(col2.withOpacity(aF).color),
                                 style: StrokeStyle(lineWidth: lwF, lineCap: .round))
                    feather(&layer)
                }
            }
        }

        // ── render the layered light ─────────────────────────────────────────────
        if dark {
            // PASS 1 · TRUE GAUSSIAN BLOOM — the bright crossing strokes re-laid fat
            // into a blurred additive layer so the beat-bands glow. Heaviest pass →
            // the only thing dropped under battery throttle.
            if wantBloom && !b.bloom.isEmpty {
                let bloomR = clampD(seg * 1.6, 5, 12)
                let bloomCtx = ctx
                bloomCtx.drawLayer { layer in
                    layer.addFilter(.blur(radius: bloomR))
                    layer.blendMode = .plusLighter
                    for (key, path) in b.bloom {
                        let lvl = key / Self.colorBuckets
                        let n = b.bloomN[key] ?? 1
                        let sAvg = (b.bloomSumS[key] ?? 0) / Double(n)
                        let base = b.bloomColor[key] ?? accent
                        // luminous glow: tint toward the iris accent, then to white.
                        let glow = base.mix(with: accent, amount: 0.32).toWhite(0.42)
                        let lw = baseW * (2.0 + Double(lvl) * 0.95)
                        layer.stroke(path,
                                     with: .color(glow.withOpacity(clampD(sAvg * 0.85, 0, 0.9)).color),
                                     style: StrokeStyle(lineWidth: lw, lineCap: .round))
                    }
                }
            }

            // PASS 2 · SATURATED BODY — the ruling itself, crossings pushed toward
            // white so the hatch brightens where the rulings phase-align.
            for (key, path) in b.body {
                let n = b.bodyN[key] ?? 1
                let aAvg = (b.bodySumA[key] ?? 0) / Double(n)
                let base = b.bodyColor[key] ?? accent
                let col = base.toWhite(0.18 + 0.42 * aAvg)
                let lw = baseW * (0.85 + 1.1 * aAvg)   // crossings thicken
                ctx.stroke(path, with: .color(col.withOpacity(clampD(aAvg, 0, 1)).color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }

            // PASS 3 · HOT CORE — a crisp near-white thread riding the brightest
            // crossings, tinted a touch toward the accent. The sparkle on top.
            if b.hasCore {
                let coreCol = white.mix(with: accent, amount: 0.16)
                ctx.stroke(b.core, with: .color(coreCol.withOpacity(0.85).color),
                           style: StrokeStyle(lineWidth: baseW * 0.85, lineCap: .round))
            }
        } else {
            // LIGHT · crisp opaque ink — crossings deepen toward ink for real contrast,
            // a touch bolder than the blind port so the beat-bands read clearly.
            for (key, path) in b.body {
                let n = b.bodyN[key] ?? 1
                let aAvg = (b.bodySumA[key] ?? 0) / Double(n)
                let base = b.bodyColor[key] ?? ink
                let col = base.darkened(by: 0.50 * aAvg)
                let lw = baseW * (0.95 + 1.0 * aAvg)
                let strokeA = clampD(0.40 + 0.60 * aAvg, 0, 1)
                ctx.stroke(path, with: .color(col.withOpacity(strokeA).color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
        }

        return true
    }

    // ── build one continuous ruling family spanning the whole canvas ─────────────
    // Lines run along (dirCos,dirSin); they are stepped by `pitch` along the family
    // normal and made long enough (the canvas diagonal) to cross edge-to-edge.
    // `normalOffset` slides the whole family along its normal so the fringes crawl.
    private func buildFamily(dirCos: Double, dirSin: Double, normalOffset: Double,
                             pitch: Double, w: Double, h: Double, center: CGPoint,
                             into path: inout Path) {
        guard pitch > 0.5 else { return }
        let nx = -dirSin, ny = dirCos
        let ox = center.x + nx * normalOffset
        let oy = center.y + ny * normalOffset
        // Max |corner · normal| from centre = how far the family must extend.
        let ext = abs(w * 0.5 * nx) + abs(h * 0.5 * ny) + pitch
        let half = hypot(w, h) * 0.5 + pitch   // half line length (covers diagonal)
        var p = -ext
        while p <= ext {
            let lcx = ox + nx * p, lcy = oy + ny * p
            path.move(to: CGPoint(x: lcx - dirCos * half, y: lcy - dirSin * half))
            path.addLine(to: CGPoint(x: lcx + dirCos * half, y: lcy + dirSin * half))
            p += pitch
        }
    }

    // ── collect one ruling pass into the shared buckets ──────────────────────────
    // Each point → a short oriented stroke centred on it with deterministic length
    // jitter. `dirCos/dirSin` is the LINE direction. Body strokes bucket by
    // (brightness band × colour); bright crossings additionally feed the bloom path
    // (bucketed by glow level × colour) and the hottest feed the single core path.
    private func collect(into b: inout Buckets,
                         dots: [SwarmSubstrateDot], count: Int, dark: Bool, wantBloom: Bool,
                         dirCos: Double, dirSin: Double, seg: Double,
                         alpha: (Double, Double, Int) -> (Double, Double)) {
        let nb = Self.bands
        let cbN = Self.colorBuckets
        for i in 0..<count {
            let d = dots[i]
            let x = d.x, y = d.y
            let (a, mb) = alpha(x, y, i)
            if a < 0.012 { continue }   // skip imperceptible ink

            // Per-point length jitter for a hand-ruled feel (deterministic).
            let j = 0.82 + 0.36 * shash(Double(i) * 0.73 + dirSin * 3.1)
            let half = seg * j
            let p0 = CGPoint(x: x - dirCos * half, y: y - dirSin * half)
            let p1 = CGPoint(x: x + dirCos * half, y: y + dirSin * half)

            let cb = Self.colorBucket(d.rgba)
            let band = min(nb - 1, max(0, Int(a * Double(nb))))
            let key = band * cbN + cb
            b.body[key, default: Path()].move(to: p0)
            b.body[key, default: Path()].addLine(to: p1)
            b.bodySumA[key, default: 0] += a
            b.bodyN[key, default: 0] += 1
            if b.bodyColor[key] == nil { b.bodyColor[key] = d.rgba }

            guard dark, mb > 0 else { continue }
            // Bright crossings bloom: gate on the sharpened beat so only the bands glow.
            let s = smoothstep(0.46, 1.0, mb)
            if wantBloom && s > 0.04 {
                let lvl = min(2, max(0, Int(s * 3)))
                let bkey = lvl * cbN + cb
                b.bloom[bkey, default: Path()].move(to: p0)
                b.bloom[bkey, default: Path()].addLine(to: p1)
                b.bloomSumS[bkey, default: 0] += s
                b.bloomN[bkey, default: 0] += 1
                if b.bloomColor[bkey] == nil { b.bloomColor[bkey] = d.rgba }
            }
            // The hottest crossings get a near-white core.
            if smoothstep(0.78, 1.0, mb) > 0.12 {
                b.core.move(to: p0)
                b.core.addLine(to: p1)
                b.hasCore = true
            }
        }
    }

    /// Quantize an RGBA into one of 5³ = 125 colour buckets for stroke batching.
    @inline(__always) private static func colorBucket(_ c: RGBA) -> Int {
        let qr = min(4, max(0, Int((c.r * 4).rounded())))
        let qg = min(4, max(0, Int((c.g * 4).rounded())))
        let qb = min(4, max(0, Int((c.b * 4).rounded())))
        return qr * 25 + qg * 5 + qb
    }
}
