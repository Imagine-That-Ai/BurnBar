import SwiftUI
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SwarmCanvasView
//
// A faithful Swift port of the "Interactive Token Ember Swarm" canvas that
// powers burnbar.ai. Hundreds of ember particles drift in a noise-driven
// murmuration, then periodically *reconverge* into glyph shapes — "$",
// "</>", the BurnBar flame/bar-graph logo, concentric quota rings, and a
// router-failover S-curve — before breaking apart again.
//
// Runs on macOS, iOS and iPadOS via SwiftUI `TimelineView` + `Canvas`.
// Respects `accessibilityReduceMotion` (locks pace + cycling). Pointer or
// touch position pushes nearby particles away, matching the web build.

public struct SwarmCanvasView: View {
    public let accent: Color
    public let pace: Pace
    public let particleCount: Int
    public let colorDriver: SwarmColorDriver?
    public let isBatteryThrottled: Bool
    public let externalPointer: CGPoint?
    public let isTransparent: Bool
    public let backdropColor: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var simulation: SwarmSimulation

    public enum Pace {
        /// Snappy, energetic — matches the website home page.
        case energetic
        /// Slow, cinematic — matches inner pages.
        case cinematic
    }

    public init(
        accent: Color,
        pace: Pace = .energetic,
        particleCount: Int? = nil,
        colorDriver: SwarmColorDriver? = nil,
        isBatteryThrottled: Bool = false,
        externalPointer: CGPoint? = nil,
        isTransparent: Bool = false,
        backdropColor: Color? = nil
    ) {
        self.accent = accent
        self.pace = pace
        self.particleCount = particleCount ?? Self.adaptiveParticleCount
        self.colorDriver = colorDriver
        self.isBatteryThrottled = isBatteryThrottled
        self.externalPointer = externalPointer
        self.isTransparent = isTransparent
        self.backdropColor = backdropColor

        let sim = SwarmSimulation(
            particleCount: particleCount ?? Self.adaptiveParticleCount,
            pace: pace
        )
        sim.setColorDriver(colorDriver)
        _simulation = State(initialValue: sim)
    }

    public var body: some View {
        let fps = isBatteryThrottled ? 15.0 : 60.0
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: reduceMotion)) { timeline in
            Canvas(rendersAsynchronously: false) { context, size in
                simulation.advance(
                    to: timeline.date,
                    bounds: size,
                    reduceMotion: reduceMotion,
                    isBatteryThrottled: isBatteryThrottled
                )
                simulation.draw(
                    into: context,
                    size: size,
                    scheme: colorScheme,
                    isBatteryThrottled: isBatteryThrottled
                )
            }
            .background(backdrop)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    simulation.pointer = point
                case .ended:
                    simulation.pointer = nil
                }
            }
            #if canImport(UIKit)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        simulation.pointer = value.location
                    }
                    .onEnded { _ in
                        simulation.pointer = nil
                    }
            )
            #endif
        }
        .drawingGroup(opaque: !isTransparent, colorMode: .nonLinear)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onChange(of: colorDriver) {
            simulation.setColorDriver(colorDriver)
        }
        .onChange(of: externalPointer) {
            simulation.pointer = externalPointer
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        // Match the app's appearance so the swarm stays coherent with the
        // themed cards layered on top (dark backdrop in dark mode, soft warm
        // off-white in light mode). The particle palette adapts to match.
        Rectangle()
            .fill(isTransparent ? Color.clear : (backdropColor ?? (colorScheme == .dark
                ? Color(red: 0.020, green: 0.020, blue: 0.031)
                : Color(red: 0.953, green: 0.937, blue: 0.906))))
            .ignoresSafeArea()
    }

    /// Adaptive particle budget: more on macOS / iPad, fewer on iPhone, and
    /// further reduced under Low Power Mode.
    public static var adaptiveParticleCount: Int {
        #if os(macOS)
        let base = 1200
        #else
        let base: Int = {
            if UIDevice.current.userInterfaceIdiom == .pad { return 720 }
            return 360
        }()
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base / 2 : base
    }
}

// MARK: - Simulation Core

enum SwarmFormationMode: Equatable {
    case swarm
    case shapeDollar
    case shapeCode
    case shapeBurnBarLogo
    case shapeRings
    case shapeRouterFlow

    static let defaultCycle: [SwarmFormationMode] = [
        .swarm,
        .shapeDollar,
        .swarm,
        .shapeCode,
        .swarm,
        .shapeBurnBarLogo,
        .swarm,
        .shapeRings,
        .swarm,
        .shapeRouterFlow
    ]
}

@MainActor
private final class SwarmSimulation {

    struct Particle {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        var size: Double
        var isGlyph: Bool
        var glyph: String
        var colorIndex: Double          // 0…1 — stable per particle
        var baseOpacity: Double
        var opacity: Double
        var tx: Double?                 // target x (shape mode)
        var ty: Double?                 // target y (shape mode)
        var role: String?               // target-shape role
        var flowProgress: Double        // for router-flow bezier travel
    }

