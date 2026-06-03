import OpenBurnBarCore
import SwiftUI

// MARK: - Easter egg scene
//
// A deterministic, time-driven particle simulation. Built once per event, then
// `draw(into:size:elapsed:)` is a pure function of elapsed seconds — the
// `Canvas` closure holds no mutable state, so SwiftUI can render it
// asynchronously and the effect stays smooth.
//
// Three event flavours, all elegant and self-limiting:
//   * Logo storm  — repeated celebratory bursts of crests + provider logos
//     that pop in (scale 0 -> 1), drift/launch outward, twinkle, and fade.
//   * Token rain  — grey clouds drift across the top wearing cloud-tier crests
//     and rain gold/silver coins that fall under gravity and BOUNCE off the
//     canvas edges before settling and fading.
//   * Boundary tap — a short row of coins pops up at one edge and bounces once
//     with a soft squash so "you've reached the end" reads instantly.

struct EasterEggScene {
    let kind: EasterEggEvent.Kind
    private let logoParticles: [LogoParticle]
    private let clouds: [CloudParticle]
    private let coins: [CoinParticle]
    private let boundaryCoins: [BoundaryCoin]
    private let canvasSize: CGSize

    // Tunables shared across the rain + boundary physics.
    private static let gravity: CGFloat = 1500          // points / s^2
    private static let restitution: CGFloat = 0.62      // bounce energy retained
    private static let coinRadius: CGFloat = 15

    // MARK: Construction

    static func make(for event: EasterEggEvent, size: CGSize, colorScheme: ColorScheme) -> EasterEggScene {
        // Seed from the event id so a given summon is stable across redraws but
        // each summon still looks fresh.
        var rng = SeededGenerator(seed: event.id.uuidString.hashValue)
        let safeSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))

        switch event.kind {
        case .logoStorm:
            return EasterEggScene(
                kind: event.kind,
                logoParticles: buildLogoBursts(size: safeSize, rng: &rng),
                clouds: [],
                coins: [],
                boundaryCoins: [],
                canvasSize: safeSize
            )
        case .cloudTokenRain:
            let clouds = buildClouds(size: safeSize, rng: &rng)
            return EasterEggScene(
                kind: event.kind,
                logoParticles: [],
                clouds: clouds,
                coins: buildRainCoins(size: safeSize, clouds: clouds, rng: &rng),
                boundaryCoins: [],
                canvasSize: safeSize
            )
        case .boundary(let edge):
            return EasterEggScene(
                kind: event.kind,
                logoParticles: [],
                clouds: [],
                coins: [],
                boundaryCoins: buildBoundaryCoins(size: safeSize, edge: edge, rng: &rng),
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
        case .boundary(let edge):
            drawBoundary(context, size: size, elapsed: elapsed, edge: edge)
        }
    }
}

// MARK: - Logo storm

extension EasterEggScene {

    private struct LogoParticle {
        let symbolID: EasterEggSymbolID
        let origin: CGPoint
        let drift: CGVector       // outward launch velocity (points / s)
        let baseScale: CGFloat
        let spin: Double          // radians / s
        let birth: TimeInterval   // burst start time
        let life: TimeInterval    // visible lifetime after birth
        let twinklePhase: Double
    }

