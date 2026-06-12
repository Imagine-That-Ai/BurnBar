import OpenBurnBarCore
import SwiftUI

// MARK: - Easter egg simulation
//
// A stateful, frame-stepped particle simulation — the native sibling of the
// burnbar.ai `#bgFx` FX engine. Where the first version closed-formed each mark
// against `elapsed`, the refined behaviour (spring-to-shape convergence, real
// token collision physics, time-windowed emission + removal) is path-dependent,
// so the simulation now mutates per frame exactly like the website's
// `loop(now, dt)`.
//
// Ownership: `EasterEggEventCanvas` holds one `EasterEggSimulation` per event and
// calls `step(now:dt:)` on every `TimelineView(.animation)` tick, then `draw`s the
// current particle arrays. The `Canvas` closure stays a pure function of the
// simulation's current state, so SwiftUI can still render asynchronously.
//
// Two 5-second takeovers + an independent boundary pop, mirrored verbatim from
// the website spec:
//   * LOGO STORM (dark)       — 96 provider/crest sprites explode as fireworks
//     and periodically converge into typographic shapes ($ :) </> { }) by
//     rasterising glyphs to target points and spring-pulling each sprite to one.
//   * CLOUD TOKEN RAIN (light) — 7 large fluffy procedural clouds drift overhead
//     and rain gold + silver coins with gravity, air drag, restitution, ledge /
//     wall / floor bounces, a settle phase, and an edge-on FLIP coin render.
//   * BOUNDARY POP            — a 10-coin row arcs out from the page edge under
//     REVERSE gravity and falls back, independent of theme and of any takeover.

// MARK: - Tunable constants (mirrors website `#bgFx`)

enum EasterEggFX {
    /// Takeover length for both storm and rain (ms in the website; seconds here).
    static let durationMS: Double = 5000
    static let duration: TimeInterval = durationMS / 1000

    /// The four shapes the storm converges into.
    static let shapes = ["$", ":)", "</>", "{ }"]

    // Storm
    static let sparkCount = 96

    // Rain
    static let cloudCount = 7
    static let gravity: CGFloat = 980
}

// MARK: - Simulation

/// One in-flight easter egg's mutable particle field. Reference type so the
/// `TimelineView` tick can advance it in place; the `Canvas` reads the same
/// arrays it draws from.
@MainActor
final class EasterEggSimulation {
    enum Mode { case idle, storm, rain }

    let kind: EasterEggEvent.Kind
    private(set) var mode: Mode = .idle

    // Canvas geometry (CSS-pixel-equivalent logical points).
    private var sceneWidth: CGFloat = 1
    private var sceneHeight: CGFloat = 1

    // Shared clock baseline (ms since the event started) so phase offsets line up
    // with the website's `fxStart`-relative timeline.
    private var fxStart: Double = 0

    // Storm state
    private var sparks: [Spark] = []
    private var phases: [Phase] = []
    private var phaseI = 0
    private var shapeRotation = 0

    // Rain state
    private var clouds: [Cloud] = []
    private var tokens: [Token] = []
    private var rects: [Ledge] = []
    private var nextEmit: Double = 0

    // Boundary state (coexists with any mode)
    private var edgeCoins: [EdgeCoin] = []

    private let reduceMotion: Bool
    private var rng: SeededGenerator

    /// The last-stepped `now` (ms), stamped each frame so `draw` can compute the
    /// envelope / twinkle / cloud-bob without re-deriving the clock.
    private var lastNow: Double = 0

    init(kind: EasterEggEvent.Kind, reduceMotion: Bool) {
        self.kind = kind
        self.reduceMotion = reduceMotion
        self.rng = SeededGenerator(seed: 0x0BB_EA57E_E66)
    }

    /// Whether the simulation still has work to do (a live takeover or any
    /// boundary coins). Once false, the canvas can stop ticking.
    var isActive: Bool { mode != .idle || !edgeCoins.isEmpty }

    // MARK: Lifecycle

