import OpenBurnBarCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Easter egg scene
//
// A deterministic, time-driven particle simulation. Built once per event, then
// `draw(into:size:elapsed:)` is a *pure function of elapsed seconds* — the
// `Canvas` closure holds no mutable state, so SwiftUI can render it
// asynchronously and the effect stays smooth at 60fps.
//
// Purity with real physics: rather than store mutable velocities between frames,
// each draw re-integrates the simulation from t=0 using a fixed small step. The
// per-summon RNG seed plus the closed re-step means a given `elapsed` always
// yields the same frame, so async/duplicated Canvas redraws never desync. Events
// are short (<6s) so re-stepping stays cheap.
//
// This mirrors the website's `#bgFx` FX engine spec verbatim so every surface
// feels identical:
//   * Logo storm  (dark)  — a 5s takeover: 96 logo sprites explode as fireworks
//     and periodically CONVERGE into typographic shapes ("$", ":)", "</>", "{ }")
//     by rasterising each glyph to target points and spring-pulling sprites to
//     them, on the spec's burst/converge phase timeline.
//   * Token rain  (light) — large fluffy procedural clouds (layered puffs +
//     gradient + highlight + shadow + a cloud-tier crest) drift overhead and
//     rain gold/silver coins with gravity, air-drag, restitution, ledge/wall/
//     floor bounces, settle, and an EDGE-ON FLIP coin render (horizontal scale
//     to edge + rim/specular highlight).
//   * Boundary pop — a row of 10 coins shoots inward from the hit edge under
//     REVERSE gravity, arcs out, and returns ("you've reached the end").

struct EasterEggScene {
    let kind: EasterEggEvent.Kind
    private let sparks: [Spark]
    private let stormPhases: [StormPhase]
    private let shapeTargets: [String: [CGPoint]]   // normalised glyph points, per shape string
    private let clouds: [Cloud]
    private let coinSeeds: [CoinSeed]
    private let boundaryCoins: [BoundaryCoin]
    private let boundaryEdge: EasterEggEdge?
    private let canvasSize: CGSize

    // MARK: Spec constants (CSS-pixel parity with the website FX engine)

    /// Takeover length for both storm and rain (ms in the spec → seconds here).
    static let takeoverDuration: TimeInterval = 5.0

    // Rain token physics.
    private static let rainGravity: CGFloat = 980          // px / s^2
    private static let rainAirDragPerSec: CGFloat = 0.55   // vx *= pow(0.55, dt)
    private static let floorBounceSpeed: CGFloat = 55      // |vy| above this bounces, else settles
    private static let floorRestitution: CGFloat = 0.48
    private static let wallRestitution: CGFloat = 0.5
    private static let ledgeRestitution: CGFloat = 0.5
    private static let emitWindow: TimeInterval = 4.0      // emission stops at fxStart + 4s
    private static let rainStep: CGFloat = 1.0 / 120.0     // fixed sim step

    // Boundary pop physics.
    private static let boundaryLaunchG: CGFloat = 1150     // reverse gravity magnitude
    private static let boundaryLife: TimeInterval = 0.95

    // MARK: Construction

    static func make(for event: EasterEggEvent, size: CGSize, colorScheme: ColorScheme) -> EasterEggScene {
        // Seed from the event id so a given summon is stable across redraws but
        // each summon still looks fresh.
        var rng = SeededGenerator(seed: event.id.uuidString.hashValue)
        let safeSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))

        switch event.kind {
        case .logoStorm:
            let shapes = ["$", ":)", "</>", "{ }"]
            var targets: [String: [CGPoint]] = [:]
            for shape in shapes { targets[shape] = GlyphSampler.points(for: shape) }
            return EasterEggScene(
                kind: event.kind,
                sparks: buildSparks(size: safeSize, rng: &rng),
                stormPhases: buildStormPhases(shapes: shapes, rng: &rng),
                shapeTargets: targets,
                clouds: [],
                coinSeeds: [],
                boundaryCoins: [],
                boundaryEdge: nil,
                canvasSize: safeSize
            )
        case .cloudTokenRain:
            let clouds = buildClouds(size: safeSize, rng: &rng)
            return EasterEggScene(
                kind: event.kind,
                sparks: [],
                stormPhases: [],
                shapeTargets: [:],
                clouds: clouds,
                coinSeeds: buildCoinSeeds(size: safeSize, clouds: clouds, rng: &rng),
                boundaryCoins: [],
                boundaryEdge: nil,
                canvasSize: safeSize
            )
        case .boundary(let edge):
            return EasterEggScene(
                kind: event.kind,
                sparks: [],
                stormPhases: [],
                shapeTargets: [:],
                clouds: [],
                coinSeeds: [],
                boundaryCoins: buildBoundaryCoins(size: safeSize, edge: edge, rng: &rng),
                boundaryEdge: edge,
                canvasSize: safeSize
            )
        }
    }

    // MARK: Drawing

    func draw(into context: GraphicsContext, size: CGSize, elapsed: TimeInterval, reduceMotion: Bool) {
        switch kind {
        case .logoStorm:
            drawLogoStorm(context, size: size, elapsed: elapsed, reduceMotion: reduceMotion)
        case .cloudTokenRain:
            drawCloudTokenRain(context, size: size, elapsed: elapsed, reduceMotion: reduceMotion)
        case .boundary:
            drawBoundary(context, size: size, elapsed: elapsed, reduceMotion: reduceMotion)
        }
    }
}

