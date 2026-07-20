import SwiftUI
import OpenBurnBarKernel

/// Silk Streamline — ported from imaginethat `glyph/stage/styles/flow/silk-streamline.ts`.
///
/// The curl-noise wind that orients the Flow world, drawn in INK: the cloud is
/// grouped ONCE per layout into a handful of broad-nib calligraphic streamlines.
/// Each stream is a contiguous run of contour points; it is filled as a single
/// closed ribbon polygon whose two edges are offset from the centreline by a
/// FIXED flat-nib vector `E = (cos(-π/4.4), sin(-π/4.4))`, so apparent weight is
/// the true thick/thin of a calligraphy pen (`w·|sin(θ−α)|`). A slow ~0.18 Hz
/// pressure wave travels head→tail so the thick/thin contrast breathes; a faint
/// nib-wobble keeps the edge perpetually, organically wet.
///
/// Native faithfulness notes:
///  • Grouping uses `frame.structure.order` + `breaks` (the cached NN walk over the
///    contour) chopped into ~clamp(count/26,5,16) ribbons — every point consumed
///    by exactly one stream, lying exactly on the silhouette. This replaces the
///    source's per-rebuild curl-integrate + nearestUnused walk with the engine's
///    precomputed contour order (same look, off the hot loop).
///  • INK is opaque source-over on BOTH stages (`.normal`, globalAlpha 0.96 dark /
///    0.95 light) — it must read on a light canvas, so the body is NEVER additive.
///  • Per-stream LINEAR gradient sampled from the brand colors along arc-length
///    (≤8 stops, pooled-deep vs lifted-luminous by value-noise mood), cached and
///    rebuilt only when the layout/polarity changes — never a gradient per dot.
///  • A faint additive (`.plusLighter`) white wet-head bead rides each stroke's
///    travelling-wave peak — dark + !reduced + !battery only.
///  • Owns the whole silhouette → `suppressesGlyphs = true`.
public final class SilkStreamlineSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()
    public init() {}

    public var suppressesGlyphs: Bool { true }

    // ── fixed flat calligraphy nib ───────────────────────────────────────────
    private static let theta: Double = -.pi / 4.4   // ~ -41° right-handed slant
    private static let ex: Double = cos(-.pi / 4.4)
    private static let ey: Double = sin(-.pi / 4.4)

    // ── one cached calligraphic streamline ───────────────────────────────────
    private struct Stream {
        var idx: [Int]               // global dot indices, head→tail
        var pts: [CGPoint]           // centreline samples
        var pressure: [Double]       // per-vertex base pressure (the hand's swells)
        var arc: [Double]            // 0…1 arc-fraction head→tail
        var seed: Double
        var stops: [Gradient.Stop]   // cached ink gradient head→tail (≤8)
        var glowStops: [Gradient.Stop] // cached luminous bloom gradient (dark)
        var head: CGPoint
        var tail: CGPoint
        var solid: RGBA              // orphan / zero-length fallback ink
    }

    // ── per-layout caches (rebuilt only on signature / polarity change) ──────
    private var streams: [Stream] = []
    private var wob: [Double] = []   // per-dot edge wander seed
    private var sig: Double = .nan
    private var builtDark = false

    // MARK: - Render

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let dots = frame.dots
        let count = dots.count
        guard count > 0, frame.cloudRadius > 0 else { return true }

        // Rebuild the streamline grouping + cached gradients only when the cloud
        // layout (or polarity) changes — never per frame.
        let newSig = Double(count) * 131.0
            + (dots[0].x).rounded() * 0.13
            + (dots[0].y).rounded() * 0.071
            + frame.cloudRadius.rounded() * 1.7
            + frame.cx.rounded() * 0.011
            + frame.cy.rounded() * 0.017
        if newSig != sig || streams.isEmpty || frame.dark != builtDark {
            sig = newSig
            builtDark = frame.dark
            rebuild(frame)
        }
        if streams.isEmpty { return true }

        let reduced = frame.reduced
        let dark = frame.dark
        // Nib width: bounded so the ribbon always reproduces the contour with
        // confident weight. Grows in slightly as the mark forms.
        let nibW = clampD(frame.cloudRadius * 0.09, 3.2, 22)
            * (reduced ? 1 : 0.6 + 0.4 * clampD(frame.settleProgress, 0, 1))
        let wave = reduced ? 0 : frame.t * (TAU * 0.18)   // ~0.18 Hz travelling pressure
        let t = frame.t

        let ex = Self.ex, ey = Self.ey
        let nx = -ey, ny = ex   // perpendicular nib axis (edge wander)

        // ── per-vertex nib geometry (the travelling pressure wave + wet edge) ──
        @inline(__always) func halfAt(_ s: Stream, _ i: Int) -> Double {
            var pr = s.pressure[i]
            if !reduced {
                pr *= 0.78 + 0.34 * (0.5 + 0.5 * sin(wave - s.arc[i] * 5.0 + s.seed * 2.0))
            }
            return 0.5 * nibW * pr
        }
        @inline(__always) func wanderAt(_ s: Stream, _ i: Int) -> Double {
            let base = wob[s.idx[i]] * nibW * 0.5
            if reduced { return base }
            return base + sin(t * 1.3 + Double(i) * 0.7 + s.seed * 3) * nibW * 0.06
        }

        // Build each broad-nib ribbon polygon + its centreline crease ONCE this
        // frame (only a handful of fat paths → cheap to reuse across the bloom,
        // ink, and sheen passes; this is what keeps the layered depth allocation-thin).
        struct Ribbon { let body: Path; let crease: Path; let si: Int }
        var ribbons: [Ribbon] = []
        ribbons.reserveCapacity(streams.count)
        for (si, s) in streams.enumerated() {
            let n = s.pts.count
            guard n >= 2 else { continue }
            var bodyPath = Path()
            var crease = Path()
            // forward edge (centre + E·half) and the wandered centreline crease.
            for i in 0..<n {
                let p = s.pts[i]
                let w = halfAt(s, i), wd = wanderAt(s, i)
                let cx = Double(p.x) + nx * wd, cy = Double(p.y) + ny * wd
                let x = cx + ex * w, y = cy + ey * w
                if i == 0 {
                    bodyPath.move(to: CGPoint(x: x, y: y))
                    crease.move(to: CGPoint(x: cx, y: cy))
                } else {
                    bodyPath.addLine(to: CGPoint(x: x, y: y))
                    crease.addLine(to: CGPoint(x: cx, y: cy))
                }
            }
            // reverse edge (centre − E·half)
            for i in stride(from: n - 1, through: 0, by: -1) {
                let p = s.pts[i]
                let w = halfAt(s, i), wd = wanderAt(s, i)
                bodyPath.addLine(to: CGPoint(x: Double(p.x) - ex * w + nx * wd,
                                             y: Double(p.y) - ey * w + ny * wd))
            }
            bodyPath.closeSubpath()
            ribbons.append(Ribbon(body: bodyPath, crease: crease, si: si))
        }

        @inline(__always) func bodyShading(_ s: Stream) -> GraphicsContext.Shading {
            if s.stops.count >= 2, s.head != s.tail {
                return .linearGradient(Gradient(stops: s.stops), startPoint: s.head, endPoint: s.tail)
            }
            return .color(s.solid.color)
        }
        @inline(__always) func glowShading(_ s: Stream) -> GraphicsContext.Shading {
            if s.glowStops.count >= 2, s.head != s.tail {
                return .linearGradient(Gradient(stops: s.glowStops), startPoint: s.head, endPoint: s.tail)
            }
            return .color(s.solid.toWhite(0.26).color)
        }

        // ── PASS 1 (dark) — TRUE GAUSSIAN BLOOM under the ink: the silk's glow.
        // A single blurred, additive layer of the ribbons lays a luminous,
        // accent-tinged halo beneath the strokes so the field reads instantly and
        // glows. Heaviest extra pass → dropped under battery throttle (ink alone
        // still reads with full presence).
        if dark && !frame.batteryThrottled {
            let blurR = CGFloat(clampD(nibW * 0.95, 3, 15))
            var bloom = ctx
            bloom.opacity = reduced ? 0.44 : 0.52
            bloom.drawLayer { layer in
                layer.addFilter(.blur(radius: blurR))
                layer.blendMode = .plusLighter
                for r in ribbons { layer.fill(r.body, with: glowShading(streams[r.si])) }
            }
        }

        // ── PASS 2 — the INK BODY: opaque single source-over fill per stroke,
        // the saturated mid-layer riding over the soft bloom (reads dark AND light).
        var body = ctx
        body.blendMode = .normal
        body.opacity = dark ? 0.96 : 0.95
        for r in ribbons { body.fill(r.body, with: bodyShading(streams[r.si])) }
        // field-orphaned mark points: a small flat-nib dab so each still reads.
        for s in streams where s.pts.count < 2 {
            let p = s.pts[0]
            let rr = nibW * 0.34
            let rect = CGRect(x: -rr, y: -rr * 0.62, width: rr * 2, height: rr * 1.24)
            let tf = CGAffineTransform(translationX: p.x, y: p.y).rotated(by: CGFloat(Self.theta))
            body.fill(Path(ellipseIn: rect).applying(tf), with: .color(s.solid.color))
        }

        // ── PASS 3 — SATIN SHEEN: a thin luminous crease running the centreline,
        // shimmering on the travelling wave so each silk ribbon catches the light.
        let sheenStyle = StrokeStyle(lineWidth: CGFloat(max(0.6, nibW * 0.16)),
                                     lineCap: .round, lineJoin: .round)
        if dark {
            let sheenInk = RGBA(r: 1, g: 1, b: 1).mix(with: frame.stage.accent2, amount: 0.34)
            var sheen = ctx
            sheen.blendMode = .plusLighter
            for r in ribbons {
                let s = streams[r.si]
                let shimmer = reduced ? 0.5 : 0.5 + 0.5 * sin(wave * 1.3 + s.seed * 2.2)
                let a = 0.07 + 0.10 * shimmer
                sheen.stroke(r.crease, with: .color(sheenInk.withOpacity(clampD(a, 0, 1)).color),
                             style: sheenStyle)
            }
        } else {
            // light canvas: a whisper-soft satin glance (normal blend — never blows out).
            var sheen = ctx
            sheen.blendMode = .normal
            for r in ribbons {
                let s = streams[r.si]
                let shimmer = reduced ? 0.5 : 0.5 + 0.5 * sin(wave * 1.3 + s.seed * 2.2)
                let a = 0.05 + 0.06 * shimmer
                sheen.stroke(r.crease, with: .color(.white.opacity(clampD(a, 0, 1))), style: sheenStyle)
            }
        }

        // ── PASS 4 (dark) — WET-HEAD catchlight: a hot bright bead riding the
        // travelling-wave peak, the perpetually-wet nib tip, with a soft halo.
        if dark && !reduced && !frame.batteryThrottled {
            var hctx = ctx
            hctx.blendMode = .plusLighter
            for s in streams {
                let n = s.pts.count
                guard n >= 2 else { continue }
                var up = (wave + s.seed * 2.0) / 5.0
                up -= floor(up)
                let vi = min(n - 1, max(0, Int((up * Double(n - 1)).rounded())))
                let p = s.pts[vi]
                let pulse = 0.5 + 0.5 * sin(t * 2 + s.seed * 4)
                // soft halo under the hot core for depth.
                let hr = nibW * 0.5
                hctx.fill(Path(ellipseIn: CGRect(x: Double(p.x) - hr, y: Double(p.y) - hr,
                                                 width: hr * 2, height: hr * 2)),
                          with: .color(frame.stage.accent2.withOpacity(clampD(0.05 + 0.05 * pulse, 0, 1)).color))
                // hot white core.
                let r = nibW * 0.26
                let a = 0.12 + 0.07 * pulse
                hctx.fill(Path(ellipseIn: CGRect(x: Double(p.x) - r, y: Double(p.y) - r,
                                                 width: r * 2, height: r * 2)),
                          with: .color(.white.opacity(clampD(a, 0, 1))))
            }
        }

        return true
    }

    // MARK: - Layout: group the cloud into streamlines pinned to the mark

    private func rebuild(_ frame: SwarmSubstrateFrame) {
        let dots = frame.dots
        let count = dots.count
        streams.removeAll(keepingCapacity: true)

        // per-dot wobble seed (coherent value-noise, stable per layout).
        wob = (0..<count).map { Self.vnoise(Double($0) * 0.37, Double($0) * 0.91) - 0.5 }

        guard count > 1 else {
            if count == 1 { streams.append(makeStream([0], dots, 0, frame.dark, frame.stage.accent)) }
            return
        }

        // The engine's cached NN walk over the contour is our streamline spine:
        // chop the single ordered stroke into ~target contiguous ribbons, breaking
        // wherever a segment is too long to connect. Every point consumed once.
        let s = frame.structure.structure(for: dots, k: 6)
        let order = s.order
        let breaks = s.breaks
        let n = order.count
        guard n > 0 else { return }

        let target = Int(clampD((Double(count) / 26.0).rounded(), 5, 16))
        let segLen = max(2, Int((Double(count) / Double(target)).rounded()))

        var current: [Int] = []
        current.reserveCapacity(segLen + 1)
        var seedN = 0
        for k in 0..<n {
            current.append(order[k])
            let atBreak = (k < breaks.count) && breaks[k]
            let isLast = (k == n - 1)
            if isLast || atBreak || current.count >= segLen {
                streams.append(makeStream(current, dots, seedN, frame.dark, frame.stage.accent))
                seedN += 1
                current.removeAll(keepingCapacity: true)
            }
        }
    }

    private func makeStream(_ idx: [Int], _ dots: [SwarmSubstrateDot],
                            _ seedN: Int, _ dark: Bool, _ accent: RGBA) -> Stream {
        let n = idx.count
        let seed = 1 + Double(seedN) * 0.6180339887
        var pts = [CGPoint](repeating: .zero, count: n)
        var pressure = [Double](repeating: 0, count: n)
        var arc = [Double](repeating: 0, count: n)

        var len = 0.0
        for i in 0..<n {
            let d = dots[idx[i]]
            pts[i] = CGPoint(x: d.x, y: d.y)
            if i > 0 {
                len += hypot(Double(pts[i].x - pts[i - 1].x), Double(pts[i].y - pts[i - 1].y))
            }
        }

        var acc = 0.0
        for i in 0..<n {
            if i > 0 {
                acc += hypot(Double(pts[i].x - pts[i - 1].x), Double(pts[i].y - pts[i - 1].y))
            }
            let u = len > 0 ? acc / len : 0
            arc[i] = u
            // base pressure: coherent noise along the stroke → the hand's swells.
            let slow = Self.vnoise(u * 2.0 + seed * 1.7, seed)
            let fast = Self.vnoise(u * 6.3 + seed * 0.9, seed + 5.3)
            var pr = 0.5 + 0.62 * slow + 0.16 * (fast - 0.5)
            // taper the ends to a hairline lift.
            let endK = min(0.16, 2 / Double(max(2, n)))
            let e = min(u, 1 - u) / max(1e-3, endK)
            pr *= 0.18 + 0.82 * smoothstep(0, 1, clampD(e, 0, 1))
            pressure[i] = clampD(pr, 0.16, 1.25)
        }

        let solid = (n > 0 ? dots[idx[0]].rgba : RGBA(r: 0.8, g: 0.93, b: 1)).withOpacity(1)
        let stops = makeStops(idx, dots, pts, seed, dark)
        let glowStops = makeGlowStops(idx, dots, accent)
        return Stream(idx: idx, pts: pts, pressure: pressure, arc: arc, seed: seed,
                      stops: stops, glowStops: glowStops,
                      head: pts.first ?? .zero, tail: pts.last ?? .zero,
                      solid: solid)
    }

    /// Cached ink gradient along the stroke: sample the brand color and pool deep /
    /// lift luminous (noise mood) so it reads as wet calligraphy, not a flat fill.
    private func makeStops(_ idx: [Int], _ dots: [SwarmSubstrateDot], _ pts: [CGPoint],
                           _ seed: Double, _ dark: Bool) -> [Gradient.Stop] {
        let n = idx.count
        guard n >= 2 else { return [] }
        let stopCount = min(8, n)
        var out: [Gradient.Stop] = []
        out.reserveCapacity(stopCount)
        for k in 0..<stopCount {
            let u = stopCount == 1 ? 0 : Double(k) / Double(stopCount - 1)
            let pi = idx[min(n - 1, Int((u * Double(n - 1)).rounded()))]
            let raw = dots[pi].rgba
            let mood = Self.vnoise(u * 3.1 + seed * 1.3, seed)
            let tone: RGBA
            if dark {
                if mood > 0.5 {
                    let deep = RGBA(r: raw.r * 0.5, g: raw.g * 0.5, b: raw.b * 0.52 + 8.0 / 255.0)
                    tone = raw.mix(with: deep, amount: (mood - 0.5) * 1.4)
                } else {
                    tone = raw.toWhite((0.5 - mood) * 0.7)
                }
            } else {
                if mood > 0.5 {
                    let deep = RGBA(r: raw.r * 0.32, g: raw.g * 0.30, b: raw.b * 0.36 + 6.0 / 255.0)
                    tone = raw.mix(with: deep, amount: (mood - 0.5) * 1.5)
                } else {
                    let mid = RGBA(r: raw.r * 0.60, g: raw.g * 0.60, b: raw.b * 0.66 + 10.0 / 255.0)
                    tone = raw.mix(with: mid, amount: (0.5 - mood) * 0.9)
                }
            }
            out.append(Gradient.Stop(color: tone.withOpacity(1).color, location: CGFloat(u)))
        }
        return out
    }

    /// Cached LUMINOUS gradient for the dark bloom layer: lift each brand tone
    /// toward white at the crest and tint it toward the stage accent in the
    /// spread, so the blurred halo glows as accent-tinged silk rather than a
    /// washed-out grey haze. Built once per layout — never per dot per frame.
    private func makeGlowStops(_ idx: [Int], _ dots: [SwarmSubstrateDot],
                               _ accent: RGBA) -> [Gradient.Stop] {
        let n = idx.count
        guard n >= 2 else { return [] }
        let stopCount = min(8, n)
        var out: [Gradient.Stop] = []
        out.reserveCapacity(stopCount)
        for k in 0..<stopCount {
            let u = stopCount == 1 ? 0 : Double(k) / Double(stopCount - 1)
            let pi = idx[min(n - 1, Int((u * Double(n - 1)).rounded()))]
            let raw = dots[pi].rgba
            // saturate the hue, lift toward white, then breathe a little accent in.
            let mood = Self.vnoise(u * 3.1 + 7.0, 2.0)
            let lit = raw.toWhite(0.22 + 0.16 * mood).mix(with: accent, amount: 0.16)
            out.append(Gradient.Stop(color: lit.withOpacity(1).color, location: CGFloat(u)))
        }
        return out
    }

    // MARK: - Self-contained value noise (coherent, deterministic)

    @inline(__always) private static func vhash(_ ix: Int, _ iy: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: ix) &* 374761393 &+ UInt32(truncatingIfNeeded: iy) &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h % 100000) / 100000.0
    }

    @inline(__always) private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - Double(ix), fy = y - Double(iy)
        let ux = fx * fx * (3 - 2 * fx)
        let uy = fy * fy * (3 - 2 * fy)
        let a = vhash(ix, iy), b = vhash(ix + 1, iy)
        let c = vhash(ix, iy + 1), d = vhash(ix + 1, iy + 1)
        return lerp(lerp(a, b, ux), lerp(c, d, ux), uy)
    }
}