    /// Begin the takeover/boundary for `kind`. `now` is ms (event-relative is fine
    /// since every offset is `fxStart`-relative). `ledges` are the on-screen UI
    /// rects coins bounce off (rain only); pass empty for none.
    func begin(now: Double, size: CGSize, ledges: [Ledge]) {
        sceneWidth = max(size.width, 1)
        sceneHeight = max(size.height, 1)
        lastNow = now
        switch kind {
        case .logoStorm:
            if reduceMotion { return }
            startStorm(now)
        case .cloudTokenRain:
            if reduceMotion { return }
            rects = ledges
            startRain(now)
        case .boundary(let edge):
            if reduceMotion { return }
            boundary(edge, now)
        }
    }

    /// Keep the working geometry current (window resize between frames).
    func updateSize(_ size: CGSize) {
        sceneWidth = max(size.width, 1)
        sceneHeight = max(size.height, 1)
    }

    /// Advance one frame. `now` is ms, `dt` is seconds (already clamped/seeded by
    /// the caller to match the website's `Math.min(0.05, …)`).
    func step(now: Double, dt: Double) {
        lastNow = now
        switch mode {
        case .storm: updateStorm(now: now, dt: dt)
        case .rain: updateRain(now: now, dt: dt)
        case .idle: break
        }
        // Boundary coins advance inside the main loop (not updateRain) so they can
        // coexist with any takeover.
        stepEdgeCoins(dt: dt)
    }

    // MARK: Drawing

    /// Draw the current particle state. Resolve logo + crest symbols for the
    /// storm/cloud crests; tokens and clouds are drawn procedurally.
    func draw(into context: GraphicsContext, resolveLogo: (Int) -> GraphicsContext.ResolvedSymbol?,
              resolveCrest: (Int) -> GraphicsContext.ResolvedSymbol?) {
        switch mode {
        case .storm: drawStorm(context, resolveLogo: resolveLogo)
        case .rain: drawRain(context, resolveCrest: resolveCrest)
        case .idle: break
        }
        for coin in edgeCoins {
            drawToken(context, token: coin.token, alpha: coin.alpha)
        }
    }
}

// MARK: - Particle structs

extension EasterEggSimulation {

    struct Spark {
        var li: Int            // logo index
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var size: CGFloat
        var rot: CGFloat
        var vr: CGFloat
        var tw: Double         // twinkle / sway phase
        var target: CGPoint?   // spring target while converging
    }

    /// A gold/silver coin with edge-on-flip + tumble state (rain + boundary).
    struct Token {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var r: CGFloat
        var gold: Bool
        var flip: Double       // edge-on-flip phase (cos drives width squash)
        var vflip: Double
        var tilt: Double       // in-plane rotation
        var vtilt: Double
        var rest: Int          // settle counter
    }

    struct Cloud {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var vx: CGFloat
        var crest: Int         // crest image index
        var seed: Double       // bob phase
    }

    /// A collision ledge: coins bounce off the top edge of an on-screen UI rect.
    struct Ledge {
        var l: CGFloat
        var r: CGFloat
        var t: CGFloat
    }

    struct Phase {
        var at: Double         // ms (fxStart-relative absolute)
        var fn: () -> Void
    }

    struct EdgeCoin {
        var token: Token
        var g: CGFloat         // (reverse) gravity
        var t: Double          // lifetime seconds
        var alpha: Double
    }
}

// MARK: - DARK LOGO STORM

extension EasterEggSimulation {

    private func pickShape() -> String {
        // Rotate through the 4-element set for variety + determinism.
        let shape = EasterEggFX.shapes[shapeRotation % EasterEggFX.shapes.count]
        shapeRotation += 1
        return shape
    }

