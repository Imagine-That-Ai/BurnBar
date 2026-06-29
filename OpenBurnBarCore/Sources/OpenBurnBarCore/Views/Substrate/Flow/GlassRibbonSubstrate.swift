import SwiftUI

/// Glass Ribbon — ported from imaginethat `glyph/stage/styles/flow/glass-ribbon.ts`.
///
/// The whole point cloud is read as ONE streamline (the cached nearest-neighbour
/// walk, `frame.structure.order`) and extruded into a twisted liquid-glass ribbon.
/// Between consecutive ordered mark points a quad cross-section is laid down whose
/// half-width tracks a deterministic curl-noise wind (fast wind = thin/taut, slow =
/// swollen) and breathes on a slow pulse. Each quad is filled with a cross-band
/// linear gradient — dark glass edge → bright glass body → dark edge — shaded by the
/// facet normal vs a fixed top-left light, then trimmed by a fixed cyan / magenta
/// chromatic-dispersion fringe and pinned by a crisp dark edge stroke. A second pass
/// rakes a blown white specular streak down the band along arc-length.
///
/// Faithful idiom, perf-tuned for ~520–1080 points at 60fps:
///   • body fill is source-over on BOTH stages (solid glass, never blown out);
///   • specular pass is additive (`.plusLighter`) on dark, source-over on light;
///   • `reduced` → a poised STILL frame (frozen twist, one fixed mid-band glint);
///   • `batteryThrottled` → drop the dispersion rails (cheap body + edge + specular);
///   • all motion derives from `frame.t` + per-point position — no wall clock.
public final class GlassRibbonSubstrate: SwarmSubstrate {
    private let sprites = SpriteCache()

    // Preallocated rail vertices (screen px), grown when the cloud grows — zero
    // per-frame heap churn for the hot arrays (mirrors the source Float32 buffers).
    private var mx: [Double] = []   // centreline = the mark point
    private var my: [Double] = []
    private var lx: [Double] = []   // left rail
    private var ly: [Double] = []
    private var rx: [Double] = []   // right rail
    private var ry: [Double] = []
    private var nrm: [Double] = []  // band-normal angle (radians)
    private var brk: [Bool] = []    // segment k→k+1 is a seam (skip)

    public init() {}

