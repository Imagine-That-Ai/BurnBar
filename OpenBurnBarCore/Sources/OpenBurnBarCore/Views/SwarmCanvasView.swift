import SwiftUI
import CoreGraphics
import CoreText
#if canImport(AppKit)
import AppKit
#endif
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
    public let backdropColors: [Color]?
    public let colorPalette: SwarmColorPalette
    public let motionSpeedMultiplier: Double
    public let enabledProviderGlyphs: [AgentProvider]

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
        backdropColor: Color? = nil,
        backdropColors: [Color]? = nil,
        colorPalette: SwarmColorPalette = .defaultEmber,
        motionSpeedMultiplier: Double = 1.0,
        enabledProviderGlyphs: [AgentProvider]? = nil
    ) {
        let normalizedProviderGlyphs = enabledProviderGlyphs.map(SwarmProviderGlyphSelection.normalized) ?? SwarmProviderGlyphSelection.allProviders

        self.accent = accent
        self.pace = pace
        self.particleCount = particleCount ?? Self.adaptiveParticleCount
        self.colorDriver = colorDriver
        self.isBatteryThrottled = isBatteryThrottled
        self.externalPointer = externalPointer
        self.isTransparent = isTransparent
        self.backdropColor = backdropColor
        self.backdropColors = backdropColors
        self.colorPalette = colorPalette
        self.motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
        self.enabledProviderGlyphs = normalizedProviderGlyphs

        let sim = SwarmSimulation(
            particleCount: particleCount ?? Self.adaptiveParticleCount,
            pace: pace,
            enabledProviderGlyphs: normalizedProviderGlyphs
        )
        sim.colorPalette = colorPalette
        sim.motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
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
        .drawingGroup(opaque: false, colorMode: .nonLinear)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onChange(of: colorDriver) {
            simulation.setColorDriver(colorDriver)
        }
        .onChange(of: externalPointer) {
            simulation.pointer = externalPointer
        }
        .onChange(of: colorPalette) {
            simulation.colorPalette = colorPalette
        }
        .onChange(of: motionSpeedMultiplier) {
            simulation.motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
        }
        .onChange(of: enabledProviderGlyphs) {
            simulation.setEnabledProviderGlyphs(enabledProviderGlyphs)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleSwarmShapeRequested)) { _ in
            simulation.forceCycleShape()
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        // Match the app's appearance so the swarm stays coherent with the
        // themed cards layered on top (dark backdrop in dark mode, soft warm
        // off-white in light mode). The particle palette adapts to match.
        if isTransparent {
            Rectangle()
                .fill(Color.clear)
                .ignoresSafeArea()
        } else if let backdropColors, backdropColors.count > 1 {
            LinearGradient(
                colors: backdropColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05))
            .ignoresSafeArea()
        } else {
            Rectangle()
                .fill(backdropColor ?? (colorScheme == .dark
                    ? Color(red: 0.020, green: 0.020, blue: 0.031)
                    : Color(red: 0.953, green: 0.937, blue: 0.906)))
                .ignoresSafeArea()
        }
    }

    /// Adaptive particle budget: more on macOS / iPad, fewer on iPhone, and
    /// further reduced under Low Power Mode.
    public static var adaptiveParticleCount: Int {
        #if os(macOS)
        let base = 1800
        #else
        let base: Int = {
            if UIDevice.current.userInterfaceIdiom == .pad { return 1080 }
            return 520
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
    case shapeProviderLogo([AgentProvider])
    case shapeGrok

    static let showcaseProviders: [AgentProvider] = AgentProvider.swarmGlyphProviders

    static var providerLogoGroups: [[AgentProvider]] {
        providerLogoGroups(for: showcaseProviders)
    }

    static var defaultCycle: [SwarmFormationMode] {
        defaultCycle(for: showcaseProviders)
    }

    static var inspectionCycle: [SwarmFormationMode] {
        inspectionCycle(for: showcaseProviders)
    }

    static func providerLogoGroups(for providers: [AgentProvider]) -> [[AgentProvider]] {
        grouped(SwarmProviderGlyphSelection.normalized(providers), size: 6)
    }

    static func defaultCycle(for providers: [AgentProvider]) -> [SwarmFormationMode] {
        let enabledProviders = SwarmProviderGlyphSelection.normalized(providers)
        let providerCycle = providerLogoGroups(for: enabledProviders).flatMap { group in
            [
                SwarmFormationMode.swarm,
                SwarmFormationMode.shapeProviderLogo(group)
            ]
        }
        let grokCycle: [SwarmFormationMode] = enabledProviders.contains(.xAI)
            ? [.swarm, .shapeGrok]
            : []

        return [
            .swarm,
            .shapeDollar,
            .swarm,
            .shapeCode,
            .swarm,
            .shapeBurnBarLogo
        ] + providerCycle + grokCycle + [
            .swarm,
            .shapeRings,
            .swarm,
            .shapeRouterFlow
        ]
    }

    static func inspectionCycle(for providers: [AgentProvider]) -> [SwarmFormationMode] {
        let enabledProviders = SwarmProviderGlyphSelection.normalized(providers)
        let grokCycle: [SwarmFormationMode] = enabledProviders.contains(.xAI) ? [.shapeGrok] : []

        return [
            .swarm,
            .shapeDollar,
            .shapeCode,
            .shapeBurnBarLogo,
            .shapeRings,
            .shapeRouterFlow
        ] + enabledProviders.map { provider in
            .shapeProviderLogo([provider])
        } + grokCycle + providerLogoGroups(for: enabledProviders).map { group in
            .shapeProviderLogo(group)
        }
    }

    var requiresSettledAdmireHold: Bool {
        switch self {
        case .shapeDollar, .shapeCode, .shapeBurnBarLogo, .shapeRings, .shapeProviderLogo(_), .shapeGrok:
            return true
        case .swarm, .shapeRouterFlow:
            return false
        }
    }

    private static func grouped(_ providers: [AgentProvider], size: Int) -> [[AgentProvider]] {
        guard size > 0 else { return [] }
        var groups: [[AgentProvider]] = []
        var index = 0
        while index < providers.count {
            groups.append(Array(providers[index..<min(index + size, providers.count)]))
            index += size
        }
        return groups
    }
}

@MainActor
private final class SwarmSimulation {
    private struct ProviderLogoSlot {
        let centerX: Double
        let centerY: Double
        let scale: Double
    }


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
        var logoColor: RGBA?            // source logo pixel color for asset-derived provider marks
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
    private var enabledProviderGlyphs: [AgentProvider]
    private var modes: [SwarmFormationMode]

    private var particles: [Particle] = []
    private var mode: SwarmFormationMode = .swarm
    private var cycleIndex: Int = 0
    private var nextCycleAt: TimeInterval = 0
    private var flowTime: Double = 0
    private var bounds: CGSize = .zero
    private var initialized = false
    private var modeAssignedAt: TimeInterval = 0
    private var shapeSettledAt: TimeInterval?
    private var renderScheme: ColorScheme = .dark

    private lazy var dollarPoints = SwarmSimulation.sampleTextPoints(text: "$", fontSize: 280)
    private lazy var codePoints = SwarmSimulation.sampleTextPoints(text: "</>", fontSize: 220)
    private lazy var burnBarLogoPoints = SwarmLogoShape.generatePoints()
    private lazy var ringPoints = SwarmSimulation.generateRingPoints()
    private lazy var routerFlowPoints = SwarmSimulation.generateRouterFlowPoints()

    private lazy var providerLogoPointCache: [AgentProvider: [ShapePoint]] = {
        Dictionary(uniqueKeysWithValues: SwarmFormationMode.showcaseProviders.map { provider in
            (
                provider,
                SwarmSimulation.logoPoints(
                    for: provider,
                    fallback: SwarmSimulation.fallbackLogoPoints(for: provider)
                )
            )
        })
    }()
    private lazy var xAILogoPoints = SwarmSimulation.generateXAILogoPoints()
    private lazy var grokLogoPoints = SwarmSimulation.logoPoints(named: ["GrokLogo", "xAILogo"], fallback: SwarmSimulation.generateGrokLogoPoints())

    var pointer: CGPoint?
    var motionSpeedMultiplier: Double = 1.0 {
        didSet {
            motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
            shouldResetCycleTimer = true
        }
    }

    // MARK: Color Driver State
    var colorPalette: SwarmColorPalette = .defaultEmber
    private var shouldResetCycleTimer = false
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
    private static let shapeAdmireHoldDuration: TimeInterval = 4.0
    private static let shapeSettleRecheckInterval: TimeInterval = 0.25
    private static let shapeSettleFallbackDelay: TimeInterval = 6.0
    private static let shapeSettledParticleFraction: Double = 0.82

    init(
        particleCount: Int,
        pace: SwarmCanvasView.Pace,
        enabledProviderGlyphs: [AgentProvider]
    ) {
        let normalizedProviderGlyphs = SwarmProviderGlyphSelection.normalized(enabledProviderGlyphs)
        self.enabledProviderGlyphs = normalizedProviderGlyphs
        self.modes = SwarmFormationMode.defaultCycle(for: normalizedProviderGlyphs)

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
            modeAssignedAt = now
            if mode != .swarm {
                assignMode(mode, at: now)
            }
            nextCycleAt = now + effectiveCycleInterval
            initialized = true
        }

        if shouldResetCycleTimer {
            nextCycleAt = now + effectiveCycleInterval
            shouldResetCycleTimer = false
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
        if !reduceMotion, colorDriver?.mode != .active, now >= nextCycleAt {
            if shouldDelayCycleForAdmireHold(now: now) {
                nextCycleAt = now + Self.shapeSettleRecheckInterval
            } else {
                cycleIndex = (cycleIndex + 1) % modes.count
                assignMode(modes[cycleIndex], at: now)
                nextCycleAt = now + effectiveCycleInterval
            }
        }

        // Time-driven noise field.
        flowTime += timeStep * 1000.0 * motionSpeedMultiplier   // tuned to feel right at 60Hz

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
            p.vx += (noiseX * swarmNoise * motionSpeedMultiplier + pushX) * motion
            p.vy += (noiseY * swarmNoise * motionSpeedMultiplier + pushY) * motion
            p.vx *= swarmDrag
            p.vy *= swarmDrag

            let speed = sqrt(p.vx * p.vx + p.vy * p.vy)
            let maxSpeed = (p.isGlyph ? maxSpeedGlyph : maxSpeedPixel) * motionSpeedMultiplier
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
                    p.flowProgress += (pace_isEnergetic ? 0.006 : 0.003) * motionSpeedMultiplier
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
                    p.vx += (dx / dist) * morphAttract * attract * motionSpeedMultiplier
                    p.vy += (dy / dist) * morphAttract * attract * motionSpeedMultiplier
                }
                p.vx += (noiseX * morphNoise * motionSpeedMultiplier + pushX) * motion
                p.vy += (noiseY * morphNoise * motionSpeedMultiplier + pushY) * motion
                p.vx *= morphDrag
                p.vy *= morphDrag
                p.x += p.vx
                p.y += p.vy
            } else {
                // Surplus particles do a gentle ambient swirl.
                p.vx += (noiseX * swarmNoise * 0.75 * motionSpeedMultiplier + pushX) * motion
                p.vy += (noiseY * swarmNoise * 0.75 * motionSpeedMultiplier + pushY) * motion
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

        let shouldRenderIndividually: Bool = {
            if colorDriver != nil { return true }
            if case .shapeProviderLogo = mode { return true }
            return false
        }()

        if shouldRenderIndividually {
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
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            )
            ctx.draw(resolved, at: CGPoint(x: p.x, y: p.y), anchor: .center)
        }
    }

    // MARK: Mode transitions

    private func assignMode(_ next: SwarmFormationMode, at assignedAt: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        mode = next
        modeAssignedAt = assignedAt
        shapeSettledAt = nil
        let shapePoints: [SIMD2<Double>]
        let shapeRoles: [String?]
        let progress: [Double]
        switch next {
        case .swarm:
            for i in particles.indices {
                particles[i].tx = nil
                particles[i].ty = nil
                particles[i].role = nil
                particles[i].logoColor = nil
            }
            return
        case .shapeProviderLogo(let providers):
            let specs = providers.map { provider in (provider: provider, points: providerLogoPoints(for: provider)) }
            assignProviderLogoFormation(specs)
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
        case .shapeGrok:
            assignProviderLogoFormation([(provider: .xAI, points: grokLogoPoints)])
            return
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
                particles[particleIdx].logoColor = nil
                particles[particleIdx].flowProgress = progress[slot]
            } else {
                particles[particleIdx].tx = nil
                particles[particleIdx].ty = nil
                particles[particleIdx].role = nil
                particles[particleIdx].logoColor = nil
            }
        }
    }

    private func providerLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        if provider == .xAI {
            return xAILogoPoints
        }
        return providerLogoPointCache[provider] ?? SwarmSimulation.logoPoints(
            for: provider,
            fallback: SwarmSimulation.fallbackLogoPoints(for: provider)
        )
    }

    private func assignProviderLogoFormation(_ specs: [(provider: AgentProvider, points: [ShapePoint])]) {
        let visibleSpecs = specs.filter { !$0.points.isEmpty }
        let count = visibleSpecs.count
        guard count > 0 else {
            for i in particles.indices {
                particles[i].tx = nil
                particles[i].ty = nil
                particles[i].role = nil
                particles[i].logoColor = nil
            }
            return
        }

        var groups: [[Int]] = Array(repeating: [], count: count)
        var indices = Array(particles.indices)
        indices.shuffle()
        for (slot, idx) in indices.enumerated() {
            groups[slot % count].append(idx)
        }

        let width = Double(bounds.width)
        let height = Double(bounds.height)
        let slots = Self.providerLogoSlots(count: count, width: width, height: height)

        for specIndex in 0..<count {
            let spec = visibleSpecs[specIndex]
            let logoSlot = slots[specIndex]
            let groupParticles = groups[specIndex]
            for (slot, particleIdx) in groupParticles.enumerated() {
                let pointIndex: Int
                if groupParticles.count <= spec.points.count {
                    let t = Double(slot) / Double(max(groupParticles.count - 1, 1))
                    pointIndex = min(spec.points.count - 1, Int((Double(spec.points.count - 1) * t).rounded()))
                } else {
                    pointIndex = slot % spec.points.count
                }
                let pt = spec.points[pointIndex]
                particles[particleIdx].tx = logoSlot.centerX + Double(pt.point.x) * logoSlot.scale
                particles[particleIdx].ty = logoSlot.centerY + Double(pt.point.y) * logoSlot.scale
                particles[particleIdx].isGlyph = false
                particles[particleIdx].logoColor = pt.logoColor

                let providerSuffix = ":\(spec.provider.persistedToken)"
                particles[particleIdx].role = (pt.role ?? "logo-flame-inner") + providerSuffix
                particles[particleIdx].flowProgress = pt.progress
            }
        }
    }

    private func shouldDelayCycleForAdmireHold(now: TimeInterval) -> Bool {
        guard mode.requiresSettledAdmireHold else { return false }

        if shapeSettledAt == nil {
            if currentShapeIsSettled()
                || now - modeAssignedAt >= effectiveCycleInterval + Self.shapeSettleFallbackDelay {
                shapeSettledAt = now
            } else {
                return true
            }
        }

        guard let settledAt = shapeSettledAt else { return true }
        return now < settledAt + Self.shapeAdmireHoldDuration
    }

    private func currentShapeIsSettled() -> Bool {
        let threshold = max(22.0, Double(min(bounds.width, bounds.height)) * 0.022)
        var targeted = 0
        var close = 0
        var totalDistance = 0.0

        for particle in particles {
            guard let tx = particle.tx, let ty = particle.ty else { continue }
            targeted += 1
            let distance = hypot(tx - particle.x, ty - particle.y)
            totalDistance += distance
            if distance <= threshold {
                close += 1
            }
        }

        guard targeted > 0 else { return true }
        let closeFraction = Double(close) / Double(targeted)
        let averageDistance = totalDistance / Double(targeted)
        return closeFraction >= Self.shapeSettledParticleFraction
            && averageDistance <= threshold * 1.75
    }

    // MARK: Color

    // Color key encoding: `bucket * 100 + tier`, where `tier` is 0…15 (a full
    // 16-step opacity ramp, max ~0.98) and `bucket` selects the palette color.
    // Buckets 0–3 are the regular palette; 4–8 are router-flow roles; 9–15 are
    // BurnBar logo roles. Using a ×100 stride keeps tiers (<16) from colliding.
    private func colorKey(for p: Particle) -> Int {
        let tier = min(15, max(0, Int(p.opacity * 16)))
        if case .shapeProviderLogo = mode, let rawRole = p.role {
            let (role, _) = Self.parseRoleAndProvider(rawRole)
            switch role {
            case "logo-flame-inner": return 9 * 100 + tier
            case "logo-flame-outer": return 10 * 100 + tier
            case "logo-flame-spark": return 11 * 100 + tier
            default:                 return 9 * 100 + tier
            }
        }
        if mode == .shapeRouterFlow, let role = p.role {
            switch role {
            case "gateway":              return 4 * 100 + tier
            case "path-1", "target-1":   return 5 * 100 + tier
            case "path-2", "target-2":   return 6 * 100 + tier
            case "path-3", "target-3":   return 7 * 100 + tier
            default:                     return 8 * 100 + tier
            }
        }
        if (mode == .shapeBurnBarLogo || mode == .shapeGrok), let role = p.role {
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

    private func rgbaFromKey(_ key: Int) -> RGBA {
        let bucket = key / 100
        let tier = key % 100
        // In light mode, lift the opacity floor a touch so the deeper palette
        // still reads against the warm off-white backdrop.
        let base = Double(tier) / 16.0 + 0.04        // ~0.04 … 0.98
        let opacity = renderScheme == .dark ? base : min(1.0, base + 0.08)
        let dark = renderScheme == .dark

        let whimsy: RGBA
        let ember: RGBA
        let amber: RGBA
        let blaze: RGBA

        let logoGold: RGBA
        let logoYellow: RGBA
        let logoOrange: RGBA
        let logoRed: RGBA
        let logoCrimson: RGBA

        switch colorPalette {
        case .defaultEmber:
            whimsy = dark ? RGBA(r: 0.50, g: 0.50, b: 1.00, a: opacity) : RGBA(r: 0.32, g: 0.30, b: 0.86, a: opacity)
            ember  = dark ? RGBA(r: 0.98, g: 0.42, b: 0.024, a: opacity) : RGBA(r: 0.80, g: 0.30, b: 0.0, a: opacity)
            amber  = dark ? RGBA(r: 0.99, g: 0.768, b: 0.172, a: opacity) : RGBA(r: 0.78, g: 0.52, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.93, g: 0.094, b: 0.012, a: opacity) : RGBA(r: 0.74, g: 0.07, b: 0.0, a: opacity)

            logoGold = dark ? RGBA(r: 1.00, g: 0.78, b: 0.15, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.80, g: 0.54, b: 0.00, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.00, g: 0.64, b: 0.11, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.82, g: 0.40, b: 0.00, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.96, g: 0.36, b: 0.04, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.76, g: 0.22, b: 0.00, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.90, g: 0.11, b: 0.08, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.68, g: 0.06, b: 0.04, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.69, g: 0.07, b: 0.15, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.50, g: 0.04, b: 0.09, a: min(1.0, opacity * 1.6))

        case .auroraTeal:
            whimsy = dark ? RGBA(r: 0.54, g: 0.17, b: 0.89, a: opacity) : RGBA(r: 0.44, g: 0.07, b: 0.79, a: opacity)
            ember  = dark ? RGBA(r: 0.0, g: 0.5, b: 0.5, a: opacity) : RGBA(r: 0.0, g: 0.4, b: 0.4, a: opacity)
            amber  = dark ? RGBA(r: 0.0, g: 0.96, b: 1.0, a: opacity) : RGBA(r: 0.0, g: 0.76, b: 0.80, a: opacity)
            blaze  = dark ? RGBA(r: 0.0, g: 1.0, b: 0.5, a: opacity) : RGBA(r: 0.0, g: 0.8, b: 0.4, a: opacity)

            logoGold = dark ? RGBA(r: 0.0, g: 1.0, b: 0.64, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.0, g: 0.8, b: 0.50, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.0, g: 0.96, b: 1.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.0, g: 0.76, b: 0.80, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.0, g: 0.42, b: 0.42, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.0, g: 0.32, b: 0.32, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.64, g: 0.40, b: 1.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.50, g: 0.30, b: 0.86, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.42, g: 0.0, b: 0.7, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.32, g: 0.0, b: 0.56, a: min(1.0, opacity * 1.6))

        case .sunsetCrimson:
            whimsy = dark ? RGBA(r: 0.29, g: 0.0, b: 0.51, a: opacity) : RGBA(r: 0.22, g: 0.0, b: 0.41, a: opacity)
            ember  = dark ? RGBA(r: 1.0, g: 0.08, b: 0.58, a: opacity) : RGBA(r: 0.8, g: 0.04, b: 0.46, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.27, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.18, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.7, g: 0.13, b: 0.13, a: opacity) : RGBA(r: 0.56, g: 0.08, b: 0.08, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 0.67, b: 0.2, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.8, g: 0.51, b: 0.1, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.0, g: 0.77, b: 0.62, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.8, g: 0.59, b: 0.46, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 1.0, g: 0.2, b: 0.5, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.8, g: 0.12, b: 0.38, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.49, g: 0.15, b: 0.8, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.38, g: 0.08, b: 0.64, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.5, g: 0.0, b: 0.12, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.38, g: 0.0, b: 0.08, a: min(1.0, opacity * 1.6))

        case .cyberpunkViolet:
            whimsy = dark ? RGBA(r: 0.0, g: 0.9, b: 1.0, a: opacity) : RGBA(r: 0.0, g: 0.7, b: 0.8, a: opacity)
            ember  = dark ? RGBA(r: 0.58, g: 0.0, b: 0.83, a: opacity) : RGBA(r: 0.46, g: 0.0, b: 0.68, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.0, b: 1.0, a: opacity) : RGBA(r: 0.8, g: 0.0, b: 0.8, a: opacity)
            blaze  = dark ? RGBA(r: 1.0, g: 0.0, b: 0.5, a: opacity) : RGBA(r: 0.8, g: 0.0, b: 0.38, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 0.0, b: 0.5, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.8, g: 0.0, b: 0.38, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.0, g: 1.0, b: 1.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.0, g: 0.8, b: 0.8, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.54, g: 0.0, b: 1.0, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.42, g: 0.0, b: 0.8, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 1.0, g: 0.0, b: 1.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.8, g: 0.0, b: 0.8, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.0, g: 0.0, b: 0.54, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.0, g: 0.0, b: 0.42, a: min(1.0, opacity * 1.6))

        case .forestMoss:
            whimsy = dark ? RGBA(r: 0.56, g: 0.74, b: 0.56, a: opacity) : RGBA(r: 0.46, g: 0.62, b: 0.46, a: opacity)
            ember  = dark ? RGBA(r: 0.13, g: 0.55, b: 0.13, a: opacity) : RGBA(r: 0.08, g: 0.44, b: 0.08, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.75, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.6, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 0.82, g: 0.41, b: 0.12, a: opacity) : RGBA(r: 0.68, g: 0.32, b: 0.08, a: opacity)

            logoGold = dark ? RGBA(r: 0.85, g: 0.65, b: 0.13, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.68, g: 0.51, b: 0.08, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 0.68, g: 1.0, b: 0.18, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.54, g: 0.8, b: 0.1, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 0.72, g: 0.45, b: 0.2, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.58, g: 0.35, b: 0.14, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.0, g: 0.39, b: 0.0, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.0, g: 0.3, b: 0.0, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.29, g: 0.02, b: 0.02, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.22, g: 0.01, b: 0.01, a: min(1.0, opacity * 1.6))

        case .solarFlare:
            whimsy = dark ? RGBA(r: 1.0, g: 0.97, b: 0.86, a: opacity) : RGBA(r: 0.9, g: 0.87, b: 0.76, a: opacity)
            ember  = dark ? RGBA(r: 1.0, g: 0.84, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.67, b: 0.0, a: opacity)
            amber  = dark ? RGBA(r: 1.0, g: 0.55, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.44, b: 0.0, a: opacity)
            blaze  = dark ? RGBA(r: 1.0, g: 0.19, b: 0.0, a: opacity) : RGBA(r: 0.8, g: 0.12, b: 0.0, a: opacity)

            logoGold = dark ? RGBA(r: 1.0, g: 1.0, b: 0.88, a: min(1.0, opacity * 1.65)) : RGBA(r: 0.88, g: 0.88, b: 0.76, a: min(1.0, opacity * 1.65))
            logoYellow = dark ? RGBA(r: 1.0, g: 0.84, b: 0.0, a: min(1.0, opacity * 1.35)) : RGBA(r: 0.8, g: 0.67, b: 0.0, a: min(1.0, opacity * 1.35))
            logoOrange = dark ? RGBA(r: 1.0, g: 0.27, b: 0.0, a: min(1.0, opacity * 1.55)) : RGBA(r: 0.8, g: 0.18, b: 0.0, a: min(1.0, opacity * 1.55))
            logoRed = dark ? RGBA(r: 0.86, g: 0.08, b: 0.24, a: min(1.0, opacity * 1.5)) : RGBA(r: 0.68, g: 0.04, b: 0.18, a: min(1.0, opacity * 1.5))
            logoCrimson = dark ? RGBA(r: 0.36, g: 0.0, b: 0.0, a: min(1.0, opacity * 1.6)) : RGBA(r: 0.26, g: 0.0, b: 0.0, a: min(1.0, opacity * 1.6))
        }

        switch bucket {
        case 0: return whimsy
        case 1: return ember
        case 2: return amber
        case 3: return blaze
        case 4: return RGBA(r: whimsy.r, g: whimsy.g, b: whimsy.b, a: min(1.0, opacity * 1.6))   // gateway
        case 5: return RGBA(r: blaze.r, g: blaze.g, b: blaze.b, a: min(1.0, opacity * 1.5))    // throttled
        case 6: return RGBA(r: amber.r, g: amber.g, b: amber.b, a: min(1.0, opacity * 1.5))    // active backup
        case 7: return RGBA(r: ember.r, g: ember.g, b: ember.b, a: min(1.0, opacity * 1.5))    // standby
        case 9: return logoGold
        case 10: return logoOrange
        case 11: return logoYellow
        case 12: return RGBA(r: logoGold.r, g: logoGold.g, b: logoGold.b, a: min(1.0, opacity * 1.45))
        case 13: return RGBA(r: logoYellow.r, g: logoYellow.g, b: logoYellow.b, a: min(1.0, opacity * 1.5))
        case 14: return logoRed
        case 15: return logoCrimson
        default: return RGBA(r: blaze.r, g: blaze.g, b: blaze.b, a: opacity * 0.35)            // dim bg
        }
    }

    private func colorFromKey(_ key: Int) -> Color {
        rgbaFromKey(key).color
    }

    private func colorFor(particle p: Particle) -> Color {
        colorFromKey(colorKey(for: p))
    }

    private func resolvedColor(for p: Particle, at index: Int, isBatteryThrottled: Bool = false) -> Color {
        if let providerLogoRGBA = resolvedProviderLogoRGBA(for: p, at: index) {
            var intensity = 1.0
            if let driver = colorDriver, driver.mode == .active {
                intensity = driver.intensityMultiplier
            }
            if isBatteryThrottled {
                intensity *= 0.5
            }
            return Color(
                red: providerLogoRGBA.r,
                green: providerLogoRGBA.g,
                blue: providerLogoRGBA.b
            )
            .opacity(providerLogoRGBA.a * intensity)
        }

        // Data-driven color path (active session only)
        if let driver = colorDriver, driver.mode == .active {
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

        // Fallback to original palette (when idle or driver nil)
        let fallbackRGBA = rgbaFromKey(colorKey(for: p))
        var intensity = 1.0
        if isBatteryThrottled {
            intensity *= 0.5
        }

        // Smooth transition from previous color (if transitioning back to idle)
        if colorTransitionProgress < 1.0,
           index < previousColors.count,
           let prev = previousColors[index] {
            let t = colorTransitionProgress
            let r = prev.r * (1 - t) + fallbackRGBA.r * t
            let g = prev.g * (1 - t) + fallbackRGBA.g * t
            let b = prev.b * (1 - t) + fallbackRGBA.b * t
            return Color(red: r, green: g, blue: b).opacity(fallbackRGBA.a * intensity)
        }

        return Color(red: fallbackRGBA.r, green: fallbackRGBA.g, blue: fallbackRGBA.b).opacity(fallbackRGBA.a * intensity)
    }

    private func resolvedDriverRGBA(_ driver: SwarmColorDriver, for p: Particle, at index: Int) -> RGBA? {
        if let providerLogoRGBA = resolvedProviderLogoRGBA(for: p, at: index) {
            return providerLogoRGBA
        }

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
        let cleanRole = p.role.map { parseRoleAndProvider($0).role } ?? ""
        switch cleanRole {
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

    func setEnabledProviderGlyphs(_ providers: [AgentProvider]) {
        let normalizedProviders = SwarmProviderGlyphSelection.normalized(providers)
        guard normalizedProviders != enabledProviderGlyphs else { return }

        enabledProviderGlyphs = normalizedProviders
        modes = SwarmFormationMode.defaultCycle(for: normalizedProviders)
        cycleIndex = min(cycleIndex, max(0, modes.count - 1))

        if colorDriver?.mode == .active {
            let activeProvidersList = filteredEnabledProviders(colorDriver?.activeProviders ?? [])
            assignMode(activeProvidersList.isEmpty ? .swarm : .shapeProviderLogo(activeProvidersList))
        } else if case .shapeProviderLogo(let providers) = mode {
            let visibleProviders = filteredEnabledProviders(providers)
            assignMode(visibleProviders.isEmpty ? .swarm : .shapeProviderLogo(visibleProviders))
        } else if mode == .shapeGrok, !normalizedProviders.contains(.xAI) {
            assignMode(.swarm)
        }

        shouldResetCycleTimer = true
    }

    /// Updates the color driver and triggers a smooth transition.
    func setColorDriver(_ driver: SwarmColorDriver?) {
        // Snapshot current resolved colors for transition.
        previousColors = particles.enumerated().map { index, p in
            if let d = colorDriver, d.mode == .active {
                return resolvedDriverRGBA(d, for: p, at: index)
            } else {
                return rgbaFromKey(colorKey(for: p))
            }
        }

        let wasActive = colorDriver?.mode == .active
        let wasIdle = colorDriver?.mode == .idle || colorDriver == nil
        let nowActive = driver?.mode == .active

        let activeProvidersList = filteredEnabledProviders(driver?.activeProviders ?? [])

        colorDriver = driver
        colorTransitionProgress = 0.0

        // Fast ignition when going idle → active.
        if wasIdle && nowActive {
            activeTransitionDuration = Self.ignitionTransitionDuration
        } else {
            activeTransitionDuration = Self.colorTransitionDuration
        }

        // Shape morph control
        if nowActive {
            assignMode(activeProvidersList.isEmpty ? .swarm : .shapeProviderLogo(activeProvidersList))
        } else if wasActive && !nowActive {
            // Revert back to swarm when cooling down to idle
            assignMode(.swarm)
            cycleIndex = 0
            shouldResetCycleTimer = true
        }
    }

    func forceCycleShape() {
        let inspectionCycle = SwarmFormationMode.inspectionCycle(for: enabledProviderGlyphs)
        guard !inspectionCycle.isEmpty else { return }

        let currentIdx = inspectionCycle.firstIndex(where: { $0 == mode }) ?? -1
        let nextIdx = (currentIdx + 1) % inspectionCycle.count
        assignMode(inspectionCycle[nextIdx])

        // Reset the auto-cycling timer so the shape stays for visual inspection
        shouldResetCycleTimer = true
    }

    private func filteredEnabledProviders(_ providers: [AgentProvider]) -> [AgentProvider] {
        let enabled = Set(enabledProviderGlyphs)
        guard !enabled.isEmpty else { return [] }

        var seen = Set<AgentProvider>()
        return providers.filter { provider in
            enabled.contains(provider) && seen.insert(provider).inserted
        }
    }

    private static func providerLogoSlots(count: Int, width: Double, height: Double) -> [ProviderLogoSlot] {
        guard count > 0 else { return [] }

        if count == 1 {
            return [
                ProviderLogoSlot(
                    centerX: width > 960 ? width * 0.74 : width * 0.5,
                    centerY: width > 960 ? height * 0.30 : height * 0.24,
                    scale: min(width, height) * 0.34
                )
            ]
        }

        let maxColumns: Int
        if width >= 1320 {
            maxColumns = 5
        } else if width >= 920 {
            maxColumns = 4
        } else {
            maxColumns = 2
        }
        let columns = min(count, maxColumns)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let xStep = min(300.0, max(180.0, width * 0.78 / Double(max(columns - 1, 1))))
        let yStep = min(210.0, max(130.0, height * 0.44 / Double(max(rows - 1, 1))))
        let gridHeight = yStep * Double(max(rows - 1, 0))
        let gridCenterY = height * (rows > 1 ? 0.40 : 0.34)
        let scale = min(
            min(width, height) * 0.32,
            max(110.0, min(xStep, rows > 1 ? yStep : height * 0.32) * 0.72)
        )

        var slots: [ProviderLogoSlot] = []
        slots.reserveCapacity(count)
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let rowCount = min(columns, count - row * columns)
            let rowWidth = xStep * Double(max(rowCount - 1, 0))
            let x = width * 0.5 - rowWidth / 2.0 + xStep * Double(column)
            let y = gridCenterY - gridHeight / 2.0 + yStep * Double(row)
            slots.append(ProviderLogoSlot(centerX: x, centerY: y, scale: scale))
        }
        return slots
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
            logoColor: nil,
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
    private var effectiveCycleInterval: TimeInterval {
        cycleInterval / motionSpeedMultiplier.clamped(to: 0.35...2.5)
    }

    // MARK: Shape sampling

    private struct ShapePoint {
        let point: CGPoint
        let role: String?
        let logoColor: RGBA?
        let progress: Double

        init(point: CGPoint, role: String?, progress: Double, logoColor: RGBA? = nil) {
            self.point = point
            self.role = role
            self.progress = progress
            self.logoColor = logoColor
        }
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

    private static func logoPoints(for provider: AgentProvider, fallback: [ShapePoint]) -> [ShapePoint] {
        let candidates: [String]
        switch provider {
        case .openAI:
            candidates = [provider.bundledLogoName, "OpenAILogo"]
        case .claudeCode:
            candidates = [provider.bundledLogoName, "ClaudeCodeLogo", "AnthropicLogo"]
        case .geminiCLI:
            candidates = [provider.bundledLogoName, "GeminiCLILogo"]
        case .antigravity:
            candidates = ["AntigravityLogo"]
        case .xAI:
            candidates = ["GrokLogo", "xAILogo"]
        default:
            candidates = [provider.bundledLogoName]
        }
        return logoPoints(named: candidates, fallback: fallback)
    }

    private static func logoPoints(named candidates: [String], fallback: [ShapePoint]) -> [ShapePoint] {
        for candidate in candidates {
            if let image = platformImage(named: candidate) {
                let points = sampleLogoImage(image, maxPoints: 1600)
                if !points.isEmpty {
                    return points
                }
            }
        }
        return fallback
    }

    private static func sampleLogoImage(_ image: CGImage, maxPoints: Int) -> [ShapePoint] {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return [] }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return [] }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let backgroundColor = inferredOpaqueBackgroundColor(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel
        )
        let borderBackgroundMask = connectedBackgroundMask(
            pixels: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytesPerPixel: bytesPerPixel,
            backgroundColor: backgroundColor
        )

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let pixelIndex = y * width + x
                if isLogoForegroundPixel(
                    pixels,
                    offset: offset,
                    pixelIndex: pixelIndex,
                    borderBackgroundMask: borderBackgroundMask,
                    backgroundColor: backgroundColor
                ) {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return [] }

        let occupiedWidth = max(1, maxX - minX + 1)
        let occupiedHeight = max(1, maxY - minY + 1)
        let sampleStep = max(2, Int(ceil(sqrt(Double(occupiedWidth * occupiedHeight) / Double(maxPoints)))))
        let centerX = Double(minX + maxX) / 2.0
        let centerY = Double(minY + maxY) / 2.0
        let scale = Double(max(occupiedWidth, occupiedHeight)) / 2.0

        var points: [ShapePoint] = []
        points.reserveCapacity(maxPoints)
        for y in stride(from: minY, through: maxY, by: sampleStep) {
            for x in stride(from: minX, through: maxX, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let pixelIndex = y * width + x
                guard isLogoForegroundPixel(
                    pixels,
                    offset: offset,
                    pixelIndex: pixelIndex,
                    borderBackgroundMask: borderBackgroundMask,
                    backgroundColor: backgroundColor
                ) else { continue }

                let alpha = Double(pixels[offset + 3]) / 255.0
                let premultipliedRed = Double(pixels[offset]) / 255.0
                let premultipliedGreen = Double(pixels[offset + 1]) / 255.0
                let premultipliedBlue = Double(pixels[offset + 2]) / 255.0
                let red = alpha > 0 ? min(1.0, premultipliedRed / alpha) : 0
                let green = alpha > 0 ? min(1.0, premultipliedGreen / alpha) : 0
                let blue = alpha > 0 ? min(1.0, premultipliedBlue / alpha) : 0
                let color = RGBA(r: red, g: green, b: blue, a: alpha)
                let luminance = relativeLuminance(color)
                let role: String
                if luminance < 0.30 {
                    role = "logo-flame-outer"
                } else if luminance > 0.76 {
                    role = "logo-flame-spark"
                } else {
                    role = "logo-flame-inner"
                }
                points.append(
                    ShapePoint(
                        point: CGPoint(
                            x: (Double(x) - centerX) / scale,
                            y: (Double(y) - centerY) / scale
                        ),
                        role: role,
                        progress: Double(points.count % max(maxPoints, 1)) / Double(max(maxPoints - 1, 1)),
                        logoColor: color
                    )
                )
            }
        }

        guard points.count > maxPoints else { return points }
        return evenlyDownsample(points, maxCount: maxPoints)
    }

    private static func inferredOpaqueBackgroundColor(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int
    ) -> RGBA? {
        let cornerSide = min(8, max(1, min(width, height) / 10))
        let cornerRanges: [(ClosedRange<Int>, ClosedRange<Int>)] = [
            (0...max(0, cornerSide - 1), 0...max(0, cornerSide - 1)),
            (max(0, width - cornerSide)...max(0, width - 1), 0...max(0, cornerSide - 1)),
            (0...max(0, cornerSide - 1), max(0, height - cornerSide)...max(0, height - 1)),
            (max(0, width - cornerSide)...max(0, width - 1), max(0, height - cornerSide)...max(0, height - 1))
        ]

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var alpha = 0.0
        var count = 0.0
        for (xRange, yRange) in cornerRanges {
            for y in yRange {
                for x in xRange {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    let a = Double(pixels[offset + 3]) / 255.0
                    guard a > 0.85 else { continue }
                    alpha += a
                    red += Double(pixels[offset]) / 255.0
                    green += Double(pixels[offset + 1]) / 255.0
                    blue += Double(pixels[offset + 2]) / 255.0
                    count += 1
                }
            }
        }

        guard count >= 4, alpha / count > 0.88 else { return nil }
        return RGBA(r: red / count, g: green / count, b: blue / count, a: alpha / count)
    }

    private static func connectedBackgroundMask(
        pixels: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int,
        backgroundColor: RGBA?
    ) -> [Bool]? {
        guard let backgroundColor else { return nil }
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [(x: Int, y: Int)] = []
        queue.reserveCapacity(width * 2 + height * 2)

        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let index = y * width + x
            guard !visited[index] else { return }
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard isBackgroundLikePixel(pixels, offset: offset, backgroundColor: backgroundColor) else { return }
            visited[index] = true
            queue.append((x, y))
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            enqueue(current.x + 1, current.y)
            enqueue(current.x - 1, current.y)
            enqueue(current.x, current.y + 1)
            enqueue(current.x, current.y - 1)
        }
        return visited
    }

    private static func isBackgroundLikePixel(
        _ pixels: [UInt8],
        offset: Int,
        backgroundColor: RGBA
    ) -> Bool {
        let alpha = Double(pixels[offset + 3]) / 255.0
        guard alpha > 0.22 else { return true }
        let red = alpha > 0 ? min(1.0, Double(pixels[offset]) / 255.0 / alpha) : 0
        let green = alpha > 0 ? min(1.0, Double(pixels[offset + 1]) / 255.0 / alpha) : 0
        let blue = alpha > 0 ? min(1.0, Double(pixels[offset + 2]) / 255.0 / alpha) : 0
        let distance = sqrt(
            pow(red - backgroundColor.r, 2) +
            pow(green - backgroundColor.g, 2) +
            pow(blue - backgroundColor.b, 2)
        )
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let saturation = maxChannel - minChannel
        return distance < 0.12 || (relativeLuminance(backgroundColor) > 0.86 && luminance > 0.88 && saturation < 0.10)
    }

    private static func isLogoForegroundPixel(
        _ pixels: [UInt8],
        offset: Int,
        pixelIndex: Int,
        borderBackgroundMask: [Bool]?,
        backgroundColor: RGBA?
    ) -> Bool {
        let alpha = Double(pixels[offset + 3]) / 255.0
        guard alpha > 0.22 else { return false }
        if let borderBackgroundMask, borderBackgroundMask.indices.contains(pixelIndex) {
            return !borderBackgroundMask[pixelIndex]
        }
        let premultipliedRed = Double(pixels[offset]) / 255.0
        let premultipliedGreen = Double(pixels[offset + 1]) / 255.0
        let premultipliedBlue = Double(pixels[offset + 2]) / 255.0
        let red = alpha > 0 ? min(1.0, premultipliedRed / alpha) : 0
        let green = alpha > 0 ? min(1.0, premultipliedGreen / alpha) : 0
        let blue = alpha > 0 ? min(1.0, premultipliedBlue / alpha) : 0

        guard let backgroundColor else { return true }
        let distance = sqrt(
            pow(red - backgroundColor.r, 2) +
            pow(green - backgroundColor.g, 2) +
            pow(blue - backgroundColor.b, 2)
        )
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let maxChannel = max(red, max(green, blue))
        let minChannel = min(red, min(green, blue))
        let saturation = maxChannel - minChannel

        if distance < 0.09 { return false }
        if relativeLuminance(backgroundColor) > 0.86, luminance > 0.88, saturation < 0.10 {
            return false
        }
        return true
    }

    private static func fallbackLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        switch provider {
        case .openAI:
            return generateOpenAILogoPoints()
        case .codex:
            return generateCodexLogoPoints()
        case .claudeCode:
            return generateAnthropicLogoPoints()
        case .geminiCLI:
            return generateGeminiLogoPoints()
        case .antigravity:
            return generateAntigravityLogoPoints()
        case .cursor:
            return generateCursorLogoPoints()
        case .openCode:
            return generateOpenCodeLogoPoints()
        case .xAI:
            return generateXAILogoPoints()
        default:
            return initialsLogoPoints(for: provider)
        }
    }

    private static func initialsLogoPoints(for provider: AgentProvider) -> [ShapePoint] {
        let words = provider.rawValue
            .split(separator: " ")
            .map(String.init)
        let initials: String
        if words.count >= 2 {
            initials = words.prefix(2).compactMap(\.first).map(String.init).joined()
        } else {
            initials = String(provider.rawValue.prefix(2))
        }
        let points = sampleTextPoints(text: initials.uppercased(), fontSize: 220)
        let denominator = max(1, points.count - 1)
        return points.enumerated().map { index, point in
            ShapePoint(
                point: point,
                role: index.isMultiple(of: 3) ? "logo-flame-spark" : "logo-flame-inner",
                progress: Double(index) / Double(denominator)
            )
        }
    }

    private static func evenlyDownsample(_ points: [ShapePoint], maxCount: Int) -> [ShapePoint] {
        guard maxCount > 0, points.count > maxCount else { return points }
        return (0..<maxCount).map { index in
            let t = Double(index) / Double(max(maxCount - 1, 1))
            return points[min(points.count - 1, Int((Double(points.count - 1) * t).rounded()))]
        }
    }

    private static func platformImage(named name: String) -> CGImage? {
        #if canImport(AppKit)
        var nsImage: NSImage? = nil
        if let img = NSImage(named: NSImage.Name(name)) {
            nsImage = img
        } else {
            for bundle in Bundle.allBundles {
                if let img = bundle.image(forResource: NSImage.Name(name)) {
                    nsImage = img
                    break
                }
            }
        }

        guard let image = nsImage else { return nil }
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return cgImage
        }

        // Fallback: draw NSImage into a bitmap context to extract CGImage robustly
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        guard width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage()
        #endif

        #if canImport(UIKit)
        var uiImage: UIImage? = nil
        if let img = UIImage(named: name) {
            uiImage = img
        } else {
            for bundle in Bundle.allBundles {
                if let img = UIImage(named: name, in: bundle, compatibleWith: nil) {
                    uiImage = img
                    break
                }
            }
        }
        return uiImage?.cgImage
        #endif
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

    private static func interpolateCatmullRom(
        _ p0: CGPoint,
        _ p1: CGPoint,
        _ p2: CGPoint,
        _ p3: CGPoint,
        t: Double
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2.0 * p1.x) +
            (-p0.x + p2.x) * t +
            (2.0 * p0.x - 5.0 * p1.x + 4.0 * p2.x - p3.x) * t2 +
            (-p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2.0 * p1.y) +
            (-p0.y + p2.y) * t +
            (2.0 * p0.y - 5.0 * p1.y + 4.0 * p2.y - p3.y) * t2 +
            (-p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y) * t3
        )
        return CGPoint(x: x, y: y)
    }

    private static func generateSplinePoints(
        controlPoints: [CGPoint],
        stepsPerSegment: Int,
        role: String?
    ) -> [ShapePoint] {
        guard controlPoints.count >= 3 else { return [] }
        var pts: [ShapePoint] = []
        let n = controlPoints.count
        for i in 0..<n {
            let p0 = controlPoints[(i - 1 + n) % n]
            let p1 = controlPoints[i]
            let p2 = controlPoints[(i + 1) % n]
            let p3 = controlPoints[(i + 2) % n]

            for j in 0..<stepsPerSegment {
                let t = Double(j) / Double(stepsPerSegment)
                let pt = interpolateCatmullRom(p0, p1, p2, p3, t: t)
                let progress = Double(i * stepsPerSegment + j) / Double(n * stepsPerSegment)
                pts.append(ShapePoint(point: pt, role: role, progress: progress))
            }
        }
        return pts
    }

    private static func generateOpenAILogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []
        let A = 0.22
        let B = 0.07
        let d = 0.12
        let alpha = 0.2
        let steps = 70
        for i in 0..<6 {
            let theta = Double(i) * (.pi / 3.0)
            for j in 0..<steps {
                let t = Double(j) / Double(steps) * (.pi * 2.0)
                let localX = d + A * cos(t) * cos(alpha) - B * sin(t) * sin(alpha)
                let localY = A * cos(t) * sin(alpha) + B * sin(t) * cos(alpha)

                let x = localX * cos(theta) - localY * sin(theta)
                let y = localX * sin(theta) + localY * cos(theta)

                pts.append(ShapePoint(
                    point: CGPoint(x: x, y: y),
                    role: "logo-flame-inner",
                    progress: Double(j) / Double(steps)
                ))
            }
        }
        return pts
    }

    private static func generateAnthropicLogoPoints() -> [ShapePoint] {
        let outer = [
            CGPoint(x: -0.22, y: -0.30),
            CGPoint(x: -0.07, y: 0.32),
            CGPoint(x: 0.07, y: 0.32),
            CGPoint(x: 0.22, y: -0.30),
            CGPoint(x: 0.12, y: -0.30),
            CGPoint(x: 0.0, y: 0.02),
            CGPoint(x: -0.12, y: -0.30)
        ]
        let inner = [
            CGPoint(x: 0.0, y: 0.20),
            CGPoint(x: 0.05, y: 0.08),
            CGPoint(x: -0.05, y: 0.08)
        ]

        let outerPts = generateSplinePoints(controlPoints: outer, stepsPerSegment: 35, role: "logo-flame-outer")
        let innerPts = generateSplinePoints(controlPoints: inner, stepsPerSegment: 35, role: "logo-flame-inner")
        return outerPts + innerPts
    }

    private static func generateGeminiLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []
        let outerR = 0.34
        let innerR = 0.18

        // Outer astroid
        let outerCount = 220
        for i in 0..<outerCount {
            let t = Double(i) / Double(outerCount) * (.pi * 2.0)
            let x = outerR * pow(cos(t), 3)
            let y = outerR * pow(sin(t), 3)
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-outer",
                progress: Double(i) / Double(outerCount)
            ))
        }

        // Inner astroid
        let innerCount = 150
        for i in 0..<innerCount {
            let t = Double(i) / Double(innerCount) * (.pi * 2.0)
            let x = innerR * pow(cos(t), 3)
            let y = innerR * pow(sin(t), 3)
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-inner",
                progress: Double(i) / Double(innerCount)
            ))
        }
        return pts
    }

    private static func generateCursorLogoPoints() -> [ShapePoint] {
        let controlPoints = [
            CGPoint(x: 0.0, y: 0.32),
            CGPoint(x: 0.18, y: -0.18),
            CGPoint(x: 0.0, y: -0.05),
            CGPoint(x: -0.18, y: -0.18)
        ]
        return generateSplinePoints(controlPoints: controlPoints, stepsPerSegment: 90, role: "logo-flame-inner")
    }

    private static func generateOpenCodeLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        func appendLine(
            startX: Double,
            startY: Double,
            endX: Double,
            endY: Double,
            count: Int,
            role: String
        ) {
            for i in 0..<count {
                let t = Double(i) / Double(max(count - 1, 1))
                pts.append(ShapePoint(
                    point: CGPoint(
                        x: startX + (endX - startX) * t,
                        y: startY + (endY - startY) * t
                    ),
                    role: role,
                    progress: t
                ))
            }
        }

        appendLine(startX: -0.34, startY: 0.0, endX: -0.12, endY: -0.22, count: 90, role: "logo-flame-outer")
        appendLine(startX: -0.34, startY: 0.0, endX: -0.12, endY: 0.22, count: 90, role: "logo-flame-inner")
        appendLine(startX: 0.34, startY: 0.0, endX: 0.12, endY: -0.22, count: 90, role: "logo-flame-outer")
        appendLine(startX: 0.34, startY: 0.0, endX: 0.12, endY: 0.22, count: 90, role: "logo-flame-inner")
        appendLine(startX: -0.04, startY: 0.30, endX: 0.08, endY: -0.30, count: 120, role: "logo-flame-spark")
        return pts
    }

    private static func generateXAILogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        // x.ai folded X diagonal 1: Top-Left to Bottom-Right
        let diagonalCount = 140
        for i in 0..<diagonalCount {
            let t = Double(i) / Double(diagonalCount)
            let x = -0.22 + t * 0.44
            let y = 0.25 - t * 0.50

            pts.append(ShapePoint(
                point: CGPoint(x: x - 0.015, y: y),
                role: "logo-flame-outer",
                progress: t
            ))
            pts.append(ShapePoint(
                point: CGPoint(x: x + 0.015, y: y),
                role: "logo-flame-inner",
                progress: t
            ))
        }

        // x.ai diagonal 2: Bottom-Left to Top-Right split segments
        let segmentCount = 60
        // Bottom-Left segment
        for i in 0..<segmentCount {
            let t = Double(i) / Double(segmentCount)
            let x = -0.22 + t * 0.16
            let y = -0.25 + t * 0.18
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-spark",
                progress: t * 0.5
            ))
        }
        // Top-Right segment
        for i in 0..<segmentCount {
            let t = Double(i) / Double(segmentCount)
            let x = 0.06 + t * 0.16
            let y = 0.07 + t * 0.18
            pts.append(ShapePoint(
                point: CGPoint(x: x, y: y),
                role: "logo-flame-spark",
                progress: 0.5 + t * 0.5
            ))
        }
        return pts
    }

    private static func generateGrokLogoPoints() -> [ShapePoint] {
        var pts: [ShapePoint] = []

        func appendArc(radius: Double, start: Double, end: Double, count: Int, role: String) {
            for i in 0..<count {
                let t = Double(i) / Double(max(count - 1, 1))
                let angle = start + (end - start) * t
                pts.append(ShapePoint(
                    point: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius),
                    role: role,
                    progress: t
                ))
            }
        }

        appendArc(radius: 0.34, start: 0.70, end: 2.85, count: 130, role: "logo-flame-outer")
        appendArc(radius: 0.23, start: 0.80, end: 2.65, count: 95, role: "logo-flame-inner")
        appendArc(radius: 0.34, start: 3.65, end: 6.02, count: 145, role: "logo-flame-outer")
        appendArc(radius: 0.23, start: 3.90, end: 5.78, count: 95, role: "logo-flame-inner")

        let slashCount = 180
        for i in 0..<slashCount {
            let t = Double(i) / Double(max(slashCount - 1, 1))
            let x = -0.42 + t * 0.84
            let y = 0.40 - t * 0.82
            let normal = 0.018
            for lane in [-1.0, 0.0, 1.0] {
                pts.append(ShapePoint(
                    point: CGPoint(x: x + lane * normal, y: y + lane * normal * 0.45),
                    role: lane == 0 ? "logo-flame-spark" : "logo-flame-inner",
                    progress: t
                ))
            }
        }
        return pts
    }

    private static func generateCodexLogoPoints() -> [ShapePoint] {
        let leftBrace = [
            CGPoint(x: -0.06, y: 0.28),
            CGPoint(x: -0.18, y: 0.26),
            CGPoint(x: -0.16, y: 0.12),
            CGPoint(x: -0.28, y: 0.0),
            CGPoint(x: -0.16, y: -0.12),
            CGPoint(x: -0.18, y: -0.26),
            CGPoint(x: -0.06, y: -0.28)
        ]
        let rightBrace = [
            CGPoint(x: 0.06, y: 0.28),
            CGPoint(x: 0.18, y: 0.26),
            CGPoint(x: 0.16, y: 0.12),
            CGPoint(x: 0.28, y: 0.0),
            CGPoint(x: 0.16, y: -0.12),
            CGPoint(x: 0.18, y: -0.26),
            CGPoint(x: 0.06, y: -0.28)
        ]
        let leftPts = generateSplinePoints(controlPoints: leftBrace, stepsPerSegment: 50, role: "logo-flame-outer")
        let rightPts = generateSplinePoints(controlPoints: rightBrace, stepsPerSegment: 50, role: "logo-flame-inner")
        return leftPts + rightPts
    }

    private static func generateAntigravityLogoPoints() -> [ShapePoint] {
        let diamond = [
            CGPoint(x: 0.0, y: 0.32),
            CGPoint(x: 0.24, y: 0.0),
            CGPoint(x: 0.0, y: -0.32),
            CGPoint(x: -0.24, y: 0.0)
        ]
        let triangle = [
            CGPoint(x: 0.0, y: 0.12),
            CGPoint(x: 0.10, y: -0.08),
            CGPoint(x: -0.10, y: -0.08)
        ]
        let diamondPts = generateSplinePoints(controlPoints: diamond, stepsPerSegment: 60, role: "logo-flame-outer")
        let trianglePts = generateSplinePoints(controlPoints: triangle, stepsPerSegment: 60, role: "logo-flame-inner")
        return diamondPts + trianglePts
    }

    private func resolvedProviderLogoRGBA(for p: Particle, at index: Int) -> RGBA? {
        guard let rawRole = p.role else { return nil }
        let parsed = Self.parseRoleAndProvider(rawRole)
        guard let provider = parsed.provider else { return nil }

        let color = Self.colorForProvider(
            provider,
            under: colorPalette,
            role: parsed.role,
            toneSeed: Self.flameToneSeed(for: p, at: index),
            sourceLogoColor: p.logoColor
        )
        let opacity = Self.logoOpacity(for: p, role: parsed.role, colorScheme: renderScheme)
        return RGBA(r: color.r, g: color.g, b: color.b, a: opacity)
    }

    private static func logoOpacity(for p: Particle, role: String, colorScheme: ColorScheme) -> Double {
        let raw = p.opacity.clamped(to: 0...1)
        let base = colorScheme == .dark ? raw : min(1.0, raw + 0.08)
        let multiplier: Double
        switch role {
        case "logo-flame-inner": multiplier = 1.62
        case "logo-flame-outer": multiplier = 1.44
        case "logo-flame-spark": multiplier = 1.72
        default: multiplier = 1.36
        }
        return min(1.0, base * multiplier)
    }

    private static func parseRoleAndProvider(_ rawRole: String) -> (role: String, provider: AgentProvider?) {
        let parts = rawRole.split(separator: ":")
        if parts.count == 2 {
            let role = String(parts[0])
            let providerToken = String(parts[1])
            let provider = AgentProvider.fromPersistedToken(providerToken)
            return (role, provider)
        }
        return (rawRole, nil)
    }

    private static func colorForProvider(
        _ provider: AgentProvider,
        under palette: SwarmColorPalette,
        role: String?,
        toneSeed: Double,
        sourceLogoColor: RGBA? = nil
    ) -> RGBA {
        if let sourceLogoColor {
            return contrastAdjustedSourceLogoColor(sourceLogoColor)
        }

        // To ensure all logos are pristine, easily distinguishable, and use the correct colors,
        // we use their canonical brand colors across all custom palette states.
        let base: RGBA
        if provider == .xAI {
            base = RGBA(r: 0.95, g: 0.95, b: 0.98) // Beautiful glowing silver-white for xAI
        } else {
            base = DesignSystemColors.providerRGBA(for: provider)
        }

        if let r = role {
            let sourceLuminance = sourceLogoColor.map(Self.relativeLuminance) ?? 0.5
            let seed = ((toneSeed - floor(toneSeed)) * 0.35 + sourceLuminance * 0.65).clamped(to: 0...1)
            let hot = base.lightened(by: r == "logo-flame-inner" ? 0.24 : 0.10)
            let shadow = base.darkened(by: r == "logo-flame-outer" ? 0.30 : 0.15)
            return shadow.mix(with: hot, amount: seed)
        }
        return base
    }

    private static func contrastAdjustedSourceLogoColor(_ color: RGBA) -> RGBA {
        let luminance = relativeLuminance(color)
        if luminance < 0.08 {
            return RGBA(r: 0.84, g: 0.86, b: 0.90, a: color.a)
        }
        if luminance < 0.22 {
            return color.lightened(by: 0.46)
        }
        return color
    }

    private static func relativeLuminance(_ color: RGBA) -> Double {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
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
                CGPoint(x: 171.6, y: 4.7),
                CGPoint(x: 149, y: 24),
                CGPoint(x: 126, y: 54),
                CGPoint(x: 112.8, y: 98.3),
                CGPoint(x: 105, y: 84),
                CGPoint(x: 94.7, y: 79.6),
                CGPoint(x: 96, y: 97),
                CGPoint(x: 80.6, y: 125.1),
                CGPoint(x: 78, y: 112),
                CGPoint(x: 75.1, y: 105.8),
                CGPoint(x: 54, y: 130),
                CGPoint(x: 35.7, y: 183),
                CGPoint(x: 39, y: 202),
                CGPoint(x: 52.3, y: 224.2),
                CGPoint(x: 52.3, y: 213.6),
                CGPoint(x: 56.9, y: 209.6),
                CGPoint(x: 82.2, y: 209.6),
                CGPoint(x: 71, y: 192),
                CGPoint(x: 80, y: 166),
                CGPoint(x: 103.3, y: 144.9),
                CGPoint(x: 101, y: 155),
                CGPoint(x: 112.5, y: 168.8),
                CGPoint(x: 145, y: 158),
                CGPoint(x: 167.3, y: 133.2),
                CGPoint(x: 173, y: 111),
                CGPoint(x: 159, y: 72.1),
                CGPoint(x: 162, y: 42),
                CGPoint(x: 171.6, y: 4.7)
            ],
            samplesPerSegment: 4,
            role: "logo-flame-outer"
        )

        appendCatmullRom(
            into: &raw,
            controls: [
                CGPoint(x: 219.4, y: 165.8),
                CGPoint(x: 218, y: 143),
                CGPoint(x: 210, y: 121),
                CGPoint(x: 203.2, y: 106.3),
                CGPoint(x: 196.5, y: 108.5),
                CGPoint(x: 193.5, y: 127),
                CGPoint(x: 182.2, y: 139.2),
                CGPoint(x: 181.3, y: 143.3),
                CGPoint(x: 187.5, y: 144.7),
                CGPoint(x: 192.2, y: 149.5),
                CGPoint(x: 192.2, y: 225.9),
                CGPoint(x: 207, y: 211),
                CGPoint(x: 219.4, y: 184),
                CGPoint(x: 219.4, y: 165.8)
            ],
            samplesPerSegment: 3,
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

public extension Notification.Name {
    static let cycleSwarmShapeRequested = Notification.Name("com.openburnbar.swarm.cycleSwarmShapeRequested")
}