// MARK: - DARK LOGO STORM

extension EasterEggScene {

    /// One firework spark carrying a logo sprite. Initial kinematics + per-spark
    /// jitter phases are fixed at build; the per-frame state is re-integrated.
    fileprivate struct Spark {
        let symbolID: EasterEggSymbolID
        let startX: CGFloat
        let startY: CGFloat
        let size: CGFloat        // sprite draw size (px)
        let startRot: Double     // radians
        let startVR: Double      // rad/s
        let tw: Double           // twinkle / sway phase
        /// Per-burst outward kicks, evaluated lazily during the re-step so the
        /// closed integration stays deterministic.
        let burstAngleJitter: Double
        let burstSpeed: CGFloat
        let burstUpBias: CGFloat
        let burstVR: Double
    }

    /// A scheduled phase: at `at` seconds, either explode outward or converge
    /// every spark onto a sampled glyph shape.
    fileprivate struct StormPhase {
        enum Action { case burst(centerX: CGFloat, centerY: CGFloat); case shape(String) }
        let at: TimeInterval
        let action: Action
    }

    private static func buildSparks(size: CGSize, rng: inout SeededGenerator) -> [Spark] {
        let names = EasterEggAssets.stormLogoNames
        guard !names.isEmpty else { return [] }
        let count = 96
        var sparks: [Spark] = []
        sparks.reserveCapacity(count)
        for index in 0..<count {
            let name = names[index % names.count]
            sparks.append(
                Spark(
                    symbolID: .logo(assetName: name),
                    startX: CGFloat(rng.nextDouble(in: 0...Double(size.width))),
                    startY: CGFloat(rng.nextDouble(in: 0...Double(size.height))),
                    size: CGFloat(rng.nextDouble(in: 22...48)),
                    startRot: rng.nextDouble(in: -0.5...0.5),
                    startVR: rng.nextDouble(in: -2...2),
                    tw: rng.nextDouble(in: 0...6.28),
                    burstAngleJitter: rng.nextDouble(in: -0.5...0.5),
                    burstSpeed: CGFloat(rng.nextDouble(in: 140...460)),
                    burstUpBias: CGFloat(rng.nextDouble(in: 20...140)),
                    burstVR: rng.nextDouble(in: -3...3)
                )
            )
        }
        return sparks
    }

    /// The spec's alternating burst / converge timeline (offsets from fxStart):
    /// +0 burst, +1.05 shape, +2.25 burst, +3.05 shape, +4.2 burst. Burst centres
    /// + the two shapes picked from the 4-element set are fixed per summon.
    private static func buildStormPhases(shapes: [String], rng: inout SeededGenerator) -> [StormPhase] {
        func burstCenter() -> (CGFloat, CGFloat) {
            // Centres are stored as normalised fractions and scaled at draw time.
            (CGFloat(rng.nextDouble(in: 0.2...0.8)), CGFloat(rng.nextDouble(in: 0.2...0.62)))
        }
        func pickShape() -> String { shapes[Int(rng.next() % UInt64(shapes.count))] }

        let c0 = burstCenter(); let s1 = pickShape(); let c2 = burstCenter()
        let s3 = pickShape(); let c4 = burstCenter()
        return [
            StormPhase(at: 0.0,  action: .burst(centerX: c0.0, centerY: c0.1)),
            StormPhase(at: 1.05, action: .shape(s1)),
            StormPhase(at: 2.25, action: .burst(centerX: c2.0, centerY: c2.1)),
            StormPhase(at: 3.05, action: .shape(s3)),
            StormPhase(at: 4.2,  action: .burst(centerX: c4.0, centerY: c4.1))
        ]
    }