    private func startStorm(_ now: Double) {
        mode = .storm
        fxStart = now
        sparks = []
        phaseI = 0
        shapeRotation = Int(rng.next() % UInt64(EasterEggFX.shapes.count))

        let logoCount = max(1, EasterEggAssets.stormLogoNames.count)
        sparks.reserveCapacity(EasterEggFX.sparkCount)
        for _ in 0..<EasterEggFX.sparkCount {
            sparks.append(
                Spark(
                    li: Int(rng.next() % UInt64(logoCount)),
                    x: rng.cg(0, sceneWidth), y: rng.cg(0, sceneHeight),
                    vx: 0, vy: 0,
                    size: rng.cg(22, 48),
                    rot: rng.cg(-0.5, 0.5),
                    vr: rng.cg(-2, 2),
                    tw: rng.d(0, 6.28),
                    target: nil
                )
            )
        }

        // Phase timeline (offsets in ms from fxStart): alternating burst / converge.
        phases = [
            Phase(at: now + 0) { [weak self] in self?.burstAll() },
            Phase(at: now + 1050) { [weak self] in guard let self else { return }; self.toShape(self.pickShape()) },
            Phase(at: now + 2250) { [weak self] in self?.burstAll() },
            Phase(at: now + 3050) { [weak self] in guard let self else { return }; self.toShape(self.pickShape()) },
            Phase(at: now + 4200) { [weak self] in self?.burstAll() }
        ]
    }

    /// Fireworks explosion: each spark radiates outward from a random burst centre.
    private func burstAll() {
        let cx = rng.cg(sceneWidth * 0.2, sceneWidth * 0.8)
        let cy = rng.cg(sceneHeight * 0.2, sceneHeight * 0.62)
        for i in sparks.indices {
            sparks[i].target = nil
            let ang = atan2(sparks[i].y - cy, sparks[i].x - cx) + rng.cg(-0.5, 0.5)
            let sp = rng.cg(140, 460)
            sparks[i].vx = cos(ang) * sp
            sparks[i].vy = sin(ang) * sp - rng.cg(20, 140)  // slight upward bias
            sparks[i].vr = rng.cg(-3, 3)
        }
    }

    /// Convergence: assign each spark a spring target sampled from the glyph raster.
    private func toShape(_ text: String) {
        let pts = EasterEggGlyphSampler.points(for: text)
        guard !pts.isEmpty else { burstAll(); return }

        let n = sparks.count
        var use = pts
        if pts.count > n {
            use = []
            use.reserveCapacity(n)
            let stride = Double(pts.count) / Double(n)
            for i in 0..<n { use.append(pts[Int(Double(i) * stride)]) }
        }

        let cx = sceneWidth * 0.5
        let cy = sceneHeight * 0.42
        let sc = min(sceneWidth, sceneHeight) * 0.62
        let count = use.count
        for j in sparks.indices {
            if j < count {
                let q = use[j % count]
                sparks[j].target = CGPoint(x: cx + q.x * sc, y: cy + q.y * sc)
            } else {
                sparks[j].target = nil  // leftover sparks drift free
            }
        }
    }

    private func updateStorm(now: Double, dt: Double) {
        // Run any due phases.
        while phaseI < phases.count, now >= phases[phaseI].at {
            phases[phaseI].fn()
            phaseI += 1
        }

        let dtC = CGFloat(dt)
        for i in sparks.indices {
            if let target = sparks[i].target {
                // Spring to target (stiffness 150, damping 24).
                let dx = target.x - sparks[i].x
                let dy = target.y - sparks[i].y
                sparks[i].vx += (dx * 150 - sparks[i].vx * 24) * dtC
                sparks[i].vy += (dy * 150 - sparks[i].vy * 24) * dtC
            } else {
                // Free firework: frame-rate-independent half-life decay + gentle sway.
                let decay = CGFloat(pow(0.5, dt))
                sparks[i].vx = sparks[i].vx * decay + CGFloat(sin(now * 0.001 + sparks[i].tw)) * 7 * dtC
                sparks[i].vy = sparks[i].vy * decay + 14 * dtC
            }
            sparks[i].x += sparks[i].vx * dtC
            sparks[i].y += sparks[i].vy * dtC
            sparks[i].rot += sparks[i].vr * dtC
        }

        if now > fxStart + EasterEggFX.durationMS {
            mode = .idle
            sparks = []
        }
    }

