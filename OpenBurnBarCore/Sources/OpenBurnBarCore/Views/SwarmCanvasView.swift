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
    public let isAutoCyclingEnabled: Bool
    public let enabledProviderGlyphs: [AgentProvider]
    public let isAvatarEnabled: Bool
    public let isBrandTextEnabled: Bool
    public let enableSwarmSparkles: Bool
    public let excludeBrandShapesFromSwarm: Bool
    public let currentMode: Binding<SwarmFormationMode>?

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
        isAutoCyclingEnabled: Bool = true,
        enabledProviderGlyphs: [AgentProvider]? = nil,
        isAvatarEnabled: Bool = true,
        isBrandTextEnabled: Bool = true,
        enableSwarmSparkles: Bool = true,
        excludeBrandShapesFromSwarm: Bool = false,
        currentMode: Binding<SwarmFormationMode>? = nil
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
        self.isAutoCyclingEnabled = isAutoCyclingEnabled
        self.enabledProviderGlyphs = normalizedProviderGlyphs
        self.isAvatarEnabled = isAvatarEnabled
        self.isBrandTextEnabled = isBrandTextEnabled
        self.enableSwarmSparkles = enableSwarmSparkles
        self.excludeBrandShapesFromSwarm = excludeBrandShapesFromSwarm
        self.currentMode = currentMode

        let sim = SwarmSimulation(
            particleCount: particleCount ?? Self.adaptiveParticleCount,
            pace: pace,
            enabledProviderGlyphs: normalizedProviderGlyphs,
            excludeBrandShapes: excludeBrandShapesFromSwarm
        )
        sim.isAvatarEnabled = isAvatarEnabled
        sim.isBrandTextEnabled = isBrandTextEnabled
        sim.setAutoCyclingEnabled(isAutoCyclingEnabled)
        sim.colorPalette = colorPalette
        sim.motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
        sim.setColorDriver(colorDriver)
        sim.enableSwarmSparkles = enableSwarmSparkles
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
        .onChange(of: isAutoCyclingEnabled) {
            simulation.setAutoCyclingEnabled(isAutoCyclingEnabled)
        }
        .onChange(of: enabledProviderGlyphs) {
            simulation.setEnabledProviderGlyphs(enabledProviderGlyphs)
        }
        .onChange(of: enableSwarmSparkles) {
            simulation.enableSwarmSparkles = enableSwarmSparkles
        }
        .onChange(of: excludeBrandShapesFromSwarm) {
            simulation.setExcludeBrandShapes(excludeBrandShapesFromSwarm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cycleSwarmShapeRequested)) { _ in
            currentMode?.wrappedValue = simulation.forceCycleShape()
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

public enum SwarmFormationMode: Equatable {
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
        grouped(SwarmProviderGlyphSelection.normalized(providers), size: 2)
    }

    static func defaultCycle(for providers: [AgentProvider], excludeBrandShapes: Bool = false) -> [SwarmFormationMode] {
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

        if excludeBrandShapes {
            return [.swarm] + providerCycle + grokCycle
        }

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

    static func inspectionCycle(for providers: [AgentProvider], excludeBrandShapes: Bool = false) -> [SwarmFormationMode] {
        let enabledProviders = SwarmProviderGlyphSelection.normalized(providers)
        let grokCycle: [SwarmFormationMode] = enabledProviders.contains(.xAI) ? [.shapeGrok] : []

        if excludeBrandShapes {
            return [.swarm] + enabledProviders.map { provider in
                .shapeProviderLogo([provider])
            } + grokCycle + providerLogoGroups(for: enabledProviders).map { group in
                .shapeProviderLogo(group)
            }
        }

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
public final class SwarmSimulation {
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
    private var excludeBrandShapes: Bool = false
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
    private var isAutoCyclingEnabled = true

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
    public var enableSwarmSparkles: Bool = true
    var motionSpeedMultiplier: Double = 1.0 {
        didSet {
            motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
            shouldResetCycleTimer = true
        }
    }

    // MARK: Color Driver State
    public var colorPalette: SwarmColorPalette = .defaultEmber
    var isAvatarEnabled: Bool = true
    var isBrandTextEnabled: Bool = true
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
    private static let shapeAdmireHoldDuration: TimeInterval = 5.0
    private static let shapeSettleRecheckInterval: TimeInterval = 0.25
    private static let shapeSettleFallbackDelay: TimeInterval = 6.0
    private static let shapeSettledParticleFraction: Double = 0.95

    public init(
        particleCount: Int,
        pace: SwarmCanvasView.Pace,
        enabledProviderGlyphs: [AgentProvider],
        excludeBrandShapes: Bool = false
    ) {
        let normalizedProviderGlyphs = SwarmProviderGlyphSelection.normalized(enabledProviderGlyphs)
        self.enabledProviderGlyphs = normalizedProviderGlyphs
        self.excludeBrandShapes = excludeBrandShapes
        self.modes = SwarmFormationMode.defaultCycle(for: normalizedProviderGlyphs, excludeBrandShapes: excludeBrandShapes)

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

    public func advance(to date: Date, bounds size: CGSize, reduceMotion: Bool, isBatteryThrottled: Bool) {
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
        if isAutoCyclingEnabled, !reduceMotion, colorDriver?.mode != .active, now >= nextCycleAt {
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

    public func draw(into ctx: GraphicsContext, size: CGSize, scheme: ColorScheme, isBatteryThrottled: Bool) {
        renderScheme = scheme   // drives the light/dark particle palette in colorFromKey

        let shouldRenderIndividually: Bool = {
            if colorDriver != nil { return true }
            if case .shapeProviderLogo = mode { return true }
            if mode != .swarm { return true } // Ensure shapes always support high-quality sparkles & transitions
            return false
        }()

        if shouldRenderIndividually {
            // Data-driven path: each particle may have a unique color from the
            // provider palette, so we render individually.
            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let color = resolvedColor(for: p, at: index, isBatteryThrottled: isBatteryThrottled)
                let inShape = (mode != .swarm && p.tx != nil)
                var r = max(0.4, p.size * (inShape ? 1.2 : 0.85))

                var isSparkling = false
                var sparkleIntensity = 0.0

                if enableSwarmSparkles, inShape, shapeSettledAt != nil {
                    // Premium, organic-feeling, extremely elegant twinkle
                    let pHash = Double((index * 127) % 1000) / 1000.0 // Unique phase 0.0 - 1.0
                    let speed = 0.5 + Double((index * 17) % 5) * 0.15 // Slower speed (0.5 to 1.1 rad/s)
                    let sparkleVal = sin(flowTime * speed + pHash * .pi * 2)

                    // Only a tiny fraction of particles (top 6%) twinkle at any given time
                    // Using a smooth power-based curve makes the fade-in and fade-out extremely soft.
                    if sparkleVal > 0.94 {
                        let normalized = (sparkleVal - 0.94) / 0.06 // 0.0 to 1.0
                        let intensity = pow(normalized, 2.0) // Quadratic ease-in for a soft peak

                        // Very subtle size increase (max 6%) to prevent layout from looking "bumpy" or "wild"
                        r *= (1.0 + intensity * 0.06)
                        isSparkling = true
                        sparkleIntensity = intensity
                    }
                }

                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(color))

                if isSparkling {
                    // Draw core glint
                    let sr = r * 0.35
                    let sRect = CGRect(x: p.x - sr, y: p.y - sr, width: sr * 2, height: sr * 2)
                    let sColor = Color.white.opacity(sparkleIntensity * 0.55)
                    ctx.fill(Path(ellipseIn: sRect), with: .color(sColor))

                    // Draw outer subtle glow halo
                    let glowR = r * 0.75
                    let glowRect = CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)
                    let glowColor = Color.white.opacity(sparkleIntensity * 0.15)
                    ctx.fill(Path(ellipseIn: glowRect), with: .color(glowColor))
                }
            }
        } else {
            // Original bucket path: batch particles by color key to minimize fill calls.
            var bucketPaths: [Int: Path] = [:]
            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let key = colorKey(for: p)
                var path = bucketPaths[key] ?? Path()
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

    public func assignMode(_ next: SwarmFormationMode, at assignedAt: TimeInterval = Date.timeIntervalSinceReferenceDate) {
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

    func setExcludeBrandShapes(_ exclude: Bool) {
        guard exclude != excludeBrandShapes else { return }
        excludeBrandShapes = exclude
        modes = SwarmFormationMode.defaultCycle(for: enabledProviderGlyphs, excludeBrandShapes: exclude)
        cycleIndex = min(cycleIndex, max(0, modes.count - 1))

        switch mode {
        case .shapeDollar, .shapeCode, .shapeBurnBarLogo, .shapeRings, .shapeRouterFlow:
            assignMode(.swarm)
        default:
            break
        }

        shouldResetCycleTimer = true
    }

    func setEnabledProviderGlyphs(_ providers: [AgentProvider]) {
        let normalizedProviders = SwarmProviderGlyphSelection.normalized(providers)
        guard normalizedProviders != enabledProviderGlyphs else { return }

        enabledProviderGlyphs = normalizedProviders
        modes = SwarmFormationMode.defaultCycle(for: normalizedProviders, excludeBrandShapes: excludeBrandShapes)
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
    public func setColorDriver(_ driver: SwarmColorDriver?) {
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

    public func setAutoCyclingEnabled(_ enabled: Bool) {
        isAutoCyclingEnabled = enabled
        shouldResetCycleTimer = true
    }

    func forceCycleShape() -> SwarmFormationMode {
        let inspectionCycle = SwarmFormationMode.inspectionCycle(for: enabledProviderGlyphs)
        guard !inspectionCycle.isEmpty else { return mode }

        let currentIdx = inspectionCycle.firstIndex(where: { $0 == mode }) ?? -1
        let nextIdx = (currentIdx + 1) % inspectionCycle.count
        let nextMode = inspectionCycle[nextIdx]
        assignMode(nextMode)

        // Reset the auto-cycling timer so the shape stays for visual inspection
        shouldResetCycleTimer = true
        return nextMode
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
        case .ollama:
            return generateOllamaLogoPoints()
        case .hermes:
            return generateHermesLogoPoints()
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

    private static func providerTextPoints(for provider: AgentProvider) -> [ShapePoint] {
        guard let data = providerTextPointsData[provider] else { return [] }
        var raw: [(point: CGPoint, role: String)] = []
        raw.reserveCapacity(data.count / 2)
        var idx = 0
        while idx < data.count {
            raw.append((CGPoint(x: data[idx], y: data[idx+1]), "logo-flame-inner"))
            idx += 2
        }
        var pts: [ShapePoint] = []
        pts.reserveCapacity(raw.count)
        let denom = Double(max(raw.count - 1, 1))
        for (i, item) in raw.enumerated() {
            pts.append(ShapePoint(point: item.point, role: item.role, progress: Double(i) / denom))
        }
        return pts
    }

    private static let providerTextPointsData: [AgentProvider: [Double]] = [
        .claudeCode: [-0.3695, -0.0402, -0.4497, -0.1423, -0.3566, -0.2011, -0.4814, -0.2089, -0.4981, -0.1723, -0.4441, -0.025, -0.3615, -0.2029, -0.4732, -0.2089, -0.366, -0.189, -0.4683, -0.2229, -0.3695, -0.204, -0.4894, -0.189, -0.4851, -0.1863, -0.487, -0.1863, -0.457, -0.1397, -0.3695, -0.048, -0.3925, -0.0793, -0.4522, -0.082, -0.3695, -0.0445, -0.1833, -0.0616, -0.1828, -0.1942, -0.31, -0.2089, -0.3267, -0.1723, -0.3138, -0.0372, -0.1779, -0.082, -0.2303, -0.2255, -0.3056, -0.2281, -0.1728, -0.1168, -0.2019, -0.1723, -0.2311, -0.2229, -0.1796, -0.0846, -0.3138, -0.1898, -0.3243, -0.1788, -0.3156, -0.1723, -0.2894, -0.1082, -0.295, -0.0989, -0.242, -0.082, -0.2821, -0.1712, -0.2821, -0.1424, -0.2019, -0.048, -0.1931, -0.0616, -0.2019, -0.0454, -0.0157, -0.0666, -0.0214, -0.1942, -0.1443, -0.2089, -0.0157, -0.082, -0.0263, -0.2133, -0.138, -0.2153, -0.0052, -0.1916, -0.0219, -0.1723, -0.1332, -0.2229, -0.0101, -0.1185, -0.1032, -0.1712, -0.0902, -0.0627, -0.0983, -0.082, -0.1008, -0.1406, -0.0959, -0.0846, -0.0306, -0.048, -0.0263, -0.0562, -0.0343, -0.0437, 0.1027, -0.0846, 0.119, -0.1132, 0.0717, -0.1712, 0.1648, -0.216, 0.0214, -0.1476, 0.1573, -0.1916, 0.0312, -0.2089, 0.1624, -0.189, 0.0344, -0.2136, 0.1519, -0.1942, 0.0607, -0.1712, 0.1202, -0.1211, 0.1227, -0.1298, 0.0693, -0.1712, 0.1182, -0.1159, 0.0588, -0.0981, 0.1575, -0.0576, 0.1599, -0.0454, 0.0684, -0.0981, 0.1589, -0.0428, -0.3609, 0.2157, -0.423, 0.0846, -0.3566, 0.0251, -0.4814, 0.0567, -0.5, 0.1204, -0.3695, 0.2308, -0.4708, 0.0358, -0.3591, 0.0277, -0.4024, 0.0469, -0.3639, 0.0616, -0.4814, 0.0651, -0.4918, 0.0835, -0.4832, 0.0835, -0.4626, 0.1208, -0.3639, 0.1887, -0.3642, 0.2104, -0.4538, 0.0846, -0.359, 0.213, -0.2821, 0.172, -0.189, 0.0695, -0.3305, 0.0469, -0.2019, 0.0642, -0.3218, 0.0414, -0.1915, 0.0407, -0.2802, 0.047, -0.1982, 0.0616, -0.2894, 0.1667, -0.287, 0.2104, -0.2915, 0.213, -0.04, 0.1942, -0.0214, 0.0764, -0.0717, 0.064, -0.1591, 0.0251, -0.1524, 0.1942, -0.1194, 0.0303, -0.1567, 0.0341, -0.0717, 0.1016, -0.029, 0.1738, -0.0619, 0.0469, -0.0239, 0.1765, -0.1518, 0.0423, -0.0717, 0.106, -0.0424, 0.0469, -0.0287, 0.1712, -0.1218, 0.1648, -0.1274, 0.1931, -0.1019, 0.1738, -0.1194, 0.1577, -0.1145, 0.1667, -0.0511, 0.2078, -0.0449, 0.1942, -0.0529, 0.2113, 0.1145, 0.0846, 0.1605, 0.2157, 0.1065, 0.0251, 0.0214, 0.0616, 0.0028, 0.1817, 0.1599, 0.2104, 0.0684, 0.0303, 0.0676, 0.0277, 0.1624, 0.213, 0.1333, 0.0713, 0.1389, 0.0329, 0.1538, 0.2078, 0.0214, 0.0668, 0.011, 0.0706, 0.0158, 0.0835, 0.0439, 0.2078, 0.0482, 0.1265, 0.0402, 0.2121, 0.3176, 0.1942, 0.3262, 0.0616, 0.1947, 0.0469, 0.3009, 0.2207, 0.3089, 0.0668, 0.198, 0.0469, 0.3176, 0.0642, 0.3195, 0.1738, 0.2021, 0.0423, 0.3251, 0.0695, 0.2283, 0.0846, 0.2821, 0.1931, 0.2369, 0.1144, 0.2344, 0.1765, 0.2679, 0.1712, 0.3065, 0.2033, 0.3089, 0.2104, 0.3044, 0.213, 0.5, 0.1712, 0.4499, 0.1476, 0.4069, 0.0936, 0.5, 0.0695, 0.3585, 0.0469, 0.4871, 0.0642, 0.3672, 0.0414, 0.4976, 0.0407, 0.4088, 0.0469, 0.4908, 0.0616, 0.394, 0.0964, 0.4555, 0.1156],
        .copilot: [-0.0221, 0.0877, -0.0012, 0.085, 0.0165, 0.0771, 0.031, 0.064, 0.0414, 0.0469, 0.0476, 0.0265, 0.0496, 0.003, 0.0473, -0.0231, 0.0404, -0.0456, 0.0288, -0.0646, 0.0128, -0.0792, -0.0066, -0.088, -0.0293, -0.0909, -0.0438, -0.0894, -0.0568, -0.085, -0.0683, -0.0776, -0.0689, -0.0771, -0.0694, -0.0766, -0.07, -0.0761, -0.07, -0.1039, -0.07, -0.1317, -0.07, -0.1594, -0.0832, -0.1594, -0.0963, -0.1594, -0.1094, -0.1594, -0.1094, -0.0783, -0.1094, 0.0029, -0.1094, 0.084, -0.0963, 0.084, -0.0832, 0.084, -0.07, 0.084, -0.07, 0.079, -0.07, 0.0741, -0.07, 0.0691, -0.0698, 0.0694, -0.0695, 0.0696, -0.0692, 0.0699, -0.0566, 0.0792, -0.0421, 0.0851, -0.0258, 0.0876, -0.0246, 0.0876, -0.0233, 0.0877, -0.0221, 0.0877, 0.3048, 0.0877, 0.3285, 0.085, 0.3486, 0.0771, 0.365, 0.0638, 0.3771, 0.046, 0.3843, 0.0244, 0.3867, -0.001, 0.3841, -0.0261, 0.3764, -0.0478, 0.3634, -0.0661, 0.3461, -0.0799, 0.3253, -0.0881, 0.3011, -0.0909, 0.2776, -0.0882, 0.2573, -0.0801, 0.2403, -0.0667, 0.2276, -0.0489, 0.22, -0.0278, 0.2175, -0.0034, 0.2201, 0.0227, 0.228, 0.045, 0.2412, 0.0633, 0.2589, 0.0769, 0.2801, 0.085, 0.3048, 0.0877, -0.2173, 0.0877, -0.1937, 0.085, -0.1736, 0.0771, -0.1571, 0.0638, -0.1451, 0.046, -0.1379, 0.0244, -0.1355, -0.001, -0.1381, -0.0261, -0.1458, -0.0478, -0.1588, -0.0661, -0.1761, -0.0799, -0.1969, -0.0881, -0.221, -0.0909, -0.2446, -0.0882, -0.2649, -0.0801, -0.2819, -0.0667, -0.2946, -0.0489, -0.3022, -0.0278, -0.3047, -0.0034, -0.3021, 0.0227, -0.2942, 0.045, -0.281, 0.0633, -0.2633, 0.0769, -0.2421, 0.085, -0.2173, 0.0877, -0.3803, 0.1505, -0.3597, 0.1495, -0.3414, 0.1463, -0.3255, 0.1409, -0.3241, 0.1403, -0.3227, 0.1396, -0.3213, 0.139, -0.3213, 0.1243, -0.3213, 0.1095, -0.3213, 0.0948, -0.3248, 0.0968, -0.3283, 0.0987, -0.3318, 0.1007, -0.347, 0.1075, -0.3633, 0.1116, -0.3807, 0.113, -0.4025, 0.1104, -0.4212, 0.1027, -0.437, 0.0899, -0.4491, 0.0727, -0.4563, 0.0518, -0.4587, 0.0272, -0.4565, 0.004, -0.4497, -0.0157, -0.4386, -0.0319, -0.4239, -0.0439, -0.4063, -0.0511, -0.3859, -0.0535, -0.366, -0.052, -0.348, -0.0474, -0.332, -0.0398, -0.3284, -0.0376, -0.3249, -0.0354, -0.3213, -0.0333, -0.3213, -0.0473, -0.3213, -0.0612, -0.3213, -0.0752, -0.3225, -0.0759, -0.3238, -0.0765, -0.3251, -0.0772, -0.3438, -0.0848, -0.3652, -0.0894, -0.3893, -0.0909, -0.4204, -0.0873, -0.4473, -0.0765, -0.4698, -0.0585, -0.4866, -0.0347, -0.4966, -0.0067, -0.5, 0.0257, -0.4962, 0.0604, -0.4849, 0.0905, -0.4661, 0.1159, -0.4415, 0.1351, -0.4129, 0.1467, -0.3803, 0.1505, 0.4603, 0.1331, 0.4603, 0.1167, 0.4603, 0.1004, 0.4603, 0.084, 0.4735, 0.084, 0.4868, 0.084, 0.5, 0.084, 0.5, 0.0721, 0.5, 0.0602, 0.5, 0.0483, 0.4868, 0.0483, 0.4735, 0.0483, 0.4603, 0.0483, 0.4603, 0.0212, 0.4603, -0.0059, 0.4603, -0.033, 0.4607, -0.0403, 0.4617, -0.046, 0.4634, -0.05, 0.4636, -0.0504, 0.4639, -0.0507, 0.4641, -0.0511, 0.4668, -0.0533, 0.4709, -0.0547, 0.4764, -0.0552, 0.481, -0.0548, 0.4851, -0.0535, 0.4886, -0.0514, 0.4924, -0.0486, 0.4962, -0.0457, 0.5, -0.0429, 0.5, -0.0562],
        .cursor: [-0.416, 0.0813, -0.3978, 0.0813, -0.3795, 0.0813, -0.3613, 0.0813, -0.3613, 0.0712, -0.3613, 0.0612, -0.3613, 0.0512, -0.3789, 0.0512, -0.3965, 0.0512, -0.4142, 0.0512, -0.44, 0.0456, -0.4581, 0.0287, -0.465, -0.0, -0.4581, -0.0287, -0.44, -0.0456, -0.4142, -0.0512, -0.3965, -0.0512, -0.3789, -0.0512, -0.3613, -0.0512, -0.3613, -0.0612, -0.3613, -0.0712, -0.3613, -0.0813, -0.3803, -0.0813, -0.3993, -0.0813, -0.4183, -0.0813, -0.4607, -0.072, -0.4894, -0.0447, -0.5, -0.0, -0.4888, 0.0447, -0.459, 0.072, -0.416, 0.0813, -0.3334, 0.0813, -0.3221, 0.0813, -0.3108, 0.0813, -0.2995, 0.0813, -0.2995, 0.0482, -0.2995, 0.015, -0.2995, -0.0181, -0.2956, -0.0385, -0.2832, -0.0505, -0.2615, -0.0544, -0.2398, -0.0505, -0.2274, -0.0385, -0.2234, -0.0181, -0.2234, 0.015, -0.2234, 0.0482, -0.2234, 0.0813, -0.2121, 0.0813, -0.2009, 0.0813, -0.1896, 0.0813, -0.1896, 0.0458, -0.1896, 0.0104, -0.1896, -0.025, -0.1973, -0.0563, -0.2211, -0.0767, -0.2615, -0.084, -0.3019, -0.0767, -0.3257, -0.0562, -0.3334, -0.0248, -0.3334, 0.0106, -0.3334, 0.0459, -0.3334, 0.0813, -0.0125, 0.0352, -0.0158, 0.0187, -0.0244, 0.0057, -0.0369, -0.0028, -0.0369, -0.0029, -0.0369, -0.0031, -0.0369, -0.0032, -0.0247, -0.0079, -0.0173, -0.0172, -0.0146, -0.0299, -0.0144, -0.047, -0.0142, -0.0641, -0.0139, -0.0813, -0.0252, -0.0813, -0.0365, -0.0813, -0.0478, -0.0813, -0.048, -0.066, -0.0483, -0.0507, -0.0485, -0.0354, -0.0507, -0.0266, -0.0568, -0.021, -0.0668, -0.019, -0.0856, -0.019, -0.1044, -0.019, -0.1232, -0.019, -0.1232, -0.0397, -0.1232, -0.0605, -0.1232, -0.0813, -0.1345, -0.0813, -0.1458, -0.0813, -0.1571, -0.0813, -0.1571, -0.0271, -0.1571, 0.0271, -0.1571, 0.0813, -0.1259, 0.0813, -0.0947, 0.0813, -0.0636, 0.0813, -0.0367, 0.0761, -0.019, 0.0607, -0.0125, 0.0352, -0.0466, 0.0306, -0.0491, 0.0423, -0.0563, 0.0496, -0.068, 0.0521, -0.0864, 0.0521, -0.1048, 0.0521, -0.1232, 0.0521, -0.1232, 0.0377, -0.1232, 0.0234, -0.1232, 0.009, -0.1046, 0.009, -0.0861, 0.009, -0.0675, 0.009, -0.0564, 0.0115, -0.0492, 0.0188, -0.0466, 0.0306, 0.1155, -0.0338, 0.1132, -0.0244, 0.1067, -0.0188, 0.097, -0.0164, 0.0845, -0.0153, 0.0719, -0.0141, 0.0594, -0.013, 0.0321, -0.0064, 0.0156, 0.0085, 0.01, 0.0336, 0.0165, 0.0596, 0.0343, 0.0757, 0.0608, 0.0813, 0.0885, 0.0813, 0.1162, 0.0813, 0.1438, 0.0813, 0.1438, 0.0715, 0.1438, 0.0618, 0.1438, 0.0521, 0.1169, 0.0521, 0.09, 0.0521, 0.0631, 0.0521, 0.053, 0.0501, 0.0464, 0.0442, 0.0441, 0.0345, 0.0465, 0.0249, 0.0532, 0.019, 0.0633, 0.0164, 0.0761, 0.0154, 0.0889, 0.0143, 0.1016, 0.0132, 0.127, 0.0068, 0.1436, -0.0082, 0.1496, -0.0336, 0.1434, -0.0597, 0.1262, -0.0758, 0.1009, -0.0813, 0.072, -0.0813, 0.0431, -0.0813, 0.0142, -0.0813, 0.0142, -0.0715, 0.0142, -0.0618, 0.0142, -0.0521, 0.042, -0.0521, 0.0698, -0.0521, 0.0977, -0.0521, 0.1072, -0.0498, 0.1133, -0.0434, 0.1155, -0.0338, 0.2487, 0.084, 0.293, 0.0737, 0.3218, 0.0447, 0.332, 0.0002, 0.3214, -0.0444, 0.292, -0.0736, 0.2473, -0.084, 0.1993, 0.0197, 0.2072, 0.0706, 0.2487, 0.084, 0.297, -0.0, 0.2907, 0.0293, 0.2736, 0.0479],
        .openAI: [-0.3936, 0.1345, -0.4472, 0.1199, -0.4854, 0.0817, -0.5, 0.0281, -0.4854, -0.0255, -0.4472, -0.0637, -0.3936, -0.0783, -0.34, -0.0638, -0.3018, -0.0256, -0.2872, 0.0281, -0.3227, 0.0635, -0.3582, 0.099, -0.3936, 0.1345, -0.3936, -0.0402, -0.4268, -0.031, -0.4503, -0.0067, -0.4592, 0.0281, -0.4261, 0.0189, -0.4025, -0.0054, -0.3936, -0.0402, -0.1797, 0.0754, -0.1984, 0.0729, -0.2148, 0.0658, -0.2272, 0.0547, -0.2272, 0.0606, -0.2272, 0.0665, -0.2272, 0.0724, -0.2401, 0.0724, -0.2529, 0.0724, -0.2657, 0.0724, -0.2657, 0.0034, -0.2657, -0.0655, -0.2657, -0.1345, -0.2529, -0.1345, -0.2401, -0.1345, -0.2272, -0.1345, -0.2272, -0.1095, -0.2272, -0.0846, -0.2272, -0.0597, -0.215, -0.0699, -0.1986, -0.0762, -0.1797, -0.0783, -0.1421, -0.0682, -0.1157, -0.0411, -0.1058, -0.0015, -0.1157, 0.0381, -0.1421, 0.0653, -0.1797, 0.0754, -0.1862, -0.0449, -0.2066, -0.0395, -0.2217, -0.0244, -0.2275, -0.0015, -0.2071, -0.0069, -0.192, -0.022, -0.1862, -0.0449, -0.0154, 0.0754, -0.0535, 0.0652, -0.0803, 0.038, -0.0904, -0.0015, -0.0812, -0.041, -0.055, -0.0682, -0.0142, -0.0783, 0.0198, -0.0713, 0.0438, -0.0532, 0.057, -0.0287, 0.0445, -0.0287, 0.032, -0.0287, 0.0195, -0.0287, 0.0121, -0.0384, 0.0004, -0.0449, -0.0145, -0.0473, -0.0324, -0.0429, -0.0458, -0.0311, -0.0529, -0.0136, -0.0157, -0.0136, 0.0216, -0.0136, 0.0588, -0.0136, 0.0588, -0.0086, 0.0588, -0.0036, 0.0588, 0.0015, 0.0498, 0.0385, 0.0244, 0.0651, -0.0154, 0.0753, -0.0154, 0.0754, -0.0526, 0.0136, -0.045, 0.0298, -0.0317, 0.0405, -0.0145, 0.0443, 0.0034, 0.0403, 0.0163, 0.0294, 0.0222, 0.0136, -0.0028, 0.0136, -0.0277, 0.0136, -0.0526, 0.0136, 0.1611, 0.0754, 0.144, 0.0729, 0.1287, 0.0659, 0.1176, 0.055, 0.1176, 0.0608, 0.1176, 0.0666, 0.1176, 0.0724, 0.1048, 0.0724, 0.092, 0.0724, 0.0792, 0.0724, 0.0792, 0.0231, 0.0792, -0.0261, 0.0792, -0.0754, 0.092, -0.0754, 0.1048, -0.0754, 0.1176, -0.0754, 0.1176, -0.0489, 0.1176, -0.0224, 0.1176, 0.0041, 0.1216, 0.0243, 0.1328, 0.0375, 0.1501, 0.0423, 0.1658, 0.0378, 0.1755, 0.0259, 0.1788, 0.0083, 0.1788, -0.0196, 0.1788, -0.0475, 0.1788, -0.0754, 0.1916, -0.0754, 0.2044, -0.0754, 0.2172, -0.0754, 0.2172, -0.0454, 0.2172, -0.0155, 0.2172, 0.0145, 0.2101, 0.0465, 0.1906, 0.0677, 0.1611, 0.0754, 0.3156, 0.1315, 0.2877, 0.0625, 0.2599, -0.0064, 0.232, -0.0754, 0.2457, -0.0754, 0.2594, -0.0754, 0.273, -0.0754, 0.279, -0.0603, 0.2849, -0.0452, 0.2908, -0.0301, 0.3225, -0.0301, 0.3542, -0.0301, 0.3859, -0.0301, 0.3918, -0.0452, 0.3977, -0.0603, 0.4037, -0.0754, 0.4175, -0.0754, 0.4314, -0.0754, 0.4453, -0.0754, 0.4177, -0.0064, 0.39, 0.0626, 0.3623, 0.1315, 0.3467, 0.1315, 0.3311, 0.1315, 0.3156, 0.1315, 0.3041, 0.0041, 0.3155, 0.033, 0.3269, 0.0619, 0.3384, 0.0907, 0.3497, 0.0619, 0.361, 0.033, 0.3723, 0.0041, 0.3496, 0.0041, 0.3268, 0.0041, 0.3041, 0.0041, 0.5, 0.1315, 0.487, 0.1315, 0.474, 0.1315, 0.461, 0.1315, 0.461, 0.0625, 0.461, -0.0064, 0.461, -0.0754, 0.474, -0.0754, 0.487, -0.0754, 0.5, -0.0754, 0.5, -0.0064, 0.5, 0.0625, 0.5, 0.1315],
        .deepSeek: [0.4152, 0.1009, 0.3983, 0.1009, 0.3899, 0.0499, 0.3899, -0.0522, 0.4068, -0.0522, 0.4152, -0.0011, 0.4152, 0.1009, -0.4423, 0.0598, -0.4327, 0.0598, -0.4327, 0.0449, -0.4375, 0.0374, -0.4471, 0.0374, -0.4642, 0.0339, -0.4756, 0.0218, -0.479, 0.0038, -0.464, -0.0039, -0.4463, -0.0039, -0.4313, 0.0038, -0.4241, 0.0196, -0.4233, 0.0512, -0.4233, 0.0958, -0.4064, 0.0958, -0.398, 0.0465, -0.398, -0.0522, -0.4149, -0.0522, -0.4233, -0.049, -0.4233, -0.0428, -0.4264, -0.0428, -0.4353, -0.0474, -0.4536, -0.0506, -0.4819, -0.0448, -0.4965, -0.0257, -0.5, 0.0039, -0.4945, 0.0338, -0.4754, 0.054, -0.4471, 0.0598, -0.0664, -0.0482, -0.076, -0.0482, -0.076, -0.0333, -0.0712, -0.0258, -0.0616, -0.0258, -0.0445, -0.0223, -0.0331, -0.0102, -0.0297, 0.0078, -0.0447, 0.0154, -0.0582, 0.0091, -0.0616, -0.009, -0.0616, -0.0703, -0.07, -0.1009, -0.0869, -0.1009, -0.0869, 0.0089, -0.0784, 0.0637, -0.0616, 0.0637, -0.0616, 0.0575, -0.06, 0.0543, -0.0569, 0.0543, -0.0495, 0.059, -0.0313, 0.0622, -0.0029, 0.0564, 0.0162, 0.0362, 0.0217, 0.0062, 0.0162, -0.0238, -0.0029, -0.044, -0.0312, -0.0497, -0.0514, -0.0487, -0.2629, -0.0033, -0.2629, 0.0027, -0.2642, 0.0218, -0.2767, 0.0491, -0.3026, 0.0623, -0.3332, 0.0623, -0.3591, 0.0491, -0.3717, 0.0219, -0.3717, -0.0103, -0.3591, -0.0376, -0.3332, -0.0508, -0.3026, -0.0508, -0.2767, -0.0376, -0.2685, -0.0249, -0.2742, -0.0174, -0.2908, -0.0174, -0.3064, -0.0253, -0.3248, -0.0253, -0.3403, -0.0174, -0.3478, -0.001, -0.3478, 0.0183, -0.3403, 0.0347, -0.3248, 0.0426, -0.3064, 0.0426, -0.2908, 0.0347, -0.2847, 0.0239, -0.2989, 0.0176, -0.3303, 0.0176, -0.3303, 0.0056, -0.3079, -0.0004, -0.2629, -0.0004, -0.2629, -0.0023, -0.1357, 0.0057, -0.1357, -0.0003, -0.1582, -0.0033, -0.2032, -0.0033, -0.2032, 0.0087, -0.1882, 0.0147, -0.1584, 0.0147, -0.1624, 0.0268, -0.1731, 0.0369, -0.1908, 0.0405, -0.1982, 0.0242, -0.1982, 0.0048, -0.1908, -0.0115, -0.1752, -0.0194, -0.1568, -0.0194, -0.1413, -0.0115, -0.1397, -0.0096, -0.1306, -0.0086, -0.1139, -0.0086, -0.1201, -0.0229, -0.1366, -0.0374, -0.166, -0.0434, -0.1785, -0.0161, -0.1681, 0.0085, -0.1387, 0.0145, -0.1261, -0.0128, -0.1284, -0.0173, -0.1357, 0.0057, 0.093, -0.0486, 0.0635, -0.0522, 0.0341, -0.0486, 0.0142, -0.0363, 0.0085, -0.018, 0.0283, -0.018, 0.0389, -0.0217, 0.0448, -0.0279, 0.057, -0.0309, 0.0714, -0.0309, 0.0836, -0.0279, 0.0895, -0.0217, 0.0895, -0.0143, 0.0836, -0.0081, 0.0709, -0.0051, 0.0496, -0.0039, 0.0262, 0.0039, 0.0149, 0.02, 0.0149, 0.0389, 0.0262, 0.0551, 0.0496, 0.0629, 0.0774, 0.0628, 0.1008, 0.0551, 0.1121, 0.039, 0.1047, 0.0295, 0.0876, 0.0295, 0.0851, 0.0365, 0.0767, 0.0413, 0.0641, 0.0427, 0.0587, 0.0365, 0.0588, 0.0291, 0.0641, 0.0229, 0.0747, 0.0199, 0.0964, 0.0187, 0.1223, 0.011, 0.1348, -0.0052, 0.1348, -0.0241, 0.1223, -0.0403, 0.1106, -0.0425, 0.2457, 0.0057, 0.2457, -0.0003, 0.2232, -0.0033, 0.1783, -0.0033, 0.1783, 0.0087, 0.1932, 0.0147, 0.223, 0.0147, 0.219, 0.0268, 0.2084, 0.0369, 0.1907, 0.0405, 0.1832, 0.0242, 0.1832, 0.0048, 0.1907, -0.0115, 0.2062, -0.0194, 0.2246, -0.0194, 0.2402, -0.0115],
        .codex: [0.3952, -0.0346, 0.3736, -0.0052, 0.3521, 0.0241, 0.3306, 0.0535, 0.3436, 0.0535, 0.3565, 0.0535, 0.3695, 0.0535, 0.3846, 0.0331, 0.3997, 0.0126, 0.4148, -0.0078, 0.4299, 0.0126, 0.445, 0.0331, 0.46, 0.0535, 0.4727, 0.0535, 0.4853, 0.0535, 0.4979, 0.0535, 0.4765, 0.0244, 0.4551, -0.0047, 0.4337, -0.0339, 0.4558, -0.0642, 0.4779, -0.0945, 0.5, -0.1248, 0.4869, -0.1248, 0.4738, -0.1248, 0.4608, -0.1248, 0.4452, -0.1034, 0.4296, -0.082, 0.414, -0.0606, 0.3982, -0.082, 0.3824, -0.1034, 0.3666, -0.1248, 0.3539, -0.1248, 0.3412, -0.1248, 0.3284, -0.1248, 0.3507, -0.0947, 0.3729, -0.0647, 0.3952, -0.0346, 0.237, -0.1284, 0.2218, -0.1271, 0.2075, -0.1233, 0.1942, -0.117, 0.1825, -0.1083, 0.1725, -0.0975, 0.1643, -0.0845, 0.1581, -0.0697, 0.1544, -0.0533, 0.1532, -0.0353, 0.1544, -0.0175, 0.1581, -0.0014, 0.1643, 0.0132, 0.1727, 0.0262, 0.1828, 0.037, 0.1946, 0.0456, 0.2076, 0.052, 0.2215, 0.0558, 0.2363, 0.0571, 0.2563, 0.0549, 0.274, 0.0485, 0.2895, 0.0378, 0.3018, 0.0234, 0.3104, 0.0059, 0.3151, -0.0146, 0.3159, -0.0231, 0.3162, -0.0322, 0.3162, -0.0421, 0.2732, -0.0421, 0.2301, -0.0421, 0.1871, -0.0421, 0.1892, -0.0588, 0.1942, -0.073, 0.2021, -0.0845, 0.2122, -0.093, 0.2236, -0.0981, 0.2363, -0.0999, 0.237, -0.0999, 0.2377, -0.0999, 0.2385, -0.0999, 0.248, -0.099, 0.2567, -0.0964, 0.2645, -0.092, 0.2711, -0.0861, 0.2761, -0.079, 0.2795, -0.0706, 0.2909, -0.0706, 0.3023, -0.0706, 0.3137, -0.0706, 0.2799, -0.1089, 0.2564, -0.1251, 0.237, -0.1284, 0.2816, -0.0153, 0.2795, -0.0027, 0.2749, 0.008, 0.2681, 0.0168, 0.2593, 0.0235, 0.2492, 0.0275, 0.2377, 0.0289, 0.2369, 0.0289, 0.2361, 0.0289, 0.2352, 0.0289, 0.2243, 0.0277, 0.2142, 0.024, 0.2049, 0.0178, 0.1974, 0.0094, 0.1918, -0.0017, 0.1882, -0.0153, 0.2193, -0.0153, 0.2505, -0.0153, 0.2816, -0.0153, 0.0207, -0.1284, 0.0058, -0.1271, -0.0081, -0.1233, -0.021, -0.117, -0.0323, -0.1083, -0.0418, -0.0975, -0.0495, -0.0845, -0.0553, -0.0697, -0.0587, -0.0535, -0.0599, -0.0357, -0.0587, -0.0179, -0.0551, -0.0016, -0.0492, 0.0132, -0.0412, 0.0262, -0.0314, 0.037, -0.0199, 0.0456, -0.0069, 0.052, 0.0072, 0.0558, 0.0221, 0.0571, 0.0343, 0.0562, 0.0456, 0.0536, 0.056, 0.0492, 0.0652, 0.0435, 0.0727, 0.0369, 0.0785, 0.0292, 0.0785, 0.0611, 0.0785, 0.093, 0.0785, 0.1248, 0.0898, 0.1248, 0.1011, 0.1248, 0.1124, 0.1248, 0.1124, 0.0416, 0.1124, -0.0416, 0.1124, -0.1248, 0.1011, -0.1248, 0.0898, -0.1248, 0.0785, -0.1248, 0.0785, -0.1166, 0.0785, -0.1084, 0.0785, -0.1002, 0.0728, -0.1077, 0.0652, -0.1143, 0.0557, -0.1202, 0.0448, -0.1247, 0.0331, -0.1275, 0.0207, -0.1284, 0.0275, -0.0995, 0.0371, -0.0986, 0.046, -0.0959, 0.0542, -0.0913, 0.0615, -0.0852, 0.0675, -0.0777, 0.0724, -0.0688, 0.0762, -0.0586, 0.0784, -0.0476, 0.0792, -0.0357, 0.0784, -0.0238, 0.0762, -0.0128, 0.0724, -0.0028, 0.0675, 0.0062, 0.0615, 0.0138, 0.0542, 0.02, 0.0535, 0.02, 0.0528, 0.02, 0.0521, 0.02, 0.0378, 0.018, 0.0255, 0.012, 0.015, 0.0021, 0.0073, -0.0109, 0.0026, -0.0262, 0.0011, -0.0439, 0.0026, -0.0615],
        .openCode: [-0.4231, -0.0385, -0.4402, -0.0385, -0.4573, -0.0385, -0.4744, -0.0385, -0.4744, -0.0214, -0.4744, -0.0043, -0.4744, 0.0128, -0.4573, 0.0128, -0.4402, 0.0128, -0.4231, 0.0128, -0.4231, -0.0043, -0.4231, -0.0214, -0.4231, -0.0385, -0.4231, 0.0385, -0.4402, 0.0385, -0.4573, 0.0385, -0.4744, 0.0385, -0.4744, 0.0128, -0.4744, -0.0128, -0.4744, -0.0385, -0.4573, -0.0385, -0.4402, -0.0385, -0.4231, -0.0385, -0.4231, -0.0128, -0.4231, 0.0128, -0.4231, 0.0385, -0.3974, -0.0641, -0.4316, -0.0641, -0.4658, -0.0641, -0.5, -0.0641, -0.5, -0.0214, -0.5, 0.0214, -0.5, 0.0641, -0.4658, 0.0641, -0.4316, 0.0641, -0.3974, 0.0641, -0.3974, 0.0214, -0.3974, -0.0214, -0.3974, -0.0641, -0.2949, -0.0385, -0.312, -0.0385, -0.3291, -0.0385, -0.3462, -0.0385, -0.3462, -0.0214, -0.3462, -0.0043, -0.3462, 0.0128, -0.3291, 0.0128, -0.312, 0.0128, -0.2949, 0.0128, -0.2949, -0.0043, -0.2949, -0.0214, -0.2949, -0.0385, -0.3462, -0.0385, -0.3291, -0.0385, -0.312, -0.0385, -0.2949, -0.0385, -0.2949, -0.0128, -0.2949, 0.0128, -0.2949, 0.0385, -0.312, 0.0385, -0.3291, 0.0385, -0.3462, 0.0385, -0.3462, 0.0128, -0.3462, -0.0128, -0.3462, -0.0385, -0.2692, -0.0641, -0.2949, -0.0641, -0.3205, -0.0641, -0.3462, -0.0641, -0.3462, -0.0727, -0.3462, -0.0812, -0.3462, -0.0897, -0.3547, -0.0897, -0.3632, -0.0897, -0.3718, -0.0897, -0.3718, -0.0385, -0.3718, 0.0128, -0.3718, 0.0641, -0.3376, 0.0641, -0.3034, 0.0641, -0.2692, 0.0641, -0.2692, 0.0214, -0.2692, -0.0214, -0.2692, -0.0641, -0.141, -0.0128, -0.141, -0.0214, -0.141, -0.0299, -0.141, -0.0385, -0.1667, -0.0385, -0.1923, -0.0385, -0.2179, -0.0385, -0.2179, -0.0299, -0.2179, -0.0214, -0.2179, -0.0128, -0.1923, -0.0128, -0.1667, -0.0128, -0.141, -0.0128, -0.1667, -0.0128, -0.1923, -0.0128, -0.2179, -0.0128, -0.2179, -0.0214, -0.2179, -0.0299, -0.2179, -0.0385, -0.1923, -0.0385, -0.1667, -0.0385, -0.141, -0.0385, -0.141, -0.047, -0.141, -0.0556, -0.141, -0.0641, -0.1752, -0.0641, -0.2094, -0.0641, -0.2436, -0.0641, -0.2436, -0.0214, -0.2436, 0.0214, -0.2436, 0.0641, -0.2094, 0.0641, -0.1752, 0.0641, -0.141, 0.0641, -0.141, 0.0385, -0.141, 0.0128, -0.141, -0.0128, -0.2179, 0.0128, -0.2009, 0.0128, -0.1838, 0.0128, -0.1667, 0.0128, -0.1667, 0.0214, -0.1667, 0.0299, -0.1667, 0.0385, -0.1838, 0.0385, -0.2009, 0.0385, -0.2179, 0.0385, -0.2179, 0.0299, -0.2179, 0.0214, -0.2179, 0.0128, -0.0385, -0.0641, -0.0556, -0.0641, -0.0726, -0.0641, -0.0897, -0.0641, -0.0897, -0.0385, -0.0897, -0.0128, -0.0897, 0.0128, -0.0726, 0.0128, -0.0556, 0.0128, -0.0385, 0.0128, -0.0385, -0.0128, -0.0385, -0.0385, -0.0385, -0.0641, -0.0385, 0.0385, -0.0556, 0.0385, -0.0726, 0.0385, -0.0897, 0.0385, -0.0897, 0.0043, -0.0897, -0.0299, -0.0897, -0.0641, -0.0983, -0.0641, -0.1068, -0.0641, -0.1154, -0.0641, -0.1154, -0.0214, -0.1154, 0.0214, -0.1154, 0.0641, -0.0897, 0.0641, -0.0641, 0.0641, -0.0385, 0.0641, -0.0385, 0.0556, -0.0385, 0.047, -0.0385, 0.0385, -0.0128, -0.0641, -0.0214, -0.0641, -0.0299, -0.0641, -0.0385, -0.0641, -0.0385, -0.0299, -0.0385, 0.0043, -0.0385, 0.0385, -0.0299, 0.0385, -0.0214, 0.0385, -0.0128, 0.0385, -0.0128, 0.0043, -0.0128, -0.0299, -0.0128, -0.0641, 0.1154, -0.0385],
        .zai: [0.4077, -0.1739, 0.4077, -0.0674, 0.4077, 0.039, 0.4077, 0.1454, 0.4372, 0.1454, 0.4667, 0.1454, 0.4963, 0.1454, 0.4963, 0.039, 0.4963, -0.0674, 0.4963, -0.1739, 0.4667, -0.1739, 0.4372, -0.1739, 0.4077, -0.1739, 0.4522, 0.1866, 0.4444, 0.196, 0.4398, 0.2066, 0.4383, 0.2184, 0.4398, 0.23, 0.4444, 0.2405, 0.4522, 0.2498, 0.4647, 0.2483, 0.4759, 0.2438, 0.4858, 0.2364, 0.4937, 0.2271, 0.4984, 0.2167, 0.5, 0.2051, 0.4984, 0.1933, 0.4937, 0.1827, 0.4859, 0.1733, 0.4746, 0.1777, 0.4634, 0.1821, 0.4522, 0.1866, 0.1592, -0.1799, 0.1395, -0.1787, 0.1214, -0.1752, 0.1047, -0.1693, 0.0971, -0.154, 0.0925, -0.1364, 0.091, -0.1165, 0.0921, -0.0997, 0.0953, -0.0848, 0.1008, -0.0718, 0.1081, -0.0606, 0.1169, -0.0508, 0.1274, -0.0427, 0.142, -0.0393, 0.1571, -0.0367, 0.1727, -0.0348, 0.183, -0.0327, 0.1913, -0.0301, 0.1975, -0.0269, 0.2017, -0.0229, 0.2043, -0.0178, 0.2051, -0.0115, 0.2051, -0.0111, 0.2051, -0.0107, 0.2051, -0.0103, 0.2037, 0.0019, 0.1996, 0.0121, 0.1927, 0.0203, 0.1833, 0.0263, 0.1717, 0.0299, 0.1577, 0.0311, 0.1429, 0.0299, 0.1302, 0.0264, 0.1197, 0.0205, 0.0924, 0.0227, 0.0651, 0.0249, 0.0378, 0.0271, 0.0511, 0.0403, 0.0669, 0.0512, 0.085, 0.06, 0.1054, 0.0664, 0.1278, 0.0703, 0.1523, 0.0716, 0.1698, 0.0709, 0.1868, 0.0688, 0.2032, 0.0654, 0.219, 0.0604, 0.2335, 0.054, 0.2467, 0.046, 0.2585, 0.0365, 0.2686, 0.0252, 0.2768, 0.0124, 0.283, -0.0021, 0.2866, -0.0184, 0.2879, -0.0365, 0.2879, -0.1083, 0.2879, -0.1801, 0.2879, -0.2518, 0.2599, -0.2518, 0.2319, -0.2518, 0.2039, -0.2518, 0.2039, -0.2371, 0.2039, -0.2223, 0.2039, -0.2076, 0.203, -0.2076, 0.2022, -0.2076, 0.2014, -0.2076, 0.1957, -0.2172, 0.1888, -0.226, 0.1808, -0.234, 0.1681, -0.2374, 0.1542, -0.2395, 0.139, -0.2402, 0.1457, -0.2201, 0.1525, -0.2, 0.1592, -0.1799, 0.1845, -0.1188, 0.1971, -0.1179, 0.2086, -0.1154, 0.2191, -0.1111, 0.2283, -0.1052, 0.2361, -0.0982, 0.2426, -0.0899, 0.2473, -0.0806, 0.2501, -0.0706, 0.2511, -0.0598, 0.2511, -0.0485, 0.2511, -0.0372, 0.2511, -0.0259, 0.2479, -0.0276, 0.2441, -0.0293, 0.2396, -0.0309, 0.2342, -0.0316, 0.2288, -0.0324, 0.2234, -0.0332, 0.2135, -0.035, 0.2044, -0.0374, 0.1962, -0.0404, 0.189, -0.0442, 0.183, -0.0487, 0.1781, -0.0539, 0.1745, -0.0599, 0.1724, -0.0669, 0.1717, -0.0747, 0.1731, -0.0858, 0.1775, -0.0951, 0.1848, -0.1024, 0.1944, -0.1076, 0.2057, -0.1107, 0.2184, -0.1117, 0.2071, -0.1141, 0.1958, -0.1164, 0.1845, -0.1188, -0.0545, -0.1793, -0.0529, -0.1664, -0.048, -0.1547, -0.0399, -0.1444, -0.0294, -0.1363, -0.0177, -0.1314, -0.0046, -0.1298, 0.0082, -0.1314, 0.0198, -0.1363, 0.0303, -0.1444, 0.0387, -0.1547, 0.0437, -0.1664, 0.0453, -0.1793, 0.0445, -0.1882, 0.0422, -0.1966, 0.0382, -0.2044, 0.0332, -0.2114, 0.0272, -0.2175, 0.0202, -0.2225, -0.0047, -0.2081, -0.0296, -0.1937, -0.0545, -0.1793, -0.4996, -0.1739, -0.4996, -0.1561, -0.4996, -0.1383, -0.4996, -0.1205, -0.4288, -0.0211, -0.358, 0.0783, -0.2872, 0.1776, -0.3581, 0.1776, -0.4291, 0.1776, -0.5, 0.1776, -0.5, 0.2024, -0.5, 0.2271, -0.5, 0.2518],
        .minimax: [-0.5, -0.0909, -0.5, -0.0303, -0.5, 0.0303, -0.5, 0.0909, -0.4872, 0.0909, -0.4744, 0.0909, -0.4615, 0.0909, -0.4482, 0.0702, -0.4348, 0.0495, -0.4214, 0.0288, -0.4084, 0.0495, -0.3954, 0.0702, -0.3824, 0.0909, -0.3703, 0.0909, -0.3582, 0.0909, -0.3462, 0.0909, -0.3462, 0.0303, -0.3462, -0.0303, -0.3462, -0.0909, -0.3582, -0.0908, -0.3703, -0.0906, -0.3824, -0.0904, -0.3824, -0.0519, -0.3824, -0.0135, -0.3824, 0.025, -0.3923, 0.0107, -0.4022, -0.0036, -0.4121, -0.0179, -0.4181, -0.0179, -0.4242, -0.0179, -0.4302, -0.0179, -0.4407, -0.0036, -0.4511, 0.0107, -0.4615, 0.025, -0.4615, -0.0136, -0.4615, -0.0523, -0.4615, -0.0909, -0.4744, -0.0909, -0.4872, -0.0909, -0.5, -0.0909, -0.2775, 0.0909, -0.2892, 0.0909, -0.3009, 0.0909, -0.3126, 0.0909, -0.3126, 0.0303, -0.3126, -0.0303, -0.3126, -0.0909, -0.3009, -0.0909, -0.2892, -0.0909, -0.2775, -0.0909, -0.2775, -0.0303, -0.2775, 0.0303, -0.2775, 0.0909, -0.2451, 0.0909, -0.2328, 0.0909, -0.2205, 0.0909, -0.2082, 0.0909, -0.1855, 0.0534, -0.1628, 0.0158, -0.1401, -0.0217, -0.1401, 0.0158, -0.1401, 0.0534, -0.1401, 0.0909, -0.128, 0.0909, -0.1159, 0.0909, -0.1038, 0.0909, -0.1038, 0.0303, -0.1038, -0.0303, -0.1038, -0.0909, -0.1159, -0.0909, -0.128, -0.0909, -0.1401, -0.0909, -0.1628, -0.0538, -0.1855, -0.0166, -0.2082, 0.0206, -0.2082, -0.0164, -0.2082, -0.0534, -0.2082, -0.0904, -0.2205, -0.0904, -0.2328, -0.0904, -0.2451, -0.0904, -0.2451, -0.0299, -0.2451, 0.0305, -0.2451, 0.0909, -0.0352, 0.0909, -0.0476, 0.0909, -0.0601, 0.0909, -0.0725, 0.0909, -0.0725, 0.0303, -0.0725, -0.0303, -0.0725, -0.0909, -0.0601, -0.0909, -0.0476, -0.0909, -0.0352, -0.0909, -0.0352, -0.0303, -0.0352, 0.0303, -0.0352, 0.0909, -0.0033, 0.0909, -0.0033, 0.0303, -0.0033, -0.0303, -0.0033, -0.0909, 0.0095, -0.0909, 0.0223, -0.0909, 0.0352, -0.0909, 0.0352, -0.0523, 0.0352, -0.0136, 0.0352, 0.025, 0.0456, 0.0107, 0.056, -0.0036, 0.0665, -0.0179, 0.0725, -0.0179, 0.0786, -0.0179, 0.0846, -0.0179, 0.0945, -0.0036, 0.1044, 0.0107, 0.1143, 0.025, 0.1143, -0.0135, 0.1143, -0.0519, 0.1143, -0.0904, 0.1264, -0.0906, 0.1385, -0.0908, 0.1506, -0.0909, 0.1506, -0.0303, 0.1506, 0.0303, 0.1506, 0.0909, 0.1385, 0.0909, 0.1264, 0.0909, 0.1143, 0.0909, 0.1013, 0.0702, 0.0883, 0.0495, 0.0753, 0.0288, 0.0619, 0.0495, 0.0485, 0.0702, 0.0352, 0.0909, 0.0223, 0.0909, 0.0095, 0.0909, -0.0033, 0.0909, 0.1736, -0.0909, 0.1929, -0.0303, 0.2121, 0.0303, 0.2313, 0.0909, 0.2467, 0.0909, 0.2621, 0.0909, 0.2775, 0.0909, 0.2969, 0.0303, 0.3163, -0.0303, 0.3357, -0.0909, 0.3222, -0.0909, 0.3086, -0.0909, 0.2951, -0.0909, 0.2924, -0.0818, 0.2897, -0.0726, 0.287, -0.0635, 0.2653, -0.0635, 0.2437, -0.0635, 0.222, -0.0635, 0.2193, -0.0726, 0.2165, -0.0818, 0.2137, -0.0909, 0.2004, -0.0909, 0.187, -0.0909, 0.1736, -0.0909, 0.2315, -0.0327, 0.2469, -0.0327, 0.2623, -0.0327, 0.2777, -0.0327, 0.2701, -0.0074, 0.2625, 0.0179, 0.2549, 0.0431, 0.2471, 0.0179, 0.2393, -0.0074, 0.2315, -0.0327, 0.5, 0.0909, 0.4855, 0.0909, 0.4711, 0.0909, 0.4566, 0.0909, 0.4456, 0.0725, 0.4346, 0.0541, 0.4237, 0.0356, 0.4125, 0.0541],
        .kimi: [0.4789, 0.0599, 0.486, 0.0599, 0.493, 0.0599, 0.5, 0.0599, 0.5, 0.0209, 0.5, -0.018, 0.5, -0.0569, 0.493, -0.0569, 0.486, -0.0569, 0.4789, -0.0569, 0.4789, -0.018, 0.4789, 0.0209, 0.4789, 0.0599, 0.2651, 0.0599, 0.2651, 0.0494, 0.2651, 0.0389, 0.2651, 0.0284, 0.2715, 0.0284, 0.2779, 0.0284, 0.2842, 0.0284, 0.2842, 0.0214, 0.2842, 0.0144, 0.2842, 0.0074, 0.2779, 0.0074, 0.2715, 0.0074, 0.2651, 0.0074, 0.2651, -0.0141, 0.2651, -0.0355, 0.2651, -0.0569, 0.2581, -0.0569, 0.2511, -0.0569, 0.2441, -0.0569, 0.2441, -0.0355, 0.2441, -0.0141, 0.2441, 0.0074, 0.2382, 0.0074, 0.2322, 0.0074, 0.2263, 0.0074, 0.2263, 0.0144, 0.2263, 0.0214, 0.2263, 0.0284, 0.2322, 0.0284, 0.2382, 0.0284, 0.2441, 0.0284, 0.2441, 0.0389, 0.2441, 0.0494, 0.2441, 0.0599, 0.2511, 0.0599, 0.2581, 0.0599, 0.2651, 0.0599, 0.1178, -0.0061, 0.1178, -0.0231, 0.1178, -0.04, 0.1178, -0.057, 0.1112, -0.057, 0.1045, -0.057, 0.0978, -0.057, 0.0978, -0.0394, 0.0978, -0.0219, 0.0978, -0.0043, 0.0943, 0.0058, 0.0867, 0.0113, 0.0792, 0.013, 0.0791, 0.013, 0.0789, 0.013, 0.0788, 0.013, 0.0705, 0.0112, 0.0617, 0.0043, 0.0576, -0.0101, 0.0576, -0.0257, 0.0576, -0.0414, 0.0576, -0.057, 0.0507, -0.057, 0.0438, -0.057, 0.0368, -0.057, 0.0368, -0.0181, 0.0368, 0.0209, 0.0368, 0.0598, 0.0438, 0.0598, 0.0508, 0.0599, 0.0577, 0.0599, 0.0577, 0.0461, 0.0577, 0.0323, 0.0577, 0.0185, 0.0673, 0.0272, 0.0783, 0.031, 0.0862, 0.0319, 0.0916, 0.0316, 0.0966, 0.0306, 0.1013, 0.0291, 0.1056, 0.0269, 0.1093, 0.0241, 0.1125, 0.0206, 0.1146, 0.0173, 0.1161, 0.014, 0.117, 0.0106, 0.1175, 0.0065, 0.1177, 0.0009, 0.1178, -0.0061, 0.0227, 0.0149, 0.018, 0.0101, 0.0133, 0.0053, 0.0086, 0.0005, -0.0096, 0.01, -0.0258, 0.011, -0.0345, 0.0061, -0.0317, 0.0004, -0.0204, -0.003, -0.0062, -0.0058, -0.0049, -0.0061, -0.0037, -0.0064, -0.0024, -0.0067, 0.0093, -0.0104, 0.0202, -0.0179, 0.0247, -0.0313, 0.0172, -0.0488, 0.0011, -0.0575, -0.0164, -0.0599, -0.0331, -0.0567, -0.0493, -0.0491, -0.0622, -0.0399, -0.0571, -0.0346, -0.0521, -0.0294, -0.047, -0.0241, -0.0289, -0.0354, -0.0107, -0.0382, 0.0, -0.0333, -0.0009, -0.0271, -0.011, -0.024, -0.0289, -0.0215, -0.0449, -0.0156, -0.0546, -0.006, -0.0578, 0.0032, -0.0542, 0.0157, -0.0424, 0.0273, -0.02, 0.0325, -0.0026, 0.0306, 0.0114, 0.0248, 0.0227, 0.0149, -0.1127, 0.0126, -0.1128, 0.0126, -0.1129, 0.0126, -0.1234, 0.0096, -0.1308, 0.002, -0.1336, -0.0098, -0.1336, -0.0255, -0.1336, -0.0412, -0.1336, -0.0569, -0.1413, -0.0569, -0.1489, -0.0569, -0.1566, -0.0569, -0.1566, -0.0283, -0.1566, 0.0002, -0.1566, 0.0288, -0.1492, 0.0288, -0.1418, 0.0288, -0.1344, 0.0288, -0.1344, 0.0247, -0.1344, 0.0206, -0.1344, 0.0165, -0.1342, 0.0167, -0.1341, 0.017, -0.1339, 0.0172, -0.1285, 0.0233, -0.1191, 0.0296, -0.1052, 0.0323, -0.0892, 0.0285, -0.0763, 0.0179, -0.0711, 0.0014, -0.0711, -0.0181, -0.0711, -0.0375, -0.0711, -0.0569, -0.0789, -0.0569, -0.0868, -0.0569, -0.0947, -0.0569, -0.0947, -0.0393, -0.0947, -0.0217, -0.0947, -0.0042, -0.0982, 0.0061, -0.1056, 0.0113],
        .cline: [0.4243, -0.0757, 0.41, -0.0749, 0.3965, -0.0724, 0.3838, -0.0683, 0.3838, -0.0658, 0.3838, -0.0633, 0.3838, -0.0608, 0.3846, -0.0457, 0.3871, -0.0316, 0.3912, -0.0184, 0.3967, -0.0064, 0.4034, 0.0044, 0.4114, 0.014, 0.4252, 0.0132, 0.4379, 0.0107, 0.4495, 0.0066, 0.46, 0.0012, 0.4693, -0.0055, 0.4773, -0.0135, 0.4842, -0.0227, 0.4899, -0.0331, 0.4943, -0.0446, 0.4975, -0.057, 0.4994, -0.0701, 0.5, -0.084, 0.5, -0.0903, 0.5, -0.0966, 0.5, -0.103, 0.4565, -0.103, 0.4131, -0.103, 0.3696, -0.103, 0.3696, -0.1033, 0.3696, -0.1036, 0.3696, -0.1039, 0.3712, -0.1121, 0.3733, -0.1194, 0.3759, -0.1258, 0.379, -0.1315, 0.3829, -0.1368, 0.3875, -0.1416, 0.3927, -0.1462, 0.3984, -0.15, 0.4048, -0.153, 0.4117, -0.1553, 0.4191, -0.1566, 0.4269, -0.1571, 0.4376, -0.1564, 0.4477, -0.1543, 0.4574, -0.1508, 0.4653, -0.1584, 0.4732, -0.166, 0.481, -0.1737, 0.4732, -0.1829, 0.463, -0.1915, 0.4504, -0.1994, 0.4359, -0.2058, 0.4193, -0.2096, 0.4009, -0.2109, 0.4087, -0.1658, 0.4165, -0.1207, 0.4243, -0.0757, 0.4189, 0.0952, 0.4128, 0.0948, 0.407, 0.0937, 0.4015, 0.0917, 0.3964, 0.0892, 0.3916, 0.086, 0.3873, 0.0821, 0.3833, 0.0775, 0.3798, 0.0724, 0.3768, 0.0667, 0.408, 0.0667, 0.4393, 0.0667, 0.4705, 0.0667, 0.4705, 0.0676, 0.4705, 0.0686, 0.4705, 0.0696, 0.4702, 0.0754, 0.4691, 0.0811, 0.4674, 0.0867, 0.4615, 0.0889, 0.4551, 0.0902, 0.448, 0.0906, 0.4383, 0.0921, 0.4286, 0.0937, 0.4189, 0.0952, 0.1048, -0.072, 0.1048, -0.0056, 0.1048, 0.0608, 0.1048, 0.1272, 0.118, 0.1272, 0.1313, 0.1272, 0.1446, 0.1272, 0.1455, 0.1178, 0.1464, 0.1083, 0.1473, 0.0989, 0.1501, 0.1026, 0.1531, 0.1061, 0.1562, 0.1094, 0.1595, 0.1126, 0.163, 0.1155, 0.1667, 0.1182, 0.1722, 0.1112, 0.1769, 0.1031, 0.1807, 0.0937, 0.1834, 0.0832, 0.1851, 0.0713, 0.1856, 0.058, 0.1856, 0.0166, 0.1856, -0.0249, 0.1856, -0.0663, 0.171, -0.0663, 0.1563, -0.0663, 0.1416, -0.0663, 0.1416, -0.0251, 0.1416, 0.0161, 0.1416, 0.0573, 0.1413, 0.065, 0.1404, 0.0719, 0.1389, 0.0779, 0.1367, 0.083, 0.134, 0.0875, 0.1308, 0.0912, 0.1255, 0.0909, 0.1205, 0.0902, 0.1157, 0.0889, 0.1157, 0.0416, 0.1157, -0.0058, 0.1157, -0.0532, 0.101, -0.0532, 0.0863, -0.0532, 0.0717, -0.0532, 0.0827, -0.0595, 0.0937, -0.0657, 0.1048, -0.072, -0.1116, 0.1272, -0.0764, 0.1272, -0.0411, 0.1272, -0.0059, 0.1272, -0.0059, 0.073, -0.0059, 0.0187, -0.0059, -0.0355, 0.0136, -0.0355, 0.0332, -0.0355, 0.0527, -0.0355, 0.0527, -0.0477, 0.0527, -0.0598, 0.0527, -0.072, -0.0021, -0.072, -0.0568, -0.072, -0.1116, -0.072, -0.1116, -0.0598, -0.1116, -0.0477, -0.1116, -0.0355, -0.0911, -0.0355, -0.0707, -0.0355, -0.0503, -0.0355, -0.0503, 0.0065, -0.0503, 0.0486, -0.0503, 0.0906, -0.0707, 0.0906, -0.0911, 0.0906, -0.1116, 0.0906, -0.1116, 0.1028, -0.1116, 0.115, -0.1116, 0.1272, -0.0543, 0.1788, -0.0541, 0.1823, -0.0535, 0.1855, -0.0525, 0.1886, -0.0501, 0.1905, -0.0475, 0.1921, -0.0446, 0.1934, -0.0412, 0.1944, -0.0377, 0.195, -0.0339, 0.1952, -0.0277, 0.1946, -0.0223, 0.1929, -0.0178, 0.1901, -0.0143, 0.1864],
        .kiloCode: [0.4709, -0.0707, 0.4542, -0.0684, 0.4406, -0.0614, 0.431, -0.0507, 0.4262, -0.0365, 0.4255, -0.0193, 0.4255, -0.0012, 0.428, 0.0144, 0.4382, 0.024, 0.455, 0.0263, 0.4715, 0.024, 0.4849, 0.017, 0.4943, 0.0061, 0.4994, -0.008, 0.5, -0.0226, 0.5, -0.0356, 0.4556, -0.0356, 0.4334, -0.0381, 0.4334, -0.0432, 0.4358, -0.056, 0.4432, -0.0637, 0.4552, -0.0662, 0.4648, -0.065, 0.4716, -0.0612, 0.475, -0.055, 0.4912, -0.055, 0.4963, -0.0637, 0.4843, -0.0774, 0.4659, -0.0847, 0.4603, -0.0807, 0.4709, -0.0707, 0.4921, -0.0049, 0.4921, -0.001, 0.4898, 0.0116, 0.4827, 0.0195, 0.4709, 0.0222, 0.4591, 0.0195, 0.4548, 0.0147, 0.4548, 0.012, 0.4846, 0.0122, 0.4988, 0.0117, 0.4976, 0.0104, 0.494, -0.0011, 0.3457, -0.0707, 0.3269, -0.0658, 0.3141, -0.0512, 0.3097, -0.0295, 0.3097, -0.01, 0.3108, 0.0116, 0.3195, 0.03, 0.3355, 0.04, 0.354, 0.0404, 0.3669, 0.0336, 0.3739, 0.0211, 0.3729, 0.0149, 0.3692, 0.0187, 0.373, 0.0187, 0.3747, 0.0272, 0.3741, 0.0444, 0.3741, 0.0646, 0.3823, 0.0747, 0.3987, 0.0747, 0.3987, -0.021, 0.3907, -0.0688, 0.3747, -0.0688, 0.3747, -0.055, 0.3729, -0.0481, 0.3692, -0.0481, 0.3729, -0.0443, 0.3739, -0.0506, 0.3669, -0.0633, 0.354, -0.0699, 0.3543, -0.0495, 0.365, -0.0471, 0.3718, -0.0397, 0.3741, -0.0283, 0.3741, -0.0102, 0.3736, 0.005, 0.3688, 0.0143, 0.3601, 0.0194, 0.3485, 0.0194, 0.3396, 0.0145, 0.3349, 0.0051, 0.3343, -0.0102, 0.3343, -0.0283, 0.3366, -0.0398, 0.3436, -0.0471, 0.3543, -0.0495, 0.2303, -0.07, 0.2151, -0.0654, 0.2102, -0.0511, 0.2096, -0.0339, 0.2096, -0.0161, 0.212, -0.0004, 0.2223, 0.0092, 0.239, 0.0116, 0.2559, 0.0092, 0.2662, -0.0004, 0.2687, -0.0159, 0.2687, -0.0339, 0.2681, -0.0511, 0.263, -0.0654, 0.2479, -0.07, 0.239, -0.0491, 0.2501, -0.0468, 0.2572, -0.0396, 0.2597, -0.0281, 0.2597, -0.0103, 0.2591, 0.005, 0.2542, 0.0143, 0.2451, 0.0191, 0.2331, 0.0191, 0.2239, 0.0143, 0.219, 0.005, 0.2184, -0.0103, 0.2184, -0.0281, 0.2209, -0.0396, 0.228, -0.0468, 0.239, -0.0491, 0.1152, -0.0702, 0.0998, -0.0656, 0.0882, -0.0567, 0.0809, -0.0441, 0.0784, -0.0283, 0.0784, 0.0133, 0.079, 0.0425, 0.0839, 0.0568, 0.0993, 0.0615, 0.1169, 0.0615, 0.1321, 0.0568, 0.1371, 0.0425, 0.1295, 0.0342, 0.113, 0.0342, 0.1105, 0.0456, 0.1034, 0.0526, 0.0922, 0.055, 0.0808, 0.0526, 0.0736, 0.0456, 0.0711, 0.0344, 0.0711, -0.0074, 0.0718, -0.0345, 0.0767, -0.0438, 0.086, -0.0485, 0.0983, -0.0485, 0.1075, -0.0438, 0.1124, -0.0345, 0.1212, -0.0283, 0.1378, -0.0283, 0.1352, -0.0439, 0.1249, -0.0535, 0.1081, -0.0558, 0.1187, -0.0658, -0.1085, -0.0705, -0.1252, -0.0683, -0.1355, -0.0586, -0.1379, -0.0428, -0.1379, -0.025, -0.1373, -0.0079, -0.1324, 0.0063, -0.1173, 0.011, -0.0996, 0.011, -0.0845, 0.0063, -0.0794, -0.0078, -0.0788, -0.0249, -0.0788, -0.0428, -0.0813, -0.0586, -0.0916, -0.0683, -0.1085, -0.0705, -0.1024, -0.0485, -0.0933, -0.0438, -0.0885, -0.0344, -0.0878, -0.0192, -0.0878, -0.0014, -0.0903, 0.0102, -0.0974, 0.0173, -0.1085, 0.0196, -0.1195, 0.0173, -0.1236, 0.0054, -0.1236, -0.0124, -0.1212, -0.0239],
        .rooCode: [-0.4635, -0.0068, -0.4369, -0.0068, -0.4159, -0.0062, -0.4047, -0.0013, -0.3991, 0.0092, -0.3991, 0.0239, -0.4047, 0.034, -0.4159, 0.0389, -0.4369, 0.0395, -0.4635, 0.0395, -0.4635, 0.0086, -0.5, 0.0676, -0.4403, 0.0676, -0.4033, 0.0672, -0.3905, 0.0639, -0.3833, 0.0547, -0.3788, 0.0439, -0.3773, 0.0319, -0.3801, 0.0143, -0.3885, 0.0003, -0.4035, -0.0093, -0.4035, -0.0096, -0.3993, -0.0113, -0.3924, -0.0155, -0.3872, -0.0212, -0.3835, -0.028, -0.3812, -0.0358, -0.3798, -0.0441, -0.3792, -0.051, -0.3789, -0.0575, -0.3785, -0.0646, -0.3777, -0.0719, -0.3763, -0.0789, -0.374, -0.0847, -0.3846, -0.0872, -0.4089, -0.0872, -0.4119, -0.0754, -0.4143, -0.0607, -0.4205, -0.0496, -0.432, -0.0443, -0.448, -0.0436, -0.4635, -0.0436, -0.4635, -0.0865, -0.4757, -0.1079, -0.5, -0.1079, -0.5, 0.0091, -0.3181, -0.0374, -0.3175, -0.0469, -0.3156, -0.0558, -0.312, -0.0637, -0.3065, -0.0698, -0.299, -0.074, -0.289, -0.0754, -0.2791, -0.074, -0.273, -0.0684, -0.2702, -0.06, -0.2708, -0.0506, -0.2756, -0.044, -0.2855, -0.0425, -0.2955, -0.044, -0.3057, -0.0431, -0.3181, -0.0374, -0.3506, -0.0282, -0.3467, -0.0116, -0.3391, 0.0024, -0.3262, 0.0107, -0.3086, 0.0128, -0.2946, 0.0052, -0.2838, -0.0057, -0.2762, -0.0197, -0.2723, -0.0363, -0.2776, -0.0505, -0.2916, -0.0579, -0.308, -0.0618, -0.3196, -0.0543, -0.3216, -0.0365, -0.3412, -0.0371, -0.1876, -0.0374, -0.187, -0.0469, -0.1851, -0.0558, -0.1816, -0.0637, -0.1729, -0.0666, -0.1624, -0.0666, -0.1537, -0.0637, -0.15, -0.0558, -0.149, -0.0468, -0.1502, -0.0374, -0.1589, -0.0344, -0.1694, -0.0344, -0.1781, -0.0374, -0.1845, -0.0374, -0.2206, -0.0374, -0.2187, -0.0196, -0.2129, -0.0042, -0.2037, 0.0082, -0.1872, 0.0123, -0.1689, 0.0123, -0.1525, 0.0082, -0.1386, 0.0006, -0.1278, -0.0103, -0.1202, -0.0243, -0.1163, -0.0409, -0.1216, -0.0551, -0.1356, -0.0625, -0.152, -0.0664, -0.1703, -0.0664, -0.1867, -0.0625, -0.1906, -0.046, -0.2009, -0.037, -0.2206, -0.0374, 0.0729, 0.0118, 0.0598, 0.0075, 0.0609, -0.0061, 0.0642, -0.019, 0.07, -0.0303, 0.0832, -0.0344, 0.1013, -0.0338, 0.117, -0.0248, 0.1264, -0.0084, 0.1404, 0.002, 0.164, 0.002, 0.1601, -0.0173, 0.1479, -0.0285, 0.1286, -0.0305, 0.1049, -0.0277, 0.0847, -0.0191, 0.0687, -0.0059, 0.0637, 0.016, 0.0637, 0.0397, 0.0687, 0.0618, 0.0783, 0.0812, 0.0922, 0.0968, 0.1103, 0.1079, 0.0359, 0.0724, 0.0535, 0.0711, 0.0703, 0.0676, 0.0766, 0.0514, 0.0664, 0.0423, 0.0429, 0.0423, 0.0681, 0.0223, 0.1566, -0.0374, 0.1572, -0.0469, 0.1591, -0.0558, 0.1626, -0.0637, 0.1682, -0.0698, 0.1757, -0.074, 0.1856, -0.0754, 0.1955, -0.074, 0.2017, -0.0684, 0.2044, -0.06, 0.2038, -0.0506, 0.199, -0.044, 0.1891, -0.0425, 0.1792, -0.044, 0.169, -0.0431, 0.1566, -0.0374, 0.1241, -0.0282, 0.128, -0.0116, 0.1355, 0.0024, 0.1484, 0.0107, 0.1661, 0.0128, 0.1838, 0.0107, 0.199, 0.0048, 0.2114, -0.0045, 0.2206, -0.0169, 0.2264, -0.0323, 0.2284, -0.0501, 0.216, -0.0592, 0.2007, -0.065, 0.183, -0.0669, 0.1654, -0.065, 0.155, -0.0546, 0.1531, -0.0368, 0.1334, -0.0372, 0.343, -0.037, 0.3424, -0.0275, 0.3378, -0.0211, 0.3282, -0.0197, 0.3185, -0.0211, 0.3146, -0.0275],
        .hermes: [0.4912, 0.1215, 0.4505, 0.1948, 0.424, 0.1591, 0.5, 0.0303, 0.4305, -0.0126, 0.3901, 0.0587, 0.3906, 0.0725, 0.4126, 0.0147, 0.4641, 0.0064, 0.4083, 0.101, 0.3851, 0.1495, 0.4199, 0.2013, 0.4453, 0.2031, 0.4452, 0.1789, 0.4758, 0.1283, -0.3906, 0.1108, -0.3813, 0.1693, -0.4022, 0.1984, -0.3477, 0.2008, -0.3189, 0.2004, -0.3186, 0.199, -0.3322, 0.1744, -0.3329, 0.0497, -0.3281, 0.0084, -0.3837, -0.001, -0.3814, 0.0093, -0.39, 0.025, -0.4032, 0.0137, -0.384, -0.0012, -0.4597, 0.0024, -0.4499, 0.0369, -0.4498, 0.1607, -0.4963, 0.1973, -0.4434, 0.1991, -0.4173, 0.1962, -0.4386, 0.1501, -0.4193, 0.1099, -0.4082, 0.1108, 0.0963, 0.3644, 0.0967, 0.2527, 0.1087, 0.1931, 0.0688, 0.1813, 0.0878, 0.224, 0.0845, 0.3028, 0.0665, 0.3139, 0.0916, 0.1427, 0.1078, 0.0838, 0.1436, 0.201, 0.2092, 0.2024, 0.1927, 0.1928, 0.1869, 0.1516, 0.1875, 0.0255, 0.2034, -0.0006, 0.2054, -0.0033, 0.1765, -0.0033, 0.1246, -0.0027, 0.145, 0.0223, 0.1467, 0.0948, 0.1464, 0.1818, 0.1476, 0.179, 0.2851, 0.0, 0.3527, 0.0776, 0.3531, 0.0323, 0.2212, -0.0074, 0.2432, 0.0266, 0.2428, 0.0691, 0.221, 0.0982, 0.2639, 0.0997, 0.3521, 0.0408, 0.2858, 0.1942, 0.2858, 0.1087, 0.2868, 0.1077, 0.3256, 0.1506, 0.3263, 0.1007, 0.326, 0.0567, 0.2873, 0.0985, 0.2863, 0.0018, -0.2101, 0.0137, -0.1745, 0.0766, -0.1745, -0.0074, -0.295, -0.0028, -0.2839, 0.036, -0.2864, 0.0803, -0.3071, 0.0986, -0.1965, 0.0998, -0.1765, 0.0276, -0.2412, 0.1658, -0.241, 0.1084, -0.2398, 0.1076, -0.201, 0.1499, -0.2007, 0.0902, -0.2392, 0.104, -0.2403, 0.0055, -0.0631, 0.0993, -0.0315, 0.0954, -0.0167, 0.0895, -0.0423, 0.1473, -0.0287, 0.1292, -0.1047, 0.1267, -0.0826, 0.1577, -0.0817, 0.159, -0.0843, 0.1806, -0.1048, 0.1986, -0.053, 0.1999, 0.0324, 0.1468, -0.0367, 0.0977, -0.0842, 0.1658, -0.0841, 0.102, -0.0706, 0.1054, -0.0562, 0.1191, -0.0492, 0.14, -0.0489, 0.1543, -0.0665, 0.1921, -0.0841, 0.1978, -0.287, -0.1989, -0.3258, -0.2754, -0.3948, -0.2513, -0.4099, -0.1124, -0.3091, -0.0636, -0.2903, -0.1407, -0.3318, -0.1014, -0.3526, -0.1776, -0.2976, -0.2644, -0.2949, -0.2314, -0.3081, -0.1743, -0.287, -0.1676, -0.4867, -0.2218, -0.4764, -0.1622, -0.4604, -0.0739, -0.4173, -0.0684, -0.3918, -0.2731, -0.4454, -0.2726, -0.4287, -0.2692, -0.4396, -0.2368, -0.4852, -0.2739, -0.4422, -0.2065, -0.4494, -0.0922, -0.4765, -0.2066, -0.1431, -0.2651, -0.0887, -0.2206, -0.0745, -0.1901, -0.142, -0.2726, -0.1884, -0.2608, -0.1838, -0.2204, -0.1904, -0.1755, -0.2076, -0.1661, -0.076, -0.1654, -0.0906, -0.2069, -0.1437, -0.229, -0.1433, -0.2583, -0.1232, -0.2524, -0.1033, -0.2163, -0.1025, -0.2186, -0.1026, -0.3086, -0.1226, -0.2751, -0.1415, -0.3644, -0.0154, -0.123, -0.0148, -0.2064, -0.0038, -0.259, -0.0417, -0.2705, -0.0225, -0.1923, -0.0385, -0.184, 0.0005, -0.1832, 0.0023, -0.1569, -0.0048, -0.0732, 0.0304, -0.0585, 0.0092, -0.1027, -0.0535, -0.0363, -0.0154, -0.123, 0.2702, -0.0626, 0.2701, -0.1514, 0.261, -0.1273, 0.2232, -0.0683, 0.2234, -0.2239, 0.2303, -0.2581, 0.2465, -0.268, 0.1816, -0.2681, 0.17, -0.2647, 0.1835, -0.2458, 0.1856, -0.1647],
        .piAgent: [-0.4953, -0.0709, -0.5, -0.0653, -0.4941, -0.059, -0.485, -0.0504, -0.4872, 0.0485, -0.4982, 0.0533, -0.5, 0.0588, -0.4692, 0.0634, -0.4515, 0.0583, -0.4554, 0.0521, -0.4663, 0.0463, -0.4663, -0.0537, -0.4555, -0.0596, -0.4515, -0.0658, -0.4693, -0.0709, -0.4438, -0.0689, -0.4439, -0.0628, -0.4363, -0.0592, -0.4309, -0.0187, -0.4426, 0.0086, -0.4444, 0.0134, -0.4285, 0.0225, -0.4149, 0.0185, -0.4118, 0.0142, -0.3884, 0.0242, -0.3528, -0.0183, -0.3472, -0.0592, -0.3398, -0.0628, -0.3399, -0.0689, -0.3653, -0.0711, -0.37, -0.0258, -0.3858, 0.0097, -0.3876, -0.0446, -0.3797, -0.0526, -0.3742, -0.0583, -0.3789, -0.0638, -0.4309, -0.0686, -0.3282, -0.0711, -0.3329, -0.0655, -0.3275, -0.0599, -0.3194, -0.0518, -0.3206, 0.0108, -0.3315, 0.0118, -0.3337, 0.0173, -0.3285, 0.0233, -0.3229, 0.0333, -0.2815, 0.0733, -0.2566, 0.0685, -0.2412, 0.0732, -0.2374, -0.0518, -0.2292, -0.0599, -0.2237, -0.0655, -0.2287, -0.0711, -0.2674, -0.0689, -0.2676, -0.0628, -0.2599, -0.0591, -0.2543, 0.0116, -0.2674, 0.0564, -0.3073, 0.0425, -0.2819, 0.0237, -0.276, 0.018, -0.2807, 0.0111, -0.302, 0.01, -0.3019, -0.0553, -0.293, -0.0603, -0.2889, -0.066, -0.138, -0.0528, -0.2189, -0.0502, -0.1621, 0.0215, -0.1443, -0.0109, -0.1858, -0.0515, -0.1427, -0.0418, -0.1366, -0.0497, -0.2083, -0.0178, -0.2055, -0.0203, -0.1604, -0.0028, -0.1947, 0.0088, -0.1087, 0.0186, -0.067, 0.0235, -0.0572, 0.0213, -0.0475, -0.0044, -0.0524, -0.0068, -0.0853, 0.0131, -0.0961, -0.0523, -0.052, -0.0478, -0.0465, -0.056, -0.1242, -0.0501, -0.0277, 0.0083, -0.039, 0.0103, -0.0393, 0.0182, -0.0186, 0.0403, -0.0083, 0.0416, -0.0016, 0.0253, 0.0155, 0.0208, 0.0133, 0.0135, -0.0085, -0.0068, 0.0006, -0.0552, 0.0058, -0.0628, -0.0286, -0.0482, 0.0279, -0.0693, 0.0278, -0.0632, 0.0354, -0.0595, 0.0408, -0.0193, 0.0292, 0.0079, 0.0273, 0.0127, 0.0438, 0.022, 0.0578, -0.0044, 0.0632, -0.0595, 0.0708, -0.0632, 0.0707, -0.0693, 0.0321, -0.0714, 0.054, 0.0635, 0.0471, 0.0413, 0.0774, 0.0015, 0.0711, -0.0242, 0.0553, -0.0078, 0.1157, 0.011, 0.1035, -0.0538, 0.1727, -0.0714, 0.1679, -0.0659, 0.1734, -0.0603, 0.1814, -0.0522, 0.178, 0.0053, 0.1679, 0.0123, 0.1721, 0.0177, 0.1964, 0.0233, 0.1979, 0.0139, 0.2037, 0.0156, 0.2567, 0.0127, 0.26, -0.0557, 0.2688, -0.0607, 0.273, -0.0664, 0.2612, -0.0714, 0.2424, -0.0668, 0.2372, 0.0094, 0.2248, -0.0124, 0.2301, -0.0522, 0.2378, -0.0559, 0.2376, -0.062, 0.199, -0.0641, 0.4822, -0.0713, 0.4513, -0.0667, 0.4531, -0.0611, 0.4642, -0.0564, 0.4664, 0.0428, 0.4572, 0.0514, 0.4513, 0.0578, 0.4561, 0.0634, 0.4994, 0.0613, 0.4995, 0.0549, 0.4903, 0.0502, 0.4847, -0.0195, 0.4922, -0.0587, 0.5, -0.0652, 0.4978, -0.0708, 0.3165, -0.0713, 0.3115, -0.0658, 0.3165, -0.0602, 0.3296, -0.0494, 0.3638, 0.047, 0.3503, 0.0532, 0.3494, 0.0594, 0.3704, 0.0634, 0.3988, 0.0238, 0.438, -0.0586, 0.4454, -0.0632, 0.4452, -0.0692, 0.4037, -0.0713, 0.3987, -0.0657, 0.4035, -0.0603, 0.41, -0.0517, 0.4019, -0.033, 0.3514, -0.033, 0.3441, -0.05, 0.3516, -0.0607, 0.3564, -0.0658, 0.3516, -0.0713, 0.3966, -0.0208, 0.3778, 0.0309, 0.3621, -0.0019],
        .geminiCLI: [-0.2556, 0.0004, -0.259, -0.0311, -0.269, -0.058, -0.2857, -0.0803, -0.3105, -0.1001, -0.3401, -0.112, -0.3744, -0.116, -0.4077, -0.1119, -0.4374, -0.0998, -0.4635, -0.0796, -0.4838, -0.0534, -0.4959, -0.0235, -0.5, 0.0101, -0.4959, 0.0438, -0.4838, 0.0737, -0.4635, 0.0998, -0.4374, 0.1201, -0.4077, 0.1322, -0.3744, 0.1363, -0.357, 0.1352, -0.3402, 0.1321, -0.3241, 0.1268, -0.3093, 0.1197, -0.2964, 0.1108, -0.2853, 0.1002, -0.2927, 0.0928, -0.3002, 0.0854, -0.3076, 0.0779, -0.3158, 0.0863, -0.3254, 0.0933, -0.3365, 0.099, -0.3614, 0.096, -0.3837, 0.0869, -0.4033, 0.0717, -0.4183, 0.0517, -0.4273, 0.0287, -0.4303, 0.0026, -0.4107, -0.0126, -0.3884, -0.0217, -0.3635, -0.0248, -0.3407, -0.0225, -0.3207, -0.0158, -0.3034, -0.0045, -0.2897, 0.0106, -0.2804, 0.0292, -0.2757, 0.0511, -0.305, 0.0511, -0.3342, 0.0511, -0.3635, 0.0511, -0.3635, 0.0608, -0.3635, 0.0705, -0.3635, 0.0801, -0.3244, 0.0801, -0.2854, 0.0801, -0.2463, 0.0801, -0.2454, 0.0739, -0.2448, 0.0678, -0.2447, 0.0619, -0.1472, 0.1209, -0.1241, 0.1183, -0.1044, 0.1102, -0.088, 0.0969, -0.0758, 0.0788, -0.0685, 0.0563, -0.066, 0.0296, -0.0661, 0.0285, -0.0663, 0.0273, -0.0664, 0.0262, -0.1138, 0.0262, -0.1612, 0.0262, -0.2086, 0.0262, -0.2065, 0.0109, -0.201, -0.0023, -0.1922, -0.0133, -0.1811, -0.0216, -0.1686, -0.0266, -0.1547, -0.0283, -0.1362, -0.025, -0.1205, -0.015, -0.1077, 0.0017, -0.0984, -0.0029, -0.089, -0.0074, -0.0797, -0.0119, -0.1156, -0.0851, -0.1387, -0.1136, -0.1561, -0.1185, -0.1792, -0.1157, -0.1994, -0.1073, -0.2168, -0.0932, -0.23, -0.075, -0.238, -0.0537, -0.2406, -0.0295, -0.2381, -0.0055, -0.2303, 0.0157, -0.2175, 0.034, -0.2006, 0.0481, -0.1808, 0.0566, -0.1581, 0.0594, -0.1588, 0.0308, -0.1701, 0.0295, -0.1803, 0.0259, -0.1893, 0.0199, -0.1969, 0.0118, -0.2025, 0.002, -0.2062, -0.0094, -0.1743, -0.0094, -0.1423, -0.0094, -0.1104, -0.0094, -0.1126, 0.0015, -0.1173, 0.0111, -0.1245, 0.0193, -0.134, 0.0257, -0.1455, 0.0295, -0.1588, 0.0308, -0.0256, -0.1125, -0.036, -0.1125, -0.0464, -0.1125, -0.0568, -0.1125, -0.0568, -0.057, -0.0568, -0.0015, -0.0568, 0.0539, -0.0469, 0.0539, -0.0369, 0.0539, -0.0269, 0.0539, -0.0269, 0.0462, -0.0269, 0.0385, -0.0269, 0.0308, -0.0265, 0.0308, -0.026, 0.0308, -0.0256, 0.0308, -0.02, 0.0385, -0.0126, 0.0453, -0.0036, 0.0512, 0.0062, 0.0558, 0.016, 0.0585, 0.0258, 0.0594, 0.0375, 0.0584, 0.0483, 0.0556, 0.0581, 0.0509, 0.0737, 0.0686, 0.0928, 0.0793, 0.1155, 0.0828, 0.1333, 0.0809, 0.1481, 0.075, 0.16, 0.0651, 0.1687, 0.0517, 0.1739, 0.035, 0.1757, 0.0149, 0.1757, -0.0198, 0.1757, -0.0544, 0.1757, -0.0891, 0.1653, -0.0891, 0.1548, -0.0891, 0.1444, -0.0891, 0.1444, -0.056, 0.1444, -0.0229, 0.1444, 0.0101, 0.1435, 0.0243, 0.1406, 0.0356, 0.1359, 0.0439, 0.129, 0.0497, 0.1194, 0.0531, 0.1074, 0.0543, 0.096, 0.0526, 0.0859, 0.0475, 0.0771, 0.039, 0.0703, 0.0282, 0.0662, 0.0162, 0.0649, 0.003, 0.0649, -0.0277, 0.0649, -0.0584, 0.0649, -0.0891, 0.0544, -0.0891, 0.044, -0.0891, 0.0336, -0.0891, 0.0336, -0.056, 0.0336, -0.0229, 0.0336, 0.0101, 0.0326, 0.0243, 0.0298, 0.0356],
        .antigravity: [0.461, -0.0505, 0.4507, -0.0494, 0.4531, -0.0441, 0.4552, -0.0394, 0.4572, -0.0351, 0.4624, -0.024, 0.4382, 0.0392, 0.4561, 0.0236, 0.4695, -0.0076, 0.4886, 0.0392, 0.4891, 0.0141, 0.4664, -0.0381, 0.4638, -0.0442, 0.3967, 0.0265, 0.4004, 0.036, 0.4078, 0.0479, 0.4183, 0.0538, 0.4235, 0.036, 0.4338, 0.0297, 0.4183, 0.0265, 0.4186, -0.0111, 0.4243, -0.018, 0.4307, -0.0178, 0.434, -0.0196, 0.4249, -0.0243, 0.4165, -0.0089, 0.4128, 0.0265, 0.3996, 0.0265, 0.3779, 0.015, 0.3884, 0.036, 0.3849, -0.0271, 0.3833, 0.0497, 0.3891, 0.052, 0.3929, 0.0454, 0.3891, 0.0389, 0.3838, 0.0444, 0.3189, 0.015, 0.3217, 0.036, 0.3413, -0.0147, 0.3612, 0.036, 0.3637, 0.015, 0.3394, -0.0271, 0.2679, -0.0278, 0.2678, -0.0147, 0.2816, -0.0061, 0.2961, -0.0054, 0.3048, -0.0074, 0.3088, -0.0078, 0.3066, 0.003, 0.2914, 0.0103, 0.279, 0.0099, 0.2791, 0.017, 0.3023, 0.0113, 0.3096, -0.0203, 0.3029, -0.047, 0.2996, -0.0379, 0.2978, -0.0397, 0.2825, -0.0338, 0.2844, -0.0185, 0.2947, -0.0097, 0.2954, 0.0015, 0.2804, 0.0019, 0.2729, -0.0094, 0.2797, -0.0196, 0.2806, -0.0202, 0.2147, 0.015, 0.2247, 0.036, 0.2249, 0.0259, 0.2275, 0.0302, 0.2359, 0.0363, 0.2414, 0.0357, 0.2434, 0.0274, 0.2434, -0.0116, 0.2268, -0.0167, 0.1662, -0.0554, 0.1508, -0.0489, 0.1432, -0.0381, 0.1545, -0.0372, 0.1669, -0.0458, 0.1865, -0.0404, 0.1918, -0.0221, 0.1915, -0.0174, 0.1828, -0.0252, 0.1657, -0.0251, 0.1557, -0.0056, 0.1659, 0.0124, 0.1823, 0.0069, 0.1877, 0.0014, 0.1879, 0.0104, 0.1979, -0.0098, 0.1961, -0.0626, 0.1782, -0.0711, 0.1713, -0.0188, 0.1803, -0.0068, 0.1803, 0.0113, 0.1713, 0.023, 0.1581, 0.0181, 0.151, 0.0042, 0.1535, -0.0134, 0.1644, -0.0206, 0.1202, -0.006, 0.1272, 0.036, 0.1307, -0.0271, 0.1254, 0.0476, 0.1203, 0.0519, 0.1257, 0.0572, 0.1329, 0.0552, 0.1349, 0.0479, 0.1297, 0.0426, 0.1254, 0.0476, 0.0731, 0.036, 0.0842, 0.042, 0.0912, 0.0538, 0.0947, 0.036, 0.1102, 0.0329, 0.0999, 0.0265, 0.0947, -0.0079, 0.0985, -0.0172, 0.1059, -0.0181, 0.1104, -0.0162, 0.1055, -0.0259, 0.0934, -0.0139, 0.0928, 0.0265, 0.0788, 0.0265, 0.0128, -0.006, 0.0195, 0.036, 0.0229, 0.0268, 0.0253, 0.0297, 0.0394, 0.0376, 0.0612, 0.0312, 0.0671, -0.0001, 0.0601, -0.0271, 0.0566, 0.0118, 0.049, 0.0268, 0.0345, 0.0272, 0.0256, 0.0181, 0.0221, -0.0174, 0.0136, -0.0238, -0.0509, 0.032, -0.0278, 0.0615, 0.002, -0.0271, -0.0117, -0.0108, -0.0528, -0.0027, -0.0657, -0.0271, -0.0222, 0.0178, -0.0324, 0.0455, -0.034, 0.0486, -0.0414, 0.0285, -0.0286, 0.0072, -0.493, -0.0042, -0.4492, 0.0711, -0.4182, 0.0541, -0.4393, 0.0561, -0.4851, 0.021, -0.4379, -0.0138, -0.418, 0.0049, -0.4496, 0.0119, -0.4341, 0.0256, -0.4026, 0.0201, -0.4143, -0.015, -0.3331, 0.0032, -0.3546, -0.0183, -0.3498, 0.0134, -0.381, 0.0134, -0.3654, -0.0163, -0.2628, 0.0032, -0.2843, -0.0183, -0.2795, 0.0134, -0.3107, 0.0134, -0.2951, -0.0163, -0.1956, 0.0335, -0.1998, -0.0437, -0.2492, -0.0477, -0.2424, -0.0338, -0.217, -0.0431, -0.209, -0.0233, -0.2095, -0.0217, -0.2416, -0.0247, -0.2444, -0.0006, -0.2398, -0.0041],
        .goose: [-0.3176, -0.0435, -0.3297, -0.0918, -0.3626, -0.1222, -0.4114, -0.1327, -0.4511, -0.1265, -0.4807, -0.1078, -0.4989, -0.0768, -0.4852, -0.0719, -0.4715, -0.067, -0.4579, -0.0622, -0.4486, -0.0808, -0.4329, -0.0929, -0.4114, -0.0972, -0.3852, -0.0922, -0.3678, -0.076, -0.3615, -0.0475, -0.3615, -0.043, -0.3615, -0.0385, -0.3615, -0.034, -0.3747, -0.0463, -0.3931, -0.0549, -0.4157, -0.0581, -0.461, -0.0451, -0.4899, -0.0108, -0.5, 0.0373, -0.4899, 0.0854, -0.461, 0.1197, -0.4157, 0.1327, -0.3932, 0.1295, -0.3748, 0.1208, -0.3615, 0.1086, -0.3615, 0.1154, -0.3615, 0.1222, -0.3615, 0.1291, -0.3469, 0.1291, -0.3322, 0.1291, -0.3176, 0.1291, -0.3176, 0.0715, -0.3176, 0.014, -0.3176, -0.0435, -0.3608, 0.0391, -0.3667, 0.069, -0.383, 0.0878, -0.4073, 0.0943, -0.4334, 0.0875, -0.4499, 0.068, -0.4557, 0.0373, -0.4499, 0.0067, -0.4334, -0.0128, -0.4073, -0.0197, -0.383, -0.0133, -0.3667, 0.0053, -0.3608, 0.0347, -0.3608, 0.0362, -0.3608, 0.0377, -0.3608, 0.0391, -0.0953, 0.0329, -0.1073, -0.0195, -0.1398, -0.0543, -0.188, -0.0669, -0.2361, -0.0543, -0.2687, -0.0195, -0.2807, 0.0329, -0.2687, 0.0853, -0.2361, 0.1201, -0.188, 0.1327, -0.1398, 0.1201, -0.1073, 0.0853, -0.0953, 0.0329, -0.2363, 0.0329, -0.2304, -0.0008, -0.2137, -0.0224, -0.188, -0.03, -0.1622, -0.0224, -0.1456, -0.0008, -0.1396, 0.0329, -0.1456, 0.0666, -0.1622, 0.0882, -0.188, 0.0958, -0.2137, 0.0882, -0.2304, 0.0666, -0.2363, 0.0329, 0.1148, 0.0329, 0.1028, -0.0195, 0.0702, -0.0543, 0.0221, -0.0669, -0.0312, 0.0557, -0.0226, 0.1164, 0.0221, 0.1327, 0.053, 0.0994, 0.0839, 0.0662, 0.1148, 0.0329, -0.0263, 0.0329, -0.0203, -0.0008, -0.0036, -0.0224, 0.0221, -0.03, 0.0161, 0.0037, -0.0005, 0.0253, -0.0263, 0.0329, -0.052, 0.0253, -0.0687, 0.0037, -0.0746, -0.03, -0.0585, -0.009, -0.0424, 0.0119, -0.0263, 0.0329, 0.1314, -0.0263, 0.1424, -0.0175, 0.1534, -0.0088, 0.1644, -0.0, 0.1789, -0.0163, 0.1982, -0.0272, 0.2201, -0.0311, 0.2377, -0.0287, 0.2508, -0.0211, 0.256, -0.0073, 0.2507, 0.005, 0.235, 0.0117, 0.2094, 0.0172, 0.179, 0.0251, 0.1544, 0.041, 0.1442, 0.072, 0.1538, 0.1034, 0.1802, 0.1248, 0.2193, 0.1327, 0.2513, 0.128, 0.2782, 0.1153, 0.297, 0.0965, 0.2871, 0.0876, 0.2772, 0.0787, 0.2673, 0.0698, 0.254, 0.0845, 0.2369, 0.0937, 0.2168, 0.0969, 0.2011, 0.0943, 0.1908, 0.0871, 0.1871, 0.076, 0.1916, 0.0654, 0.2045, 0.0592, 0.2252, 0.0545, 0.2588, 0.0462, 0.287, 0.0296, 0.2988, -0.0033, 0.288, -0.037, 0.2596, -0.059, 0.2197, -0.0669, 0.1848, -0.0622, 0.154, -0.0485, 0.1314, -0.0263, 0.4165, -0.0669, 0.3678, -0.0542, 0.3351, -0.0193, 0.3231, 0.0329, 0.3349, 0.0838, 0.3671, 0.1193, 0.4146, 0.1327, 0.4615, 0.1199, 0.4902, 0.086, 0.5, 0.038, 0.5, 0.0331, 0.5, 0.0283, 0.5, 0.0234, 0.4551, 0.0234, 0.4101, 0.0234, 0.3652, 0.0234, 0.3737, -0.005, 0.3914, -0.0232, 0.4165, -0.0296, 0.4364, -0.026, 0.4518, -0.0156, 0.4612, 0.0011, 0.4737, -0.0037, 0.4863, -0.0084, 0.4989, -0.0132, 0.4801, -0.042, 0.4519, -0.0604, 0.4165, -0.0669, 0.4143, 0.0958, 0.3935, 0.0913, 0.3774, 0.0781, 0.3674, 0.0563],
        .openClaw: [0.3881, -0.0486, 0.3433, -0.0486, 0.3191, 0.0475, 0.3563, 0.0475, 0.3631, 0.0128, 0.3668, -0.0215, 0.3692, -0.0215, 0.3772, 0.0166, 0.3868, 0.0475, 0.4329, 0.0475, 0.4424, 0.0166, 0.4504, -0.0215, 0.4529, -0.0215, 0.4567, 0.0128, 0.4634, 0.0475, 0.5, 0.0475, 0.4747, -0.0486, 0.4299, -0.0486, 0.4175, -0.0101, 0.4104, 0.0187, 0.4079, 0.0187, 0.4007, -0.0101, 0.3881, -0.0486, 0.2928, -0.0486, 0.2816, -0.0344, 0.2803, -0.0273, 0.2797, -0.0045, 0.278, 0.0141, 0.2684, 0.0179, 0.2534, 0.0172, 0.2477, 0.0114, 0.2473, 0.0073, 0.2234, 0.007, 0.2115, 0.0073, 0.2144, 0.0229, 0.2295, 0.0403, 0.2551, 0.0488, 0.2852, 0.047, 0.3054, 0.0351, 0.3145, 0.0147, 0.3152, -0.0304, 0.2335, -0.0497, 0.2135, -0.0382, 0.2099, -0.0198, 0.2154, -0.0087, 0.2279, -0.0014, 0.2543, 0.0025, 0.2816, -0.0015, 0.2711, -0.0159, 0.2487, -0.0185, 0.2468, -0.0208, 0.2504, -0.0228, 0.261, -0.023, 0.2735, -0.0212, 0.2796, -0.0159, 0.2816, -0.0097, 0.2833, -0.0147, 0.2824, -0.0259, 0.2782, -0.0322, 0.2623, -0.0454, 0.2441, -0.0489, 0.201, -0.0486, 0.1651, -0.0486, 0.1651, 0.0791, 0.201, 0.0791, 0.201, -0.0486, 0.0604, -0.047, 0.0314, -0.0287, 0.0175, 0.0025, 0.0203, 0.0396, 0.0394, 0.0667, 0.073, 0.0801, 0.113, 0.0781, 0.1412, 0.0633, 0.1548, 0.0374, 0.1557, 0.0243, 0.129, 0.0233, 0.1157, 0.0254, 0.113, 0.0382, 0.0971, 0.0462, 0.0729, 0.0455, 0.0649, 0.0324, 0.0659, 0.0104, 0.0796, 0.0029, 0.1044, 0.0047, 0.115, 0.0163, 0.1157, 0.025, 0.1424, 0.0261, 0.1557, 0.024, 0.1521, 0.0023, 0.1334, -0.0202, 0.1007, -0.0309, 0.0871, -0.0442, -0.0041, -0.0486, -0.028, -0.0325, -0.0285, 0.0058, -0.0361, 0.0156, -0.0556, 0.0169, -0.0665, 0.0108, -0.0694, 0.001, -0.0728, 0.0067, -0.0728, 0.0183, -0.0653, 0.0227, -0.0504, 0.0323, -0.0273, 0.0338, -0.0088, 0.026, 0.0009, 0.0109, 0.0027, -0.0226, 0.0044, -0.0586, -0.0682, -0.0486, -0.104, -0.0486, -0.104, 0.0475, -0.0705, 0.0475, -0.0705, 0.0179, -0.0682, 0.017, -0.0682, -0.0486, -0.1872, -0.0483, -0.2103, -0.0362, -0.2219, -0.0118, -0.2195, 0.0182, -0.1975, 0.0315, -0.167, 0.0298, -0.1446, 0.0172, -0.1336, -0.0055, -0.1329, -0.0184, -0.1332, -0.0227, -0.1773, -0.0244, -0.1992, -0.0123, -0.1598, -0.0063, -0.1453, -0.0138, -0.1479, -0.0131, -0.15, -0.0015, -0.1616, 0.0044, -0.1815, 0.0031, -0.189, -0.0068, -0.1895, -0.0189, -0.1875, -0.0325, -0.1758, -0.0389, -0.1572, -0.0384, -0.1506, -0.0336, -0.1502, -0.0297, -0.1263, -0.029, -0.1144, -0.0305, -0.1173, -0.0444, -0.1319, -0.0595, -0.1569, -0.0672, -0.1672, -0.0562, -0.2847, -0.0497, -0.3048, -0.0378, -0.3123, -0.0238, -0.316, -0.0165, -0.3148, -0.0017, -0.3121, -0.0058, -0.3079, -0.0141, -0.2983, -0.0174, -0.2836, -0.0177, -0.2726, -0.0148, -0.2674, -0.0079, -0.2667, 0.0034, -0.2703, 0.0118, -0.2792, 0.0158, -0.2961, 0.0162, -0.3099, 0.0104, -0.3136, -0.0004, -0.3169, 0.0069, -0.3167, 0.0215, -0.3105, 0.0302, -0.2947, 0.0463, -0.2665, 0.0487, -0.2447, 0.0387, -0.2326, 0.0182, -0.2342, -0.0074, -0.2523, -0.021, -0.2709, -0.0326, -0.3124, -0.081, -0.3483, -0.081, -0.3483, 0.0475, -0.3147, 0.0475, -0.3147, 0.0204, -0.3124, 0.0179],
        .ollama: [-0.3876, 0.1054, -0.4128, 0.1032, -0.4403, 0.0945, -0.459, 0.0825, -0.478, 0.0621, -0.4888, 0.043, -0.4972, 0.0158, -0.4999, -0.0089, -0.499, -0.0345, -0.4929, -0.0632, -0.4839, -0.0834, -0.4673, -0.1053, -0.4501, -0.1192, -0.4244, -0.1307, -0.4006, -0.135, -0.3747, -0.135, -0.3455, -0.1291, -0.3253, -0.1195, -0.304, -0.1015, -0.2912, -0.0839, -0.2804, -0.0582, -0.2758, -0.0348, -0.2838, 0.004, -0.3229, 0.0709, -0.3494, 0.096, -0.381, 0.1052, -0.3788, 0.0716, -0.3592, 0.0676, -0.3459, 0.0611, -0.3346, 0.0517, -0.3238, 0.0361, -0.3178, 0.0211, -0.3137, -0.0007, -0.3155, -0.0182, -0.3299, -0.0294, -0.3438, -0.0352, -0.3597, -0.0381, -0.3814, -0.0376, -0.3969, -0.0338, -0.4134, -0.0249, -0.4242, -0.0144, -0.4341, 0.0017, -0.4394, 0.0168, -0.4423, 0.034, -0.4427, 0.0579, -0.4404, 0.0758, -0.4341, 0.0951, -0.4265, 0.1083, -0.4132, 0.1219, -0.4003, 0.1295, -0.3854, 0.1341, -0.3696, 0.1316, -0.3744, 0.1157, -0.3804, 0.0958, -0.3852, 0.0799, -0.2472, 0.0758, -0.2472, 0.0167, -0.2472, -0.0424, -0.2472, -0.1163, -0.2403, -0.131, -0.2288, -0.131, -0.2195, -0.131, -0.2103, -0.1163, -0.2103, -0.0572, -0.2103, 0.002, -0.2103, 0.0758, -0.2149, 0.1054, -0.2265, 0.1054, -0.2357, 0.1054, -0.2472, 0.1054, -0.173, 0.0611, -0.173, 0.002, -0.173, -0.0719, -0.173, -0.131, -0.1615, -0.131, -0.1523, -0.131, -0.1407, -0.131, -0.1361, -0.1015, -0.1361, -0.0424, -0.1361, 0.0315, -0.1361, 0.0906, -0.1453, 0.1054, -0.1546, 0.1054, -0.1661, 0.1054, -0.0259, 0.0414, -0.0411, 0.0407, -0.0577, 0.0379, -0.0691, 0.034, -0.0817, 0.0266, -0.0906, 0.0184, -0.0974, 0.0082, -0.103, -0.0071, -0.0968, -0.0111, -0.0854, -0.012, -0.0762, -0.0127, -0.0667, -0.0119, -0.0644, -0.0059, -0.0611, -0.0008, -0.0557, 0.0043, -0.0507, 0.0074, -0.0439, 0.0099, -0.0376, 0.011, -0.0285, 0.0115, -0.0128, 0.0095, -0.0015, 0.0034, 0.0062, -0.01, 0.0075, -0.0217, 0.0075, -0.0237, 0.0075, -0.0253, 0.0075, -0.0274, 0.0006, -0.028, -0.0086, -0.0282, -0.02, -0.0285, -0.0292, -0.0287, -0.0506, -0.0307, -0.0655, -0.0341, -0.0812, -0.0409, -0.0917, -0.0483, -0.1, -0.0575, -0.1064, -0.0714, -0.1085, -0.0844, -0.1076, -0.0978, -0.1047, -0.1069, -0.0983, -0.1169, -0.0911, -0.1239, -0.0825, -0.1292, -0.0699, -0.1337, -0.0582, -0.1354, -0.0438, -0.1353, -0.0338, -0.1341, -0.0223, -0.1313, -0.0139, -0.1281, -0.0071, -0.1244, 0.0006, -0.1188, 0.0062, -0.1135, 0.01, -0.1117, 0.01, -0.1172, 0.01, -0.1241, 0.01, -0.1297, 0.0165, -0.131, 0.0272, -0.131, 0.0358, -0.131, 0.0444, -0.1243, 0.0444, -0.0975, 0.0444, -0.0641, 0.0444, -0.0373, 0.0442, -0.0164, 0.0414, 0.0002, 0.037, 0.0114, 0.0288, 0.0229, 0.0188, 0.031, 0.0028, 0.0379, -0.0127, 0.0408, 0.0074, -0.0544, 0.0074, -0.057, 0.0074, -0.0591, 0.0074, -0.0618, 0.0072, -0.0676, 0.0045, -0.0786, 0.0003, -0.0864, -0.0057, -0.0934, -0.0152, -0.1003, -0.0237, -0.1042, -0.0356, -0.1069, -0.0449, -0.1073, -0.0519, -0.1064, -0.0568, -0.1048, -0.0612, -0.1025, -0.0658, -0.0989, -0.0684, -0.0955, -0.0702, -0.0907, -0.0707, -0.0865, -0.0667, -0.071, -0.0577, -0.0624, -0.0436, -0.0571, -0.0249, -0.0553, -0.0157, -0.0551, -0.0041, -0.0547, 0.0051, -0.0545, 0.1515, 0.0411, 0.1397, 0.0384, 0.1283, 0.033, 0.1148, 0.0223, 0.1121, 0.0229, 0.1121, 0.0283, 0.1121, 0.0326, 0.1098, 0.0369, 0.1006, 0.0369, 0.0913, 0.0369, 0.0798, 0.0369, 0.0752, 0.0159, 0.0752, -0.0366, 0.0752, -0.0786, 0.0752, -0.131, 0.0844, -0.131, 0.0937, -0.131, 0.1052, -0.131, 0.1121, -0.1247, 0.1121, -0.0933, 0.1121, -0.0681, 0.1121, -0.0367, 0.1125, -0.0243, 0.114, -0.0167, 0.1176, -0.008, 0.1218, -0.0018, 0.1285, 0.0048, 0.1347, 0.0083, 0.1435, 0.0104, 0.1552, 0.01, 0.1676, 0.0052, 0.1773, -0.0075, 0.1804, -0.0231, 0.1805, -0.0536, 0.1805, -0.0794, 0.1805, -0.1117, 0.1828, -0.131, 0.192, -0.131, 0.2036, -0.131, 0.2128, -0.131, 0.2174, -0.1118, 0.2174, -0.0861, 0.2174, -0.0541, 0.2174, -0.0284, 0.218, -0.0197, 0.2203, -0.0103, 0.2236, -0.0039, 0.2292, 0.0027, 0.2343, 0.0066, 0.2415, 0.0096, 0.2478, 0.0105, 0.2564, 0.0102, 0.2661, 0.0083, 0.2724, 0.0055, 0.2784, 0.0003, 0.2818, -0.0051, 0.2846, -0.014, 0.2857, -0.0226, 0.2858, -0.0404, 0.2858, -0.0728, 0.2858, -0.0987, 0.2858, -0.131, 0.295, -0.131, 0.3066, -0.131, 0.3158, -0.131, 0.3227, -0.1242, 0.3227, -0.0898, 0.3227, -0.0622, 0.3227, -0.0278, 0.3221, -0.0109, 0.3185, 0.0042, 0.3132, 0.0148, 0.3059, 0.0242, 0.2942, 0.0334, 0.2837, 0.0382, 0.2691, 0.0411, 0.2586, 0.0413, 0.249, 0.0403, 0.2422, 0.0386, 0.236, 0.0363, 0.2283, 0.032, 0.2222, 0.0273, 0.2147, 0.0196, 0.2082, 0.0174, 0.1954, 0.0307, 0.1822, 0.0376, 0.1664, 0.041, 0.4219, 0.0412, 0.4076, 0.0399, 0.392, 0.0361, 0.3815, 0.0315, 0.3692, 0.0227, 0.3614, 0.0135, 0.3556, 0.0024, 0.3542, -0.0107, 0.3634, -0.0115, 0.3748, -0.0124, 0.384, -0.0131, 0.3894, -0.0103, 0.3927, -0.0033, 0.3965, 0.0014, 0.4025, 0.006, 0.4075, 0.0085, 0.4148, 0.0105, 0.4215, 0.0114, 0.4315, 0.0114, 0.449, 0.007, 0.458, -0.0012, 0.4629, -0.0173, 0.4631, -0.0225, 0.4631, -0.0245, 0.4631, -0.0261, 0.4631, -0.0278, 0.4516, -0.0281, 0.4425, -0.0283, 0.431, -0.0286, 0.4175, -0.0292, 0.3973, -0.0322, 0.3835, -0.0365, 0.3717, -0.0426, 0.3594, -0.0527, 0.3525, -0.0628, 0.3478, -0.0777, 0.3471, -0.0904, 0.3492, -0.1025, 0.3531, -0.1111, 0.359, -0.1187, 0.3686, -0.1268, 0.3779, -0.1313, 0.3914, -0.1347, 0.4038, -0.1356, 0.4169, -0.1348, 0.4265, -0.1332, 0.4355, -0.1306, 0.4451, -0.1263, 0.4517, -0.1223, 0.4591, -0.1162, 0.4644, -0.1105, 0.4657, -0.1145, 0.4657, -0.12, 0.4657, -0.1255, 0.4678, -0.131, 0.4764, -0.131, 0.4871, -0.131, 0.4957, -0.131, 0.5, -0.1109, 0.5, -0.0841, 0.5, -0.0574, 0.5, -0.0239, 0.499, -0.0094, 0.4951, 0.006, 0.4897, 0.0164, 0.4798, 0.0272, 0.4685, 0.0342, 0.4548, 0.0388, 0.4342, 0.0413, 0.4631, -0.0554, 0.4631, -0.0581, 0.4631, -0.0602, 0.4631, -0.0628, 0.4621, -0.0721, 0.4593, -0.0806, 0.4532, -0.09, 0.4463, -0.0965, 0.4363, -0.1025, 0.4273, -0.1056, 0.4148, -0.1073, 0.4078, -0.1071, 0.4025, -0.1061, 0.3966, -0.1038, 0.3924, -0.1012, 0.3884, -0.0972, 0.3863, -0.0937, 0.3851, -0.0887, 0.3856, -0.0797, 0.3907, -0.0685, 0.4043, -0.0593, 0.4211, -0.0558, 0.4353, -0.0552, 0.4446, -0.0549, 0.4561, -0.0546],
        .windsurf: [-0.2056, 0.0568, -0.2164, 0.0568, -0.2217, 0.0137, -0.2217, -0.0725, -0.2203, -0.0751, -0.2134, -0.0755, -0.2027, -0.0755, -0.2027, 0.0107, -0.2037, 0.0548, -0.2056, 0.0568, -0.2165, 0.1053, -0.2051, 0.1053, -0.2026, 0.1039, -0.2022, 0.0953, -0.2022, 0.0813, -0.2156, 0.0813, -0.2222, 0.0883, -0.2222, 0.1024, -0.2208, 0.1049, -0.2203, 0.1053, -0.2222, 0.1053, -0.1258, 0.0585, -0.149, 0.0449, -0.149, 0.0488, -0.1542, 0.0508, -0.1648, 0.0508, -0.1648, -0.0354, -0.1644, -0.08, -0.1618, -0.0814, -0.1513, -0.0814, -0.146, -0.0542, -0.146, 0.0004, -0.133, 0.0324, -0.1104, 0.0073, -0.1104, -0.0481, -0.1089, -0.0507, -0.102, -0.0511, -0.0913, -0.0511, -0.0913, 0.0084, -0.0971, 0.0646, -0.1372, 0.0849, -0.1279, 0.0767, -0.1094, 0.0604, 0.0548, 0.0629, 0.0548, 0.1024, 0.0563, 0.1049, 0.063, 0.1053, 0.0736, 0.1053, 0.0761, 0.1039, 0.0765, 0.0431, 0.0765, -0.0755, 0.066, -0.0755, 0.0607, -0.0729, 0.0607, -0.0678, 0.0565, -0.0635, 0.0435, -0.0735, 0.0115, -0.0821, -0.0385, -0.0502, -0.0379, 0.0287, 0.0123, 0.0604, 0.0438, 0.0518, 0.0539, 0.0431, 0.0548, 0.0431, -0.0176, -0.0439, 0.021, -0.0619, 0.0594, -0.0439, 0.0594, 0.022, 0.021, 0.0402, -0.0066, 0.0061, 0.1758, -0.0026, 0.1585, 0.0004, 0.1355, 0.0062, 0.1273, 0.0211, 0.139, 0.0393, 0.177, 0.0391, 0.1913, 0.0193, 0.1928, 0.017, 0.1995, 0.0166, 0.2099, 0.0166, 0.2126, 0.0182, 0.2046, 0.0419, 0.159, 0.0605, 0.1126, 0.0406, 0.1111, 0.0006, 0.1439, -0.017, 0.1629, -0.0205, 0.1848, -0.026, 0.1934, -0.0404, 0.1813, -0.0609, 0.1556, -0.0632, 0.1451, -0.0632, 0.1737, -0.1007, 0.2308, -0.1, 0.2574, -0.0625, 0.238, -0.032, 0.2038, -0.018, 0.1758, -0.0026, 0.3123, -0.06, 0.3251, -0.028, 0.3251, 0.0265, 0.3255, 0.0553, 0.328, 0.0567, 0.3387, 0.0567, 0.3456, 0.0563, 0.3471, 0.0538, 0.3471, -0.0324, 0.3417, -0.0755, 0.331, -0.0755, 0.331, -0.0718, 0.3298, -0.0666, 0.3239, -0.0667, 0.301, -0.0802, 0.2612, -0.0772, 0.2396, -0.0354, 0.2396, 0.024, 0.24, 0.0553, 0.2426, 0.0567, 0.2533, 0.0567, 0.2601, 0.0563, 0.2616, 0.0538, 0.2616, -0.0016, 0.264, -0.0506, 0.2962, -0.0627, 0.2922, -0.0627, 0.4757, 0.0568, 0.4757, 0.0683, 0.4774, 0.0803, 0.488, 0.0864, 0.496, 0.0864, 0.5, 0.0918, 0.5, 0.1024, 0.4944, 0.1024, 0.4713, 0.0981, 0.4537, 0.0667, 0.4537, 0.0581, 0.4479, 0.0538, 0.4363, 0.0538, 0.41, 0.0493, 0.3975, 0.0407, 0.3935, 0.0454, 0.3935, 0.051, 0.3882, 0.0538, 0.3775, 0.0538, 0.3775, -0.0324, 0.3779, -0.077, 0.3804, -0.0784, 0.3911, -0.0784, 0.3965, -0.0514, 0.3965, 0.0026, 0.4102, 0.0331, 0.4406, 0.0357, 0.4567, 0.0357, 0.4567, -0.0384, 0.4571, -0.077, 0.4596, -0.0785, 0.4703, -0.0785, 0.4757, -0.0394, 0.4757, 0.0386, 0.4919, 0.0386, 0.5, 0.0437, 0.5, 0.0538, 0.4838, 0.0538, 0.4757, 0.0548, 0.4757, 0.0568, -0.3019, 0.0046, -0.2773, 0.1031, -0.265, 0.1031, -0.2572, 0.1026, -0.256, 0.0994, -0.2869, -0.0192, -0.3133, -0.0785, -0.3352, -0.0785, -0.3559, 0.0222, -0.3663, 0.0725, -0.3665, 0.0725, -0.3922, -0.0266, -0.4203, -0.0762, -0.4509, -0.0762, -0.4836, 0.0423, -0.4939, 0.1016],
        .xAI: [0.4312, 0.2671, 0.4541, 0.2671, 0.4771, 0.2671, 0.5, 0.2671, 0.5, 0.089, 0.5, -0.089, 0.5, -0.2671, 0.4771, -0.2671, 0.4541, -0.2671, 0.4312, -0.2671, 0.4312, -0.089, 0.4312, 0.089, 0.4312, 0.2671, 0.0842, 0.2671, 0.1084, 0.2671, 0.1326, 0.2671, 0.1568, 0.2671, 0.2258, 0.089, 0.2949, -0.089, 0.364, -0.2671, 0.339, -0.2671, 0.3141, -0.2671, 0.2892, -0.2671, 0.2705, -0.2174, 0.2518, -0.1678, 0.2331, -0.1182, 0.1568, -0.1182, 0.0805, -0.1182, 0.0042, -0.1182, -0.0145, -0.1678, -0.0332, -0.2174, -0.0519, -0.2671, -0.0759, -0.2671, -0.0998, -0.2671, -0.1238, -0.2671, -0.0545, -0.089, 0.0149, 0.089, 0.0842, 0.2671, 0.2121, -0.0584, 0.1807, 0.0242, 0.1493, 0.1067, 0.1179, 0.1893, 0.0869, 0.1067, 0.056, 0.0242, 0.0251, -0.0584, 0.0874, -0.0584, 0.1498, -0.0584, 0.2121, -0.0584, -0.3571, -0.0636, -0.4003, -0.0025, -0.4434, 0.0586, -0.4865, 0.1197, -0.4611, 0.1197, -0.4357, 0.1197, -0.4102, 0.1197, -0.3796, 0.0741, -0.3489, 0.0284, -0.3182, -0.0172, -0.2863, 0.0284, -0.2544, 0.0741, -0.2225, 0.1197, -0.1993, 0.1197, -0.1761, 0.1197, -0.1529, 0.1197, -0.1953, 0.0589, -0.2377, -0.002, -0.2801, -0.0628, -0.2332, -0.1309, -0.1863, -0.199, -0.1394, -0.2671, -0.1646, -0.2671, -0.1898, -0.2671, -0.215, -0.2671, -0.2504, -0.215, -0.2858, -0.1628, -0.3212, -0.1107, -0.3569, -0.1628, -0.3925, -0.215, -0.4282, -0.2671, -0.4521, -0.2671, -0.4761, -0.2671, -0.5, -0.2671, -0.4524, -0.1992, -0.4047, -0.1314, -0.3571, -0.0636],
    ]

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

    private static func generateOllamaLogoPoints() -> [ShapePoint] {
        let coords: [CGPoint] = [
            CGPoint(x: -0.19965000000000002, y: -0.55), CGPoint(x: -0.19415000000000002, y: -0.54747), CGPoint(x: -0.18700000000000003, y: -0.54329), CGPoint(x: -0.18183000000000002, y: -0.53966), CGPoint(x: -0.17688, y: -0.5354800000000001), CGPoint(x: -0.16962000000000002, y: -0.5281100000000001), CGPoint(x: -0.16225, y: -0.51898), CGPoint(x: -0.15532, y: -0.50875), CGPoint(x: -0.14696, y: -0.49335000000000007), CGPoint(x: -0.14135, y: -0.4807), CGPoint(x: -0.13618, y: -0.4671700000000001), CGPoint(x: -0.13046000000000002, y: -0.44814000000000004), CGPoint(x: -0.12683, y: -0.43351000000000006), CGPoint(x: -0.12397000000000001, y: -0.41855000000000003), CGPoint(x: -0.12188, y: -0.40337000000000006), CGPoint(x: -0.12067000000000001, y: -0.39325), CGPoint(x: -0.12012000000000002, y: -0.39325), CGPoint(x: -0.11968000000000001, y: -0.39325), CGPoint(x: -0.11913, y: -0.39336), CGPoint(x: -0.11869, y: -0.39336), CGPoint(x: -0.10329, y: -0.39413000000000004), CGPoint(x: -0.07315, y: -0.39259000000000005), CGPoint(x: -0.05115, y: -0.38874000000000003), CGPoint(x: -0.0297, y: -0.38280000000000003), CGPoint(x: -0.00253, y: -0.3712500000000001), CGPoint(x: 0.00011000000000000002, y: -0.36982000000000004), CGPoint(x: 0.0027500000000000003, y: -0.36839), CGPoint(x: 0.0061600000000000005, y: -0.36630000000000007), CGPoint(x: 0.0088, y: -0.36487), CGPoint(x: 0.011330000000000002, y: -0.36322000000000004), CGPoint(x: 0.013750000000000002, y: -0.38313), CGPoint(x: 0.016280000000000003, y: -0.39787000000000006), CGPoint(x: 0.01958, y: -0.41239000000000003), CGPoint(x: 0.02508, y: -0.4310900000000001), CGPoint(x: 0.029920000000000002, y: -0.44462), CGPoint(x: 0.03531, y: -0.4576), CGPoint(x: 0.04136000000000001, y: -0.4697), CGPoint(x: 0.05016, y: -0.48411000000000004), CGPoint(x: 0.057420000000000006, y: -0.49357), CGPoint(x: 0.06468, y: -0.5000600000000001), CGPoint(x: 0.07392, y: -0.50248), CGPoint(x: 0.08096, y: -0.50336), CGPoint(x: 0.08800000000000001, y: -0.5032500000000001), CGPoint(x: 0.09735, y: -0.50182), CGPoint(x: 0.10659, y: -0.49896000000000007), CGPoint(x: 0.11649, y: -0.49434000000000006), CGPoint(x: 0.1287, y: -0.4862), CGPoint(x: 0.13706000000000002, y: -0.47872000000000003), CGPoint(x: 0.14476, y: -0.46992000000000006), CGPoint(x: 0.15345000000000003, y: -0.45738000000000006), CGPoint(x: 0.15906, y: -0.44715), CGPoint(x: 0.16401000000000002, y: -0.43604), CGPoint(x: 0.16984000000000002, y: -0.41976), CGPoint(x: 0.17347, y: -0.40656000000000003), CGPoint(x: 0.17853000000000002, y: -0.3806), CGPoint(x: 0.18249, y: -0.34144), CGPoint(x: 0.18315000000000003, y: -0.30899), CGPoint(x: 0.18194000000000002, y: -0.27379000000000003), CGPoint(x: 0.17886000000000002, y: -0.23606000000000002), CGPoint(x: 0.17941000000000001, y: -0.23562000000000002), CGPoint(x: 0.17996, y: -0.23529000000000003), CGPoint(x: 0.18040000000000003, y: -0.23496000000000003), CGPoint(x: 0.18095000000000003, y: -0.23441000000000004), CGPoint(x: 0.18139, y: -0.23419000000000004), CGPoint(x: 0.18172000000000002, y: -0.23397), CGPoint(x: 0.18205000000000002, y: -0.23364000000000001), CGPoint(x: 0.18227, y: -0.23353000000000002), CGPoint(x: 0.18249, y: -0.23331000000000002), CGPoint(x: 0.20702000000000004, y: -0.21109), CGPoint(x: 0.22275000000000003, y: -0.19184), CGPoint(x: 0.23606000000000002, y: -0.17072), CGPoint(x: 0.25014000000000003, y: -0.13981), CGPoint(x: 0.25905, y: -0.11033000000000001), CGPoint(x: 0.26521000000000006, y: -0.0704), CGPoint(x: 0.26389, y: -0.018150000000000003), CGPoint(x: 0.25608000000000003, y: 0.018150000000000003), CGPoint(x: 0.24266000000000001, y: 0.049830000000000006), CGPoint(x: 0.23045000000000002, y: 0.06798000000000001), CGPoint(x: 0.23023000000000005, y: 0.06831000000000001), CGPoint(x: 0.23001000000000002, y: 0.06842000000000001), CGPoint(x: 0.22979000000000002, y: 0.06886), CGPoint(x: 0.23683, y: 0.08239), CGPoint(x: 0.24585, y: 0.10285000000000001), CGPoint(x: 0.25322, y: 0.12375000000000001), CGPoint(x: 0.26015, y: 0.15213000000000002), CGPoint(x: 0.26312, y: 0.1738), CGPoint(x: 0.26378, y: 0.18139), CGPoint(x: 0.26378, y: 0.18183000000000002), CGPoint(x: 0.26378, y: 0.18216000000000002), CGPoint(x: 0.26389, y: 0.18249), CGPoint(x: 0.26323, y: 0.21989), CGPoint(x: 0.25883, y: 0.24805000000000002), CGPoint(x: 0.25124, y: 0.27599), CGPoint(x: 0.23573, y: 0.31317000000000006), CGPoint(x: 0.22572, y: 0.33176), CGPoint(x: 0.22561000000000003, y: 0.33198000000000005), CGPoint(x: 0.2255, y: 0.33242000000000005), CGPoint(x: 0.22572, y: 0.33275), CGPoint(x: 0.22583000000000003, y: 0.33308000000000004), CGPoint(x: 0.23353000000000002, y: 0.35365), CGPoint(x: 0.24211000000000002, y: 0.38412), CGPoint(x: 0.24761000000000002, y: 0.4147), CGPoint(x: 0.24992000000000003, y: 0.4555100000000001), CGPoint(x: 0.24783000000000002, y: 0.4862), CGPoint(x: 0.24640000000000004, y: 0.4965400000000001), CGPoint(x: 0.24629, y: 0.49698000000000003), CGPoint(x: 0.24629, y: 0.49742000000000003), CGPoint(x: 0.24618, y: 0.4977500000000001), CGPoint(x: 0.24618, y: 0.49808), CGPoint(x: 0.24893, y: 0.47102000000000005), CGPoint(x: 0.24849000000000002, y: 0.44374), CGPoint(x: 0.24486000000000002, y: 0.41635000000000005), CGPoint(x: 0.23496000000000003, y: 0.37972000000000006), CGPoint(x: 0.22363000000000002, y: 0.35211000000000003), CGPoint(x: 0.22385, y: 0.35189000000000004), CGPoint(x: 0.24200000000000002, y: 0.31955), CGPoint(x: 0.25157, y: 0.29557), CGPoint(x: 0.25795, y: 0.27181), CGPoint(x: 0.26158000000000003, y: 0.24024000000000004), CGPoint(x: 0.2607, y: 0.21780000000000002), CGPoint(x: 0.25762, y: 0.19745000000000001), CGPoint(x: 0.25014000000000003, y: 0.17061), CGPoint(x: 0.24200000000000002, y: 0.15070000000000003), CGPoint(x: 0.23177, y: 0.13123), CGPoint(x: 0.22407000000000002, y: 0.11825000000000001), CGPoint(x: 0.22418000000000002, y: 0.11803000000000001), CGPoint(x: 0.22847, y: 0.11473000000000001), CGPoint(x: 0.23650000000000002, y: 0.10505), CGPoint(x: 0.24189000000000002, y: 0.09537000000000001), CGPoint(x: 0.24651, y: 0.08371), CGPoint(x: 0.25036, y: 0.0704), CGPoint(x: 0.24519000000000002, y: 0.047850000000000004), CGPoint(x: 0.23727, y: 0.031240000000000004), CGPoint(x: 0.22781, y: 0.01617), CGPoint(x: 0.21274, y: -0.0016500000000000002), CGPoint(x: 0.19976000000000002, y: -0.013090000000000003), CGPoint(x: 0.18315000000000003, y: -0.023870000000000002), CGPoint(x: 0.15796000000000002, y: -0.03443), CGPoint(x: 0.13684000000000002, y: -0.039490000000000004), CGPoint(x: 0.11363000000000001, y: -0.04191), CGPoint(x: 0.08558, y: -0.0473), CGPoint(x: 0.07612000000000001, y: -0.06325000000000001), CGPoint(x: 0.06545000000000001, y: -0.07733000000000001), CGPoint(x: 0.049060000000000006, y: -0.09328), CGPoint(x: 0.03542, y: -0.10318000000000001), CGPoint(x: 0.014740000000000001, y: -0.10758000000000001), CGPoint(x: -0.02607, y: -0.09669000000000001), CGPoint(x: -0.05291, y: -0.08305), CGPoint(x: -0.07524000000000002, y: -0.06556000000000001), CGPoint(x: -0.09603, y: -0.03751), CGPoint(x: -0.11748000000000001, y: -0.02926), CGPoint(x: -0.14278000000000002, y: -0.026510000000000002), CGPoint(x: -0.16577, y: -0.02134), CGPoint(x: -0.19294000000000003, y: -0.011000000000000001), CGPoint(x: -0.21065000000000003, y: -0.0008800000000000001), CGPoint(x: -0.22484, y: 0.01012), CGPoint(x: -0.24024000000000004, y: 0.026510000000000002), CGPoint(x: -0.24981, y: 0.040260000000000004), CGPoint(x: -0.25784, y: 0.055330000000000004), CGPoint(x: -0.26587, y: 0.07722000000000001), CGPoint(x: -0.26246, y: 0.09141), CGPoint(x: -0.25806, y: 0.10439000000000001), CGPoint(x: -0.25102, y: 0.11957000000000001), CGPoint(x: -0.24508000000000002, y: 0.12903), CGPoint(x: -0.23870000000000002, y: 0.13662000000000002), CGPoint(x: -0.23848, y: 0.13684000000000002), CGPoint(x: -0.23826, y: 0.13695000000000002), CGPoint(x: -0.23353000000000002, y: 0.14289), CGPoint(x: -0.22990000000000002, y: 0.15202), CGPoint(x: -0.22913000000000003, y: 0.15939), CGPoint(x: -0.23023000000000005, y: 0.16665000000000002), CGPoint(x: -0.23628000000000002, y: 0.17930000000000001), CGPoint(x: -0.24497000000000002, y: 0.19789), CGPoint(x: -0.25234, y: 0.21868), CGPoint(x: -0.25828, y: 0.24101), CGPoint(x: -0.26345, y: 0.27214000000000005), CGPoint(x: -0.26499, y: 0.29667000000000004), CGPoint(x: -0.26389, y: 0.32219000000000003), CGPoint(x: -0.25806, y: 0.35376), CGPoint(x: -0.25036, y: 0.37532000000000004), CGPoint(x: -0.2398, y: 0.39468000000000003), CGPoint(x: -0.23089, y: 0.40656000000000003), CGPoint(x: -0.23067000000000001, y: 0.40678000000000003), CGPoint(x: -0.23056000000000001, y: 0.40700000000000003), CGPoint(x: -0.23518, y: 0.41800000000000004), CGPoint(x: -0.24706, y: 0.44869000000000003), CGPoint(x: -0.25509000000000004, y: 0.47729000000000005), CGPoint(x: -0.25993000000000005, y: 0.5119400000000001), CGPoint(x: -0.25916, y: 0.5354800000000001), CGPoint(x: -0.2585, y: 0.54098), CGPoint(x: -0.26169000000000003, y: 0.50336), CGPoint(x: -0.25949, y: 0.47344), CGPoint(x: -0.25333, y: 0.44198000000000004), CGPoint(x: -0.23914000000000002, y: 0.39787000000000006), CGPoint(x: -0.23441000000000004, y: 0.38621000000000005), CGPoint(x: -0.2343, y: 0.38588000000000006), CGPoint(x: -0.23408, y: 0.38544), CGPoint(x: -0.23397, y: 0.38522000000000006), CGPoint(x: -0.23386000000000004, y: 0.38489), CGPoint(x: -0.23397, y: 0.38456000000000007), CGPoint(x: -0.23419000000000004, y: 0.38423), CGPoint(x: -0.2343, y: 0.3840100000000001), CGPoint(x: -0.2343, y: 0.38368), CGPoint(x: -0.23441000000000004, y: 0.38335), CGPoint(x: -0.23232000000000003, y: 0.35937), CGPoint(x: -0.22858000000000003, y: 0.3355), CGPoint(x: -0.22110000000000002, y: 0.3047), CGPoint(x: -0.21384, y: 0.2827), CGPoint(x: -0.20537000000000002, y: 0.26224000000000003), CGPoint(x: -0.20515000000000003, y: 0.26191000000000003), CGPoint(x: -0.20504000000000003, y: 0.26169000000000003), CGPoint(x: -0.20493, y: 0.26136000000000004), CGPoint(x: -0.20482000000000003, y: 0.26092000000000004), CGPoint(x: -0.21219000000000002, y: 0.24937000000000004), CGPoint(x: -0.21868, y: 0.23672), CGPoint(x: -0.22616000000000003, y: 0.21846000000000002), CGPoint(x: -0.23067000000000001, y: 0.20394000000000004), CGPoint(x: -0.2343, y: 0.18865000000000004), CGPoint(x: -0.23441000000000004, y: 0.18821000000000002), CGPoint(x: -0.23452, y: 0.18788000000000002), CGPoint(x: -0.23452, y: 0.18755000000000002), CGPoint(x: -0.22638000000000003, y: 0.16412000000000002), CGPoint(x: -0.21175000000000002, y: 0.13519), CGPoint(x: -0.19778, y: 0.11539), CGPoint(x: -0.18150000000000002, y: 0.09735), CGPoint(x: -0.16225, y: 0.08096), CGPoint(x: -0.1606, y: 0.07975), CGPoint(x: -0.15895, y: 0.07865), CGPoint(x: -0.15675, y: 0.07711), CGPoint(x: -0.1551, y: 0.07590000000000001), CGPoint(x: -0.15532, y: 0.06226), CGPoint(x: -0.15829000000000001, y: 0.01331), CGPoint(x: -0.15829000000000001, y: -0.02035), CGPoint(x: -0.15631, y: -0.05126000000000001), CGPoint(x: -0.15070000000000003, y: -0.08800000000000001), CGPoint(x: -0.14641, y: -0.10538), CGPoint(x: -0.14245000000000002, y: -0.11792000000000001), CGPoint(x: -0.13607000000000002, y: -0.13343000000000002), CGPoint(x: -0.13068000000000002, y: -0.14399), CGPoint(x: -0.12463, y: -0.15367), CGPoint(x: -0.11506000000000001, y: -0.16577), CGPoint(x: -0.10692, y: -0.17369000000000004), CGPoint(x: -0.09801, y: -0.18040000000000003), CGPoint(x: -0.08855, y: -0.18590000000000004), CGPoint(x: -0.07502, y: -0.19107000000000002), CGPoint(x: -0.06798000000000001, y: -0.19261000000000003), CGPoint(x: -0.06094, y: -0.19327), CGPoint(x: -0.051590000000000004, y: -0.19272), CGPoint(x: -0.044550000000000006, y: -0.19140000000000001), CGPoint(x: -0.03773, y: -0.18909), CGPoint(x: -0.07821, y: -0.27940000000000004), CGPoint(x: -0.10857, y: -0.34705), CGPoint(x: -0.13893, y: -0.4147), CGPoint(x: -0.17941000000000001, y: -0.5049), CGPoint(x: -0.00715, y: -0.12485000000000002), CGPoint(x: 0.017050000000000003, y: -0.12331000000000002), CGPoint(x: 0.047740000000000005, y: -0.11682000000000001), CGPoint(x: 0.0693, y: -0.10868000000000001), CGPoint(x: 0.09537000000000001, y: -0.09383000000000001), CGPoint(x: 0.11264000000000002, y: -0.08019000000000001), CGPoint(x: 0.12694000000000003, y: -0.0649), CGPoint(x: 0.14179, y: -0.04268), CGPoint(x: 0.14926999999999999, y: -0.02486), CGPoint(x: 0.15400000000000003, y: -0.00033), CGPoint(x: 0.15334, y: 0.02101), CGPoint(x: 0.14883000000000002, y: 0.04202), CGPoint(x: 0.13695000000000002, y: 0.06677), CGPoint(x: 0.12386000000000001, y: 0.08272000000000002), CGPoint(x: 0.10120000000000001, y: 0.10043000000000002), CGPoint(x: 0.08393000000000002, y: 0.10934), CGPoint(x: 0.06468, y: 0.11638000000000001), CGPoint(x: 0.036300000000000006, y: 0.12287000000000001), CGPoint(x: 0.01331, y: 0.12551), CGPoint(x: -0.01111, y: 0.12650000000000003), CGPoint(x: -0.04521, y: 0.12419000000000001), CGPoint(x: -0.06875, y: 0.11968000000000001), CGPoint(x: -0.09735, y: 0.10989000000000002), CGPoint(x: -0.11627000000000001, y: 0.09999), CGPoint(x: -0.13299, y: 0.08789000000000001), CGPoint(x: -0.15103000000000003, y: 0.06908), CGPoint(x: -0.16104000000000002, y: 0.05324), CGPoint(x: -0.16984000000000002, y: 0.03036), CGPoint(x: -0.17259000000000002, y: 0.0121), CGPoint(x: -0.17193, y: -0.00649), CGPoint(x: -0.16522, y: -0.030910000000000003), CGPoint(x: -0.15631, y: -0.048510000000000005), CGPoint(x: -0.13937000000000002, y: -0.0704), CGPoint(x: -0.12342, y: -0.08514000000000001), CGPoint(x: -0.10483, y: -0.09812000000000001), CGPoint(x: -0.07733000000000001, y: -0.11176), CGPoint(x: -0.05489, y: -0.11891000000000002), CGPoint(x: -0.023430000000000003, y: -0.12419000000000001), CGPoint(x: -0.00715, y: -0.08294), CGPoint(x: -0.021560000000000003, y: -0.0693), CGPoint(x: -0.03212, y: -0.054560000000000004), CGPoint(x: -0.03751, y: -0.043230000000000005), CGPoint(x: -0.040810000000000006, y: -0.028160000000000004), CGPoint(x: -0.03993, y: -0.013420000000000001), CGPoint(x: -0.03542, y: 0.0007700000000000001), CGPoint(x: -0.027280000000000002, y: 0.01397), CGPoint(x: -0.019030000000000002, y: 0.02299), CGPoint(x: -0.00396, y: 0.03432), CGPoint(x: 0.015620000000000002, y: 0.043780000000000006), CGPoint(x: 0.038500000000000006, y: 0.05038), CGPoint(x: 0.06446, y: 0.053680000000000005), CGPoint(x: 0.08536, y: 0.05412000000000001), CGPoint(x: 0.11165000000000001, y: 0.05214), CGPoint(x: 0.13519, y: 0.047740000000000005), CGPoint(x: 0.15565, y: 0.04092), CGPoint(x: 0.16885, y: 0.034210000000000004), CGPoint(x: 0.18304, y: 0.02332), CGPoint(x: 0.19327, y: 0.0099), CGPoint(x: 0.19943, y: -0.005940000000000001), CGPoint(x: 0.20152, y: -0.024530000000000003), CGPoint(x: 0.20031000000000002, y: -0.03586), CGPoint(x: 0.19514, y: -0.05115), CGPoint(x: 0.18612, y: -0.06611), CGPoint(x: 0.17336000000000001, y: -0.08008000000000001), CGPoint(x: 0.15609, y: -0.09306), CGPoint(x: 0.14102000000000003, y: -0.10109), CGPoint(x: 0.11891000000000002, y: -0.10890000000000001), CGPoint(x: 0.09493000000000001, y: -0.11286), CGPoint(x: 0.07128, y: -0.10956), CGPoint(x: 0.04884000000000001, y: -0.10197000000000002), CGPoint(x: 0.032010000000000004, y: -0.09625), CGPoint(x: 0.00957, y: -0.08866000000000002), CGPoint(x: 0.023760000000000003, y: -0.026400000000000003), CGPoint(x: 0.024970000000000003, y: -0.02486), CGPoint(x: 0.027280000000000002, y: -0.018920000000000003), CGPoint(x: 0.02739, y: -0.014190000000000001), CGPoint(x: 0.02552, y: -0.00825), CGPoint(x: 0.022660000000000003, y: -0.0044), CGPoint(x: 0.018810000000000004, y: -0.0012100000000000001), CGPoint(x: 0.016280000000000003, y: 0.0007700000000000001), CGPoint(x: 0.012870000000000001, y: 0.0034100000000000003), CGPoint(x: 0.01023, y: 0.0055000000000000005), CGPoint(x: 0.007700000000000001, y: 0.0074800000000000005), CGPoint(x: 0.007700000000000001, y: 0.012650000000000002), CGPoint(x: 0.007700000000000001, y: 0.016610000000000003), CGPoint(x: 0.007700000000000001, y: 0.021780000000000004), CGPoint(x: 0.007700000000000001, y: 0.025740000000000002), CGPoint(x: 0.007700000000000001, y: 0.025630000000000003), CGPoint(x: 0.007700000000000001, y: 0.021670000000000002), CGPoint(x: 0.007700000000000001, y: 0.016280000000000003), CGPoint(x: 0.007700000000000001, y: 0.012210000000000002), CGPoint(x: 0.007700000000000001, y: 0.0068200000000000005), CGPoint(x: 0.00528, y: 0.00495), CGPoint(x: 0.0029700000000000004, y: 0.0029700000000000004), CGPoint(x: -0.00022000000000000003, y: 0.00044000000000000007), CGPoint(x: -0.00264, y: -0.00143), CGPoint(x: -0.0044, y: -0.00286), CGPoint(x: -0.0024200000000000003, y: -0.00132), CGPoint(x: 0.0, y: 0.00066), CGPoint(x: 0.00198, y: 0.0022), CGPoint(x: 0.0044, y: 0.0041800000000000006), CGPoint(x: 0.00638, y: 0.0036300000000000004), CGPoint(x: 0.00825, y: 0.0020900000000000003), CGPoint(x: 0.010890000000000002, y: 0.00011000000000000002), CGPoint(x: 0.01276, y: -0.00143), CGPoint(x: 0.015400000000000002, y: -0.0034100000000000003), CGPoint(x: 0.01694, y: -0.007810000000000001), CGPoint(x: 0.019030000000000002, y: -0.013530000000000002), CGPoint(x: 0.020680000000000004, y: -0.01782), CGPoint(x: 0.022770000000000002, y: -0.023540000000000002), CGPoint(x: -0.21197000000000002, y: -0.11616000000000001), CGPoint(x: -0.20779000000000003, y: -0.11594), CGPoint(x: -0.19987000000000002, y: -0.11429000000000002), CGPoint(x: -0.19613, y: -0.11297000000000001), CGPoint(x: -0.18931, y: -0.10912000000000001), CGPoint(x: -0.18612, y: -0.10681000000000002), CGPoint(x: -0.18326, y: -0.10417000000000001), CGPoint(x: -0.17831, y: -0.09812000000000001), CGPoint(x: -0.17633000000000001, y: -0.09482), CGPoint(x: -0.17457000000000003, y: -0.0913), CGPoint(x: -0.17226, y: -0.08360000000000001), CGPoint(x: -0.1716, y: -0.07953), CGPoint(x: -0.17138, y: -0.07535000000000001), CGPoint(x: -0.17644, y: -0.08052000000000001), CGPoint(x: -0.17897000000000002, y: -0.08305), CGPoint(x: -0.18403000000000003, y: -0.08811000000000001), CGPoint(x: -0.18656, y: -0.09064000000000001), CGPoint(x: -0.18909, y: -0.09317), CGPoint(x: -0.19415000000000002, y: -0.09834), CGPoint(x: -0.19668, y: -0.10087000000000002), CGPoint(x: -0.20174000000000003, y: -0.10593000000000001), CGPoint(x: -0.20438, y: -0.10846), CGPoint(x: -0.20691, y: -0.11099000000000002), CGPoint(x: -0.21197000000000002, y: -0.11616000000000001), CGPoint(x: 0.19525, y: -0.11616000000000001), CGPoint(x: 0.19943, y: -0.11594), CGPoint(x: 0.20735, y: -0.11429000000000002), CGPoint(x: 0.21109, y: -0.11297000000000001), CGPoint(x: 0.21791000000000002, y: -0.10912000000000001), CGPoint(x: 0.22110000000000002, y: -0.10681000000000002), CGPoint(x: 0.22396000000000002, y: -0.10417000000000001), CGPoint(x: 0.22891000000000003, y: -0.09812000000000001), CGPoint(x: 0.23089, y: -0.09482), CGPoint(x: 0.23265000000000002, y: -0.0913), CGPoint(x: 0.23496000000000003, y: -0.08360000000000001), CGPoint(x: 0.23562000000000002, y: -0.07953), CGPoint(x: 0.23584000000000002, y: -0.07535000000000001), CGPoint(x: 0.23078, y: -0.08052000000000001), CGPoint(x: 0.22825, y: -0.08305), CGPoint(x: 0.22319000000000003, y: -0.08811000000000001), CGPoint(x: 0.22066000000000002, y: -0.09064000000000001), CGPoint(x: 0.21802, y: -0.09317), CGPoint(x: 0.21296, y: -0.09834), CGPoint(x: 0.21043, y: -0.10087000000000002), CGPoint(x: 0.20537000000000002, y: -0.10593000000000001), CGPoint(x: 0.20284000000000002, y: -0.10846), CGPoint(x: 0.20031000000000002, y: -0.11099000000000002), CGPoint(x: 0.19525, y: -0.11616000000000001), CGPoint(x: -0.22143000000000002, y: -0.49346000000000007), CGPoint(x: -0.22165000000000004, y: -0.49324000000000007), CGPoint(x: -0.22176, y: -0.49313), CGPoint(x: -0.22418000000000002, y: -0.48950000000000005), CGPoint(x: -0.22759000000000001, y: -0.48356000000000005), CGPoint(x: -0.23078, y: -0.47663000000000005), CGPoint(x: -0.23276000000000002, y: -0.47157000000000004), CGPoint(x: -0.23551000000000002, y: -0.46332000000000007), CGPoint(x: -0.23804000000000003, y: -0.45408000000000004), CGPoint(x: -0.24189000000000002, y: -0.43472000000000005), CGPoint(x: -0.24376, y: -0.42042), CGPoint(x: -0.24552000000000004, y: -0.3971), CGPoint(x: -0.24607000000000004, y: -0.37158), CGPoint(x: -0.24563000000000001, y: -0.35321), CGPoint(x: -0.24387000000000003, y: -0.32406), CGPoint(x: -0.23232000000000003, y: -0.32714000000000004), CGPoint(x: -0.22044000000000002, y: -0.32978), CGPoint(x: -0.21241000000000002, y: -0.33132000000000006), CGPoint(x: -0.19987000000000002, y: -0.33308000000000004), CGPoint(x: -0.18700000000000003, y: -0.33451000000000003), CGPoint(x: -0.17809, y: -0.33506), CGPoint(x: -0.17798000000000003, y: -0.3351700000000001), CGPoint(x: -0.17765000000000003, y: -0.33528), CGPoint(x: -0.17754, y: -0.3355), CGPoint(x: -0.17743, y: -0.3357200000000001), CGPoint(x: -0.17721, y: -0.33605), CGPoint(x: -0.1771, y: -0.33638000000000007), CGPoint(x: -0.17688, y: -0.33671), CGPoint(x: -0.17600000000000002, y: -0.33814000000000005), CGPoint(x: -0.17479000000000003, y: -0.34034000000000003), CGPoint(x: -0.17347, y: -0.34243000000000007), CGPoint(x: -0.17270000000000002, y: -0.34375), CGPoint(x: -0.17127, y: -0.34584000000000004), CGPoint(x: -0.16995000000000002, y: -0.3479300000000001), CGPoint(x: -0.16775, y: -0.36883), CGPoint(x: -0.16753, y: -0.38335), CGPoint(x: -0.16885, y: -0.40535000000000004), CGPoint(x: -0.17215000000000003, y: -0.42735000000000006), CGPoint(x: -0.17732000000000003, y: -0.44869000000000003), CGPoint(x: -0.18172000000000002, y: -0.4622200000000001), CGPoint(x: -0.18546, y: -0.47135000000000005), CGPoint(x: -0.18931, y: -0.47971), CGPoint(x: -0.19195, y: -0.48477000000000003), CGPoint(x: -0.19602, y: -0.49148000000000003), CGPoint(x: -0.20020000000000002, y: -0.4970900000000001), CGPoint(x: -0.20416, y: -0.49984000000000006), CGPoint(x: -0.20647000000000001, y: -0.49896000000000007), CGPoint(x: -0.20988, y: -0.4976400000000001), CGPoint(x: -0.21329, y: -0.49643000000000004), CGPoint(x: -0.21681, y: -0.49511000000000005), CGPoint(x: -0.21912, y: -0.49423), CGPoint(x: 0.20768, y: -0.4915900000000001), CGPoint(x: 0.20614000000000002, y: -0.49005000000000004), CGPoint(x: 0.20339000000000002, y: -0.4866400000000001), CGPoint(x: 0.19932000000000002, y: -0.4805900000000001), CGPoint(x: 0.19514, y: -0.47355), CGPoint(x: 0.1925, y: -0.4682700000000001), CGPoint(x: 0.18876, y: -0.45958000000000004), CGPoint(x: 0.18634, y: -0.45342000000000005), CGPoint(x: 0.17974, y: -0.4317500000000001), CGPoint(x: 0.17501, y: -0.40887), CGPoint(x: 0.17314000000000002, y: -0.39336), CGPoint(x: 0.17215000000000003, y: -0.37004), CGPoint(x: 0.17336000000000001, y: -0.34749), CGPoint(x: 0.17556, y: -0.33308000000000004), CGPoint(x: 0.17611000000000002, y: -0.33231), CGPoint(x: 0.17666, y: -0.33143000000000006), CGPoint(x: 0.17699, y: -0.33088000000000006), CGPoint(x: 0.17743, y: -0.33), CGPoint(x: 0.17776, y: -0.32945), CGPoint(x: 0.17831, y: -0.32857000000000003), CGPoint(x: 0.17853000000000002, y: -0.32824000000000003), CGPoint(x: 0.17864, y: -0.32813000000000003), CGPoint(x: 0.17875000000000002, y: -0.32791), CGPoint(x: 0.17908000000000002, y: -0.32791), CGPoint(x: 0.17930000000000001, y: -0.32791), CGPoint(x: 0.17963, y: -0.32791), CGPoint(x: 0.17996, y: -0.32791), CGPoint(x: 0.18073000000000003, y: -0.3377), CGPoint(x: 0.18194000000000002, y: -0.36553), CGPoint(x: 0.18183000000000002, y: -0.39127000000000006), CGPoint(x: 0.18106, y: -0.40722), CGPoint(x: 0.17886000000000002, y: -0.42933), CGPoint(x: 0.17677000000000004, y: -0.44286000000000003), CGPoint(x: 0.17325000000000002, y: -0.45837000000000006), CGPoint(x: 0.17072, y: -0.46728000000000003), CGPoint(x: 0.16885, y: -0.47278000000000003), CGPoint(x: 0.16577, y: -0.48015), CGPoint(x: 0.16247, y: -0.48675000000000007), CGPoint(x: 0.16016000000000002, y: -0.49060000000000004), CGPoint(x: 0.15774000000000002, y: -0.49423), CGPoint(x: 0.15752, y: -0.49445000000000006), CGPoint(x: 0.16049000000000002, y: -0.49423), CGPoint(x: 0.16995000000000002, y: -0.49368), CGPoint(x: 0.17622000000000002, y: -0.49335000000000007), CGPoint(x: 0.18568, y: -0.49280000000000007), CGPoint(x: 0.19503000000000004, y: -0.4922500000000001), CGPoint(x: 0.2013, y: -0.49192)
        ]
        let denominator = max(1, coords.count - 1)
        return coords.enumerated().map { index, pt in
            ShapePoint(
                point: pt,
                role: index.isMultiple(of: 3) ? "logo-flame-spark" : "logo-flame-inner",
                progress: Double(index) / Double(denominator)
            )
        }
    }

    private static func generateHermesLogoPoints() -> [ShapePoint] {
        let coords: [CGPoint] = [
            CGPoint(x: -0.30448000000000003, y: 0.06732), CGPoint(x: -0.18700000000000003, y: -0.09614000000000002), CGPoint(x: -0.18722, y: -0.09581), CGPoint(x: -0.18744000000000002, y: -0.09548000000000001), CGPoint(x: -0.18755000000000002, y: -0.09515), CGPoint(x: -0.18425000000000002, y: -0.09405000000000001), CGPoint(x: -0.17567000000000002, y: -0.09185000000000001), CGPoint(x: -0.16885, y: -0.09020000000000002), CGPoint(x: -0.16192, y: -0.08844), CGPoint(x: -0.1606, y: -0.08723), CGPoint(x: -0.16104000000000002, y: -0.08624000000000001), CGPoint(x: -0.16159, y: -0.08514000000000001), CGPoint(x: -0.16203, y: -0.08415), CGPoint(x: -0.16159, y: -0.08327000000000001), CGPoint(x: -0.16093000000000002, y: -0.08239), CGPoint(x: -0.15994000000000003, y: -0.08129), CGPoint(x: -0.15928000000000003, y: -0.08041000000000001), CGPoint(x: -0.16071000000000002, y: -0.07931), CGPoint(x: -0.16214, y: -0.07832), CGPoint(x: -0.16357000000000002, y: -0.07722000000000001), CGPoint(x: -0.165, y: -0.07623), CGPoint(x: -0.16467, y: -0.07524000000000002), CGPoint(x: -0.16434, y: -0.07414000000000001), CGPoint(x: -0.16401000000000002, y: -0.07315), CGPoint(x: -0.16434, y: -0.07205), CGPoint(x: -0.16665000000000002, y: -0.07150000000000001), CGPoint(x: -0.16896, y: -0.07106000000000001), CGPoint(x: -0.17138, y: -0.07051000000000002), CGPoint(x: -0.17292000000000002, y: -0.06974000000000001), CGPoint(x: -0.17204000000000003, y: -0.06831000000000001), CGPoint(x: -0.17116, y: -0.06677), CGPoint(x: -0.17039, y: -0.06534000000000001), CGPoint(x: -0.17127, y: -0.06424), CGPoint(x: -0.17424000000000003, y: -0.06424), CGPoint(x: -0.17721, y: -0.06424), CGPoint(x: -0.18018, y: -0.06424), CGPoint(x: -0.18172000000000002, y: -0.06336), CGPoint(x: -0.18183000000000002, y: -0.06171), CGPoint(x: -0.18194000000000002, y: -0.06017), CGPoint(x: -0.18194000000000002, y: -0.05852), CGPoint(x: -0.18238000000000001, y: -0.05698), CGPoint(x: -0.18315000000000003, y: -0.055110000000000006), CGPoint(x: -0.18381, y: -0.053680000000000005), CGPoint(x: -0.18436000000000002, y: -0.05214), CGPoint(x: -0.18568, y: -0.051480000000000005), CGPoint(x: -0.18733000000000002, y: -0.05115), CGPoint(x: -0.18887, y: -0.050710000000000005), CGPoint(x: -0.19041000000000002, y: -0.05027), CGPoint(x: -0.19195, y: -0.05016), CGPoint(x: -0.19338000000000002, y: -0.05016), CGPoint(x: -0.19525, y: -0.05016), CGPoint(x: -0.19679000000000002, y: -0.05016), CGPoint(x: -0.19613, y: -0.052250000000000005), CGPoint(x: -0.19547, y: -0.054340000000000006), CGPoint(x: -0.19492, y: -0.05643), CGPoint(x: -0.19426000000000002, y: -0.058410000000000004), CGPoint(x: -0.19294000000000003, y: -0.06182000000000001), CGPoint(x: -0.19162, y: -0.06523000000000001), CGPoint(x: -0.1903, y: -0.06864), CGPoint(x: -0.18887, y: -0.07348), CGPoint(x: -0.18843000000000001, y: -0.07953), CGPoint(x: -0.18788000000000002, y: -0.08558), CGPoint(x: -0.18744000000000002, y: -0.09163), CGPoint(x: -0.20306, y: -0.03047), CGPoint(x: -0.01573, y: -0.5453800000000001), CGPoint(x: -0.01727, y: -0.54351), CGPoint(x: -0.018920000000000003, y: -0.54164), CGPoint(x: -0.02046, y: -0.5397700000000001), CGPoint(x: -0.022000000000000002, y: -0.53801), CGPoint(x: -0.021780000000000004, y: -0.53768), CGPoint(x: -0.02145, y: -0.53724), CGPoint(x: -0.02112, y: -0.53691), CGPoint(x: -0.02486, y: -0.53691), CGPoint(x: -0.02849, y: -0.53691), CGPoint(x: -0.03223, y: -0.53691), CGPoint(x: -0.03597, y: -0.53691), CGPoint(x: -0.03586, y: -0.53625), CGPoint(x: -0.03564, y: -0.5357000000000001), CGPoint(x: -0.035530000000000006, y: -0.53493), CGPoint(x: -0.03542, y: -0.53427), CGPoint(x: -0.03509, y: -0.53339), CGPoint(x: -0.034760000000000006, y: -0.5324), CGPoint(x: -0.03443, y: -0.5315200000000001), CGPoint(x: -0.03564, y: -0.53086), CGPoint(x: -0.041580000000000006, y: -0.53086), CGPoint(x: -0.04741, y: -0.53086), CGPoint(x: -0.05335000000000001, y: -0.53086), CGPoint(x: -0.05786000000000001, y: -0.53097), CGPoint(x: -0.05808000000000001, y: -0.5313), CGPoint(x: -0.058410000000000004, y: -0.53174), CGPoint(x: -0.05863, y: -0.53207), CGPoint(x: -0.06028000000000001, y: -0.5315200000000001), CGPoint(x: -0.06182000000000001, y: -0.53108), CGPoint(x: -0.06347000000000001, y: -0.5305300000000001), CGPoint(x: -0.06512000000000001, y: -0.5300900000000001), CGPoint(x: -0.09119000000000001, y: -0.5300900000000001), CGPoint(x: -0.11726, y: -0.5300900000000001), CGPoint(x: -0.14344, y: -0.5300900000000001), CGPoint(x: -0.16951, y: -0.5300900000000001), CGPoint(x: -0.17072, y: -0.5300900000000001), CGPoint(x: -0.17182000000000003, y: -0.5300900000000001), CGPoint(x: -0.17292000000000002, y: -0.5300900000000001), CGPoint(x: -0.17402000000000004, y: -0.5300900000000001), CGPoint(x: -0.21538000000000002, y: -0.5300900000000001), CGPoint(x: -0.25685, y: -0.5300900000000001), CGPoint(x: -0.30855000000000005, y: -0.5300900000000001), CGPoint(x: -0.33957, y: -0.5313), CGPoint(x: -0.33913000000000004, y: -0.53625), CGPoint(x: -0.33869000000000005, y: -0.5413100000000001), CGPoint(x: -0.33825, y: -0.5462600000000001), CGPoint(x: -0.31229, y: -0.5424100000000001), CGPoint(x: -0.23441000000000004, y: -0.52283), CGPoint(x: -0.18689, y: -0.5166700000000001), CGPoint(x: -0.15862, y: -0.51865), CGPoint(x: -0.13541, y: -0.5237100000000001), CGPoint(x: -0.10351000000000002, y: -0.5294300000000001), CGPoint(x: -0.07161000000000001, y: -0.5352600000000001), CGPoint(x: -0.03971, y: -0.5410900000000001), CGPoint(x: -0.10406000000000001, y: 0.54483), CGPoint(x: -0.10428, y: 0.54549), CGPoint(x: -0.10450000000000001, y: 0.54615), CGPoint(x: -0.10483, y: 0.54681), CGPoint(x: -0.10505, y: 0.54747), CGPoint(x: -0.10527, y: 0.5480200000000001), CGPoint(x: -0.10560000000000001, y: 0.5486800000000001), CGPoint(x: -0.10582, y: 0.54934), CGPoint(x: -0.10615000000000001, y: 0.55), CGPoint(x: -0.10626000000000002, y: 0.5498900000000001), CGPoint(x: -0.10648, y: 0.54978), CGPoint(x: -0.10659, y: 0.54967), CGPoint(x: -0.10681000000000002, y: 0.54956), CGPoint(x: -0.10703, y: 0.54934), CGPoint(x: -0.10714000000000001, y: 0.5492300000000001), CGPoint(x: -0.10736000000000001, y: 0.54912), CGPoint(x: -0.10714000000000001, y: 0.54879), CGPoint(x: -0.10681000000000002, y: 0.5482400000000001), CGPoint(x: -0.10637, y: 0.54769), CGPoint(x: -0.10593000000000001, y: 0.54725), CGPoint(x: -0.10549000000000001, y: 0.5467000000000001), CGPoint(x: -0.10505, y: 0.54615), CGPoint(x: -0.10461000000000001, y: 0.5456000000000001), CGPoint(x: -0.10417000000000001, y: 0.54505), CGPoint(x: -0.02519, y: 0.36828), CGPoint(x: -0.026290000000000004, y: 0.36949), CGPoint(x: -0.02849, y: 0.3718000000000001), CGPoint(x: -0.02959, y: 0.37290000000000006), CGPoint(x: -0.03179, y: 0.37521000000000004), CGPoint(x: -0.03289, y: 0.37642000000000003), CGPoint(x: -0.033990000000000006, y: 0.37752), CGPoint(x: -0.03619, y: 0.37983), CGPoint(x: -0.037290000000000004, y: 0.38104), CGPoint(x: -0.03839, y: 0.38214000000000004), CGPoint(x: -0.0407, y: 0.38445), CGPoint(x: -0.041800000000000004, y: 0.38555), CGPoint(x: -0.0429, y: 0.38676000000000005), CGPoint(x: -0.0407, y: 0.38445), CGPoint(x: -0.039490000000000004, y: 0.38324), CGPoint(x: -0.037290000000000004, y: 0.38104), CGPoint(x: -0.03619, y: 0.37983), CGPoint(x: -0.03509, y: 0.37873), CGPoint(x: -0.03289, y: 0.37642000000000003), CGPoint(x: -0.03179, y: 0.37521000000000004), CGPoint(x: -0.02959, y: 0.37290000000000006), CGPoint(x: -0.02849, y: 0.3718000000000001), CGPoint(x: -0.02739, y: 0.37059000000000003), CGPoint(x: -0.02519, y: 0.36828), CGPoint(x: -0.30448000000000003, y: 0.38093000000000005), CGPoint(x: 0.40953000000000006, y: 0.16181), CGPoint(x: 0.40942, y: 0.16192), CGPoint(x: 0.4092, y: 0.16203), CGPoint(x: 0.40909000000000006, y: 0.16203), CGPoint(x: 0.40898000000000007, y: 0.16214), CGPoint(x: 0.40887, y: 0.16225), CGPoint(x: 0.40865, y: 0.16236000000000003), CGPoint(x: 0.40854, y: 0.16247), CGPoint(x: 0.40843000000000007, y: 0.16258), CGPoint(x: 0.40821, y: 0.16269000000000003), CGPoint(x: 0.4081, y: 0.16269000000000003), CGPoint(x: 0.40799, y: 0.1628), CGPoint(x: 0.40799, y: 0.1628), CGPoint(x: 0.4081, y: 0.16269000000000003), CGPoint(x: 0.40821, y: 0.16269000000000003), CGPoint(x: 0.40832, y: 0.16258), CGPoint(x: 0.40854, y: 0.16247), CGPoint(x: 0.40865, y: 0.16236000000000003), CGPoint(x: 0.40876, y: 0.16225), CGPoint(x: 0.40898000000000007, y: 0.16214), CGPoint(x: 0.40909000000000006, y: 0.16203), CGPoint(x: 0.4092, y: 0.16203), CGPoint(x: 0.40931, y: 0.16192), CGPoint(x: 0.40953000000000006, y: 0.16181), CGPoint(x: -0.31119, y: -0.14982), CGPoint(x: -0.31141, y: -0.14740000000000003), CGPoint(x: -0.31163, y: -0.14509), CGPoint(x: -0.31196000000000007, y: -0.14190000000000003), CGPoint(x: -0.31218, y: -0.13948000000000002), CGPoint(x: -0.3124, y: -0.13717000000000001), CGPoint(x: -0.31251000000000007, y: -0.13739), CGPoint(x: -0.31273, y: -0.13761), CGPoint(x: -0.31295, y: -0.13805), CGPoint(x: -0.31372000000000005, y: -0.13816), CGPoint(x: -0.31548000000000004, y: -0.13783), CGPoint(x: -0.31735, y: -0.1375), CGPoint(x: -0.31911000000000006, y: -0.13717000000000001), CGPoint(x: -0.32153000000000004, y: -0.13673), CGPoint(x: -0.3229600000000001, y: -0.13684000000000002), CGPoint(x: -0.32384, y: -0.13805), CGPoint(x: -0.32472000000000006, y: -0.13926), CGPoint(x: -0.32582000000000005, y: -0.1408), CGPoint(x: -0.32659000000000005, y: -0.14201), CGPoint(x: -0.32615, y: -0.14322000000000001), CGPoint(x: -0.32318, y: -0.14454), CGPoint(x: -0.32021000000000005, y: -0.14586000000000002), CGPoint(x: -0.31625, y: -0.14762000000000003), CGPoint(x: -0.31317000000000006, y: -0.14894000000000002), CGPoint(x: 0.09933000000000002, y: 0.27841), CGPoint(x: 0.09889, y: 0.27874000000000004), CGPoint(x: 0.09801, y: 0.27929000000000004), CGPoint(x: 0.09757, y: 0.27951000000000004), CGPoint(x: 0.09669000000000001, y: 0.28006000000000003), CGPoint(x: 0.09625, y: 0.28028000000000003), CGPoint(x: 0.09581, y: 0.28061), CGPoint(x: 0.09493000000000001, y: 0.28116), CGPoint(x: 0.09449000000000002, y: 0.2813800000000001), CGPoint(x: 0.09405000000000001, y: 0.28171), CGPoint(x: 0.09317, y: 0.28215), CGPoint(x: 0.09273, y: 0.28248), CGPoint(x: 0.09229000000000001, y: 0.2827), CGPoint(x: 0.09317, y: 0.28215), CGPoint(x: 0.09361, y: 0.28193), CGPoint(x: 0.09449000000000002, y: 0.2813800000000001), CGPoint(x: 0.09493000000000001, y: 0.28116), CGPoint(x: 0.09537000000000001, y: 0.2808300000000001), CGPoint(x: 0.09625, y: 0.28028000000000003), CGPoint(x: 0.09669000000000001, y: 0.28006000000000003), CGPoint(x: 0.09757, y: 0.27951000000000004), CGPoint(x: 0.09801, y: 0.27929000000000004), CGPoint(x: 0.09845000000000001, y: 0.27896000000000004), CGPoint(x: 0.09933000000000002, y: 0.27841), CGPoint(x: 0.08701000000000002, y: 0.16335), CGPoint(x: 0.08679, y: 0.16071000000000002), CGPoint(x: 0.08635000000000001, y: 0.15543), CGPoint(x: 0.08624000000000001, y: 0.15279), CGPoint(x: 0.0858, y: 0.14751), CGPoint(x: 0.08558, y: 0.14487000000000003), CGPoint(x: 0.08536, y: 0.14223000000000002), CGPoint(x: 0.08492000000000001, y: 0.13684000000000002), CGPoint(x: 0.08481000000000001, y: 0.1342), CGPoint(x: 0.08459, y: 0.13156), CGPoint(x: 0.08415, y: 0.12628), CGPoint(x: 0.08393000000000002, y: 0.12364000000000001), CGPoint(x: 0.08371, y: 0.12100000000000001), CGPoint(x: 0.08415, y: 0.12628), CGPoint(x: 0.08437000000000001, y: 0.12892), CGPoint(x: 0.08481000000000001, y: 0.1342), CGPoint(x: 0.08492000000000001, y: 0.13684000000000002), CGPoint(x: 0.08514000000000001, y: 0.13959000000000002), CGPoint(x: 0.08558, y: 0.14487000000000003), CGPoint(x: 0.0858, y: 0.14751), CGPoint(x: 0.08624000000000001, y: 0.15279), CGPoint(x: 0.08635000000000001, y: 0.15543), CGPoint(x: 0.08657000000000001, y: 0.15807000000000002), CGPoint(x: 0.08701000000000002, y: 0.16335), CGPoint(x: 0.23419000000000004, y: -0.22506), CGPoint(x: 0.23540000000000003, y: -0.22165000000000004), CGPoint(x: 0.23661000000000004, y: -0.21824000000000002), CGPoint(x: 0.23771, y: -0.21483000000000002), CGPoint(x: 0.23859000000000002, y: -0.21230000000000002), CGPoint(x: 0.24409, y: -0.19393000000000002), CGPoint(x: 0.25102, y: -0.17061), CGPoint(x: 0.25795, y: -0.14729), CGPoint(x: 0.26488, y: -0.12408000000000001), CGPoint(x: 0.26686000000000004, y: -0.11825000000000001), CGPoint(x: 0.26730000000000004, y: -0.11836), CGPoint(x: 0.26774000000000003, y: -0.11847000000000002), CGPoint(x: 0.26719000000000004, y: -0.12177000000000002), CGPoint(x: 0.26642000000000005, y: -0.12606), CGPoint(x: 0.26565, y: -0.13035), CGPoint(x: 0.26477, y: -0.13475), CGPoint(x: 0.26389, y: -0.13783), CGPoint(x: 0.26246, y: -0.14179), CGPoint(x: 0.26114000000000004, y: -0.14586000000000002), CGPoint(x: 0.25971000000000005, y: -0.14982), CGPoint(x: 0.25586000000000003, y: -0.16104000000000002), CGPoint(x: 0.25124, y: -0.17468), CGPoint(x: 0.24508000000000002, y: -0.19305), CGPoint(x: 0.23881, y: -0.21131), CGPoint(x: -0.29073, y: 0.1375), CGPoint(x: -0.33825, y: 0.026510000000000002), CGPoint(x: -0.33539, y: -0.030250000000000003), CGPoint(x: -0.33539, y: -0.030030000000000005), CGPoint(x: -0.33539, y: -0.02959), CGPoint(x: -0.33539, y: -0.02926), CGPoint(x: -0.33539, y: -0.028820000000000002), CGPoint(x: -0.33539, y: -0.0286), CGPoint(x: -0.33539, y: -0.028270000000000003), CGPoint(x: -0.33539, y: -0.02783), CGPoint(x: -0.33539, y: -0.027610000000000003), CGPoint(x: -0.33539, y: -0.027280000000000002), CGPoint(x: -0.33539, y: -0.026840000000000003), CGPoint(x: -0.33539, y: -0.02662), CGPoint(x: -0.33539, y: -0.026290000000000004), CGPoint(x: -0.33539, y: -0.026840000000000003), CGPoint(x: -0.33539, y: -0.027060000000000004), CGPoint(x: -0.33539, y: -0.027610000000000003), CGPoint(x: -0.33539, y: -0.02783), CGPoint(x: -0.33539, y: -0.028050000000000002), CGPoint(x: -0.33539, y: -0.0286), CGPoint(x: -0.33539, y: -0.028820000000000002), CGPoint(x: -0.33539, y: -0.02926), CGPoint(x: -0.33539, y: -0.02959), CGPoint(x: -0.33539, y: -0.02981), CGPoint(x: -0.33539, y: -0.030250000000000003), CGPoint(x: -0.33616, y: -0.07656), CGPoint(x: -0.33561, y: -0.07612000000000001), CGPoint(x: -0.33506, y: -0.07557), CGPoint(x: -0.33451000000000003, y: -0.07513), CGPoint(x: -0.33396, y: -0.07469), CGPoint(x: -0.33341, y: -0.07425000000000001), CGPoint(x: -0.33286, y: -0.07381000000000001), CGPoint(x: -0.33231, y: -0.07337), CGPoint(x: -0.33176, y: -0.07282), CGPoint(x: -0.33319000000000004, y: -0.07293000000000001), CGPoint(x: -0.33462000000000003, y: -0.07293000000000001), CGPoint(x: -0.33605, y: -0.07293000000000001), CGPoint(x: -0.33748000000000006, y: -0.07293000000000001), CGPoint(x: -0.33968000000000004, y: -0.07304000000000001), CGPoint(x: -0.34111, y: -0.07304000000000001), CGPoint(x: -0.34254, y: -0.07304000000000001), CGPoint(x: -0.34276, y: -0.07326000000000002), CGPoint(x: -0.3418800000000001, y: -0.07370000000000002), CGPoint(x: -0.341, y: -0.07414000000000001), CGPoint(x: -0.34012, y: -0.07458000000000001), CGPoint(x: -0.33924000000000004, y: -0.07502), CGPoint(x: -0.33836, y: -0.07546), CGPoint(x: -0.33748000000000006, y: -0.07590000000000001), CGPoint(x: -0.3366, y: -0.07634), CGPoint(x: 0.15279, y: -0.06105000000000001), CGPoint(x: -0.20647000000000001, y: -0.23606000000000002), CGPoint(x: -0.20790000000000003, y: -0.23859000000000002), CGPoint(x: -0.21065000000000003, y: -0.24365000000000003), CGPoint(x: -0.21208000000000002, y: -0.24618), CGPoint(x: -0.21494000000000002, y: -0.25113), CGPoint(x: -0.21626, y: -0.25366), CGPoint(x: -0.21769000000000002, y: -0.25619000000000003), CGPoint(x: -0.22055000000000002, y: -0.26114000000000004), CGPoint(x: -0.22198000000000004, y: -0.26367), CGPoint(x: -0.22330000000000003, y: -0.2662), CGPoint(x: -0.22616000000000003, y: -0.27126000000000006), CGPoint(x: -0.22759000000000001, y: -0.27368000000000003), CGPoint(x: -0.22902, y: -0.27621), CGPoint(x: -0.22616000000000003, y: -0.27126000000000006), CGPoint(x: -0.22473000000000004, y: -0.26873), CGPoint(x: -0.22198000000000004, y: -0.26367), CGPoint(x: -0.22055000000000002, y: -0.26114000000000004), CGPoint(x: -0.21912, y: -0.25872), CGPoint(x: -0.21626, y: -0.25366), CGPoint(x: -0.21494000000000002, y: -0.25113), CGPoint(x: -0.21208000000000002, y: -0.24618), CGPoint(x: -0.21065000000000003, y: -0.24365000000000003), CGPoint(x: -0.20922000000000002, y: -0.24112000000000003), CGPoint(x: -0.20647000000000001, y: -0.23606000000000002), CGPoint(x: -0.09141, y: -0.5220600000000001), CGPoint(x: -0.08536, y: -0.5192), CGPoint(x: -0.0814, y: -0.5173300000000001), CGPoint(x: -0.07535000000000001, y: -0.5144700000000001), CGPoint(x: -0.07139000000000001, y: -0.51249), CGPoint(x: -0.06534000000000001, y: -0.50963), CGPoint(x: -0.05929000000000001, y: -0.50677), CGPoint(x: -0.05918, y: -0.50699), CGPoint(x: -0.058960000000000005, y: -0.50732), CGPoint(x: -0.05874000000000001, y: -0.50754), CGPoint(x: -0.05863, y: -0.5077600000000001), CGPoint(x: -0.05852, y: -0.50798), CGPoint(x: -0.05808000000000001, y: -0.5082000000000001), CGPoint(x: -0.05775, y: -0.50831), CGPoint(x: -0.0572, y: -0.50853), CGPoint(x: -0.05687000000000001, y: -0.50875), CGPoint(x: -0.05632000000000001, y: -0.50897), CGPoint(x: -0.05577000000000001, y: -0.50919), CGPoint(x: -0.05786000000000001, y: -0.51007), CGPoint(x: -0.06457, y: -0.51249), CGPoint(x: -0.06908, y: -0.51403), CGPoint(x: -0.07579000000000001, y: -0.51645), CGPoint(x: -0.0825, y: -0.51887), CGPoint(x: -0.08701000000000002, y: -0.5205200000000001), CGPoint(x: 0.22957000000000002, y: -0.2376), CGPoint(x: 0.22946000000000003, y: -0.23782000000000003), CGPoint(x: 0.22935, y: -0.23815000000000003), CGPoint(x: 0.22924000000000003, y: -0.23826), CGPoint(x: 0.22913000000000003, y: -0.23848), CGPoint(x: 0.22902, y: -0.23881), CGPoint(x: 0.2288, y: -0.23903000000000002), CGPoint(x: 0.22869000000000003, y: -0.23925000000000002), CGPoint(x: 0.22869000000000003, y: -0.23947000000000002), CGPoint(x: 0.22847, y: -0.23969000000000004), CGPoint(x: 0.22836000000000004, y: -0.23958000000000002), CGPoint(x: 0.22825, y: -0.23947000000000002), CGPoint(x: 0.22803000000000004, y: -0.23947000000000002), CGPoint(x: 0.22803000000000004, y: -0.23936000000000002), CGPoint(x: 0.22781, y: -0.23925000000000002), CGPoint(x: 0.22781, y: -0.23914000000000002), CGPoint(x: 0.22814, y: -0.23892000000000002), CGPoint(x: 0.22825, y: -0.23881), CGPoint(x: 0.22847, y: -0.23859000000000002), CGPoint(x: 0.22869000000000003, y: -0.23837000000000003), CGPoint(x: 0.22891000000000003, y: -0.23815000000000003), CGPoint(x: 0.22913000000000003, y: -0.23804000000000003), CGPoint(x: 0.22924000000000003, y: -0.23793), CGPoint(x: 0.22946000000000003, y: -0.23771), CGPoint(x: -0.39215, y: -0.35871000000000003), CGPoint(x: -0.39435000000000003, y: -0.35662), CGPoint(x: -0.39754, y: -0.35343), CGPoint(x: -0.39974000000000004, y: -0.35134000000000004), CGPoint(x: -0.40304, y: -0.34815), CGPoint(x: -0.40513000000000005, y: -0.34606000000000003), CGPoint(x: -0.40733, y: -0.34386), CGPoint(x: -0.40931, y: -0.34166), CGPoint(x: -0.40887, y: -0.34155), CGPoint(x: -0.40821, y: -0.34133), CGPoint(x: -0.40777, y: -0.34122), CGPoint(x: -0.40711, y: -0.34089), CGPoint(x: -0.40667, y: -0.34078), CGPoint(x: -0.40623000000000004, y: -0.34067), CGPoint(x: -0.40590000000000004, y: -0.34078), CGPoint(x: -0.40579000000000004, y: -0.34089), CGPoint(x: -0.40568000000000004, y: -0.34122), CGPoint(x: -0.40557000000000004, y: -0.34133), CGPoint(x: -0.40304, y: -0.34463000000000005), CGPoint(x: -0.40139, y: -0.3468300000000001), CGPoint(x: -0.39974000000000004, y: -0.34892), CGPoint(x: -0.39721, y: -0.35222000000000003), CGPoint(x: -0.39545, y: -0.35442), CGPoint(x: -0.39303000000000005, y: -0.35761000000000004), CGPoint(x: 0.22781, y: -0.24365000000000003), CGPoint(x: 0.22781, y: -0.24354000000000003), CGPoint(x: 0.22792, y: -0.24354000000000003), CGPoint(x: 0.22792, y: -0.24343), CGPoint(x: 0.22803000000000004, y: -0.24343), CGPoint(x: 0.22814, y: -0.24321), CGPoint(x: 0.22825, y: -0.2431), CGPoint(x: 0.22836000000000004, y: -0.24299000000000004), CGPoint(x: 0.22847, y: -0.24288), CGPoint(x: 0.22847, y: -0.24277000000000004), CGPoint(x: 0.22858000000000003, y: -0.24277000000000004), CGPoint(x: 0.22858000000000003, y: -0.24266000000000001), CGPoint(x: 0.22858000000000003, y: -0.24266000000000001), CGPoint(x: 0.22858000000000003, y: -0.24277000000000004), CGPoint(x: 0.22847, y: -0.24277000000000004), CGPoint(x: 0.22847, y: -0.24288), CGPoint(x: 0.22836000000000004, y: -0.24299000000000004), CGPoint(x: 0.22825, y: -0.2431), CGPoint(x: 0.22814, y: -0.24321), CGPoint(x: 0.22803000000000004, y: -0.24332000000000004), CGPoint(x: 0.22803000000000004, y: -0.24343), CGPoint(x: 0.22792, y: -0.24354000000000003), CGPoint(x: 0.22781, y: -0.24354000000000003), CGPoint(x: 0.22781, y: -0.24365000000000003), CGPoint(x: -0.38753000000000004, y: -0.33176), CGPoint(x: -0.38555, y: -0.33176), CGPoint(x: -0.3834600000000001, y: -0.33176), CGPoint(x: -0.38148000000000004, y: -0.33176), CGPoint(x: -0.37939, y: -0.33176), CGPoint(x: -0.3773000000000001, y: -0.33176), CGPoint(x: -0.37653000000000003, y: -0.33176), CGPoint(x: -0.37620000000000003, y: -0.33176), CGPoint(x: -0.37587000000000004, y: -0.33165), CGPoint(x: -0.37576000000000004, y: -0.33044), CGPoint(x: -0.37576000000000004, y: -0.32857000000000003), CGPoint(x: -0.37576000000000004, y: -0.3267), CGPoint(x: -0.37576000000000004, y: -0.32483), CGPoint(x: -0.37576000000000004, y: -0.32307), CGPoint(x: -0.37565000000000004, y: -0.32186000000000003), CGPoint(x: -0.37532000000000004, y: -0.32175), CGPoint(x: -0.37510000000000004, y: -0.32175), CGPoint(x: -0.37356000000000006, y: -0.32494), CGPoint(x: -0.36971000000000004, y: -0.33440000000000003), CGPoint(x: -0.3657500000000001, y: -0.34386), CGPoint(x: -0.36179000000000006, y: -0.35332), CGPoint(x: -0.35783, y: -0.36278), CGPoint(x: -0.35398, y: -0.37235000000000007), CGPoint(x: -0.35387, y: -0.37257), CGPoint(x: -0.35376, y: -0.37290000000000006), CGPoint(x: -0.35365, y: -0.37323), CGPoint(x: -0.35783, y: -0.36806000000000005), CGPoint(x: -0.36421000000000003, y: -0.36036), CGPoint(x: -0.37059000000000003, y: -0.35255000000000003), CGPoint(x: -0.37697, y: -0.34474000000000005), CGPoint(x: -0.38324, y: -0.33704), CGPoint(x: -0.28853, y: -0.36377000000000004), CGPoint(x: -0.28853, y: -0.36399000000000004), CGPoint(x: -0.28864000000000006, y: -0.36432000000000003), CGPoint(x: -0.28875000000000006, y: -0.36443000000000003), CGPoint(x: -0.28886, y: -0.36476000000000003), CGPoint(x: -0.28776, y: -0.3652), CGPoint(x: -0.28622000000000003, y: -0.36586), CGPoint(x: -0.28523, y: -0.36619), CGPoint(x: -0.28358, y: -0.36685000000000006), CGPoint(x: -0.28259000000000006, y: -0.36729), CGPoint(x: -0.28105, y: -0.36795000000000005), CGPoint(x: -0.2805, y: -0.36784), CGPoint(x: -0.2805, y: -0.36707), CGPoint(x: -0.2805, y: -0.36652), CGPoint(x: -0.2805, y: -0.36597), CGPoint(x: -0.2805, y: -0.3652), CGPoint(x: -0.2805, y: -0.36465000000000003), CGPoint(x: -0.2805, y: -0.36377000000000004), CGPoint(x: -0.28149, y: -0.36377000000000004), CGPoint(x: -0.28303, y: -0.36377000000000004), CGPoint(x: -0.28402, y: -0.36377000000000004), CGPoint(x: -0.28556000000000004, y: -0.36377000000000004), CGPoint(x: -0.28655, y: -0.36377000000000004), CGPoint(x: -0.28798, y: -0.36377000000000004), CGPoint(x: -0.09801, y: -0.38005), CGPoint(x: -0.09911, y: -0.38005), CGPoint(x: -0.09988000000000001, y: -0.38005), CGPoint(x: -0.10098000000000001, y: -0.38005), CGPoint(x: -0.10219, y: -0.38005), CGPoint(x: -0.10285000000000001, y: -0.38005), CGPoint(x: -0.10406000000000001, y: -0.38005), CGPoint(x: -0.10439000000000001, y: -0.38082000000000005), CGPoint(x: -0.10472000000000002, y: -0.38137000000000004), CGPoint(x: -0.10516000000000002, y: -0.38214000000000004), CGPoint(x: -0.10549000000000001, y: -0.38291000000000003), CGPoint(x: -0.10582, y: -0.3834600000000001), CGPoint(x: -0.10626000000000002, y: -0.38423), CGPoint(x: -0.10593000000000001, y: -0.38423), CGPoint(x: -0.10571000000000001, y: -0.38423), CGPoint(x: -0.10549000000000001, y: -0.38434), CGPoint(x: -0.10516000000000002, y: -0.38434), CGPoint(x: -0.10494, y: -0.38434), CGPoint(x: -0.10428, y: -0.38412), CGPoint(x: -0.10307000000000001, y: -0.38324), CGPoint(x: -0.10219, y: -0.38280000000000003), CGPoint(x: -0.10098000000000001, y: -0.38192000000000004), CGPoint(x: -0.09966000000000001, y: -0.38115), CGPoint(x: -0.09889, y: -0.3806), CGPoint(x: -0.2255, y: -0.3468300000000001), CGPoint(x: -0.22462000000000001, y: -0.34540000000000004), CGPoint(x: -0.22374000000000002, y: -0.34397), CGPoint(x: -0.22297, y: -0.34254), CGPoint(x: -0.22209, y: -0.341), CGPoint(x: -0.22132000000000002, y: -0.33957), CGPoint(x: -0.22044000000000002, y: -0.33814000000000005), CGPoint(x: -0.21956, y: -0.33671), CGPoint(x: -0.21879, y: -0.33528), CGPoint(x: -0.21901, y: -0.34397), CGPoint(x: -0.21923000000000004, y: -0.35277000000000003), CGPoint(x: -0.21956, y: -0.36146000000000006), CGPoint(x: -0.21978000000000003, y: -0.37015000000000003), CGPoint(x: -0.22011000000000003, y: -0.38324), CGPoint(x: -0.22044000000000002, y: -0.39193000000000006), CGPoint(x: -0.22066000000000002, y: -0.40073000000000003), CGPoint(x: -0.22110000000000002, y: -0.40139), CGPoint(x: -0.22165000000000004, y: -0.39413000000000004), CGPoint(x: -0.22220000000000004, y: -0.38687000000000005), CGPoint(x: -0.22286000000000003, y: -0.37961000000000006), CGPoint(x: -0.22341000000000003, y: -0.37224), CGPoint(x: -0.22396000000000002, y: -0.36498), CGPoint(x: -0.22462000000000001, y: -0.35772000000000004), CGPoint(x: -0.22517, y: -0.35046000000000005), CGPoint(x: -0.21219000000000002, y: -0.3296700000000001), CGPoint(x: -0.21175000000000002, y: -0.33), CGPoint(x: -0.21120000000000003, y: -0.33033), CGPoint(x: -0.21076, y: -0.33055), CGPoint(x: -0.21032000000000003, y: -0.33088000000000006), CGPoint(x: -0.20988, y: -0.33121), CGPoint(x: -0.20933000000000002, y: -0.33154), CGPoint(x: -0.20889000000000002, y: -0.33176), CGPoint(x: -0.20845000000000002, y: -0.33209000000000005), CGPoint(x: -0.20889000000000002, y: -0.33440000000000003), CGPoint(x: -0.20944000000000004, y: -0.33682000000000006), CGPoint(x: -0.20988, y: -0.33913000000000004), CGPoint(x: -0.21032000000000003, y: -0.34155), CGPoint(x: -0.21109, y: -0.34507), CGPoint(x: -0.21153000000000002, y: -0.3473800000000001), CGPoint(x: -0.21208000000000002, y: -0.34969000000000006), CGPoint(x: -0.21230000000000002, y: -0.34958000000000006), CGPoint(x: -0.21230000000000002, y: -0.34694), CGPoint(x: -0.21219000000000002, y: -0.34430000000000005), CGPoint(x: -0.21219000000000002, y: -0.34166), CGPoint(x: -0.21219000000000002, y: -0.33902), CGPoint(x: -0.21219000000000002, y: -0.33638000000000007), CGPoint(x: -0.21219000000000002, y: -0.33363000000000004), CGPoint(x: -0.21219000000000002, y: -0.33099), CGPoint(x: 0.27775000000000005, y: -0.41217), CGPoint(x: 0.27643000000000006, y: -0.4136), CGPoint(x: 0.27555, y: -0.41459000000000007), CGPoint(x: 0.27434000000000003, y: -0.41591), CGPoint(x: 0.27302000000000004, y: -0.41723000000000005), CGPoint(x: 0.27324000000000004, y: -0.41635000000000005), CGPoint(x: 0.27423000000000003, y: -0.4139300000000001), CGPoint(x: 0.27522, y: -0.41140000000000004), CGPoint(x: 0.27588000000000007, y: -0.40953000000000006), CGPoint(x: 0.27676, y: -0.40766), CGPoint(x: 0.27709000000000006, y: -0.40777), CGPoint(x: 0.27731, y: -0.4078800000000001), CGPoint(x: 0.27797, y: -0.40711), CGPoint(x: 0.27907, y: -0.40535000000000004), CGPoint(x: 0.27984000000000003, y: -0.40414000000000005), CGPoint(x: 0.28094, y: -0.40249), CGPoint(x: 0.28182, y: -0.4011700000000001), CGPoint(x: 0.28215, y: -0.40139), CGPoint(x: 0.28248, y: -0.40161), CGPoint(x: 0.28292, y: -0.40183), CGPoint(x: 0.28479000000000004, y: -0.39809000000000005), CGPoint(x: 0.28622000000000003, y: -0.39534), CGPoint(x: 0.28809000000000007, y: -0.39171000000000006), CGPoint(x: 0.28996000000000005, y: -0.38797000000000004), CGPoint(x: 0.29073, y: -0.3872), CGPoint(x: 0.29117000000000004, y: -0.38742000000000004), CGPoint(x: 0.29161000000000004, y: -0.38753000000000004), CGPoint(x: 0.29205000000000003, y: -0.3872), CGPoint(x: 0.29271, y: -0.38632000000000005), CGPoint(x: 0.29337, y: -0.38544), CGPoint(x: 0.29392, y: -0.38478), CGPoint(x: 0.29447, y: -0.38412), CGPoint(x: 0.29480000000000006, y: -0.38434), CGPoint(x: 0.29502, y: -0.38445), CGPoint(x: 0.29557, y: -0.38445), CGPoint(x: 0.29689, y: -0.38368), CGPoint(x: 0.29788000000000003, y: -0.38324), CGPoint(x: 0.2992, y: -0.38247000000000003), CGPoint(x: 0.30041, y: -0.38181000000000004), CGPoint(x: 0.30019, y: -0.38368), CGPoint(x: 0.29997, y: -0.3861), CGPoint(x: 0.29964, y: -0.38863000000000003), CGPoint(x: 0.29942, y: -0.3905), CGPoint(x: 0.29942, y: -0.39182000000000006), CGPoint(x: 0.29986, y: -0.39215), CGPoint(x: 0.30008, y: -0.39226), CGPoint(x: 0.30052, y: -0.39248000000000005), CGPoint(x: 0.30239, y: -0.39116000000000006), CGPoint(x: 0.30426000000000003, y: -0.38984), CGPoint(x: 0.30558, y: -0.38885000000000003), CGPoint(x: 0.30745000000000006, y: -0.38742000000000004), CGPoint(x: 0.30833, y: -0.38654), CGPoint(x: 0.30866000000000005, y: -0.38599), CGPoint(x: 0.30910000000000004, y: -0.38522000000000006), CGPoint(x: 0.30954, y: -0.38445), CGPoint(x: 0.30998000000000003, y: -0.38423), CGPoint(x: 0.31031000000000003, y: -0.38445), CGPoint(x: 0.31064, y: -0.38478), CGPoint(x: 0.30657, y: -0.38830000000000003), CGPoint(x: 0.29832000000000003, y: -0.39512), CGPoint(x: 0.29007, y: -0.40194), CGPoint(x: 0.28391, y: -0.40711), CGPoint(x: -0.03619, y: -0.39655), CGPoint(x: -0.04059000000000001, y: -0.39556), CGPoint(x: -0.04499, y: -0.39446), CGPoint(x: -0.05049000000000001, y: -0.39325), CGPoint(x: -0.05324, y: -0.3916), CGPoint(x: -0.05137, y: -0.38830000000000003), CGPoint(x: -0.0495, y: -0.385), CGPoint(x: -0.04752000000000001, y: -0.38181000000000004), CGPoint(x: -0.04587000000000001, y: -0.37906000000000006), CGPoint(x: -0.04488000000000001, y: -0.37818), CGPoint(x: -0.044000000000000004, y: -0.3773000000000001), CGPoint(x: -0.043120000000000006, y: -0.37653000000000003), CGPoint(x: -0.04191, y: -0.37598000000000004), CGPoint(x: -0.04048, y: -0.37543000000000004), CGPoint(x: -0.038610000000000005, y: -0.37488000000000005), CGPoint(x: -0.037070000000000006, y: -0.37444), CGPoint(x: -0.04015, y: -0.37169), CGPoint(x: -0.04488000000000001, y: -0.36828), CGPoint(x: -0.0495, y: -0.36487), CGPoint(x: -0.055330000000000004, y: -0.36069000000000007), CGPoint(x: -0.057420000000000006, y: -0.36311000000000004), CGPoint(x: -0.0594, y: -0.36564), CGPoint(x: -0.06138000000000001, y: -0.36806000000000005), CGPoint(x: -0.06347000000000001, y: -0.37059000000000003), CGPoint(x: -0.05665, y: -0.37708), CGPoint(x: -0.04807000000000001, y: -0.38522000000000006), CGPoint(x: -0.04125, y: -0.39171000000000006)
        ]
        let denominator = max(1, coords.count - 1)
        return coords.enumerated().map { index, pt in
            ShapePoint(
                point: pt,
                role: index.isMultiple(of: 3) ? "logo-flame-spark" : "logo-flame-inner",
                progress: Double(index) / Double(denominator)
            )
        }
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