    private func drawLogoStorm(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) {
        guard !sparks.isEmpty else { return }
        // Reduce Motion: one calm, settled frame — sprites simply rest at their
        // seeded scatter positions, faded in, with no launch/converge/spin.
        if reduceMotion {
            for spark in sparks {
                guard let symbol = context.resolveSymbol(id: spark.symbolID) else { continue }
                var ctx = context
                ctx.opacity = 0.85
                ctx.translateBy(x: spark.startX, y: spark.startY)
                let s = spark.size / 64
                ctx.scaleBy(x: s, y: s)
                ctx.draw(symbol, at: .zero, anchor: .center)
            }
            return
        }

        let env = stormEnvelope(elapsed: elapsed)
        guard env > 0.001 else { return }

        for (index, spark) in sparks.enumerated() {
            let state = simulateSpark(spark, sparkIndex: index, size: size, elapsed: elapsed)
            guard let symbol = context.resolveSymbol(id: spark.symbolID) else { continue }
            let twinkle = 0.85 + 0.15 * sin(elapsed * 0.012 * 1000 + spark.tw)
            var ctx = context
            ctx.opacity = max(0, env * twinkle)
            ctx.translateBy(x: state.x, y: state.y)
            ctx.rotate(by: .radians(state.rot))
            let s = spark.size / 64           // symbols are authored at 64pt
            ctx.scaleBy(x: s, y: s)
            ctx.draw(symbol, at: .zero, anchor: .center)
        }
    }

    /// 350ms linear fade-in × 650ms linear fade-out, multiplied — full only in
    /// the sustain middle. `elapsed` is seconds; the spec uses ms.
    private func stormEnvelope(elapsed: TimeInterval) -> Double {
        let fadeIn = clamp01(elapsed / 0.350)
        let fadeOut = clamp01((Self.takeoverDuration - elapsed) / 0.650)
        return fadeIn * fadeOut
    }

    private struct SparkState { let x: CGFloat; let y: CGFloat; let rot: Double }

    /// Re-integrate one spark from t=0 to `elapsed`, applying each phase's burst
    /// kick / shape target as its scheduled time is crossed. Spring toward target
    /// (stiffness 150, damping 24) when converging; drag + sway when free.
    private func simulateSpark(
        _ spark: Spark,
        sparkIndex: Int,
        size: CGSize,
        elapsed: TimeInterval
    ) -> SparkState {
        var x = spark.startX, y = spark.startY
        var vx: CGFloat = 0, vy: CGFloat = 0
        var rot = spark.startRot, vr = spark.startVR
        var target: CGPoint? = nil

        let step: CGFloat = 1.0 / 120.0
        var simTime: CGFloat = 0
        var remaining = CGFloat(elapsed)
        var nextPhase = 0

        // Apply any phases due at/just after t=0 before the first step.
        func applyDuePhases(upTo t: CGFloat) {
            while nextPhase < stormPhases.count, CGFloat(stormPhases[nextPhase].at) <= t {
                let phase = stormPhases[nextPhase]
                nextPhase += 1
                switch phase.action {
                case let .burst(cxFrac, cyFrac):
                    target = nil
                    let cx = cxFrac * size.width, cy = cyFrac * size.height
                    let ang = atan2(Double(y - cy), Double(x - cx)) + spark.burstAngleJitter
                    vx = CGFloat(cos(ang)) * spark.burstSpeed
                    vy = CGFloat(sin(ang)) * spark.burstSpeed - spark.burstUpBias
                    vr = spark.burstVR
                case let .shape(text):
                    target = shapeTarget(text, for: sparkIndex, size: size)
                }
            }
        }

        applyDuePhases(upTo: 0)
        while remaining > 0 {
            let dt = min(step, remaining)
            remaining -= dt
            simTime += dt
            applyDuePhases(upTo: simTime)

            if let target {
                let dx = target.x - x, dy = target.y - y
                vx += (dx * 150 - vx * 24) * dt
                vy += (dy * 150 - vy * 24) * dt
            } else {
                // Frame-rate-independent ~half-life decay + gentle sway/drift.
                let decay = pow(0.5, dt)
                vx = vx * decay + CGFloat(sin(Double(simTime) + spark.tw)) * 7 * dt
                vy = vy * decay + 14 * dt
            }
            x += vx * dt
            y += vy * dt
            rot += vr * Double(dt)
        }
        return SparkState(x: x, y: y, rot: rot)
    }