    private func drawStorm(_ context: GraphicsContext, resolveLogo: (Int) -> GraphicsContext.ResolvedSymbol?) {
        // Global envelope: 350ms linear fade-in × 650ms linear fade-out.
        let now = currentNow
        let env = clamp01((now - fxStart) / 350) * clamp01((fxStart + EasterEggFX.durationMS - now) / 650)
        guard env > 0 else { return }

        for spark in sparks {
            let a = env * (0.85 + 0.15 * sin(now * 0.012 + spark.tw))
            guard a > 0.01 else { continue }
            guard let symbol = resolveLogo(spark.li) else { continue }
            var mark = context
            mark.opacity = clamp01(a)
            mark.translateBy(x: spark.x, y: spark.y)
            mark.rotate(by: .radians(Double(spark.rot)))
            // Symbols authored at 64pt; scale to the spark's draw size, aspect 1:1.
            let scale = spark.size / 64
            mark.scaleBy(x: scale, y: scale)
            mark.draw(symbol, at: .zero, anchor: .center)
        }
    }

    /// The draw pass needs `now`; the canvas stamps it before drawing.
    fileprivate var currentNow: Double { lastNow }
}

// MARK: - LIGHT CLOUD TOKEN RAIN

extension EasterEggSimulation {

    private func startRain(_ now: Double) {
        mode = .rain
        fxStart = now
        tokens = []
        clouds = []
        nextEmit = now + 150

        let crestCount = max(1, EasterEggAssets.cloudCrestNames.count)
        let nc = EasterEggFX.cloudCount
        clouds.reserveCapacity(nc)
        for i in 0..<nc {
            clouds.append(
                Cloud(
                    x: (CGFloat(i) + 0.5) / CGFloat(nc) * sceneWidth + rng.cg(-30, 30),
                    y: rng.cg(26, 120),
                    w: rng.cg(210, 360),
                    vx: rng.cg(-10, 10),
                    crest: i % crestCount,
                    seed: rng.d(0, 99)
                )
            )
        }
    }

    /// Each cloud drops 2–4 coins beneath itself.
    private func emit() {
        for cl in clouds {
            let n = 2 + Int(rng.next() % 3)
            for _ in 0..<n {
                let gold = rng.next() % 2 == 0
                tokens.append(
                    Token(
                        x: cl.x + rng.cg(-cl.w * 0.42, cl.w * 0.42),
                        y: cl.y + cl.w * 0.18,
                        vx: rng.cg(-40, 40),
                        vy: rng.cg(20, 90),
                        r: rng.cg(5, 11),
                        gold: gold,
                        flip: rng.d(0, 6.28),
                        vflip: rng.d(5, 11) * (rng.next() % 2 == 0 ? 1 : -1),
                        tilt: rng.d(0, 6.28),
                        vtilt: rng.d(-3, 3),
                        rest: 0
                    )
                )
            }
        }
    }

    private func updateRain(now: Double, dt: Double) {
        let dtC = CGFloat(dt)

        // Clouds drift + wrap.
        for i in clouds.indices {
            clouds[i].x += clouds[i].vx * dtC
            if clouds[i].x < -clouds[i].w { clouds[i].x = sceneWidth + clouds[i].w }
            if clouds[i].x > sceneWidth + clouds[i].w { clouds[i].x = -clouds[i].w }
        }

        // Emission window: until +4000ms.
        if now >= nextEmit, now < fxStart + 4000 {
            emit()
            nextEmit = now + rng.d(85, 165)
        }

        let drag = CGFloat(pow(0.55, dt))
        for k in tokens.indices.reversed() {
            // Gravity + air drag.
            tokens[k].vy += EasterEggFX.gravity * dtC
            tokens[k].vx *= drag
            tokens[k].x += tokens[k].vx * dtC
            tokens[k].y += tokens[k].vy * dtC
            tokens[k].flip += tokens[k].vflip * dt
            tokens[k].tilt += tokens[k].vtilt * dt

            let r = tokens[k].r
            // Side walls (restitution 0.5).
            if tokens[k].x < r {
                tokens[k].x = r
                tokens[k].vx = abs(tokens[k].vx) * 0.5
                tokens[k].vflip *= 0.85
            }
            if tokens[k].x > sceneWidth - r {
                tokens[k].x = sceneWidth - r
                tokens[k].vx = -abs(tokens[k].vx) * 0.5
                tokens[k].vflip *= 0.85
            }

            // Ledge collisions: bounce off the top band of each UI rect.
            if tokens[k].vy > 0 {
                for rect in rects {
                    if tokens[k].x > rect.l - r, tokens[k].x < rect.r + r,
                       tokens[k].y > rect.t - r, tokens[k].y < rect.t + 12 {
                        tokens[k].y = rect.t - r
                        tokens[k].vy = -tokens[k].vy * 0.5
                        tokens[k].vx += rng.cg(-30, 30)
                        tokens[k].vflip *= 0.85
                    }
                }
            }

            // Floor: bounce (restitution 0.48) or settle.
            if tokens[k].y > sceneHeight - r {
                tokens[k].y = sceneHeight - r
                if abs(tokens[k].vy) > 55 {
                    tokens[k].vy = -abs(tokens[k].vy) * 0.48
                    tokens[k].vx *= 0.7
                    tokens[k].vflip *= 0.7
                } else {
                    tokens[k].vy = 0
                    tokens[k].vx *= 0.82
                    tokens[k].vflip *= 0.86
                    tokens[k].rest += 1
                }
            }

            // Removal.
            if now > fxStart + EasterEggFX.durationMS + 800 || tokens[k].rest > 26 {
                tokens.remove(at: k)
            }
        }

        if now > fxStart + EasterEggFX.durationMS, tokens.isEmpty {
            mode = .idle
            clouds = []
        }
    }