    private static func buildLogoBursts(size: CGSize, rng: inout SeededGenerator) -> [LogoParticle] {
        let names = EasterEggAssets.stormLogoNames
        guard !names.isEmpty else { return [] }

        // 3 staggered bursts over ~4.5s — celebratory but not chaotic.
        let burstTimes: [TimeInterval] = [0.0, 1.3, 2.6]
        let perBurst = 9
        var particles: [LogoParticle] = []
        particles.reserveCapacity(burstTimes.count * perBurst)
        var nameIndex = Int(rng.next() % UInt64(names.count))

        for (burstIndex, birth) in burstTimes.enumerated() {
            // Each burst radiates from a different, gently off-centre origin.
            let originAngle = Double(burstIndex) * 2.39996 // golden angle spread
            let originRadius = CGFloat(0.18) * min(size.width, size.height)
            let origin = CGPoint(
                x: size.width * 0.5 + cos(originAngle) * originRadius,
                y: size.height * 0.46 + sin(originAngle) * originRadius
            )
            for slot in 0..<perBurst {
                let angle = (Double(slot) / Double(perBurst)) * 2 * .pi
                    + rng.nextDouble(in: -0.25...0.25)
                let speed = CGFloat(rng.nextDouble(in: 120...260))
                let name = names[nameIndex % names.count]
                nameIndex += 1
                particles.append(
                    LogoParticle(
                        symbolID: .logo(assetName: name),
                        origin: origin,
                        drift: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 40),
                        baseScale: CGFloat(rng.nextDouble(in: 0.42...0.78)),
                        spin: rng.nextDouble(in: -1.2...1.2),
                        birth: birth,
                        life: rng.nextDouble(in: 1.4...1.9),
                        twinklePhase: rng.nextDouble(in: 0...(2 * .pi))
                    )
                )
            }
        }
        return particles
    }

    private func drawLogoStorm(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) {
        for particle in logoParticles {
            // Reduce Motion: render one calm, settled frame — the marks simply
            // fade in at their origin with no launch, spin, or twinkle.
            let localTime = reduceMotion ? min(0.45, particle.life * 0.5) : elapsed - particle.birth
            guard localTime >= 0 else { continue }
            guard localTime <= particle.life else { continue }

            let t = localTime / particle.life            // 0...1 progress
            // Pop-in: scale springs 0 -> 1 over the first ~22% of life.
            let popT = min(1, localTime / (particle.life * 0.22))
            let pop = easeOutBack(popT)
            // Fade out over the last ~38% of life.
            let fade = t < 0.62 ? 1.0 : 1.0 - (t - 0.62) / 0.38
            guard fade > 0.01 else { continue }

            let position: CGPoint
            let scale: CGFloat
            let rotation: Double
            let twinkle: Double

            if reduceMotion {
                position = particle.origin
                scale = particle.baseScale
                rotation = 0
                twinkle = 1
            } else {
                // Outward drift with light gravity so the burst arcs gracefully.
                let dt = CGFloat(localTime)
                position = CGPoint(
                    x: particle.origin.x + particle.drift.dx * dt,
                    y: particle.origin.y + particle.drift.dy * dt + 60 * dt * dt
                )
                scale = particle.baseScale * pop
                rotation = particle.spin * localTime
                // Per-mark twinkle while it holds, like the constellation shimmer.
                twinkle = 0.78 + 0.22 * sin(localTime * 7 + particle.twinklePhase)
            }

            guard let symbol = context.resolveSymbol(id: particle.symbolID) else { continue }
            var markContext = context
            markContext.opacity = fade * twinkle
            markContext.translateBy(x: position.x, y: position.y)
            markContext.rotate(by: .radians(rotation))
            markContext.scaleBy(x: scale, y: scale)
            // Symbols are authored at 64pt; draw centred at the origin.
            markContext.draw(symbol, at: .zero, anchor: .center)
        }
    }
}

// MARK: - Cloud token rain

extension EasterEggScene {

    private struct CloudParticle {
        let crestID: EasterEggSymbolID
        let entryX: CGFloat       // start x (off the left edge)
        let y: CGFloat
        let speed: CGFloat        // drift speed (points / s)
        let scale: CGFloat
    }

    private struct CoinParticle {
        let symbolID: EasterEggSymbolID
        let cloudIndex: Int           // parent cloud in `clouds`
        let spawnX: CGFloat
        let spawnY: CGFloat
        let releaseAt: TimeInterval   // when the coin leaves its cloud
        let vx0: CGFloat
        let spin: Double
    }

    private static func buildClouds(size: CGSize, rng: inout SeededGenerator) -> [CloudParticle] {
        let crests = EasterEggAssets.cloudCrestNames.filter { EasterEggAssets.imageExists($0) }
        let count = 3
        var clouds: [CloudParticle] = []
        for index in 0..<count {
            let crestName = crests.isEmpty ? nil : crests[index % crests.count]
            clouds.append(
                CloudParticle(
                    crestID: crestName.map { .logo(assetName: $0) } ?? .cloud,
                    entryX: -CGFloat(rng.nextDouble(in: 60...220)),
                    y: size.height * CGFloat(0.10 + 0.07 * Double(index)),
                    speed: CGFloat(rng.nextDouble(in: 34...58)),
                    scale: CGFloat(rng.nextDouble(in: 0.85...1.15))
                )
            )
        }
        return clouds
    }

    private static func buildRainCoins(
        size: CGSize,
        clouds: [CloudParticle],
        rng: inout SeededGenerator
    ) -> [CoinParticle] {
        guard !clouds.isEmpty else { return [] }
        let perCloud = 7
        var coins: [CoinParticle] = []
        coins.reserveCapacity(clouds.count * perCloud)
        for (cloudIndex, cloud) in clouds.enumerated() {
            for slot in 0..<perCloud {
                let release = TimeInterval(rng.nextDouble(in: 0.4...3.4))
                // Coin spawns under the cloud at the moment of release; the
                // cloud's x at that time is recomputed in the draw pass.
                let metal: TokenMetal = rng.next() % 2 == 0 ? .gold : .silver
                coins.append(
                    CoinParticle(
                        symbolID: .coin(metal: metal),
                        cloudIndex: cloudIndex,
                        spawnX: CGFloat(slot) * 14 - 42 + CGFloat(rng.nextDouble(in: -8...8)),
                        spawnY: cloud.y + 34 * cloud.scale,
                        releaseAt: release,
                        vx0: CGFloat(rng.nextDouble(in: -40...40)),
                        spin: rng.nextDouble(in: -3...3)
                    )
                )
            }
        }
        return coins
    }