    /// The target point this spark converges to for a given shape, or `nil` if
    /// the spark index runs past the sampled point count (those stay free).
    private func shapeTarget(_ text: String, for sparkIndex: Int, size: CGSize) -> CGPoint? {
        guard let pts = shapeTargets[text], !pts.isEmpty else { return nil }
        let n = sparks.count
        // Downsample to exactly N points by stride when oversampled.
        let use: [CGPoint]
        if pts.count > n {
            var down: [CGPoint] = []
            down.reserveCapacity(n)
            let stride = Double(pts.count) / Double(n)
            for i in 0..<n { down.append(pts[Int(Double(i) * stride)]) }
            use = down
        } else {
            use = pts
        }
        guard sparkIndex < use.count else { return nil }
        let cx = size.width * 0.5, cy = size.height * 0.42
        let sc = min(size.width, size.height) * 0.62
        let p = use[sparkIndex % use.count]
        return CGPoint(x: cx + p.x * sc, y: cy + p.y * sc)
    }
}

// MARK: - LIGHT CLOUD TOKEN RAIN

extension EasterEggScene {

    fileprivate struct Cloud {
        let crestID: EasterEggSymbolID
        let startX: CGFloat
        let y: CGFloat
        let width: CGFloat        // large, fluffy
        let vx: CGFloat
        let seed: Double          // bob phase
    }

    /// Deterministic seed for one rain coin. The coin's whole trajectory is
    /// re-integrated each frame from `releaseAt`, so we only store its birth.
    fileprivate struct CoinSeed {
        let metal: TokenMetal
        let cloudIndex: Int
        let releaseAt: TimeInterval
        let offsetX: CGFloat      // spawn x offset under its cloud
        let vx0: CGFloat
        let vy0: CGFloat
        let radius: CGFloat
        let flip0: Double
        let vflip0: Double
        let tilt0: Double
        let vtilt: Double
    }

    private static func buildClouds(size: CGSize, rng: inout SeededGenerator) -> [Cloud] {
        let crests = EasterEggAssets.cloudCrestNames.filter { EasterEggAssets.imageExists($0) }
        let count = 7
        var clouds: [Cloud] = []
        clouds.reserveCapacity(count)
        for index in 0..<count {
            let crestName = crests.isEmpty ? nil : crests[index % crests.count]
            clouds.append(
                Cloud(
                    crestID: crestName.map { .logo(assetName: $0) } ?? .cloud,
                    startX: (CGFloat(index) + 0.5) / CGFloat(count) * size.width
                        + CGFloat(rng.nextDouble(in: -30...30)),
                    y: CGFloat(rng.nextDouble(in: 26...120)),
                    width: CGFloat(rng.nextDouble(in: 210...360)),
                    vx: CGFloat(rng.nextDouble(in: -10...10)),
                    seed: rng.nextDouble(in: 0...99)
                )
            )
        }
        return clouds
    }

    /// Pre-schedule every emission burst across the 0..<4s window so the coin set
    /// is fixed per summon (purity), matching the spec's ~85–165ms cadence with
    /// 2–4 coins per cloud per burst.
    private static func buildCoinSeeds(
        size: CGSize,
        clouds: [Cloud],
        rng: inout SeededGenerator
    ) -> [CoinSeed] {
        guard !clouds.isEmpty else { return [] }
        var coins: [CoinSeed] = []
        var emitAt: TimeInterval = 0.150
        while emitAt < emitWindow {
            for (cloudIndex, cloud) in clouds.enumerated() {
                let n = 2 + Int(rng.next() % 3)   // 2..4
                for _ in 0..<n {
                    let metal: TokenMetal = rng.next() % 2 == 0 ? .gold : .silver
                    coins.append(
                        CoinSeed(
                            metal: metal,
                            cloudIndex: cloudIndex,
                            releaseAt: emitAt,
                            offsetX: CGFloat(rng.nextDouble(in: -0.42...0.42)) * cloud.width,
                            vx0: CGFloat(rng.nextDouble(in: -40...40)),
                            vy0: CGFloat(rng.nextDouble(in: 20...90)),
                            radius: CGFloat(rng.nextDouble(in: 5...11)),
                            flip0: rng.nextDouble(in: 0...6.28),
                            vflip0: rng.nextDouble(in: 5...11) * (rng.next() % 2 == 0 ? 1 : -1),
                            tilt0: rng.nextDouble(in: 0...6.28),
                            vtilt: rng.nextDouble(in: -3...3)
                        )
                    )
                }
            }
            emitAt += rng.nextDouble(in: 0.085...0.165)
        }
        return coins
    }