    private func rainFade(now: Double) -> Double {
        // Begins fading at +4300ms, fully gone by FXDUR+700 = 5700ms.
        now > fxStart + 4300
            ? clamp01((fxStart + EasterEggFX.durationMS + 700 - now) / 1000)
            : 1
    }

    private func drawRain(_ context: GraphicsContext, resolveCrest: (Int) -> GraphicsContext.ResolvedSymbol?) {
        let now = currentNow
        // Clouds first (behind the rain).
        for cl in clouds {
            drawCloud(context, cloud: cl, now: now, resolveCrest: resolveCrest)
        }
        let fade = rainFade(now: now)
        for token in tokens {
            drawToken(context, token: token, alpha: fade)
        }
    }
}

// MARK: - BOUNDARY POP

extension EasterEggSimulation {

    /// Spawn a 10-coin row at the page edge that arcs out under REVERSE gravity.
    private func boundary(_ edge: EasterEggEdge, _ now: Double) {
        let y0: CGFloat = edge == .top ? 8 : sceneHeight - 8
        let dir: CGFloat = edge == .top ? 1 : -1
        let n = 10
        for i in 0..<n {
            let token = Token(
                x: (CGFloat(i) + 0.5) / CGFloat(n) * sceneWidth + rng.cg(-14, 14),
                y: y0,
                vx: 0,
                vy: dir * rng.cg(280, 460),
                r: rng.cg(5, 9),
                gold: rng.next() % 2 == 0,
                flip: rng.d(0, 6.28),
                vflip: rng.d(6, 12),
                tilt: rng.d(0, 6.28),
                vtilt: rng.d(-2, 2),
                rest: 0
            )
            edgeCoins.append(EdgeCoin(token: token, g: -dir * 1150, t: 0, alpha: 1))
        }
    }

    private func stepEdgeCoins(dt: Double) {
        let dtC = CGFloat(dt)
        for i in edgeCoins.indices.reversed() {
            edgeCoins[i].t += dt
            edgeCoins[i].token.vy += edgeCoins[i].g * dtC
            edgeCoins[i].token.y += edgeCoins[i].token.vy * dtC
            edgeCoins[i].token.flip += edgeCoins[i].token.vflip * dt
            edgeCoins[i].token.tilt += edgeCoins[i].token.vtilt * dt
            let t = edgeCoins[i].t
            edgeCoins[i].alpha = t > 0.55 ? clamp01((0.95 - t) / 0.4) : 1
            if t > 0.95 {
                edgeCoins.remove(at: i)
            }
        }
    }
}

// MARK: - Procedural drawing (tokens + clouds)

extension EasterEggSimulation {