    private func cloudX(_ cloud: CloudParticle, elapsed: TimeInterval) -> CGFloat {
        cloud.entryX + cloud.speed * CGFloat(elapsed)
    }

    private func drawCloudTokenRain(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) {
        // Reduce Motion: a single calm frame — clouds parked near the top with
        // a couple of resting coins beneath them, no falling physics.
        let drawElapsed = reduceMotion ? 1.0 : elapsed

        // Clouds (drawn first, behind their rain).
        guard let cloudSymbol = context.resolveSymbol(id: .cloud) else { return }
        let globalFade = self.rainFade(elapsed: elapsed, reduceMotion: reduceMotion)

        for (index, cloud) in clouds.enumerated() {
            let x = reduceMotion
                ? size.width * CGFloat(0.22 + 0.28 * Double(index))
                : cloudX(cloud, elapsed: drawElapsed)
            guard x < size.width + 120 else { continue }

            var cloudContext = context
            cloudContext.opacity = globalFade * 0.95
            cloudContext.translateBy(x: x, y: cloud.y)
            cloudContext.scaleBy(x: cloud.scale, y: cloud.scale)
            cloudContext.draw(cloudSymbol, at: .zero, anchor: .center)

            // The cloud-tier crest rides on the cloud's shoulder.
            if let crestSymbol = context.resolveSymbol(id: cloud.crestID),
               case .logo = cloud.crestID {
                var crestContext = context
                crestContext.opacity = globalFade
                crestContext.translateBy(x: x, y: cloud.y - 4)
                crestContext.scaleBy(x: cloud.scale * 0.46, y: cloud.scale * 0.46)
                crestContext.draw(crestSymbol, at: .zero, anchor: .center)
            }
        }

        // Coins rain from their parent cloud, fall under gravity, bounce off the
        // canvas edges, then settle on the floor and fade with the scene.
        for (coinIndex, coin) in coins.enumerated() {
            let parentCloud = clouds[min(coin.cloudIndex, clouds.count - 1)]
            let cloudCurrentX = reduceMotion
                ? size.width * 0.3
                : cloudX(parentCloud, elapsed: coin.releaseAt)
            let originX = cloudCurrentX + coin.spawnX

            if reduceMotion {
                // Calm frame: a couple of coins resting on the floor.
                guard coinIndex % 3 == 0 else { continue }
                drawCoin(
                    context,
                    symbolID: coin.symbolID,
                    at: CGPoint(x: originX, y: size.height - Self.coinRadius - 2),
                    rotation: 0,
                    squash: 1,
                    opacity: globalFade
                )
                continue
            }

            let fallTime = elapsed - coin.releaseAt
            guard fallTime >= 0 else { continue }

            let state = simulateCoin(
                startX: originX,
                startY: coin.spawnY,
                vx0: coin.vx0,
                time: fallTime,
                size: size
            )
            drawCoin(
                context,
                symbolID: coin.symbolID,
                at: state.position,
                rotation: coin.spin * fallTime * (state.resting ? 0 : 1),
                squash: state.squash,
                opacity: globalFade
            )
        }
    }

    /// Whole-scene fade: holds full, then eases out over the final second.
    private func rainFade(elapsed: TimeInterval, reduceMotion: Bool) -> Double {
        if reduceMotion { return 1 }
        let total: TimeInterval = 5.6
        let fadeStart: TimeInterval = 4.4
        if elapsed <= fadeStart { return 1 }
        return max(0, 1 - (elapsed - fadeStart) / (total - fadeStart))
    }
}

// MARK: - Coin physics (shared by rain + boundary)

extension EasterEggScene {

    private struct CoinState {
        let position: CGPoint
        let squash: CGFloat
        let resting: Bool
    }