    private func cloudX(_ cloud: Cloud, elapsed: TimeInterval) -> CGFloat {
        var x = cloud.startX + cloud.vx * CGFloat(elapsed)
        // Horizontal wrap so a cloud that drifts off re-enters from the far side.
        let w = cloud.width
        while x < -w { x += canvasSize.width + 2 * w }
        while x > canvasSize.width + w { x -= canvasSize.width + 2 * w }
        return x
    }

    private func drawCloudTokenRain(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) {
        let drawElapsed = reduceMotion ? 1.0 : elapsed

        // Clouds first (behind their rain), drawn procedurally as fluffy puffs.
        let cloudCount = max(1, clouds.count)
        for (index, cloud) in clouds.enumerated() {
            let x: CGFloat
            if reduceMotion {
                // Calm frame: spread the clouds evenly across the width.
                let frac = (CGFloat(index) + 0.5) / CGFloat(cloudCount)
                x = frac * size.width
            } else {
                x = cloudX(cloud, elapsed: drawElapsed)
            }
            drawCloud(context, cloud: cloud, x: x, elapsed: drawElapsed)
        }

        let rects = ledgeRects(size: size)
        let fade = rainFade(elapsed: elapsed, reduceMotion: reduceMotion)

        if reduceMotion {
            // Calm frame: a few coins resting on the floor under the clouds.
            for (idx, seed) in coinSeeds.enumerated() where idx % 7 == 0 {
                let parent = clouds[min(seed.cloudIndex, clouds.count - 1)]
                let originX = cloudX(parent, elapsed: 1.0) + seed.offsetX
                drawToken(
                    context,
                    metal: seed.metal,
                    at: CGPoint(x: originX, y: size.height - seed.radius - 2),
                    radius: seed.radius,
                    flip: 0, tilt: 0, opacity: fade
                )
            }
            return
        }

        for seed in coinSeeds {
            let fallTime = elapsed - seed.releaseAt
            guard fallTime >= 0 else { continue }
            let parent = clouds[min(seed.cloudIndex, clouds.count - 1)]
            let originX = cloudX(parent, elapsed: seed.releaseAt) + seed.offsetX
            let originY = parent.y + parent.width * 0.18
            let state = simulateRainCoin(seed, originX: originX, originY: originY, time: fallTime, size: size, rects: rects)
            // Removal: settled long enough (rest > 26 steps' worth) or past tail.
            guard !state.removed else { continue }
            drawToken(
                context,
                metal: seed.metal,
                at: state.position,
                radius: seed.radius,
                flip: state.flip,
                tilt: state.tilt,
                opacity: fade
            )
        }
    }

    /// Begins fading at +4.3s, fully gone by +5.7s (FXDUR + 700ms).
    private func rainFade(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        if elapsed <= 4.3 { return 1 }
        return clamp01((Self.takeoverDuration + 0.7 - elapsed) / 1.0)
    }

    /// Collision ledges. In the native re-implementation there is no DOM, so we
    /// supply an empty set (coins still bounce off the four canvas edges); the
    /// hook is here so a host can inject UI rects later for off-element ledges.
    private func ledgeRects(size: CGSize) -> [LedgeRect] { [] }

    fileprivate struct LedgeRect { let l: CGFloat; let r: CGFloat; let t: CGFloat }

    private struct RainCoinState {
        let position: CGPoint
        let flip: Double
        let tilt: Double
        let removed: Bool
    }