    // MARK: Tunables (mirrors website BaseLayout.astro)
    private let timeStep: Double
    private let swarmNoise: Double
    private let swarmDrag: Double
    private let maxSpeedGlyph: Double
    private let maxSpeedPixel: Double
    private let morphAttract: Double
    private let morphNoise: Double
    private let morphDrag: Double
    private let cycleInterval: TimeInterval
    private let mouseForceMultiplier: Double

    private let glyphs = ["$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache"]
    private let modes = SwarmFormationMode.defaultCycle

    private var particles: [Particle] = []
    private var mode: SwarmFormationMode = .swarm
    private var cycleIndex: Int = 0
    private var nextCycleAt: TimeInterval = 0
    private var flowTime: Double = 0
    private var bounds: CGSize = .zero
    private var initialized = false
    private var renderScheme: ColorScheme = .dark

    private lazy var dollarPoints = SwarmSimulation.sampleTextPoints(text: "$", fontSize: 280)
    private lazy var codePoints = SwarmSimulation.sampleTextPoints(text: "</>", fontSize: 220)
    private lazy var burnBarLogoPoints = SwarmLogoShape.generatePoints()
    private lazy var ringPoints = SwarmSimulation.generateRingPoints()
    private lazy var routerFlowPoints = SwarmSimulation.generateRouterFlowPoints()

    var pointer: CGPoint?

    // MARK: Color Driver State
    private var colorDriver: SwarmColorDriver?
    /// Previous driver's resolved colors per particle — used for smooth transition.
    private var previousColors: [RGBA?] = []
    /// Progress of the current color transition (0 = old colors, 1 = new colors).
    private var colorTransitionProgress: Double = 1.0
    /// Duration of the color transition in seconds.
    private static let colorTransitionDuration: Double = 2.0
    /// Fast ignition transition when going from idle → active.
    private static let ignitionTransitionDuration: Double = 0.8
    private var activeTransitionDuration: Double = colorTransitionDuration

    init(particleCount: Int, pace: SwarmCanvasView.Pace) {
        switch pace {
        case .energetic:
            self.timeStep = 0.000018
            self.swarmNoise = 0.12
            self.swarmDrag = 0.985
            self.maxSpeedGlyph = 1.4
            self.maxSpeedPixel = 2.4
            self.morphAttract = 0.6
            self.morphNoise = 0.045
            self.morphDrag = 0.88
            self.cycleInterval = 8.0
            self.mouseForceMultiplier = 1.8
        case .cinematic:
            self.timeStep = 0.000004
            self.swarmNoise = 0.02
            self.swarmDrag = 0.97
            self.maxSpeedGlyph = 0.35
            self.maxSpeedPixel = 0.6
            self.morphAttract = 0.12
            self.morphNoise = 0.008
            self.morphDrag = 0.9
            self.cycleInterval = 14.0
            self.mouseForceMultiplier = 0.7
        }

        particles.reserveCapacity(particleCount)
        for _ in 0..<particleCount {
            particles.append(makeParticle())
        }
    }

    // MARK: Frame step

    func advance(to date: Date, bounds size: CGSize, reduceMotion: Bool, isBatteryThrottled: Bool) {
        let now = date.timeIntervalSinceReferenceDate
        if !initialized {
            self.bounds = size
            seedParticlesAcrossBounds()
            nextCycleAt = now + cycleInterval
            initialized = true
        }

        // Resize handling — keep particles inside the new bounds without snapping.
        if size != bounds {
            let sx = size.width / max(bounds.width, 1)
            let sy = size.height / max(bounds.height, 1)
            for i in particles.indices {
                particles[i].x *= sx
                particles[i].y *= sy
                if let tx = particles[i].tx { particles[i].tx = tx * sx }
                if let ty = particles[i].ty { particles[i].ty = ty * sy }
            }
            bounds = size
        }

        // Cycling between swarm and shapes.
        if !reduceMotion, now >= nextCycleAt {
            cycleIndex = (cycleIndex + 1) % modes.count
            assignMode(modes[cycleIndex])
            nextCycleAt = now + cycleInterval
        }

        // Time-driven noise field.
        flowTime += timeStep * 1000.0   // tuned to feel right at 60Hz

        let width = Double(size.width)
        let height = Double(size.height)
        let pointerX = pointer.map { Double($0.x) }
        let pointerY = pointer.map { Double($0.y) }
        let motionFactor = reduceMotion ? 0.0 : 1.0
        let attractFactor = reduceMotion ? 0.04 : 1.0   // small pull so shapes still settle when paused

        for i in particles.indices {
            if isBatteryThrottled && i % 2 == 1 { continue } // Skip 50% of updates on battery
            stepParticle(
                index: i,
                width: width,
                height: height,
                pointerX: pointerX,
                pointerY: pointerY,
                motion: motionFactor,
                attract: attractFactor
            )
        }

        // Advance color transition.
        if colorTransitionProgress < 1.0 {
            let dt = isBatteryThrottled ? (1.0 / 15.0) : (1.0 / 60.0)  // Adapt frame delta
            colorTransitionProgress = min(1.0, colorTransitionProgress + dt / activeTransitionDuration)
        }
    }