    /// Edge-on flip coin render: `|cos(flip)|` squashes width to as little as 12%
    /// to simulate a spinning coin reaching edge-on; gold/silver face gradients
    /// with rim + specular, or a thin rim bar when edge-on.
    fileprivate func drawToken(_ context: GraphicsContext, token t: Token, alpha a: Double) {
        guard a > 0 else { return }
        let flip = abs(cos(t.flip))
        var c = context
        c.translateBy(x: t.x, y: t.y)
        c.rotate(by: .radians(t.tilt))
        c.scaleBy(x: CGFloat(max(0.12, flip)), y: 1)
        let rr = t.r
        let alpha = clamp01(a)

        if flip < 0.16 {
            // Edge-on: thin rim bar.
            let rect = CGRect(x: -rr * 0.22, y: -rr, width: rr * 0.44, height: rr * 2)
            let color = t.gold ? Color(hex: "b8860b") : Color(hex: "9aa3ad")
            c.fill(Path(rect), with: .color(color.opacity(alpha)))
            return
        }

        // Face: radial gradient centred up-left.
        let faceGradient: Gradient = t.gold
            ? Gradient(stops: [
                .init(color: Color(hex: "fff6d8"), location: 0),
                .init(color: Color(hex: "fdc42c"), location: 0.45),
                .init(color: Color(hex: "9a6b0a"), location: 1)
            ])
            : Gradient(stops: [
                .init(color: Color(hex: "ffffff"), location: 0),
                .init(color: Color(hex: "e3e9ee"), location: 0.45),
                .init(color: Color(hex: "929aa6"), location: 1)
            ])
        let face = Path(ellipseIn: CGRect(x: -rr, y: -rr, width: rr * 2, height: rr * 2))
        var faceCtx = c
        faceCtx.opacity = alpha
        faceCtx.fill(
            face,
            with: .radialGradient(
                faceGradient,
                center: CGPoint(x: -rr * 0.35, y: -rr * 0.4),
                startRadius: rr * 0.1,
                endRadius: rr
            )
        )

        // Inner ring (rim).
        var ringCtx = c
        ringCtx.opacity = alpha * 0.6
        let ring = Path(ellipseIn: CGRect(x: -rr * 0.82, y: -rr * 0.82, width: rr * 1.64, height: rr * 1.64))
        ringCtx.stroke(
            ring,
            with: .color(t.gold ? Color(hex: "7c5208") : Color(hex: "7d858f")),
            lineWidth: max(1, rr * 0.13)
        )

        // Specular highlight.
        var specCtx = c
        specCtx.opacity = alpha * 0.85
        let spec = Path(ellipseIn: CGRect(x: -rr * 0.32 - rr * 0.22, y: -rr * 0.34 - rr * 0.22,
                                          width: rr * 0.44, height: rr * 0.44))
        specCtx.fill(spec, with: .color(Color(white: 1, opacity: 0.75)))
    }

    /// One fluffy cloud = 4 overlapping puffs + a base rect, with a shadow, a
    /// vertical body gradient, a highlight crest, and a crest image on top.
    fileprivate func drawCloud(_ context: GraphicsContext, cloud cl: Cloud, now: Double,
                               resolveCrest: (Int) -> GraphicsContext.ResolvedSymbol?) {
        let x = cl.x
        let y = cl.y + CGFloat(sin(now * 0.0008 + cl.seed)) * 4
        let w = cl.w
        let h = w * 0.46

        // 1. Shadow under the cloud.
        context.fill(
            puffPath(x: x, y: y + h * 0.3, w: w * 0.9, h: h * 0.7),
            with: .color(Color(red: 44 / 255, green: 48 / 255, blue: 56 / 255).opacity(0.10))
        )

        // 2. Body — vertical gradient.
        let body = Gradient(stops: [
            .init(color: Color(red: 216 / 255, green: 220 / 255, blue: 226 / 255).opacity(0.94), location: 0),
            .init(color: Color(red: 178 / 255, green: 184 / 255, blue: 192 / 255).opacity(0.92), location: 0.55),
            .init(color: Color(red: 150 / 255, green: 156 / 255, blue: 165 / 255).opacity(0.90), location: 1)
        ])
        context.fill(
            puffPath(x: x, y: y, w: w, h: h),
            with: .linearGradient(
                body,
                startPoint: CGPoint(x: x, y: y - h * 0.7),
                endPoint: CGPoint(x: x, y: y + h * 0.7)
            )
        )

        // 3. Highlight crest.
        context.fill(
            puffPath(x: x, y: y - h * 0.2, w: w * 0.66, h: h * 0.5),
            with: .color(Color(white: 1, opacity: 0.34))
        )

        // 4. Crest image perched on top.
        if let symbol = resolveCrest(cl.crest) {
            var crest = context
            crest.opacity = 0.92
            let s = h * 1.05
            // Website draws at (x - s/2, y - s*0.96) top-left; centre is +s/2 in.
            crest.translateBy(x: x, y: y - s * 0.96 + s / 2)
            let scale = s / 64  // crest symbols authored at 64pt
            crest.scaleBy(x: scale, y: scale)
            crest.draw(symbol, at: .zero, anchor: .center)
        }
    }