    /// Re-integrate one rain coin: gravity, air-drag, side walls, ledge tops,
    /// floor bounce/settle. Closed re-step keeps the draw closure pure.
    private func simulateRainCoin(
        _ seed: CoinSeed,
        originX: CGFloat,
        originY: CGFloat,
        time: TimeInterval,
        size: CGSize,
        rects: [LedgeRect]
    ) -> RainCoinState {
        let r = seed.radius
        var x = originX, y = originY
        var vx = seed.vx0, vy = seed.vy0
        var flip = seed.flip0, tilt = seed.tilt0
        var vflip = seed.vflip0
        var restSteps = 0
        var prng = SeededGenerator(seed: seed.hashSeed)

        let step = Self.rainStep
        var remaining = CGFloat(time)
        while remaining > 0 {
            let dt = min(step, remaining)
            remaining -= dt
            vy += Self.rainGravity * dt
            vx *= pow(Self.rainAirDragPerSec, dt)
            x += vx * dt
            y += vy * dt
            flip += vflip * Double(dt)
            tilt += seed.vtilt * Double(dt)

            // Side walls.
            if x < r { x = r; vx = abs(vx) * Self.wallRestitution; vflip *= 0.85 }
            else if x > size.width - r { x = size.width - r; vx = -abs(vx) * Self.wallRestitution; vflip *= 0.85 }

            // Ledge tops (thin top band, only while falling).
            if vy > 0 {
                for ledge in rects where x > ledge.l - r && x < ledge.r + r && y > ledge.t - r && y < ledge.t + 12 {
                    y = ledge.t - r
                    vy = -vy * Self.ledgeRestitution
                    vx += CGFloat(prng.nextDouble(in: -30...30))
                    vflip *= 0.85
                    break
                }
            }

            // Floor.
            if y > size.height - r {
                y = size.height - r
                if abs(vy) > Self.floorBounceSpeed {
                    vy = -abs(vy) * Self.floorRestitution
                    vx *= 0.7
                    vflip *= 0.7
                } else {
                    vy = 0
                    vx *= 0.82
                    vflip *= 0.86
                    restSteps += 1
                }
            }
        }
        let removed = restSteps > 26
        return RainCoinState(position: CGPoint(x: x, y: y), flip: flip, tilt: tilt, removed: removed)
    }
}

// MARK: - Procedural cloud render (puffPath)

extension EasterEggScene {

    /// Builds the website `puffPath`: 4 overlapping circles + a base rectangle,
    /// as a single filled Path. Origin is the cloud centre.
    private func puffPath(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        circle(x - w * 0.34, y + h * 0.05, h * 0.50)
        circle(x - w * 0.12, y - h * 0.12, h * 0.64)
        circle(x + w * 0.12, y - h * 0.16, h * 0.68)
        circle(x + w * 0.34, y + h * 0.02, h * 0.54)
        path.addRect(CGRect(x: x - w * 0.46, y: y - 2, width: w * 0.92, height: h * 0.56))
        return path
    }

    fileprivate func drawCloud(_ context: GraphicsContext, cloud: Cloud, x: CGFloat, elapsed: TimeInterval) {
        let bob = sin(elapsed * 0.0008 * 1000 + cloud.seed) * 4
        let y = cloud.y + CGFloat(bob)
        let w = cloud.width
        let h = w * 0.46

        // 1. Soft shadow beneath the cloud.
        context.fill(
            puffPath(x: x, y: y + h * 0.3, w: w * 0.9, h: h * 0.7),
            with: .color(Color(red: 44/255, green: 48/255, blue: 56/255).opacity(0.10))
        )
        // 2. Body — vertical gradient.
        let bodyGradient = Gradient(stops: [
            .init(color: Color(red: 216/255, green: 220/255, blue: 226/255).opacity(0.94), location: 0),
            .init(color: Color(red: 178/255, green: 184/255, blue: 192/255).opacity(0.92), location: 0.55),
            .init(color: Color(red: 150/255, green: 156/255, blue: 165/255).opacity(0.90), location: 1)
        ])
        context.fill(
            puffPath(x: x, y: y, w: w, h: h),
            with: .linearGradient(
                bodyGradient,
                startPoint: CGPoint(x: x, y: y - h * 0.7),
                endPoint: CGPoint(x: x, y: y + h * 0.7)
            )
        )
        // 3. Highlight crest.
        context.fill(
            puffPath(x: x, y: y - h * 0.2, w: w * 0.66, h: h * 0.5),
            with: .color(Color.white.opacity(0.34))
        )
        // 4. Cloud-tier crest image perched on top.
        if let crestSymbol = context.resolveSymbol(id: cloud.crestID), case .logo = cloud.crestID {
            let s = h * 1.05
            var ctx = context
            ctx.opacity = 0.92
            ctx.translateBy(x: x, y: y - s * 0.46)   // perched above the cloud
            let scale = s / 64                        // crest symbols authored at 64pt
            ctx.scaleBy(x: scale, y: scale)
            ctx.draw(crestSymbol, at: .zero, anchor: .center)
        }
    }
}

// MARK: - Procedural token render (edge-on flip)

extension EasterEggScene {