    private func stepParticle(
        index i: Int,
        width: Double,
        height: Double,
        pointerX: Double?,
        pointerY: Double?,
        motion: Double,
        attract: Double
    ) {
        var p = particles[i]

        let noiseX = sin(p.y * 0.005 + flowTime * 2) * cos(p.x * 0.003 + flowTime)
        let noiseY = cos(p.x * 0.005 + flowTime * 3) * sin(p.y * 0.003 + flowTime * 2)

        var pushX = 0.0
        var pushY = 0.0
        if let mx = pointerX, let my = pointerY {
            let dx = p.x - mx
            let dy = p.y - my
            let dist = sqrt(dx * dx + dy * dy)
            if dist < 140, dist > 0 {
                let force = (140.0 - dist) / 140.0
                pushX = (dx / dist) * force * mouseForceMultiplier
                pushY = (dy / dist) * force * mouseForceMultiplier
            }
        }

        switch mode {
        case .swarm:
            p.vx += (noiseX * swarmNoise + pushX) * motion
            p.vy += (noiseY * swarmNoise + pushY) * motion
            p.vx *= swarmDrag
            p.vy *= swarmDrag

            let speed = sqrt(p.vx * p.vx + p.vy * p.vy)
            let maxSpeed = p.isGlyph ? maxSpeedGlyph : maxSpeedPixel
            if speed > maxSpeed, speed > 0 {
                p.vx = (p.vx / speed) * maxSpeed
                p.vy = (p.vy / speed) * maxSpeed
            }

            p.x += p.vx
            p.y += p.vy

            if p.x < 0 { p.x = width }
            if p.x > width { p.x = 0 }
            if p.y < 0 { p.y = height }
            if p.y > height { p.y = 0 }

        default:
            // Router-flow re-evaluates target every frame so particles flow.
            if mode == .shapeRouterFlow, let role = p.role {
                let centerX = width * 0.5
                let centerY = height * 0.48
                let scaleFactor = width > 960 ? 0.7 : 0.8
                let scale = min(width, height) * scaleFactor

                if role == "gateway" {
                    let angle = p.colorIndex * .pi * 2 + flowTime * 15
                    p.tx = centerX + (-0.45 + cos(angle) * 0.08) * scale
                    p.ty = centerY + (sin(angle) * 0.08) * scale
                } else if role.hasPrefix("target-") {
                    var tgtY = 0.0
                    if role == "target-1" { tgtY = -0.28 }
                    if role == "target-3" { tgtY = 0.28 }
                    let angle = p.colorIndex * .pi * 2 + flowTime * 12
                    p.tx = centerX + (0.45 + cos(angle) * 0.05) * scale
                    p.ty = centerY + (tgtY + sin(angle) * 0.05) * scale
                } else if role.hasPrefix("path-") {
                    var tgtY = 0.0
                    if role == "path-1" { tgtY = -0.28 }
                    if role == "path-3" { tgtY = 0.28 }
                    p.flowProgress += (pace_isEnergetic ? 0.006 : 0.003)
                    if p.flowProgress > 1.0 { p.flowProgress = 0.0 }
                    let t = p.flowProgress
                    let px = -0.45 + 0.9 * t
                    let py = tgtY * (3 * t * t - 2 * t * t * t)
                    p.tx = centerX + px * scale
                    p.ty = centerY + py * scale
                }
            }

            if let tx = p.tx, let ty = p.ty {
                let dx = tx - p.x
                let dy = ty - p.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist > 1 {
                    p.vx += (dx / dist) * morphAttract * attract
                    p.vy += (dy / dist) * morphAttract * attract
                }
                p.vx += (noiseX * morphNoise + pushX) * motion
                p.vy += (noiseY * morphNoise + pushY) * motion
                p.vx *= morphDrag
                p.vy *= morphDrag
                p.x += p.vx
                p.y += p.vy
            } else {
                // Surplus particles do a gentle ambient swirl.
                p.vx += (noiseX * swarmNoise * 0.75 + pushX) * motion
                p.vy += (noiseY * swarmNoise * 0.75 + pushY) * motion
                p.vx *= swarmDrag
                p.vy *= swarmDrag
                p.x += p.vx
                p.y += p.vy

                if p.x < 0 { p.x = width }
                if p.x > width { p.x = 0 }
                if p.y < 0 { p.y = height }
                if p.y > height { p.y = 0 }
            }
        }

        // Particles that are part of an active shape get a brightness boost
        // so the reformed glyph / rings / router-flow read through any glass
        // cards layered above the swarm.
        let shapeBoost = (mode != .swarm && p.tx != nil) ? 1.7 : 1.0
        p.opacity = min(1.0, p.baseOpacity * shapeBoost)
        particles[i] = p
    }