    /// Integrates a single coin under gravity with wall + floor bounces. Closed
    /// stepping is fine here (events are short); a fixed small step keeps the
    /// bounce response stable without per-frame mutable state.
    private func simulateCoin(
        startX: CGFloat,
        startY: CGFloat,
        vx0: CGFloat,
        time: TimeInterval,
        size: CGSize
    ) -> CoinState {
        let r = Self.coinRadius
        let floor = size.height - r
        let ceiling = r
        let leftWall = r
        let rightWall = size.width - r

        var x = startX
        var y = startY
        var vx = vx0
        var vy: CGFloat = 0
        var squash: CGFloat = 1
        var resting = false

        let step: CGFloat = 1.0 / 120.0
        var remaining = CGFloat(time)
        while remaining > 0 {
            let dt = min(step, remaining)
            remaining -= dt
            vy += Self.gravity * dt
            x += vx * dt
            y += vy * dt

            if y >= floor {
                y = floor
                if abs(vy) < 40 {
                    vy = 0
                    resting = true
                } else {
                    vy = -vy * Self.restitution
                    vx *= 0.86
                    squash = 0.7   // brief floor squash, relaxes below
                    resting = false
                }
            } else if y <= ceiling {
                y = ceiling
                vy = -vy * Self.restitution
            }

            if x <= leftWall {
                x = leftWall
                vx = abs(vx) * Self.restitution
            } else if x >= rightWall {
                x = rightWall
                vx = -abs(vx) * Self.restitution
            }
        }

        // Relax the squash back toward round once airborne again.
        if !resting, squash < 1 {
            squash = min(1, squash + 0.25)
        }
        return CoinState(position: CGPoint(x: x, y: y), squash: squash, resting: resting)
    }

    fileprivate func drawCoin(
        _ context: GraphicsContext,
        symbolID: EasterEggSymbolID,
        at position: CGPoint,
        rotation: Double,
        squash: CGFloat,
        opacity: Double
    ) {
        guard let symbol = context.resolveSymbol(id: symbolID) else { return }
        var coinContext = context
        coinContext.opacity = opacity
        coinContext.translateBy(x: position.x, y: position.y)
        if rotation != 0 { coinContext.rotate(by: .radians(rotation)) }
        // Vertical squash on impact, widening slightly to conserve area.
        coinContext.scaleBy(x: 1 + (1 - squash) * 0.5, y: squash)
        coinContext.draw(symbol, at: .zero, anchor: .center)
    }
}

// MARK: - Boundary tap

extension EasterEggScene {

    private struct BoundaryCoin {
        let symbolID: EasterEggSymbolID
        let x: CGFloat
        let phase: Double         // staggered pop offset
    }

    private static func buildBoundaryCoins(
        size: CGSize,
        edge: EasterEggEdge,
        rng: inout SeededGenerator
    ) -> [BoundaryCoin] {
        let count = 5
        let spacing: CGFloat = 34
        let totalWidth = CGFloat(count - 1) * spacing
        let startX = size.width / 2 - totalWidth / 2
        return (0..<count).map { index in
            BoundaryCoin(
                symbolID: .coin(metal: index % 2 == 0 ? .gold : .silver),
                x: startX + CGFloat(index) * spacing,
                phase: Double(index) * 0.05
            )
        }
    }

    private func drawBoundary(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        edge: EasterEggEdge
    ) {
        // A cute ~0.8s pop: each coin springs up from the edge, bounces once
        // with a soft squash, then settles and fades.
        let baseline: CGFloat = edge == .top ? Self.coinRadius + 10 : size.height - Self.coinRadius - 10
        let popDirection: CGFloat = edge == .top ? 1 : -1   // top pops downward, bottom upward
        let total: TimeInterval = 0.8

        for coin in boundaryCoins {
            let local = elapsed - coin.phase
            guard local >= 0, local <= total else { continue }
            let t = local / total

            // Single bounce arc: up fast, settle. |sin| gives one clean hop.
            let hop = abs(sin(t * .pi)) * (1 - t * 0.35)
            let lift = CGFloat(hop) * 22
            let y = baseline + popDirection * lift

            // Soft squash at the apex extremes for a springy, cute feel.
            let squash = 1 - 0.18 * CGFloat(sin(t * .pi * 2).magnitude)
            let fade = t < 0.7 ? 1.0 : 1.0 - (t - 0.7) / 0.3
            guard fade > 0.01 else { continue }

            drawCoin(
                context,
                symbolID: coin.symbolID,
                at: CGPoint(x: coin.x, y: y),
                rotation: 0,
                squash: squash,
                opacity: fade
            )
        }
    }
}

// MARK: - Easing + seeded RNG

private func easeOutBack(_ t: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let p = t - 1
    return 1 + c3 * p * p * p + c1 * p * p
}

/// A tiny deterministic generator so each summon's layout is stable across the
/// Canvas's many redraws yet varied between summons. SplitMix64.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: Int) {
        // Avoid a zero state; mix the seed.
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
