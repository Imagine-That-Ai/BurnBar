import SwiftUI
import Foundation
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

@MainActor
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
    public let maxFrameRate: Double?
    public let rendersAsynchronously: Bool
    public let currentMode: Binding<SwarmFormationMode>?
    public let logoOffsets: [CGSize]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiMode) private var uiMode

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
        maxFrameRate: Double? = nil,
        rendersAsynchronously: Bool = false,
        currentMode: Binding<SwarmFormationMode>? = nil,
        logoOffsets: [CGSize] = Array(repeating: .zero, count: 3)
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
        self.maxFrameRate = maxFrameRate
        self.rendersAsynchronously = rendersAsynchronously
        self.currentMode = currentMode
        self.logoOffsets = logoOffsets

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
        sim.panOffsets = logoOffsets
        _simulation = State(initialValue: sim)
    }

    public var body: some View {
        let fps = Self.sanitizedFrameRate(maxFrameRate, fallback: isBatteryThrottled ? 15.0 : 60.0)
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: reduceMotion)) { timeline in
            Canvas(rendersAsynchronously: rendersAsynchronously) { context, size in
                simulation.panOffsets = logoOffsets
                simulation.advance(
                    to: timeline.date,
                    bounds: size,
                    reduceMotion: reduceMotion,
                    isBatteryThrottled: isBatteryThrottled,
                    uiMode: uiMode
                )
                simulation.draw(
                    into: context,
                    size: size,
                    scheme: colorScheme,
                    isBatteryThrottled: isBatteryThrottled,
                    uiMode: uiMode
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

    nonisolated static func sanitizedFrameRate(_ frameRate: Double?, fallback: Double) -> Double {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else {
            return fallback
        }
        return frameRate.clamped(to: 1.0...120.0)
    }
}

// MARK: - Simulation Core

@MainActor
public final class SwarmSimulation {
    struct ProviderLogoSlot {
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
        var logoProvider: AgentProvider?
        var logoColor: RGBA?            // source logo pixel color for asset-derived provider marks
        var resolvedLogoColor: RGBA?
        var toneSeed: Double?
        var flowProgress: Double        // for router-flow bezier travel
        var slotIndex: Int?
    }

    private struct ResolvedGlyphTextKey: Hashable {
        let glyph: String
        let colorKey: Int
    }
    let timeStep: Double

    let swarmNoise: Double

    let swarmDrag: Double

    let maxSpeedGlyph: Double

    let maxSpeedPixel: Double

    let morphAttract: Double

    let morphNoise: Double

    let morphDrag: Double

    let cycleInterval: TimeInterval

    let mouseForceMultiplier: Double

    let glyphs = ["$", "{}", "</>", "tok", "ctx", "429", "503", "run", "cache"]

    var enabledProviderGlyphs: [AgentProvider]

    var excludeBrandShapes: Bool = false

    var modes: [SwarmFormationMode]

    var particles: [Particle] = []

    var mode: SwarmFormationMode = .swarm

    var cycleIndex: Int = 0

    var nextCycleAt: TimeInterval = 0

    var flowTime: Double = 0

    var bounds: CGSize = .zero

    var initialized = false

    var modeAssignedAt: TimeInterval = 0

    var shapeSettledAt: TimeInterval?

    var renderScheme: ColorScheme = .dark

    var isAutoCyclingEnabled = true

    lazy var dollarPoints = SwarmSimulation.sampleTextPoints(text: "$", fontSize: 280)

    lazy var codePoints = SwarmSimulation.sampleTextPoints(text: "</>", fontSize: 220)

    lazy var burnBarLogoPoints = SwarmLogoShape.generatePoints()

    lazy var ringPoints = SwarmSimulation.generateRingPoints()

    lazy var routerFlowPoints = SwarmSimulation.generateRouterFlowPoints()

    lazy var skilletPoints = SwarmSimulation.generateSkilletPoints()

    lazy var applePoints = SwarmSimulation.generateApplePoints()

    lazy var chefHatPoints = SwarmSimulation.generateChefHatPoints()

    lazy var chiliPoints = SwarmSimulation.generateChiliPoints()

    static var providerLogoPointCache: [AgentProvider: [ShapePoint]] = [:]

    static let xAILogoPoints = SwarmSimulation.generateXAILogoPoints()

    static let grokLogoPoints = SwarmSimulation.logoPoints(named: ["GrokLogo", "xAILogo"], fallback: SwarmSimulation.generateGrokLogoPoints())

    var pointer: CGPoint?

    public var enableSwarmSparkles: Bool = true

    public var panOffsets: [CGSize] = Array(repeating: .zero, count: 3)

    var motionSpeedMultiplier: Double = 1.0 {
        didSet {
            motionSpeedMultiplier = motionSpeedMultiplier.clamped(to: 0.35...2.5)
            shouldResetCycleTimer = true
        }
    }

    public var colorPalette: SwarmColorPalette = .defaultEmber

    var isAvatarEnabled: Bool = true

    var isBrandTextEnabled: Bool = true

    var shouldResetCycleTimer = false

    var colorDriver: SwarmColorDriver?

    var resolvedLogoColorPalette: SwarmColorPalette?

    var resolvedLogoColorScheme: ColorScheme?

    /// Previous driver's resolved colors per particle — used for smooth transition.
    var previousColors: [RGBA?] = []

    /// Progress of the current color transition (0 = old colors, 1 = new colors).
    var colorTransitionProgress: Double = 1.0

    /// Duration of the color transition in seconds.
    static let colorTransitionDuration: Double = 2.0

    /// Fast ignition transition when going from idle → active.
    static let ignitionTransitionDuration: Double = 0.8

    var activeTransitionDuration: Double = colorTransitionDuration

    static let shapeAdmireHoldDuration: TimeInterval = 5.0

    static let shapeSettleRecheckInterval: TimeInterval = 0.25

    static let shapeSettleFallbackDelay: TimeInterval = 6.0

    static let shapeSettledParticleFraction: Double = 0.95

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

    var lastUIMode: UIMode?

    public func advance(to date: Date, bounds size: CGSize, reduceMotion: Bool, isBatteryThrottled: Bool, uiMode: UIMode = .standard) {
        let now = date.timeIntervalSinceReferenceDate

        if lastUIMode != uiMode {
            let wasNil = (lastUIMode == nil)
            lastUIMode = uiMode
            self.modes = SwarmFormationMode.defaultCycle(for: enabledProviderGlyphs, excludeBrandShapes: excludeBrandShapes, uiMode: uiMode)
            if !wasNil {
                cycleIndex = 0
                assignMode(modes[cycleIndex], at: now, uiMode: uiMode)
                shouldResetCycleTimer = true
            }
        }

        if !initialized {
            self.bounds = size
            seedParticlesAcrossBounds()
            modeAssignedAt = now
            if mode != .swarm {
                assignMode(mode, at: now, uiMode: uiMode)
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
                assignMode(modes[cycleIndex], at: now, uiMode: uiMode)
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

    func stepParticle(
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
                let offset = p.slotIndex.map { slotIdx in
                    if slotIdx < panOffsets.count {
                        return panOffsets[slotIdx]
                    }
                    return .zero
                } ?? .zero

                let targetX = tx + Double(offset.width)
                let targetY = ty + Double(offset.height)

                let dx = targetX - p.x
                let dy = targetY - p.y
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

    public func draw(into ctx: GraphicsContext, size: CGSize, scheme: ColorScheme, isBatteryThrottled: Bool, uiMode: UIMode = .standard) {
        renderScheme = scheme   // drives the light/dark particle palette in colorFromKey
        refreshResolvedLogoColorsIfNeeded(for: scheme)

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
                let color = resolvedColor(for: p, at: index, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
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
            bucketPaths.reserveCapacity(64)
            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let key = colorKey(for: p)
                let inShape = (mode != .swarm && p.tx != nil)
                let r = max(0.4, p.size * (inShape ? 1.2 : 0.85))
                bucketPaths[key, default: Path()].addEllipse(in: CGRect(
                    x: p.x - r, y: p.y - r,
                    width: r * 2, height: r * 2
                ))
            }
            for (key, path) in bucketPaths {
                let baseColor = colorFromKey(key, uiMode: uiMode)
                let finalColor = isBatteryThrottled ? baseColor.opacity(0.5) : baseColor
                ctx.fill(path, with: .color(finalColor))
            }
        }

        // Glyphs — preserve draw order, but reuse resolved text for particles
        // with identical stable glyph/color pairs. During active color
        // transitions or logo-derived colors, each particle keeps its exact
        // per-particle resolve path.
        let canReuseGlyphText = colorDriver == nil && colorTransitionProgress >= 1.0
        var resolvedGlyphTextByKey: [ResolvedGlyphTextKey: GraphicsContext.ResolvedText] = [:]
        resolvedGlyphTextByKey.reserveCapacity(32)
        for (index, p) in particles.enumerated() where p.isGlyph {
            if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
            let color = resolvedColor(for: p, at: index, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
            let resolved: GraphicsContext.ResolvedText
            if canReuseGlyphText,
               p.logoProvider == nil,
               p.logoColor == nil,
               p.resolvedLogoColor == nil {
                let key = ResolvedGlyphTextKey(glyph: p.glyph, colorKey: colorKey(for: p))
                if let cached = resolvedGlyphTextByKey[key] {
                    resolved = cached
                } else {
                    let fresh = ctx.resolve(
                        Text(p.glyph)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(color)
                    )
                    resolvedGlyphTextByKey[key] = fresh
                    resolved = fresh
                }
            } else {
                resolved = ctx.resolve(
                    Text(p.glyph)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                )
            }
            ctx.draw(resolved, at: CGPoint(x: p.x, y: p.y), anchor: .center)
        }
    }

    func makeParticle() -> Particle {
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
            logoProvider: nil,
            logoColor: nil,
            resolvedLogoColor: nil,
            toneSeed: nil,
            flowProgress: Double.random(in: 0...1),
            slotIndex: nil
        )
    }

    func seedParticlesAcrossBounds() {
        for i in particles.indices {
            particles[i].x = Double.random(in: 0...1) * Double(bounds.width)
            particles[i].y = Double.random(in: 0...1) * Double(bounds.height)
        }
    }

    var pace_isEnergetic: Bool { cycleInterval == 8.0 }

    var effectiveCycleInterval: TimeInterval {
        cycleInterval / motionSpeedMultiplier.clamped(to: 0.35...2.5)
    }

}

#Preview {
    SwarmCanvasView(accent: .orange)
        .frame(width: 800, height: 600)
}

public extension Notification.Name {
    static let cycleSwarmShapeRequested = Notification.Name("com.openburnbar.swarm.cycleSwarmShapeRequested")
}

extension SwarmSimulation {
    /// Same-file access to the private logo samplers for `SwarmGlyphSampler`.
    static func normalizedGlyphOutlinePoints(for provider: AgentProvider, maxPoints: Int) -> [SwarmGlyphPoint] {
        let dense = logoPoints(for: provider, fallback: fallbackLogoPoints(for: provider))
        let outline = outlinePoints(from: dense)
        // Stroke-like marks (text fallbacks, thin glyphs) are already mostly
        // boundary; if the outline pass keeps nearly everything or nearly
        // nothing, the dense cloud is the better source.
        let source = (outline.count >= maxPoints / 2 && outline.count < dense.count * 9 / 10)
            ? outline
            : dense
        return evenlyDownsample(source, maxCount: maxPoints).map {
            SwarmGlyphPoint(position: $0.point, brandColor: $0.logoColor)
        }
    }

    /// Solid (filled) brand-mark cloud — the full sampled logo, not just its
    /// silhouette. Surfaces that render the mark large enough to read a fill
    /// (e.g. the launch hero) want this so the glyph looks like the actual
    /// logo instead of a hollow outline.
    static func normalizedGlyphFillPoints(for provider: AgentProvider, maxPoints: Int) -> [SwarmGlyphPoint] {
        let dense = logoPoints(for: provider, fallback: fallbackLogoPoints(for: provider))
        return evenlyDownsample(dense, maxCount: maxPoints).map {
            SwarmGlyphPoint(position: $0.point, brandColor: $0.logoColor)
        }
    }

    /// Keeps points on the silhouette of a grid-sampled fill cloud: interior
    /// grid points have ~8 same-spacing neighbors, boundary points fewer.
    private static func outlinePoints(from dense: [ShapePoint]) -> [ShapePoint] {
        guard dense.count > 24 else { return dense }

        // Estimate the sampling grid pitch from nearest-neighbor distances
        // of a subsample (the cloud comes off a regular grid).
        var nearest: [Double] = []
        let probeStride = max(1, dense.count / 96)
        for i in stride(from: 0, to: dense.count, by: probeStride) {
            var best = Double.greatestFiniteMagnitude
            let a = dense[i].point
            for j in 0..<dense.count where j != i {
                let b = dense[j].point
                let dx = a.x - b.x, dy = a.y - b.y
                let d2 = Double(dx * dx + dy * dy)
                if d2 < best { best = d2 }
            }
            nearest.append(best.squareRoot())
        }
        nearest.sort()
        guard let pitch = nearest.isEmpty ? nil : nearest[nearest.count / 2],
              pitch > 0 else { return dense }

        // Spatial hash on the pitch grid, then count 8-neighborhood occupancy.
        var buckets: [Int64: Int] = [:]
        @inline(__always) func key(_ p: CGPoint) -> Int64 {
            let gx = Int32((Double(p.x) / pitch).rounded())
            let gy = Int32((Double(p.y) / pitch).rounded())
            return (Int64(gx) << 32) | Int64(UInt32(bitPattern: gy))
        }
        for p in dense { buckets[key(p.point), default: 0] += 1 }

        var outline: [ShapePoint] = []
        for p in dense {
            let gx = Int32((Double(p.point.x) / pitch).rounded())
            let gy = Int32((Double(p.point.y) / pitch).rounded())
            var neighbors = 0
            for dx in -1...1 {
                for dy in -1...1 where !(dx == 0 && dy == 0) {
                    let k = (Int64(gx + Int32(dx)) << 32) | Int64(UInt32(bitPattern: gy + Int32(dy)))
                    if buckets[k] != nil { neighbors += 1 }
                }
            }
            if neighbors <= 6 { outline.append(p) }
        }
        return outline
    }
}