    // MARK: Draw

    func draw(into ctx: GraphicsContext, size: CGSize, scheme: ColorScheme, isBatteryThrottled: Bool) {
        renderScheme = scheme   // drives the light/dark particle palette in colorFromKey

        if colorDriver != nil {
            // Data-driven path: each particle may have a unique color from the
            // provider palette, so we render individually.
            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let color = resolvedColor(for: p, at: index, isBatteryThrottled: isBatteryThrottled)
                let inShape = (mode != .swarm && p.tx != nil)
                let r = max(0.4, p.size * (inShape ? 1.2 : 0.85))
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(color))
            }
        } else {
            // Original bucket path: batch particles by color key to minimize fill calls.
            var bucketPaths: [Int: Path] = [:]
            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let key = colorKey(for: p)
                var path = bucketPaths[key] ?? Path()
                // Particles forming the active shape render larger so the
                // glyph reads through any glass cards layered on top.
                let inShape = (mode != .swarm && p.tx != nil)
                let r = max(0.4, p.size * (inShape ? 1.2 : 0.85))
                path.addEllipse(in: CGRect(
                    x: p.x - r, y: p.y - r,
                    width: r * 2, height: r * 2
                ))
                bucketPaths[key] = path
            }
            for (key, path) in bucketPaths {
                let baseColor = colorFromKey(key)
                let finalColor = isBatteryThrottled ? baseColor.opacity(0.5) : baseColor
                ctx.fill(path, with: .color(finalColor))
            }
        }

        // Glyphs — relatively few; resolve once per draw.
        for (index, p) in particles.enumerated() where p.isGlyph {
            if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
            let color = resolvedColor(for: p, at: index, isBatteryThrottled: isBatteryThrottled)
            let resolved = ctx.resolve(
                Text(p.glyph)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            )
            ctx.draw(resolved, at: CGPoint(x: p.x, y: p.y), anchor: .center)
        }
    }

    // MARK: Mode transitions

    private func assignMode(_ next: SwarmFormationMode) {
        mode = next
        let shapePoints: [SIMD2<Double>]
        let shapeRoles: [String?]
        let progress: [Double]
        switch next {
        case .swarm:
            for i in particles.indices {
                particles[i].tx = nil
                particles[i].ty = nil
                particles[i].role = nil
            }
            return
        case .shapeDollar:
            shapePoints = dollarPoints.map { SIMD2(Double($0.x), Double($0.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeCode:
            shapePoints = codePoints.map { SIMD2(Double($0.x), Double($0.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeBurnBarLogo:
            shapePoints = burnBarLogoPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = burnBarLogoPoints.map { $0.role }
            progress = burnBarLogoPoints.map { $0.progress }
        case .shapeRings:
            shapePoints = ringPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = Array(repeating: nil, count: shapePoints.count)
            progress = (0..<shapePoints.count).map { _ in Double.random(in: 0...1) }
        case .shapeRouterFlow:
            shapePoints = routerFlowPoints.map { SIMD2(Double($0.point.x), Double($0.point.y)) }
            shapeRoles = routerFlowPoints.map { $0.role }
            progress = routerFlowPoints.map { $0.progress }
        }

        let width = Double(bounds.width)
        let height = Double(bounds.height)
        var centerX = width * 0.5
        var centerY = height * 0.45
        var scaleFactor = 0.35

        if width > 960 {
            // Wide layouts (Mac / iPad): keep shapes off to the side and high,
            // away from the central content columns.
            switch next {
            case .shapeRings:
                centerX = width * 0.78
                centerY = height * 0.30
                scaleFactor = 0.38
            case .shapeBurnBarLogo:
                centerX = width * 0.75
                centerY = height * 0.32
                scaleFactor = 0.30
            case .shapeRouterFlow:
                centerX = width * 0.5
                centerY = height * 0.26
                scaleFactor = 0.6
            default:
                centerX = width * 0.74
                centerY = height * 0.28
                scaleFactor = 0.32
            }
        } else {
            // Phones: cards fill the middle, so present shapes in the emptier
            // upper band beneath the nav bar where they're clearly visible.
            switch next {
            case .shapeRings:
                centerY = height * 0.24
                scaleFactor = 0.34
            case .shapeBurnBarLogo:
                centerY = height * 0.24
                scaleFactor = 0.30
            case .shapeRouterFlow:
                centerX = width * 0.5
                centerY = height * 0.24
                scaleFactor = 0.62
            default:
                centerY = height * 0.22
                scaleFactor = 0.32
            }
        }
        let scale = min(width, height) * scaleFactor

        // Shuffle particle order so assigned points are evenly distributed.
        var indices = Array(particles.indices)
        indices.shuffle()
        for (slot, particleIdx) in indices.enumerated() {
            if slot < shapePoints.count {
                let pt = shapePoints[slot]
                particles[particleIdx].tx = centerX + pt.x * scale
                particles[particleIdx].ty = centerY + pt.y * scale
                particles[particleIdx].role = shapeRoles[slot]
                particles[particleIdx].flowProgress = progress[slot]
            } else {
                particles[particleIdx].tx = nil
                particles[particleIdx].ty = nil
                particles[particleIdx].role = nil
            }
        }
    }

    // MARK: Color

    // Color key encoding: `bucket * 100 + tier`, where `tier` is 0…15 (a full
    // 16-step opacity ramp, max ~0.98) and `bucket` selects the palette color.
    // Buckets 0–3 are the regular palette; 4–8 are router-flow roles; 9–15 are
    // BurnBar logo roles. Using a ×100 stride keeps tiers (<16) from colliding.
    private func colorKey(for p: Particle) -> Int {
        let tier = min(15, max(0, Int(p.opacity * 16)))
        if mode == .shapeRouterFlow, let role = p.role {
            switch role {
            case "gateway":              return 4 * 100 + tier
            case "path-1", "target-1":   return 5 * 100 + tier
            case "path-2", "target-2":   return 6 * 100 + tier
            case "path-3", "target-3":   return 7 * 100 + tier
            default:                     return 8 * 100 + tier
            }
        }
        if mode == .shapeBurnBarLogo, let role = p.role {
            switch role {
            case "logo-flame-inner": return 9 * 100 + tier
            case "logo-flame-outer": return 10 * 100 + tier
            case "logo-flame-spark": return 11 * 100 + tier
            case "logo-bar-1":       return 12 * 100 + tier
            case "logo-bar-2":       return 13 * 100 + tier
            case "logo-bar-3":       return 14 * 100 + tier
            case "logo-bar-4":       return 10 * 100 + tier
            case "logo-bar-5":       return 15 * 100 + tier
            default:                 return 10 * 100 + tier
            }
        }
        return colorBucket(p: p) * 100 + tier
    }

    private func colorBucket(p: Particle) -> Int {
        if p.colorIndex < 0.08 { return 0 }       // whimsy
        if p.colorIndex < 0.35 { return 1 }       // ember
        if p.colorIndex < 0.62 { return 2 }       // amber
        return 3                                   // blaze
    }

    private func colorFromKey(_ key: Int) -> Color {
        let bucket = key / 100
        let tier = key % 100
        // In light mode, lift the opacity floor a touch so the deeper palette
        // still reads against the warm off-white backdrop.
        let base = Double(tier) / 16.0 + 0.04        // ~0.04 … 0.98
        let opacity = renderScheme == .dark ? base : min(1.0, base + 0.08)
        let dark = renderScheme == .dark

        // Dark mode: bright warm embers on near-black. Light mode: deeper,
        // more saturated versions that hold up against the off-white wash.
        let whimsy = dark ? Color(red: 0.50, green: 0.50, blue: 1.00) : Color(red: 0.32, green: 0.30, blue: 0.86)
        let ember  = dark ? Color(red: 0.98, green: 0.42, blue: 0.024) : Color(red: 0.80, green: 0.30, blue: 0.0)
        let amber  = dark ? Color(red: 0.99, green: 0.768, blue: 0.172) : Color(red: 0.78, green: 0.52, blue: 0.0)
        let blaze  = dark ? Color(red: 0.93, green: 0.094, blue: 0.012) : Color(red: 0.74, green: 0.07, blue: 0.0)
        let logoGold = dark ? Color(red: 1.00, green: 0.78, blue: 0.15) : Color(red: 0.80, green: 0.54, blue: 0.00)
        let logoYellow = dark ? Color(red: 1.00, green: 0.64, blue: 0.11) : Color(red: 0.82, green: 0.40, blue: 0.00)
        let logoOrange = dark ? Color(red: 0.96, green: 0.36, blue: 0.04) : Color(red: 0.76, green: 0.22, blue: 0.00)
        let logoRed = dark ? Color(red: 0.90, green: 0.11, blue: 0.08) : Color(red: 0.68, green: 0.06, blue: 0.04)
        let logoCrimson = dark ? Color(red: 0.69, green: 0.07, blue: 0.15) : Color(red: 0.50, green: 0.04, blue: 0.09)

        switch bucket {
        case 0: return whimsy.opacity(opacity)
        case 1: return ember.opacity(opacity)
        case 2: return amber.opacity(opacity)
        case 3: return blaze.opacity(opacity)
        case 4: return whimsy.opacity(min(1.0, opacity * 1.6))   // gateway
        case 5: return blaze.opacity(min(1.0, opacity * 1.5))    // throttled
        case 6: return amber.opacity(min(1.0, opacity * 1.5))    // active backup
        case 7: return ember.opacity(min(1.0, opacity * 1.5))    // standby
        case 9: return logoGold.opacity(min(1.0, opacity * 1.65))
        case 10: return logoOrange.opacity(min(1.0, opacity * 1.55))
        case 11: return logoYellow.opacity(min(1.0, opacity * 1.35))
        case 12: return logoGold.opacity(min(1.0, opacity * 1.45))
        case 13: return logoYellow.opacity(min(1.0, opacity * 1.5))
        case 14: return logoRed.opacity(min(1.0, opacity * 1.5))
        case 15: return logoCrimson.opacity(min(1.0, opacity * 1.6))
        default: return blaze.opacity(opacity * 0.35)            // dim bg
        }
    }

    private func colorFor(particle p: Particle) -> Color {
        colorFromKey(colorKey(for: p))
    }

    private func resolvedColor(for p: Particle, at index: Int, isBatteryThrottled: Bool = false) -> Color {
        // Data-driven color path
        if let driver = colorDriver {
            if let rgba = resolvedDriverRGBA(driver, for: p, at: index) {
                var intensity = driver.intensityMultiplier
                if isBatteryThrottled {
                    intensity *= 0.5 // scale down intensity on battery
                }
                let effectiveOpacity = p.opacity * intensity

                // Smooth transition from previous color
                if colorTransitionProgress < 1.0,
                   index < previousColors.count,
                   let prev = previousColors[index] {
                    let t = colorTransitionProgress
                    let r = prev.r * (1 - t) + rgba.r * t
                    let g = prev.g * (1 - t) + rgba.g * t
                    let b = prev.b * (1 - t) + rgba.b * t
                    return Color(red: r, green: g, blue: b).opacity(effectiveOpacity)
                }

                return Color(red: rgba.r, green: rgba.g, blue: rgba.b).opacity(effectiveOpacity)
            }
        }
        // Fallback to original palette
        let baseColor = colorFromKey(colorKey(for: p))
        if isBatteryThrottled {
            return baseColor.opacity(0.5)
        }
        return baseColor
    }

    private func resolvedDriverRGBA(_ driver: SwarmColorDriver, for p: Particle, at index: Int) -> RGBA? {
        if mode == .shapeBurnBarLogo,
           let role = p.role,
           Self.isLogoFlameRole(role) {
            return driver.resolveFlameTone(
                for: p.colorIndex,
                toneSeed: Self.flameToneSeed(for: p, at: index),
                role: role
            )
        }

        return driver.resolveColor(for: p.colorIndex)
    }

    private static func isLogoFlameRole(_ role: String) -> Bool {
        role.hasPrefix("logo-flame-")
    }

    private static func flameToneSeed(for p: Particle, at index: Int) -> Double {
        let roleShift: Double
        switch p.role {
        case "logo-flame-inner":
            roleShift = 0.31
        case "logo-flame-spark":
            roleShift = 0.67
        default:
            roleShift = 0.13
        }

        let mixed = p.flowProgress * 1.618_033_988_75
            + p.colorIndex * 0.271_828_182_84
            + Double(index % 97) * 0.010_309_278
            + roleShift
        return mixed - floor(mixed)
    }

    // MARK: Color Driver Updates

    /// Updates the color driver and triggers a smooth transition.
    func setColorDriver(_ driver: SwarmColorDriver?) {
        // Snapshot current resolved colors for transition.
        previousColors = particles.enumerated().map { index, p in
            if let d = colorDriver {
                return resolvedDriverRGBA(d, for: p, at: index)
            }
            return nil
        }

        let wasIdle = colorDriver?.mode == .idle || colorDriver == nil
        let nowActive = driver?.mode == .active

        colorDriver = driver
        colorTransitionProgress = 0.0

        // Fast ignition when going idle → active.
        if wasIdle && nowActive {
            activeTransitionDuration = Self.ignitionTransitionDuration
        } else {
            activeTransitionDuration = Self.colorTransitionDuration
        }
    }

    // MARK: Particle init

    private func makeParticle() -> Particle {
        let isGlyph = Double.random(in: 0...1) < 0.08
        return Particle(
            x: Double.random(in: 0...1) * Double(max(bounds.width, 600)),
            y: Double.random(in: 0...1) * Double(max(bounds.height, 600)),
            vx: (Double.random(in: 0...1) - 0.5) * 1.5,
            vy: (Double.random(in: 0...1) - 0.5) * 1.5,
            size: 0.8 + Double.random(in: 0...1) * 1.5,
            isGlyph: isGlyph,
            glyph: glyphs[Int.random(in: 0..<glyphs.count)],
            colorIndex: Double.random(in: 0...1),
            // Slightly brighter than the website (which accumulates trails
            // over a decay overlay we can't replicate in SwiftUI Canvas), but
            // kept restrained so particles read as fine embers, not fat dots.
            baseOpacity: 0.16 + Double.random(in: 0...1) * 0.20,
            opacity: 0.16,
            tx: nil, ty: nil, role: nil,
            flowProgress: Double.random(in: 0...1)
        )
    }

    private func seedParticlesAcrossBounds() {
        for i in particles.indices {
            particles[i].x = Double.random(in: 0...1) * Double(bounds.width)
            particles[i].y = Double.random(in: 0...1) * Double(bounds.height)
        }
    }

    private var pace_isEnergetic: Bool { cycleInterval == 8.0 }

    // MARK: Shape sampling

    private struct ShapePoint {
        let point: CGPoint
        let role: String?
        let progress: Double
    }

    private static func sampleTextPoints(text: String, fontSize: CGFloat) -> [CGPoint] {
        let side = 400
        let bytesPerRow = side
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let font = CTFontCreateWithName("Menlo-Bold" as CFString, fontSize, nil)
        let attrStr = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: CGColor(gray: 1, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attrStr)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(
            x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(side) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return [] }
        let buffer = data.assumingMemoryBound(to: UInt8.self)

        var pts: [CGPoint] = []
        let gap = 6
        for y in stride(from: 0, to: side, by: gap) {
            for x in stride(from: 0, to: side, by: gap) {
                if buffer[y * bytesPerRow + x] > 128 {
                    pts.append(CGPoint(
                        x: CGFloat(x - side / 2) / CGFloat(side / 2),
                        y: -CGFloat(y - side / 2) / CGFloat(side / 2)   // flip Y to match top-left origin
                    ))
                }
            }
        }
        return pts
    }

    private static func generateRingPoints(numRings: Int = 3) -> [ShapePoint] {
        var pts: [ShapePoint] = []
        for ring in 0..<numRings {
            let radius = 0.2 + Double(ring) * 0.25
            let count = 80 + ring * 50
            for i in 0..<count {
                let angle = Double(i) / Double(count) * .pi * 2
                pts.append(ShapePoint(
                    point: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                    role: nil,
                    progress: Double.random(in: 0...1)
                ))
            }
        }
        return pts
    }

    private static func generateRouterFlowPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        // Central gateway node
        let gatewayCount = 100
        for i in 0..<gatewayCount {
            let angle = Double(i) / Double(gatewayCount) * .pi * 2
            let r = 0.08
            pts.append(ShapePoint(
                point: CGPoint(x: -0.45 + cos(angle) * r, y: sin(angle) * r),
                role: "gateway",
                progress: Double(i) / Double(gatewayCount)
            ))
        }
        // Target nodes
        struct Target { let x: Double; let y: Double; let role: String }
        let targets = [
            Target(x: 0.45, y: -0.28, role: "target-1"),
            Target(x: 0.45, y:  0.00, role: "target-2"),
            Target(x: 0.45, y:  0.28, role: "target-3")
        ]
        for tgt in targets {
            let count = 50
            for i in 0..<count {
                let angle = Double(i) / Double(count) * .pi * 2
                let r = 0.05
                pts.append(ShapePoint(
                    point: CGPoint(x: tgt.x + cos(angle) * r, y: tgt.y + sin(angle) * r),
                    role: tgt.role,
                    progress: Double(i) / Double(count)
                ))
            }
        }
        // Bezier connector paths — particles ride these as live request packets.
        for (idx, tgt) in targets.enumerated() {
            let count = 60
            let pathRole = "path-\(idx + 1)"
            for i in 0..<count {
                let t = Double(i) / Double(count)
                let px = -0.45 + (tgt.x - -0.45) * t
                let py = (tgt.y) * (3 * t * t - 2 * t * t * t)
                pts.append(ShapePoint(
                    point: CGPoint(x: px, y: py),
                    role: pathRole,
                    progress: t
                ))
            }
        }
        return pts
    }
}

enum SwarmLogoShape {
    struct Point: Equatable {
        let point: CGPoint
        let role: String
        let progress: Double
    }

    static func generatePoints() -> [Point] {
        var raw: [RawPoint] = []

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 168, y: 5),
                CGPoint(x: 144, y: 30),
                CGPoint(x: 126, y: 65),
                CGPoint(x: 114, y: 98),
                CGPoint(x: 108, y: 82),
                CGPoint(x: 96, y: 78),
                CGPoint(x: 98, y: 96),
                CGPoint(x: 82, y: 124),
                CGPoint(x: 77, y: 108),
                CGPoint(x: 58, y: 130),
                CGPoint(x: 39, y: 162),
                CGPoint(x: 38, y: 185),
                CGPoint(x: 47, y: 209),
                CGPoint(x: 62, y: 230),
                CGPoint(x: 91, y: 248),
                CGPoint(x: 124, y: 253),
                CGPoint(x: 158, y: 247),
                CGPoint(x: 186, y: 231),
                CGPoint(x: 207, y: 204),
                CGPoint(x: 219, y: 166),
                CGPoint(x: 214, y: 135),
                CGPoint(x: 199, y: 107),
                CGPoint(x: 196, y: 123),
                CGPoint(x: 183, y: 139),
                CGPoint(x: 191, y: 145),
                CGPoint(x: 192, y: 150),
                CGPoint(x: 177, y: 126),
                CGPoint(x: 162, y: 88),
                CGPoint(x: 158, y: 52),
                CGPoint(x: 168, y: 5)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-outer"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 166, y: 6),
                CGPoint(x: 147, y: 24),
                CGPoint(x: 132, y: 53),
                CGPoint(x: 124, y: 80),
                CGPoint(x: 121, y: 105),
                CGPoint(x: 110, y: 125),
                CGPoint(x: 96, y: 137),
                CGPoint(x: 82, y: 144),
                CGPoint(x: 74, y: 142),
                CGPoint(x: 73, y: 130),
                CGPoint(x: 80, y: 113),
                CGPoint(x: 64, y: 132),
                CGPoint(x: 51, y: 157),
                CGPoint(x: 48, y: 184),
                CGPoint(x: 50, y: 193)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-inner"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 168, y: 6),
                CGPoint(x: 155, y: 30),
                CGPoint(x: 148, y: 56),
                CGPoint(x: 150, y: 80),
                CGPoint(x: 160, y: 111),
                CGPoint(x: 150, y: 133),
                CGPoint(x: 131, y: 153),
                CGPoint(x: 111, y: 164),
                CGPoint(x: 104, y: 147)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-inner"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 74, y: 113),
                CGPoint(x: 62, y: 128),
                CGPoint(x: 56, y: 145),
                CGPoint(x: 62, y: 151),
                CGPoint(x: 71, y: 151),
                CGPoint(x: 50, y: 178)
            ],
            samplesPerSegment: 3,
            role: "logo-flame-spark"
        )

        appendBar(into: &raw, minX: 58.6, maxX: 84.7, topY: 216.6, bottomY: 248.0, role: "logo-bar-1")
        appendBar(into: &raw, minX: 91.3, maxX: 118.5, topY: 195.2, bottomY: 252.0, role: "logo-bar-2")
        appendBar(into: &raw, minX: 124.9, maxX: 151.5, topY: 176.9, bottomY: 252.0, role: "logo-bar-3")
        appendBar(into: &raw, minX: 157.8, maxX: 185.7, topY: 150.6, bottomY: 246.4, role: "logo-bar-4")
        appendBar(into: &raw, minX: 192.2, maxX: 219.4, topY: 108.0, bottomY: 226.0, role: "logo-bar-5")

        let denominator = max(1, raw.count - 1)
        return raw.enumerated().map { index, point in
            Point(
                point: normalize(point.source),
                role: point.role,
                progress: Double(index) / Double(denominator)
            )
        }
    }

    private struct RawPoint {
        let source: CGPoint
        let role: String
    }

    private static let sourceCenter = CGPoint(x: 128, y: 128)
    private static let sourceScale: CGFloat = 150
    private static let barStep: CGFloat = 13

    private static func normalize(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - sourceCenter.x) / sourceScale,
            y: (point.y - sourceCenter.y) / sourceScale
        )
    }

    private static func appendBar(
        into raw: inout [RawPoint],
        minX: CGFloat,
        maxX: CGFloat,
        topY: CGFloat,
        bottomY: CGFloat,
        role: String
    ) {
        for y in strideValues(from: topY, through: bottomY, by: barStep) {
            for x in strideValues(from: minX, through: maxX, by: barStep) {
                raw.append(RawPoint(source: CGPoint(x: x, y: y), role: role))
            }
        }
    }

    private static func appendCatmullRom(
        into raw: inout [RawPoint],
        controls: [CGPoint],
        samplesPerSegment: Int,
        role: String
    ) {
        guard controls.count >= 2 else { return }
        let samples = max(1, samplesPerSegment)
        for index in 0..<(controls.count - 1) {
            let p0 = controls[max(0, index - 1)]
            let p1 = controls[index]
            let p2 = controls[index + 1]
            let p3 = controls[min(controls.count - 1, index + 2)]
            for sample in 0..<samples {
                let t = CGFloat(sample) / CGFloat(samples)
                raw.append(RawPoint(source: catmullRom(p0, p1, p2, p3, t: t), role: role))
            }
        }
        raw.append(RawPoint(source: controls[controls.count - 1], role: role))
    }

    private static func catmullRom(
        _ p0: CGPoint,
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let x = 0.5 * (
            (2 * p1.x)
            + (-p0.x + p2.x) * t
            + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
            + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y)
            + (-p0.y + p2.y) * t
            + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
            + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )
        return CGPoint(x: x, y: y)
    }

    private static func strideValues(from start: CGFloat, through end: CGFloat, by step: CGFloat) -> [CGFloat] {
        var values: [CGFloat] = []
        var current = start
        while current <= end {
            values.append(current)
            current += step
        }
        if values.last != end {
            values.append(end)
        }
        return values
    }
}

#Preview {
    SwarmCanvasView(accent: .orange)
        .frame(width: 800, height: 600)
}