    public func paint(_ frame: SwarmSubstrateFrame, into ctx: GraphicsContext) -> Bool {
        let dots = frame.dots
        let count = dots.count
        let radius = frame.cloudRadius
        guard count >= 2, radius > 0 else { return false }

        let dark = frame.dark
        let reduced = frame.reduced
        let battery = frame.batteryThrottled
        let t = frame.t
        let sizePx = frame.sizePx
        let cx = frame.cx, cy = frame.cy

        // NN walk over the cloud — the single stroke the ribbon traces.
        let s = frame.structure.structure(for: dots, k: 6)
        let order = s.order
        let nv = order.count
        guard nv >= 2 else { return false }
        grow(nv)

        // assembly reveal: the band draws in along the order path as the cloud forms.
        let form = reduced ? 1.0 : clampD(frame.settleProgress, 0, 1)
        let reveal = 0.15 + 0.85 * form

        // half-width budget, clamped so glass never bloats across negative space.
        let wMin = max(1.6, sizePx * 0.85)
        let wMax = max(wMin + 0.6, radius * 0.062)

        // resting clocks: twist sampler + travelling specular head (frozen when calm).
        let tt = reduced ? 0.6 : t * 0.42
        let specHead = reduced ? 0.5 : frac(t * 0.075)
        let seamGap = radius * 0.42
        let seamGap2 = seamGap * seamGap

        // ── build rail vertices from the NN walk ──────────────────────────────
        for k in 0..<nv {
            let i = order[k]
            let x = dots[i].x, y = dots[i].y
            mx[k] = x; my[k] = y

            // cloud-normalized sample coords keep the pattern scale-stable.
            let ux = (x - cx) / radius
            let uy = (y - cy) / radius
            let wind = Self.curlAngle(ux * 2.4, uy * 2.4, tt)
            let wind2 = Self.curlAngle(ux * 2.4 + 0.3, uy * 2.4 + 0.3, tt)
            var turn = abs(atan2(sin(wind2 - wind), cos(wind2 - wind)))
            turn = clampD(turn / 1.4, 0, 1)
            let breath = reduced ? 0.5 : 0.5 + 0.5 * sin(t * 0.9 + ux * 3 + uy * 2)
            let hw = (wMin + (wMax - wMin) * (1 - turn) * (0.7 + 0.3 * breath)) * reveal

            let na = wind + .pi / 2
            nrm[k] = na
            let cxn = cos(na) * hw
            let cyn = sin(na) * hw
            lx[k] = x - cxn; ly[k] = y - cyn
            rx[k] = x + cxn; ry[k] = y + cyn

            // seam flag for the segment leaving this vertex (source threshold radius*0.42).
            if k < nv - 1 {
                let ni = order[k + 1]
                let dx = dots[ni].x - x, dy = dots[ni].y - y
                brk[k] = dx * dx + dy * dy > seamGap2
            } else {
                brk[k] = true
            }
        }

        // fixed top-left light for orientation shading.
        let lightA = -Double.pi * 0.72
        // glass body target — near-white blue [235,242,255] in 0…1.
        let bodyWhite = RGBA(r: 235.0 / 255, g: 242.0 / 255, b: 1.0)
        let cyanRail = RGBA(r: 90.0 / 255, g: 220.0 / 255, b: 1.0)
        let magentaRail = RGBA(r: 1.0, g: 120.0 / 255, b: 235.0 / 255)
        let fillAlpha = dark ? 0.92 : 0.96
        let dispBase = dark ? 0.34 : 0.26
        let edgeAlpha = dark ? 0.55 : 0.4
        let dispTime = reduced ? 0.0 : t * 1.3

        // ── PASS 1: faceted glass body + dispersion + dark edge (source-over) ──
        for k in 0..<(nv - 1) {
            if brk[k] { continue }
            let lx0 = lx[k], ly0 = ly[k], rx0 = rx[k], ry0 = ry[k]
            let lx1 = lx[k + 1], ly1 = ly[k + 1], rx1 = rx[k + 1], ry1 = ry[k + 1]

            let col = dots[order[k]].rgba

            // orientation shading: how much this facet faces the light.
            let shade = 0.5 + 0.5 * cos(nrm[k] - lightA)   // 0 away … 1 toward

            // glass tones from the brand point colour.
            let edge = RGBA(r: col.r * 0.22, g: col.g * 0.24, b: col.b * 0.32 + 8.0 / 255)
            let bodyT = 0.32 + 0.45 * shade
            let body = RGBA(r: col.r, g: col.g, b: col.b).mix(with: bodyWhite, amount: bodyT)

            // cross-band gradient: dark edge → glass body → dark edge.
            let edgeC = edge.withOpacity(fillAlpha).color
            let grad = Gradient(stops: [
                .init(color: edgeC, location: 0),
                .init(color: body.withOpacity(fillAlpha).color, location: 0.5),
                .init(color: edgeC, location: 1)
            ])
            var quad = Path()
            quad.move(to: CGPoint(x: lx0, y: ly0))
            quad.addLine(to: CGPoint(x: rx0, y: ry0))
            quad.addLine(to: CGPoint(x: rx1, y: ry1))
            quad.addLine(to: CGPoint(x: lx1, y: ly1))
            quad.closeSubpath()
            ctx.fill(quad, with: .linearGradient(grad,
                                                 startPoint: CGPoint(x: lx0, y: ly0),
                                                 endPoint: CGPoint(x: rx0, y: ry0)))

            // chromatic dispersion: cyan left rail, magenta right rail (extra pass).
            if !battery {
                let disp = 0.5 + 0.5 * sin(nrm[k] - lightA + dispTime)
                let da = dispBase * disp
                var cyanP = Path()
                cyanP.move(to: CGPoint(x: lx0, y: ly0))
                cyanP.addLine(to: CGPoint(x: lx1, y: ly1))
                ctx.stroke(cyanP, with: .color(cyanRail.withOpacity(da).color),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                var magP = Path()
                magP.move(to: CGPoint(x: rx0, y: ry0))
                magP.addLine(to: CGPoint(x: rx1, y: ry1))
                ctx.stroke(magP, with: .color(magentaRail.withOpacity(da).color),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }

            // crisp dark glass edge — pins the silhouette on either canvas.
            var edges = Path()
            edges.move(to: CGPoint(x: lx0, y: ly0))
            edges.addLine(to: CGPoint(x: lx1, y: ly1))
            edges.move(to: CGPoint(x: rx0, y: ry0))
            edges.addLine(to: CGPoint(x: rx1, y: ry1))
            ctx.stroke(edges, with: .color(edge.withOpacity(edgeAlpha).color),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }

        // ── PASS 2: sliding specular streak (additive on dark, soft on light) ──
        var sctx = ctx
        if dark { sctx.blendMode = .plusLighter }
        let winK = Double(max(2, Int((Double(nv) * 0.12).rounded())))
        let headV = specHead * Double(nv)
        let specAlphaBase = dark ? 0.75 : 0.5
        for k in 0..<(nv - 1) {
            if brk[k] { continue }
            // distance of this vertex from the travelling highlight head (wrapped).
            var d = Double(k) - headV
            d -= (d / Double(nv)).rounded() * Double(nv)
            let along = abs(d)
            if along > winK { continue }
            let env = smoothstep(winK, 0, along)         // 1 at head → 0 at edge
            let facing = cos(nrm[k] - lightA)
            let spec = env * (0.45 + 0.55 * clampD(facing, 0, 1))
            if spec <= 0.01 { continue }

            // a thin blown streak offset toward the lit (right) rail.
            let off = 0.42
            let ax = mx[k] + (rx[k] - mx[k]) * off
            let ay = my[k] + (ry[k] - my[k]) * off
            let bx = mx[k + 1] + (rx[k + 1] - mx[k + 1]) * off
            let by = my[k + 1] + (ry[k + 1] - my[k + 1]) * off

            let a = clampD(specAlphaBase * spec, 0, 1)
            let lw = max(0.8, sizePx * 0.5 * (0.5 + spec))
            var sp = Path()
            sp.move(to: CGPoint(x: ax, y: ay))
            sp.addLine(to: CGPoint(x: bx, y: by))
            sctx.stroke(sp, with: .color(.white.opacity(a)),
                        style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        }

        return true
    }

    /// Grow the preallocated rail buffers to hold `n` vertices.
    private func grow(_ n: Int) {
        guard mx.count < n else { return }
        mx = [Double](repeating: 0, count: n)
        my = [Double](repeating: 0, count: n)
        lx = [Double](repeating: 0, count: n)
        ly = [Double](repeating: 0, count: n)
        rx = [Double](repeating: 0, count: n)
        ry = [Double](repeating: 0, count: n)
        nrm = [Double](repeating: 0, count: n)
        brk = [Bool](repeating: false, count: n)
    }

    /// Cheap, smooth, deterministic 2-D value-noise (no allocation, no random) —
    /// the curl-noise wind sampler. Ported verbatim from the source `vnoise`.
    @inline(__always) private static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = floor(x), yi = floor(y)
        let xf = x - xi, yf = y - yi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        func h(_ a: Double, _ b: Double) -> Double {
            let n = sin(a * 127.1 + b * 311.7) * 43758.5453
            return n - floor(n)
        }
        let a = h(xi, yi)
        let b = h(xi + 1, yi)
        let c = h(xi, yi + 1)
        let dd = h(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c - a) + (a - b - c + dd) * u) * v   // ~[0,2]
    }

    /// Curl angle of the value-noise scalar field at (x,y), drifting in time `tt`.
    @inline(__always) private static func curlAngle(_ x: Double, _ y: Double, _ tt: Double) -> Double {
        let e = 0.55
        let nx = vnoise(x + e, y + tt) - vnoise(x - e, y + tt)
        let ny = vnoise(x, y + e + tt) - vnoise(x, y - e + tt)
        return atan2(nx, -ny)
    }
}