    /// Draws a coin with the spec's edge-on-flip illusion: `|cos(flip)|` drives a
    /// horizontal squash to as little as 12% width (edge view), with a rim bar at
    /// the edge and a radial face + inner ring + specular dot otherwise.
    fileprivate func drawToken(
        _ context: GraphicsContext,
        metal: TokenMetal,
        at position: CGPoint,
        radius: CGFloat,
        flip: Double,
        tilt: Double,
        opacity: Double
    ) {
        guard opacity > 0 else { return }
        let flipScale = abs(cos(flip))
        let rr = radius
        var ctx = context
        ctx.opacity = clamp01(opacity)
        ctx.translateBy(x: position.x, y: position.y)
        if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
        ctx.scaleBy(x: max(0.12, CGFloat(flipScale)), y: 1)

        if flipScale < 0.16 {
            // Edge-on: a thin rim bar.
            let rim = metal == .gold
                ? Color(red: 0.722, green: 0.525, blue: 0.043)   // #b8860b
                : Color(red: 0.604, green: 0.639, blue: 0.678)   // #9aa3ad
            ctx.fill(
                Path(CGRect(x: -0.22 * rr, y: -rr, width: 0.44 * rr, height: 2 * rr)),
                with: .color(rim)
            )
        } else {
            // Face: radial gradient up-left.
            let faceStops: [Gradient.Stop]
            if metal == .gold {
                faceStops = [
                    .init(color: Color(red: 1.0, green: 0.965, blue: 0.847), location: 0),     // #fff6d8
                    .init(color: Color(red: 0.992, green: 0.769, blue: 0.173), location: 0.45), // #fdc42c
                    .init(color: Color(red: 0.604, green: 0.420, blue: 0.039), location: 1)      // #9a6b0a
                ]
            } else {
                faceStops = [
                    .init(color: Color.white, location: 0),                                      // #ffffff
                    .init(color: Color(red: 0.890, green: 0.914, blue: 0.933), location: 0.45),  // #e3e9ee
                    .init(color: Color(red: 0.573, green: 0.604, blue: 0.651), location: 1)       // #929aa6
                ]
            }
            let center = CGPoint(x: -0.35 * rr, y: -0.4 * rr)
            ctx.fill(
                Path(ellipseIn: CGRect(x: -rr, y: -rr, width: 2 * rr, height: 2 * rr)),
                with: .radialGradient(
                    Gradient(stops: faceStops),
                    center: center,
                    startRadius: 0.1 * rr,
                    endRadius: rr
                )
            )
            // Inner ring (rim).
            var ringCtx = ctx
            ringCtx.opacity = clamp01(opacity) * 0.6
            let ringColor = metal == .gold
                ? Color(red: 0.486, green: 0.322, blue: 0.031)   // #7c5208
                : Color(red: 0.490, green: 0.522, blue: 0.561)   // #7d858f
            ringCtx.stroke(
                Path(ellipseIn: CGRect(x: -0.82 * rr, y: -0.82 * rr, width: 1.64 * rr, height: 1.64 * rr)),
                with: .color(ringColor),
                lineWidth: max(1, 0.13 * rr)
            )
            // Specular highlight.
            var specCtx = ctx
            specCtx.opacity = clamp01(opacity) * 0.85
            specCtx.fill(
                Path(ellipseIn: CGRect(
                    x: -0.32 * rr - 0.22 * rr,
                    y: -0.34 * rr - 0.22 * rr,
                    width: 0.44 * rr,
                    height: 0.44 * rr
                )),
                with: .color(Color.white.opacity(0.75))
            )
        }
    }
}

// MARK: - BOUNDARY POP

extension EasterEggScene {

    fileprivate struct BoundaryCoin {
        let metal: TokenMetal
        let x: CGFloat
        let vy0: CGFloat         // shoots inward from the edge
        let g: CGFloat           // reverse gravity (back toward the edge)
        let radius: CGFloat
        let flip0: Double
        let vflip: Double
        let tilt0: Double
        let vtilt: Double
    }

    private static func buildBoundaryCoins(
        size: CGSize,
        edge: EasterEggEdge,
        rng: inout SeededGenerator
    ) -> [BoundaryCoin] {
        let count = 10
        let dir: CGFloat = edge == .top ? 1 : -1
        var coins: [BoundaryCoin] = []
        coins.reserveCapacity(count)
        for index in 0..<count {
            coins.append(
                BoundaryCoin(
                    metal: rng.next() % 2 == 0 ? .gold : .silver,
                    x: (CGFloat(index) + 0.5) / CGFloat(count) * size.width
                        + CGFloat(rng.nextDouble(in: -14...14)),
                    vy0: dir * CGFloat(rng.nextDouble(in: 280...460)),
                    g: -dir * Self.boundaryLaunchG,
                    radius: CGFloat(rng.nextDouble(in: 5...9)),
                    flip0: rng.nextDouble(in: 0...6.28),
                    vflip: rng.nextDouble(in: 6...12),
                    tilt0: rng.nextDouble(in: 0...6.28),
                    vtilt: rng.nextDouble(in: -2...2)
                )
            )
        }
        return coins
    }

