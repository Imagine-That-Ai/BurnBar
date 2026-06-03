import SwiftUI
import OpenBurnBarCore

// MARK: - Easter Egg Particle System
//
// The deterministic particle engine behind `EasterEggOverlay`. One instance is
// built per performance; it lays out a frozen field of particles from a seeded
// RNG (so the `Canvas` redraws are stable) and advances purely as a function of
// `elapsed` time — there is no per-frame mutable integration, which keeps the
// engine cheap and makes Reduced-Motion a trivial "draw the calm frame" branch.
//
// Three shows:
//   • Logo Storm        — crests + provider logos pop in (scale 0→1), drift
//     outward, twinkle, fade. A few staggered bursts across ~4.5s.
//   • Cloud Token Rain  — grey clouds wearing cloud-tier crests drift across
//     the top, raining gold/silver coins that fall under gravity and bounce
//     off the screen edges (~5.5s).
//   • Boundary Bounce   — a short row of coins pops up at one edge and bounces
//     once with a soft squash (~0.8s).
//
// Logos/crests are reused verbatim from the swarm engine's provider set and the
// cloud-tier crest assets. Coins are procedural so they stay crisp at any size.

struct EasterEggParticleSystem {
    /// A logo/crest the `Canvas` resolves through its `symbols:` builder.
    struct ImageToken: Identifiable, Hashable {
        let id: Int
        let assetName: String
    }

    private let performance: EasterEggPerformance
    private(set) var imageTokens: [ImageToken] = []

    // Frozen layouts (deterministic per show).
    private var logoSprites: [LogoSprite] = []
    private var clouds: [CloudSprite] = []
    private var coins: [CoinSprite] = []
    private var edgeCoins: [EdgeCoin] = []

    init(performance: EasterEggPerformance) {
        self.performance = performance
        var rng = SeededGenerator(seed: performance.id.hashValue)
        switch performance.kind {
        case .logoStorm:
            buildLogoStorm(rng: &rng)
        case .cloudTokenRain:
            buildCloudTokenRain(rng: &rng)
        case .boundaryBounce(let atTop):
            buildBoundaryBounce(atTop: atTop, rng: &rng)
        }
    }

    // MARK: - Draw

    func draw(into context: GraphicsContext, size: CGSize, elapsed: TimeInterval, reduceMotion: Bool) {
        let progress = performance.duration > 0 ? min(1, elapsed / performance.duration) : 1
        switch performance.kind {
        case .logoStorm:
            drawLogoStorm(context, size: size, elapsed: elapsed, progress: progress, reduceMotion: reduceMotion)
        case .cloudTokenRain:
            drawCloudTokenRain(context, size: size, elapsed: elapsed, progress: progress, reduceMotion: reduceMotion)
        case .boundaryBounce(let atTop):
            drawBoundaryBounce(context, size: size, elapsed: elapsed, atTop: atTop, reduceMotion: reduceMotion)
        }
    }

    // MARK: - Logo Storm

    private struct LogoSprite {
        let tokenID: Int
        let anchor: CGPoint        // 0...1 screen-relative spawn
        let drift: CGVector        // outward drift in points over the lifetime
        let baseScale: CGFloat
        let spin: Double           // gentle rotation amplitude (radians)
        let burst: Int             // which burst this belongs to (0...)
        let twinklePhase: Double
    }

