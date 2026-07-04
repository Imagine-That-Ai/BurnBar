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
    /// Active substrate (foreground material). `nil` ⇒ the default dot render.
    public let substrate: SwarmSubstrate?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.uiMode) private var uiMode

    /// Lazily-built simulation. `@StateObject`'s autoclosure defers the
    /// expensive construction (particle seeding, shape samplers, color
    /// snapshot) to first attach — with `@State(initialValue:)` every view
    /// reconstruction built and discarded a full simulation, and hosts like the
    /// wallpaper reconstruct this view at pointer-commit rate (~30 Hz).
    @StateObject private var simulationBox: SwarmSimulationBox

    private var simulation: SwarmSimulation { simulationBox.simulation }

    #if os(macOS)
    @StateObject private var hostWindowVisibility = HostWindowVisibility()
    #endif

    /// True when the hosting window cannot be seen (fully occluded, hidden, or
    /// miniaturized). Decorative swarms pause their timeline instead of burning
    /// a render core on frames nobody can see — the desktop wallpaper panel
    /// under a fullscreen app and a dashboard buried behind other windows were
    /// both animating 24/7 before this gate.
    private var isHostWindowOccluded: Bool {
        #if os(macOS)
        hostWindowVisibility.isOccluded
        #else
        false
        #endif
    }

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
        logoOffsets: [CGSize] = Array(repeating: .zero, count: 3),
        substrate: SwarmSubstrate? = nil
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
        self.substrate = substrate

        let resolvedParticleCount = particleCount ?? Self.adaptiveParticleCount
        let resolvedSpeed = motionSpeedMultiplier.clamped(to: 0.35...2.5)
        // Everything below runs once, on first attach (the autoclosure defers
        // it); reconstructions of the view value only capture the parameters.
        _simulationBox = StateObject(wrappedValue: SwarmSimulationBox {
            let sim = SwarmSimulation(
                particleCount: resolvedParticleCount,
                pace: pace,
                enabledProviderGlyphs: normalizedProviderGlyphs,
                excludeBrandShapes: excludeBrandShapesFromSwarm
            )
            sim.isAvatarEnabled = isAvatarEnabled
            sim.isBrandTextEnabled = isBrandTextEnabled
            sim.setAutoCyclingEnabled(isAutoCyclingEnabled)
            sim.colorPalette = colorPalette
            sim.motionSpeedMultiplier = resolvedSpeed
            sim.setColorDriver(colorDriver)
            sim.enableSwarmSparkles = enableSwarmSparkles
            sim.panOffsets = logoOffsets
            sim.substrate = substrate
            sim.substrateAccent = accent
            sim.substrateBackdrop = backdropColor
            return sim
        })
    }

    public var body: some View {
        let fps = Self.sanitizedFrameRate(maxFrameRate, fallback: isBatteryThrottled ? 15.0 : Self.defaultFrameRate)
        TimelineView(.animation(minimumInterval: 1.0 / fps, paused: reduceMotion || isHostWindowOccluded)) { timeline in
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
        #if os(macOS)
        .background(HostWindowVisibilityReader(visibility: hostWindowVisibility))
        #endif
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
        .onChange(of: substrate.map(ObjectIdentifier.init)) {
            simulation.substrate = substrate
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
        let base = 900
        #else
        let base: Int = {
            if UIDevice.current.userInterfaceIdiom == .pad { return 1080 }
            return 520
        }()
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? base / 2 : base
    }

    /// Default animation budget for decorative backgrounds. Explicit callers
    /// can still opt into a higher `maxFrameRate`, but the dashboard should not
    /// burn a full render core just to keep embers moving.
    nonisolated public static var defaultFrameRate: Double {
        #if os(macOS)
        30.0
        #else
        60.0
        #endif
    }

    nonisolated static func sanitizedFrameRate(_ frameRate: Double?, fallback: Double) -> Double {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else {
            return fallback
        }
        return frameRate.clamped(to: 1.0...120.0)
    }
}

// MARK: - Simulation Core

/// Reference-type holder that lets `@StateObject`'s autoclosure defer
/// `SwarmSimulation` construction to first attach. No published state — it
/// exists purely for identity + lazy construction.
@MainActor
final class SwarmSimulationBox: ObservableObject {
    let simulation: SwarmSimulation

    init(_ build: () -> SwarmSimulation) {
        simulation = build()
    }
}

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

    var lastAdvanceAt: TimeInterval?

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

    // MARK: - Substrate layer (pluggable per-particle material painter)

    /// The active substrate, or nil/PlainDots for the default dot render. Built
    /// once by the host and reused so it can hold per-layout caches.
    var substrate: SwarmSubstrate?

    /// Accent color forwarded into the substrate `stage` (the View's `accent`,
    /// finally load-bearing). Defaults to the ember brand accent.
    var substrateAccent = Color(red: 0.96, green: 0.31, blue: 0.36)

    /// Optional backdrop plate color the substrate may read for blend choices.
    var substrateBackdrop: Color?

    /// Reduced-motion, stashed during `advance()` so `draw()` (which has no such
    /// argument) can hand it to the substrate frame.
    var substrateReduceMotion: Bool = false

    /// Last flowTime a substrate frame was built — drives the normalized `dt`.
    var lastSubstrateT: Double = 0

    /// Shared lazily-built NN/kNN structure provider handed to every frame.
    let substrateStructure = SubstrateStructureProvider()

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

    /// SwiftUI `Color`s keyed by quantized RGBA (`RGBA.bucketKey`). `Color`
    /// construction/bridging is expensive at particle counts; the palette only
    /// produces a bounded set of distinct quantized colors per frame, so this
    /// cache turns per-frame color churn into dictionary hits. Keys encode the
    /// exact channel values, so entries never go stale; the cap just bounds
    /// memory across palette/driver transitions.
    private var colorCacheByBucketKey: [UInt32: Color] = [:]

    private static let colorCacheLimit = 4096

    func cachedColor(forBucketKey key: UInt32) -> Color {
        if let cached = colorCacheByBucketKey[key] {
            return cached
        }
        if colorCacheByBucketKey.count >= Self.colorCacheLimit {
            colorCacheByBucketKey.removeAll(keepingCapacity: true)
        }
        let color = Color(
            red: Double((key >> 24) & 0xFF) / 255.0,
            green: Double((key >> 16) & 0xFF) / 255.0,
            blue: Double((key >> 8) & 0xFF) / 255.0
        )
        .opacity(Double(key & 0xFF) / 255.0)
        colorCacheByBucketKey[key] = color
        return color
    }

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
        self.mode = self.modes.first ?? .swarm

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
        substrateReduceMotion = reduceMotion   // stashed for the substrate frame in draw()
        let now = date.timeIntervalSinceReferenceDate
        let frameScale = Self.animationFrameScale(elapsed: lastAdvanceAt.map { now - $0 })
        lastAdvanceAt = now

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
        flowTime += timeStep * 1000.0 * motionSpeedMultiplier * frameScale   // tuned to feel right at 60Hz

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
                attract: attractFactor,
                frameScale: frameScale
            )
        }

        // Advance color transition.
        if colorTransitionProgress < 1.0 {
            let dt = frameScale / 60.0
            colorTransitionProgress = min(1.0, colorTransitionProgress + dt / activeTransitionDuration)
        }
    }

    nonisolated static func animationFrameScale(elapsed: TimeInterval?) -> Double {
        guard let elapsed, elapsed.isFinite, elapsed > 0 else {
            return 1.0
        }
        return (elapsed * 60.0).clamped(to: 0.25...4.0)
    }

    func stepParticle(
        index i: Int,
        width: Double,
        height: Double,
        pointerX: Double?,
        pointerY: Double?,
        motion: Double,
        attract: Double,
        frameScale: Double
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
            p.vx += (noiseX * swarmNoise * motionSpeedMultiplier + pushX) * motion * frameScale
            p.vy += (noiseY * swarmNoise * motionSpeedMultiplier + pushY) * motion * frameScale
            let drag = pow(swarmDrag, frameScale)
            p.vx *= drag
            p.vy *= drag

            let speed = sqrt(p.vx * p.vx + p.vy * p.vy)
            let maxSpeed = (p.isGlyph ? maxSpeedGlyph : maxSpeedPixel) * motionSpeedMultiplier
            if speed > maxSpeed, speed > 0 {
                p.vx = (p.vx / speed) * maxSpeed
                p.vy = (p.vy / speed) * maxSpeed
            }

            p.x += p.vx * frameScale
            p.y += p.vy * frameScale

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
                    p.flowProgress += (pace_isEnergetic ? 0.006 : 0.003) * motionSpeedMultiplier * frameScale
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
                    p.vx += (dx / dist) * morphAttract * attract * motionSpeedMultiplier * frameScale
                    p.vy += (dy / dist) * morphAttract * attract * motionSpeedMultiplier * frameScale
                }
                p.vx += (noiseX * morphNoise * motionSpeedMultiplier + pushX) * motion * frameScale
                p.vy += (noiseY * morphNoise * motionSpeedMultiplier + pushY) * motion * frameScale
                let drag = pow(morphDrag, frameScale)
                p.vx *= drag
                p.vy *= drag
                p.x += p.vx * frameScale
                p.y += p.vy * frameScale
            } else {
                // Surplus particles do a gentle ambient swirl.
                p.vx += (noiseX * swarmNoise * 0.75 * motionSpeedMultiplier + pushX) * motion * frameScale
                p.vy += (noiseY * swarmNoise * 0.75 * motionSpeedMultiplier + pushY) * motion * frameScale
                let drag = pow(swarmDrag, frameScale)
                p.vx *= drag
                p.vy *= drag
                p.x += p.vx * frameScale
                p.y += p.vy * frameScale

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

        // Substrate layer: when an active (non-plain) substrate fully paints the
        // field, skip the engine's own dot/twinkle loops. Glyph particles still
        // render afterward unless the substrate suppresses them.
        let substrateResult = paintSubstrate(into: ctx, size: size, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
        if substrateResult.handled {
            if !substrateResult.suppressesGlyphs {
                drawGlyphParticles(into: ctx, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
            }
            return
        }

        let shouldRenderIndividually: Bool = {
            if colorDriver != nil { return true }
            if case .shapeProviderLogo = mode { return true }
            if mode != .swarm { return true } // Ensure shapes always support high-quality sparkles & transitions
            return false
        }()

        if shouldRenderIndividually {
            // Data-driven path: each particle may have a unique color from the
            // provider palette. Colors are resolved per particle but the fills
            // are batched by an 8-bit-per-channel bucket key — one
            // `GraphicsContext.fill` per distinct color instead of one per
            // particle (formerly ~900 fills + 900 SwiftUI `Color` allocations
            // per frame; the single hottest main-thread cost in profiles).
            // 8-bit quantization matches display precision, so the rendered
            // output is identical.
            var bucketPaths: [UInt32: Path] = [:]
            bucketPaths.reserveCapacity(64)
            var glints: [(core: CGRect, glow: CGRect, intensity: Double)] = []

            for (index, p) in particles.enumerated() where !p.isGlyph {
                if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
                let rgba = resolvedRGBA(for: p, at: index, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
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
                bucketPaths[rgba.bucketKey, default: Path()].addEllipse(in: rect)

                if isSparkling {
                    let sr = r * 0.35
                    let glowR = r * 0.75
                    glints.append((
                        core: CGRect(x: p.x - sr, y: p.y - sr, width: sr * 2, height: sr * 2),
                        glow: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2),
                        intensity: sparkleIntensity
                    ))
                }
            }

            for (key, path) in bucketPaths {
                ctx.fill(path, with: .color(cachedColor(forBucketKey: key)))
            }

            // Sparkle glints render above the batched dots (a handful per frame
            // at most — the 6% twinkle gate keeps this loop tiny).
            for glint in glints {
                ctx.fill(Path(ellipseIn: glint.core), with: .color(Color.white.opacity(glint.intensity * 0.55)))
                ctx.fill(Path(ellipseIn: glint.glow), with: .color(Color.white.opacity(glint.intensity * 0.15)))
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
                var rgba = rgbaFromKey(key, uiMode: uiMode)
                if isBatteryThrottled {
                    rgba = RGBA(r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a * 0.5)
                }
                ctx.fill(path, with: .color(cachedColor(forBucketKey: rgba.bucketKey)))
            }
        }

        drawGlyphParticles(into: ctx, isBatteryThrottled: isBatteryThrottled, uiMode: uiMode)
    }

    /// The brand-glyph (`$`, `tok`, `429`, provider marks) text pass, factored out
    /// of `draw()` verbatim so the substrate hook can run it independently of the
    /// dot loop. Behavior-preserving extraction.
    func drawGlyphParticles(into ctx: GraphicsContext, isBatteryThrottled: Bool, uiMode: UIMode) {
        let canReuseGlyphText = colorDriver == nil && colorTransitionProgress >= 1.0
        var resolvedGlyphTextByKey: [ResolvedGlyphTextKey: GraphicsContext.ResolvedText] = [:]
        resolvedGlyphTextByKey.reserveCapacity(32)
        for (index, p) in particles.enumerated() where p.isGlyph {
            if isBatteryThrottled && index % 2 == 1 { continue } // Skip 50% on battery
            guard Self.shouldDrawGlyphParticle(
                at: index,
                isBatteryThrottled: isBatteryThrottled,
                particleCount: particles.count
            ) else {
                continue
            }
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

    nonisolated static func shouldDrawGlyphParticle(
        at index: Int,
        isBatteryThrottled: Bool,
        particleCount: Int
    ) -> Bool {
        let stride: Int
        if isBatteryThrottled {
            stride = 5
        } else if particleCount >= 1_000 {
            stride = 4
        } else {
            stride = 3
        }
        return index % stride == 0
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

#if os(macOS)
// MARK: - Host-window occlusion tracking (macOS)

/// Publishes whether the hosting `NSWindow` is fully occluded, so the swarm can
/// pause its `TimelineView` when nothing it draws can reach the screen. The
/// desktop-wallpaper panel behind a fullscreen Space and a dashboard window
/// buried under other apps both read as occluded and stop costing CPU; the
/// moment any pixel becomes visible again, AppKit flips the occlusion state and
/// the timeline resumes.
@MainActor
final class HostWindowVisibility: ObservableObject {
    @Published var isOccluded = false
}

struct HostWindowVisibilityReader: NSViewRepresentable {
    let visibility: HostWindowVisibility

    func makeNSView(context: Context) -> TrackerView {
        TrackerView(visibility: visibility)
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {}

    @MainActor
    final class TrackerView: NSView {
        private let visibility: HostWindowVisibility
        private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?

        init(visibility: HostWindowVisibility) {
            self.visibility = visibility
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        deinit {
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
                self.occlusionObserver = nil
            }
            if let window {
                occlusionObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.refreshOcclusion()
                    }
                }
            }
            // Deferred: viewDidMoveToWindow can land inside a SwiftUI update
            // pass, and publishing from within one is not allowed. One frame at
            // the previous state is invisible.
            Task { @MainActor [weak self] in
                self?.refreshOcclusion()
            }
        }

        private func refreshOcclusion() {
            guard let window else {
                visibility.isOccluded = false
                return
            }
            let occluded = !window.occlusionState.contains(.visible)
            if visibility.isOccluded != occluded {
                visibility.isOccluded = occluded
            }
        }
    }
}
#endif

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