    /// 4 overlapping circles + a base rect, as one closed path.
    private func puffPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }
        circle(x - w * 0.34, y + h * 0.05, h * 0.50)
        circle(x - w * 0.12, y - h * 0.12, h * 0.64)
        circle(x + w * 0.12, y - h * 0.16, h * 0.68)
        circle(x + w * 0.34, y + h * 0.02, h * 0.54)
        path.addRect(CGRect(x: x - w * 0.46, y: y - 2, width: w * 0.92, height: h * 0.56))
        return path
    }
}

// MARK: - Glyph sampler (rasterise text → target points)

/// Rasterises a glyph string to a white-on-clear bitmap and samples a 7px grid,
/// returning origin-centred normalised points (roughly -0.5…+0.5). Cached per
/// string. Mirrors the website's `samplePoints`. Main-actor isolated because the
/// only caller is the main-actor simulation, which also keeps the shared `cache`
/// concurrency-safe under the Swift 6 language mode.
@MainActor
enum EasterEggGlyphSampler {
    private static var cache: [String: [CGPoint]] = [:]
    private static let dim = 300

    static func points(for text: String) -> [CGPoint] {
        if let cached = cache[text] { return cached }
        let pts = rasterize(text)
        cache[text] = pts
        return pts
    }

    private static func rasterize(_ text: String) -> [CGPoint] {
        #if canImport(AppKit)
        let size = dim
        let bytesPerRow = size * 4
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(
                data: nil,
                width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return [] }

        let nsContext = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let font = NSFont.monospacedSystemFont(ofSize: 170, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        // Centre at (150, 150) like the website's textAlign/textBaseline = center/middle.
        let origin = CGPoint(x: 150 - textSize.width / 2, y: 150 - textSize.height / 2)
        attributed.draw(at: origin)

        NSGraphicsContext.restoreGraphicsState()

        guard let data = cg.data else { return [] }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * size)

        var pts: [CGPoint] = []
        var gy = 0
        while gy < size {
            var gx = 0
            while gx < size {
                let alpha = buffer[(gy * size + gx) * 4 + 3]
                if alpha > 128 {
                    pts.append(CGPoint(x: CGFloat(gx - 150) / 300, y: CGFloat(gy - 150) / 300))
                }
                gx += 7
            }
            gy += 7
        }
        return pts
        #else
        return []
        #endif
    }
}

// MARK: - Helpers

private func clamp01(_ x: Double) -> Double { x < 0 ? 0 : x > 1 ? 1 : x }

/// A tiny deterministic generator so each simulation's randomness is stable
/// across redraws yet varied between summons. SplitMix64.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        state = UInt64(bitPattern: Int64(seed)) ^ 0x9E37_79B9_7F4A_7C15
        if state == 0 { state = 0xDEAD_BEEF_CAFE_F00D }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Double in `[a, b)` — the `rand(a,b)` of the website.
    mutating func d(_ a: Double, _ b: Double) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
        return a + unit * (b - a)
    }

    /// Uniform CGFloat in `[a, b)`.
    mutating func cg(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        CGFloat(d(Double(a), Double(b)))
    }
}