    private mutating func buildLogoStorm(rng: inout SeededGenerator) {
        let providers = AgentProvider.swarmGlyphProviders
        // Lead with the brand crests so the celebration is BurnBar-forward.
        let crests = ["CloudTierCrest", "CloudTierCrestPro", "CloudTierCrestUltra", "AppLogo"]
        var assets: [String] = crests + providers.map(\.bundledLogoName)

        // Distinct image tokens (one resolved Image per asset).
        var tokenForAsset: [String: Int] = [:]
        for asset in Set(assets) {
            let id = imageTokens.count
            tokenForAsset[asset] = id
            imageTokens.append(ImageToken(id: id, assetName: asset))
        }

        let burstCount = performance.reduceMotion ? 1 : 3
        let perBurst = performance.reduceMotion ? 6 : 9
        for burst in 0..<burstCount {
            for _ in 0..<perBurst {
                guard !assets.isEmpty else { assets = providers.map(\.bundledLogoName); continue }
                let asset = assets[Int(rng.next() % UInt64(assets.count))]
                guard let tokenID = tokenForAsset[asset] else { continue }
                let anchor = CGPoint(
                    x: rng.double(in: 0.08...0.92),
                    y: rng.double(in: 0.12...0.88)
                )
                let angle = rng.double(in: 0...(2 * .pi))
                let dist = rng.double(in: 26...88)
                logoSprites.append(LogoSprite(
                    tokenID: tokenID,
                    anchor: anchor,
                    drift: CGVector(dx: cos(angle) * dist, dy: sin(angle) * dist - 18),
                    baseScale: rng.double(in: 0.42...0.78),
                    spin: rng.double(in: -0.5...0.5),
                    burst: burst,
                    twinklePhase: rng.double(in: 0...(2 * .pi))
                ))
            }
        }
    }