    private func drawBoundary(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) {
        guard !reduceMotion else { return }
        guard let edge = boundaryEdge else { return }
        let y0: CGFloat = edge == .top ? 8 : size.height - 8
        let t = CGFloat(elapsed)
        guard elapsed <= Self.boundaryLife else { return }

        for coin in boundaryCoins {
            // Pure ballistic arc under reverse gravity (no wall/floor/ledge).
            let y = y0 + coin.vy0 * t + 0.5 * coin.g * t * t
            let flip = coin.flip0 + coin.vflip * Double(elapsed)
            let tilt = coin.tilt0 + coin.vtilt * Double(elapsed)
            let fade: Double = elapsed > 0.55 ? clamp01((0.95 - Double(elapsed)) / 0.4) : 1
            guard fade > 0.001 else { continue }
            drawToken(
                context,
                metal: coin.metal,
                at: CGPoint(x: coin.x, y: y),
                radius: coin.radius,
                flip: flip,
                tilt: tilt,
                opacity: fade
            )
        }
    }
}

// MARK: - Glyph → target points

/// Rasterises a glyph string into normalised target points (origin-centred,
/// range ~ -0.5...+0.5), the same mechanism the website uses to converge the
/// firework sparks into typographic shapes. Cached per string per process.
enum GlyphSampler {
    // Lock-protected memoisation: the `lock` guards every access, so the mutable
    // static is safe across the Canvas's async render thread. `nonisolated(unsafe)`
    // tells Swift 6 we own that synchronisation ourselves.
    nonisolated(unsafe) private static var cache: [String: [CGPoint]] = [:]
    private static let lock = NSLock()

    static func points(for text: String) -> [CGPoint] {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let pts = rasterize(text)
        cache[text] = pts
        return pts
    }

    #if canImport(UIKit)
    private static func rasterize(_ text: String) -> [CGPoint] {
        let dimension = 300
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: dimension,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }

        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))

        // White, heavy monospace glyph centred at (150, 150).
        let font = UIFont.monospacedSystemFont(ofSize: 170, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let bounds = attributed.boundingRect(
            with: CGSize(width: CGFloat(dimension), height: CGFloat(dimension)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let drawRect = CGRect(
            x: (CGFloat(dimension) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(dimension) - bounds.height) / 2 - bounds.minY,
            width: bounds.width,
            height: bounds.height
        )

        UIGraphicsPushContext(ctx)
        attributed.draw(in: drawRect)
        UIGraphicsPopContext()

        guard let data = ctx.data else { return [] }
        let buffer = data.bindMemory(to: UInt8.self, capacity: dimension * dimension)
        var points: [CGPoint] = []
        // CGContext origin is bottom-left; flip Y so points read top-down like
        // the website's getImageData scan.
        let stride = 7
        var y = 0
        while y < dimension {
            var x = 0
            while x < dimension {
                let flippedY = dimension - 1 - y
                if buffer[flippedY * dimension + x] > 128 {
                    points.append(CGPoint(
                        x: (CGFloat(x) - 150) / 300,
                        y: (CGFloat(y) - 150) / 300
                    ))
                }
                x += stride
            }
            y += stride
        }
        return points
    }
    #else
    private static func rasterize(_ text: String) -> [CGPoint] { [] }
    #endif
}

// MARK: - Helpers

private func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }

private func easeOutBack(_ t: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let p = t - 1
    return 1 + c3 * p * p * p + c1 * p * p
}

// MARK: - Seeded RNG

/// A tiny deterministic generator so each summon's layout is stable across the
/// Canvas's many redraws yet varied between summons. SplitMix64.
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

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Stable per-coin seed

extension EasterEggScene.CoinSeed {
    /// A stable integer seed for this coin's intra-step RNG (ledge scatter), so
    /// the re-stepped trajectory is identical every frame.
    fileprivate var hashSeed: Int {
        var hasher = Hasher()
        hasher.combine(cloudIndex)
        hasher.combine(releaseAt)
        hasher.combine(Double(offsetX))
        hasher.combine(Double(vx0))
        return hasher.finalize()
    }
}