    private func drawLogoStorm(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        progress: Double,
        reduceMotion: Bool
    ) {
        let burstSpacing = 0.9 // seconds between burst starts
        let life = 1.7         // seconds each sprite lives
        let baseSide = min(size.width, size.height) * 0.16

        for sprite in logoSprites {
            let burstStart = reduceMotion ? 0 : Double(sprite.burst) * burstSpacing
            let local = elapsed - burstStart
            guard local >= 0, local <= life else { continue }
            let t = local / life // 0...1 within this sprite's life

            // Pop in (scale 0→1 with a touch of overshoot), hold, then ease out.
            let popIn = easeOutBack(min(1, t / 0.22))
            let fadeOut = t > 0.7 ? 1 - smoothstep((t - 0.7) / 0.3) : 1
            let appear = reduceMotion ? smoothstep(min(1, t / 0.4)) * (1 - smoothstep(max(0, (t - 0.6) / 0.4))) : popIn * fadeOut
            guard appear > 0.01 else { continue }

            let twinkle = reduceMotion ? 1 : 0.82 + 0.18 * sin(elapsed * 6 + sprite.twinklePhase)
            let driftEase = easeOutCubic(t)
            let center = CGPoint(
                x: sprite.anchor.x * size.width + sprite.drift.dx * driftEase,
                y: sprite.anchor.y * size.height + sprite.drift.dy * driftEase
            )
            let scale = sprite.baseScale * (reduceMotion ? appear : (0.6 + 0.4 * appear))
            let side = baseSide * scale
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)

            guard let symbol = context.resolveSymbol(id: sprite.tokenID) else { continue }
            var layer = context
            layer.opacity = appear * twinkle
            if !reduceMotion {
                layer.translateBy(x: center.x, y: center.y)
                layer.rotate(by: .radians(sprite.spin * driftEase))
                layer.translateBy(x: -center.x, y: -center.y)
                // A soft glow so the storm reads celebratory, not flat.
                layer.addFilter(.shadow(color: .white.opacity(0.35 * appear), radius: side * 0.18))
            }
            layer.draw(symbol, in: rect)
        }
    }

    // MARK: - Cloud Token Rain

    private struct CloudSprite {
        let tokenID: Int
        let startX: CGFloat   // 0...1
        let driftX: CGFloat   // points across the top
        let topY: CGFloat     // 0...1, near the top
        let scale: CGFloat
        let dropStart: Double // seconds before this cloud begins raining
        let coinIndices: Range<Int>
    }

    private struct CoinSprite {
        let metal: CoinMetal
        let spawnX: CGFloat   // 0...1, under its cloud
        let spawnDelay: Double
        let vx0: CGFloat      // initial horizontal velocity (points/s)
        let radius: CGFloat   // base radius scalar
        let spinRate: Double
    }

    private enum CoinMetal { case gold, silver }

    private mutating func buildCloudTokenRain(rng: inout SeededGenerator) {
        let crestAssets = ["CloudTierCrest", "CloudTierCrestPro", "CloudTierCrestUltra"]
        for asset in crestAssets {
            imageTokens.append(ImageToken(id: imageTokens.count, assetName: asset))
        }

        let cloudCount = performance.reduceMotion ? 2 : 4
        var coinCursor = 0
        for i in 0..<cloudCount {
            let tokenID = i % crestAssets.count
            let coinsPerCloud = performance.reduceMotion ? 3 : Int(rng.double(in: 5...8))
            let range = coinCursor..<(coinCursor + coinsPerCloud)
            let startX = rng.double(in: -0.1...0.85)
            clouds.append(CloudSprite(
                tokenID: tokenID,
                startX: startX,
                driftX: rng.double(in: 30...70),
                topY: rng.double(in: 0.06...0.16),
                scale: rng.double(in: 0.85...1.15),
                dropStart: performance.reduceMotion ? 0 : rng.double(in: 0.2...1.1),
                coinIndices: range
            ))
            for _ in 0..<coinsPerCloud {
                coins.append(CoinSprite(
                    metal: rng.next() % 2 == 0 ? .gold : .silver,
                    spawnX: startX + rng.double(in: 0.02...0.14),
                    spawnDelay: rng.double(in: 0...1.0),
                    vx0: rng.double(in: -40...40),
                    radius: rng.double(in: 7...12),
                    spinRate: rng.double(in: 2...5)
                ))
            }
            coinCursor += coinsPerCloud
        }
    }

    private func drawCloudTokenRain(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        progress: Double,
        reduceMotion: Bool
    ) {
        let gravity: CGFloat = 520 // points/s^2
        let restitution: CGFloat = 0.55

        // Clouds drift across the top, fading in then out near the end.
        for cloud in clouds {
            let cloudT = min(1, elapsed / performance.duration)
            let fadeIn = smoothstep(min(1, elapsed / 0.6))
            let fadeOut = 1 - smoothstep(max(0, (cloudT - 0.78) / 0.22))
            let appear = fadeIn * fadeOut
            guard appear > 0.01 else { continue }
            let x = cloud.startX * size.width + cloud.driftX * CGFloat(elapsed) * (reduceMotion ? 0 : 1)
            let y = cloud.topY * size.height
            drawCloud(context, center: CGPoint(x: x, y: y), scale: cloud.scale, size: size, opacity: appear)
            // The cloud-tier crest rides on the cloud.
            if let symbol = context.resolveSymbol(id: cloud.tokenID) {
                let side = min(size.width, size.height) * 0.075 * cloud.scale
                let rect = CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
                var layer = context
                layer.opacity = appear
                layer.draw(symbol, in: rect)
            }
        }

        // Coins rain, fall under gravity, bounce off the four edges, settle.
        for (idx, coin) in coins.enumerated() {
            // Find the cloud this coin belongs to for its spawn point + timing.
            guard let cloud = clouds.first(where: { $0.coinIndices.contains(idx) }) else { continue }
            let spawnElapsed = elapsed - cloud.dropStart - coin.spawnDelay
            guard spawnElapsed >= 0 else { continue }

            let spawnX = coin.spawnX * size.width + cloud.driftX * CGFloat(cloud.dropStart)
            let spawnY = cloud.topY * size.height + 12
            let pos = integrateCoin(
                spawnX: spawnX,
                spawnY: spawnY,
                vx0: reduceMotion ? 0 : coin.vx0,
                t: reduceMotion ? min(spawnElapsed, 0.9) : spawnElapsed,
                gravity: gravity,
                restitution: restitution,
                bounds: size,
                radius: coin.radius
            )

            // Coins fade as the show ends so the field settles cleanly.
            let settle = 1 - smoothstep(max(0, (Double(progress) - 0.82) / 0.18))
            let spin = reduceMotion ? 0 : sin(spawnElapsed * coin.spinRate)
            drawCoin(
                context,
                center: pos,
                radius: coin.radius,
                metal: coin.metal,
                squash: 1 - 0.35 * CGFloat(max(0, spin)),
                opacity: settle
            )
        }
    }

    // MARK: - Boundary Bounce

    private struct EdgeCoin {
        let metal: CoinMetal
        let xFraction: CGFloat
        let radius: CGFloat
        let phase: Double
    }

    private mutating func buildBoundaryBounce(atTop: Bool, rng: inout SeededGenerator) {
        let count = 5
        for i in 0..<count {
            edgeCoins.append(EdgeCoin(
                metal: i % 2 == 0 ? .gold : .silver,
                xFraction: 0.5 + CGFloat(i - count / 2) * 0.085,
                radius: rng.double(in: 9...12),
                phase: Double(i) * 0.05
            ))
        }
    }

    private func drawBoundaryBounce(
        _ context: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval,
        atTop: Bool,
        reduceMotion: Bool
    ) {
        let life = performance.duration
        let t = min(1, elapsed / life)
        // A single bounce: up then down, with a soft squash at the apex.
        for coin in edgeCoins {
            let local = max(0, t - coin.phase)
            let pop = reduceMotion
                ? smoothstep(min(1, local / 0.4)) * (1 - smoothstep(max(0, (local - 0.5) / 0.5)))
                : sin(min(1, local) * .pi) // 0→1→0 arch
            guard pop > 0.01 else { continue }
            let edgeY = atTop ? size.height * 0.06 : size.height * 0.94
            let lift: CGFloat = reduceMotion ? 10 : 34
            let y = edgeY + (atTop ? pop * lift : -pop * lift)
            let squash: CGFloat = reduceMotion ? 1 : 1 - 0.25 * CGFloat(max(0, sin(local * .pi * 2)))
            drawCoin(
                context,
                center: CGPoint(x: coin.xFraction * size.width, y: y),
                radius: coin.radius,
                metal: coin.metal,
                squash: squash,
                opacity: Double(pop)
            )
        }
    }

    // MARK: - Procedural coin

    private func drawCoin(
        _ context: GraphicsContext,
        center: CGPoint,
        radius: CGFloat,
        metal: CoinMetal,
        squash: CGFloat,
        opacity: Double
    ) {
        guard opacity > 0.01 else { return }
        let rx = radius
        let ry = radius * max(0.35, squash) // squash flattens vertically
        let rect = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
        let (face, rim, sheen): (Color, Color, Color)
        switch metal {
        case .gold:
            face = Color(red: 1.0, green: 0.82, blue: 0.35)
            rim = Color(red: 0.78, green: 0.55, blue: 0.12)
            sheen = Color(red: 1.0, green: 0.95, blue: 0.7)
        case .silver:
            face = Color(red: 0.86, green: 0.88, blue: 0.92)
            rim = Color(red: 0.55, green: 0.58, blue: 0.64)
            sheen = Color(red: 0.98, green: 0.99, blue: 1.0)
        }
        var layer = context
        layer.opacity = opacity
        let path = Path(ellipseIn: rect)
        layer.fill(path, with: .radialGradient(
            Gradient(colors: [sheen, face, rim]),
            center: CGPoint(x: center.x - rx * 0.3, y: center.y - ry * 0.3),
            startRadius: 0,
            endRadius: rx * 1.4
        ))
        layer.stroke(path, with: .color(rim.opacity(0.9)), lineWidth: max(0.8, radius * 0.12))
        // Tiny "$" mark so the coins read as tokens.
        let mark = Text("$")
            .font(.system(size: radius * 1.1, weight: .bold, design: .rounded))
            .foregroundStyle(rim.opacity(0.85))
        layer.draw(mark, at: center)
    }

    // MARK: - Procedural cloud

    private func drawCloud(
        _ context: GraphicsContext,
        center: CGPoint,
        scale: CGFloat,
        size: CGSize,
        opacity: Double
    ) {
        let w = min(size.width, size.height) * 0.22 * scale
        let h = w * 0.55
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - w * 0.5, y: center.y - h * 0.18, width: w * 0.6, height: h * 0.7))
        path.addEllipse(in: CGRect(x: center.x - w * 0.15, y: center.y - h * 0.5, width: w * 0.55, height: h * 0.9))
        path.addEllipse(in: CGRect(x: center.x + w * 0.18, y: center.y - h * 0.2, width: w * 0.5, height: h * 0.65))
        path.addRoundedRect(in: CGRect(x: center.x - w * 0.45, y: center.y + h * 0.05, width: w * 0.95, height: h * 0.4), cornerSize: CGSize(width: h * 0.2, height: h * 0.2))
        var layer = context
        layer.opacity = opacity * 0.92
        layer.fill(path, with: .linearGradient(
            Gradient(colors: [
                Color(red: 0.92, green: 0.93, blue: 0.96),
                Color(red: 0.78, green: 0.80, blue: 0.85)
            ]),
            startPoint: CGPoint(x: center.x, y: center.y - h),
            endPoint: CGPoint(x: center.x, y: center.y + h)
        ))
    }

    // MARK: - Coin physics (analytic with edge bounces)

    /// Integrate a coin's position under constant gravity with per-axis edge
    /// bouncing. Stepped in fixed slices so the analytic path stays cheap while
    /// still reflecting off all four screen boundaries.
    private func integrateCoin(
        spawnX: CGFloat,
        spawnY: CGFloat,
        vx0: CGFloat,
        t: TimeInterval,
        gravity: CGFloat,
        restitution: CGFloat,
        bounds: CGSize,
        radius: CGFloat
    ) -> CGPoint {
        let dt: CGFloat = 1.0 / 60.0
        var x = spawnX
        var y = spawnY
        var vx = vx0
        var vy: CGFloat = 0
        let minX = radius, maxX = bounds.width - radius
        let minY = radius, maxY = bounds.height - radius
        var remaining = CGFloat(t)
        var steps = 0
        while remaining > 0 && steps < 600 {
            let step = min(dt, remaining)
            vy += gravity * step
            x += vx * step
            y += vy * step
            if x < minX { x = minX; vx = -vx * restitution }
            else if x > maxX { x = maxX; vx = -vx * restitution }
            if y > maxY { y = maxY; vy = -vy * restitution; vx *= 0.92 }
            else if y < minY { y = minY; vy = -vy * restitution }
            remaining -= step
            steps += 1
        }
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Easing helpers

private func smoothstep(_ x: Double) -> Double {
    let t = min(1, max(0, x))
    return t * t * (3 - 2 * t)
}

private func easeOutCubic(_ x: Double) -> Double {
    let p = 1 - min(1, max(0, x))
    return 1 - p * p * p
}

private func easeOutBack(_ x: Double) -> Double {
    let c1 = 1.70158
    let c3 = c1 + 1
    let p = min(1, max(0, x)) - 1
    return 1 + c3 * p * p * p + c1 * p * p
}

// MARK: - Deterministic RNG

/// A small splitmix64-style generator so each performance lays out a stable
/// field across the `Canvas`'s redraws (the same seed → the same show).
private struct SeededGenerator {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A uniform Double in `range`.
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) * (1.0 / 9007199254740992.0) // 53-bit
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

private extension CGFloat {
    init(_ d: Double) { self = CGFloat(d) }
}
