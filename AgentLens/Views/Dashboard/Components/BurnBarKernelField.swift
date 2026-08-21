import AppKit
import Metal
import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - The usage field, as SwiftUI content
//
// `KernelBackdropView` renders the same idea today as a WebGL2 bundle inside a
// `WKWebView`. This is the same field written as a `[[stitchable]]` fill shader
// (`Theme/Material/BurnBarKernel.metal`), which changes what *kind of object* the
// backdrop is. A `WKWebView` is a sealed rectangle in the compositor: it cannot be
// rasterised by `drawingGroup`, refracted by `layerEffect`, captured by
// `ImageRenderer`, or sampled by macOS 26 `glassEffect`. So every glass plate in the
// app currently floats above a field it cannot see. A `Rectangle().fill(shader)` is
// ordinary content, and all four of those become possible — plus a WebContent process
// and a ~255 KB JS bundle stop shipping.
//
// This is deliberately ADDITIVE. `KernelBackdropView` is untouched; wiring the swap is
// a separate change, and the only thing it needs is a `SwarmColorDriver` — the exact
// value `SwarmWallpaperColorDriverBuilder.driver(...)` already builds for the ember
// swarm.
//
// The split in this file is the same one `BurnBarGlassMaterial.swift` keeps: every
// number the GPU sees is produced by a pure, `Sendable`, view-free value type
// (`BurnBarKernelMath` → `BurnBarKernelUniforms`), so the mapping from *usage* to
// *appearance* is pinned by tests without mounting a window. The view is then a thin
// shell that owns a clock, an occlusion probe and three accessibility switches.

// MARK: - Uniforms

/// One provider ribbon of the field.
struct BurnBarKernelBand: Equatable, Sendable {
    /// Brand colour, already tinted toward warning red by the driver's quota pressure.
    let color: RGBA
    /// Fraction of the field this ribbon occupies, 0…1. Shares sum to 1.
    let share: Double
}

/// Everything *usage* tells the shader, in one value.
///
/// The only other things the GPU is handed are the clock's three phases and the page
/// colour — so if a number in the field means something about the fleet, it is in
/// here, and "what is the field saying?" is answerable from one struct and one test
/// file rather than by reading Metal.
struct BurnBarKernelUniforms: Equatable, Sendable {
    /// Exactly `BurnBarKernelMath.bandCount` ribbons, widest first.
    let bands: [BurnBarKernelBand]
    /// 0…1 burn rate. Drives filament amplitude and how much of the field survives
    /// the mix down onto the page.
    let energy: Double
    /// 0…1 churn, derived from share-weighted quota pressure. Drives domain-warp
    /// amplitude and the pulse.
    let turbulence: Double
    /// 0…1 structural amplitude. Reduce Transparency drives this down.
    let detail: Double

    /// Cumulative upper edges of the ribbons, which is what the shader indexes with.
    var edges: [Double] { BurnBarKernelMath.edges(for: bands) }
}

// MARK: - The mapping from usage to appearance

/// Pure math. No SwiftUI, no AppKit, no clock.
enum BurnBarKernelMath {

    /// How many ribbons the field carries.
    ///
    /// Four, and the fourth is a collapsed tail. Twelve providers would be twelve
    /// invisible slivers — that is noise, not information. Three legible bands plus
    /// "everyone else" is the most a backdrop can say at a glance.
    static let bandCount = 4

    /// Orbit periods, in seconds, for the three drift layers.
    ///
    /// Mutually incommensurate so the field's visible repeat is many hours out, and
    /// each one is consumed as a 0…2π phase so `Float` precision never degrades no
    /// matter how long the app has been open. See "eternal drift" in the shader.
    static let driftPeriod: TimeInterval = 191
    static let swirlPeriod: TimeInterval = 47
    static let pulsePeriod: TimeInterval = 9

    // MARK: Time

    /// Wraps absolute time into a 0…2π phase.
    ///
    /// The whole reason the shader orbits instead of translating. A `Float` carries 24
    /// mantissa bits, so a linearly growing time is quantised to ~16 ms after a day of
    /// uptime and ~125 ms after a week — visible stutter in an app that lives in the
    /// menu bar for weeks. A wrapped phase is always < 2π, so its `Float` precision is
    /// ~4e-7 radians forever.
    static func phase(at time: TimeInterval, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        let wrapped = time.truncatingRemainder(dividingBy: period)
        let positive = wrapped < 0 ? wrapped + period : wrapped
        return positive / period * 2 * .pi
    }

    /// The three drift phases at an instant.
    static func phases(at time: TimeInterval) -> SIMD3<Double> {
        SIMD3(
            phase(at: time, period: driftPeriod),
            phase(at: time, period: swirlPeriod),
            phase(at: time, period: pulsePeriod)
        )
    }

    // MARK: Uniforms

    static func uniforms(
        for driver: SwarmColorDriver,
        reduceTransparency: Bool = false
    ) -> BurnBarKernelUniforms {
        BurnBarKernelUniforms(
            bands: bands(for: driver),
            energy: energy(for: driver),
            turbulence: turbulence(pressure: pressure(for: driver), mode: driver.mode),
            detail: detail(reduceTransparency: reduceTransparency)
        )
    }

    // MARK: Colour

    /// The provider ribbons, widest first, shares summing to 1.
    static func bands(for driver: SwarmColorDriver) -> [BurnBarKernelBand] {
        let weights = driver.providers.map { max(0, $0.weight) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return idleBands }

        // Renormalise before asking the driver for colours. `resolveColor(for:)` walks
        // the raw cumulative weights and clamps its input to just under 1, so a driver
        // whose weights sum to more than 1 (nothing forbids it — `ProviderWeight`
        // clamps each weight, not the total) would answer with the *first* provider
        // for every band. Handing it a normalised copy makes the midpoint lookup
        // exact, and keeps the quota-pressure tint in the one place that owns it
        // instead of re-deriving it here.
        let normalized = SwarmColorDriver(
            mode: driver.mode,
            providers: zip(driver.providers, weights).map { entry, weight in
                SwarmColorDriver.ProviderWeight(
                    provider: entry.provider,
                    weight: weight / total,
                    quotaPressure: entry.quotaPressure
                )
            },
            totalBurnRateUSD: driver.totalBurnRateUSD
        )

        var resolved: [BurnBarKernelBand] = []
        var accumulated = 0.0
        for weight in weights {
            let share = weight / total
            // Sample each provider at the midpoint of its own slice, which is the one
            // point guaranteed to be inside it however the shares fall.
            let midpoint = accumulated + share / 2
            accumulated += share
            guard share > 0, let color = normalized.resolveColor(for: midpoint) else { continue }
            resolved.append(BurnBarKernelBand(color: color, share: share))
        }

        guard !resolved.isEmpty else { return idleBands }
        return padded(collapsingTail(of: resolved))
    }

    /// The resting palette: BurnBar's own ember in three tones.
    ///
    /// Nothing has been spent, so no provider has earned a ribbon and the field shows
    /// the house colour. Derived from the provider table (`.openBurnBar` *is* the
    /// brand ember) rather than a second hardcoded hex, so a brand change moves the
    /// field with it.
    static var idleBands: [BurnBarKernelBand] {
        let base = DesignSystemColors.providerRGBA(for: .openBurnBar)
        let tones = [base.darkened(by: 0.34), base, base.lightened(by: 0.26)]
        let share = 1.0 / Double(tones.count)
        return padded(tones.map { BurnBarKernelBand(color: $0, share: share) })
    }

    /// Cumulative upper edges. The last is forced to exactly 1 so the final ribbon
    /// always reaches the far side of the field however the shares rounded.
    static func edges(for bands: [BurnBarKernelBand]) -> [Double] {
        guard !bands.isEmpty else { return [] }
        var running = 0.0
        var result: [Double] = []
        result.reserveCapacity(bands.count)
        for band in bands {
            running = min(1, running + max(0, band.share))
            result.append(running)
        }
        result[result.count - 1] = 1
        return result
    }

    // MARK: Intensity

    /// 0…1 burn rate.
    ///
    /// Remaps `SwarmColorDriver.intensityMultiplier` (0.6 at $0/day → 1.0 at $5+/day)
    /// rather than inventing a second curve, so the field and the ember swarm agree
    /// about what "busy" means.
    static func energy(for driver: SwarmColorDriver) -> Double {
        let burn = ((driver.intensityMultiplier - 0.6) / 0.4).clamped(to: 0...1)
        switch driver.mode {
        case .active:
            // Something is running right now, so the field is alive even at $0 spend —
            // subscription agents cost nothing per token and must still read as busy.
            return (0.25 + 0.75 * burn).clamped(to: 0...1)
        case .idle:
            // Idle is a portrait of the day's footprint, not live activity. The same
            // burn rate reads about half as present.
            return (0.55 * burn).clamped(to: 0...1)
        }
    }

    /// 0…1 share-weighted quota pressure. A provider you barely use being exhausted
    /// should not set the mood of the whole window.
    static func pressure(for driver: SwarmColorDriver) -> Double {
        let total = driver.providers.reduce(0) { $0 + max(0, $1.weight) }
        guard total > 0 else { return 0 }
        let weighted = driver.providers.reduce(0.0) { $0 + max(0, $1.weight) * $1.quotaPressure }
        return (weighted / total).clamped(to: 0...1)
    }

    /// 0…1 churn.
    ///
    /// Idle air is nearly still and running work stirs it, but exhaustion reaches
    /// maximum turbulence in *either* mode: a quota you have burned through still
    /// blocks you at 3am with nothing running, and the field should say so.
    static func turbulence(pressure: Double, mode: SwarmColorDriver.Mode) -> Double {
        let restingChurn = mode == .active ? 0.22 : 0.08
        let clamped = pressure.clamped(to: 0...1)
        return (restingChurn + (1 - restingChurn) * clamped).clamped(to: 0...1)
    }

    /// 0…1 structural amplitude.
    ///
    /// Reduce Transparency is not Reduce Motion: the ask is to stop layering
    /// translucent texture under content, not to stop moving. Collapsing `detail`
    /// leaves an opaque, near-flat substrate that still carries the same provider
    /// colours in the same order, which is the accessible version of the same
    /// information rather than its removal.
    static func detail(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 0.15 : 1
    }

    // MARK: Private

    /// Collapse everything past the third provider into a single share-weighted band.
    private static func collapsingTail(of bands: [BurnBarKernelBand]) -> [BurnBarKernelBand] {
        guard bands.count > bandCount else { return bands }
        let head = Array(bands.prefix(bandCount - 1))
        let tail = Array(bands.suffix(from: bandCount - 1))
        let tailShare = tail.reduce(0) { $0 + $1.share }
        guard tailShare > 0, let first = tail.first else { return head }

        // Running weighted mean, so the tail's colour is where its spend actually is.
        var blended = first.color
        var covered = first.share
        for band in tail.dropFirst() {
            covered += band.share
            blended = blended.mix(with: band.color, amount: covered > 0 ? band.share / covered : 0)
        }
        return head + [BurnBarKernelBand(color: blended, share: tailShare)]
    }

    /// Pad to `bandCount` with zero-share ribbons carrying the *last* band's colour.
    ///
    /// A zero-width ribbon must cross-fade to itself. Pad with anything else and the
    /// shader's chained `mix` flashes a colour no provider owns through the seam.
    private static func padded(_ bands: [BurnBarKernelBand]) -> [BurnBarKernelBand] {
        guard let last = bands.last else { return [] }
        guard bands.count < bandCount else { return Array(bands.prefix(bandCount)) }
        return bands + Array(
            repeating: BurnBarKernelBand(color: last.color, share: 0),
            count: bandCount - bands.count
        )
    }
}

// MARK: - The view

/// BurnBar's living field, drawn by Metal as ordinary SwiftUI content.
///
/// Cost: O(pixels) on the GPU (36 lattice hashes per pixel, constant regardless of
/// provider count), and O(1) on the CPU — about thirty floats per frame, no display
/// list, no allocation, nothing to invalidate.
struct BurnBarKernelField: View {
    /// Live usage. The same value the ember swarm consumes, built by
    /// `SwarmWallpaperColorDriverBuilder.driver(...)`.
    var driver: SwarmColorDriver
    /// Hold the field still for reasons window state cannot see — a dashboard behind
    /// a sheet, a tab that is not front. Occlusion is handled internally.
    var isRunning = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var window = BurnBarKernelWindowState.unknown

    /// The pose the field holds when motion is off.
    ///
    /// Reference-date zero puts every phase at exactly 0, so a frozen field is the
    /// *authored* resting pose rather than whichever frame the clock happened to stop
    /// on — the same contract `PlasmaClock.still` keeps for the plasma surfaces.
    private static let restingDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Resolved once. `MaterialTier` makes the same check for the glass lens: a
    /// headless VM with no Metal device must still draw something.
    private static let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil

    /// Reduce Motion freezes the field — it does not stop drawing it. A paused
    /// `TimelineView` still renders; it just stops asking for new frames.
    private var isAnimating: Bool { isRunning && window.isVisible && !reduceMotion }

    /// The frame budget, from the policy the WebGL field already runs to.
    ///
    /// Not a constant 30: `KernelBackdropFramePolicy` presents cinematically against
    /// the display's own refresh, because 30 on a 144 Hz panel lands on an uneven
    /// cadence and strobes. Reusing the policy — rather than picking a number — is
    /// also what keeps the eventual swap from changing the app's power profile.
    private var frameRate: Double {
        KernelBackdropFramePolicy.maxFrameRate(
            isPerformanceGateLaunch: OpenBurnBarRuntime.isPerformanceGateLaunch,
            refreshHz: window.refreshHz
        )
    }

    var body: some View {
        let uniforms = BurnBarKernelMath.uniforms(
            for: driver,
            reduceTransparency: reduceTransparency
        )

        Group {
            if Self.hasMetalDevice {
                // This is atmospheric weather, not a game loop: uncapped frames on a
                // 5K window burn a render core for motion nobody can see.
                TimelineView(.animation(minimumInterval: 1 / frameRate, paused: !isAnimating)) { context in
                    Rectangle()
                        .fill(shader(uniforms, at: isAnimating ? context.date : Self.restingDate))
                }
            } else {
                Rectangle().fill(
                    LinearGradient(
                        stops: Self.gradientStops(uniforms),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .background(
            BurnBarKernelVisibilityProbe { window = $0 }
                .frame(width: 0, height: 0)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shader(_ uniforms: BurnBarKernelUniforms, at date: Date) -> Shader {
        let phase = BurnBarKernelMath.phases(at: date.timeIntervalSinceReferenceDate)
        var arguments: [Shader.Argument] = [
            // `.boundingRect` hands the shader the filled shape's rect, so the field
            // needs no `GeometryReader` and costs no layout pass to know its size.
            .boundingRect,
            .float3(phase.x, phase.y, phase.z),
            .float(uniforms.energy),
            .float(uniforms.turbulence),
            .float(uniforms.detail),
            // The page the field settles onto. The adaptive token already resolves
            // light / dark / editorial, and the shader re-derives "is this paper?"
            // from the colour's own luma rather than a flag, so it stays correct for
            // any surface this is ever hosted on.
            .color(DesignSystem.Colors.background)
        ]
        arguments.append(contentsOf: Self.bandArguments(uniforms))

        return Shader(function: ShaderLibrary.default.burnBarUsageField, arguments: arguments)
    }

    /// Packs each ribbon as rgb + its cumulative upper edge.
    ///
    /// Built as an array (rather than spelled out at the call site) so the shader's
    /// fixed arity is satisfied by construction even if `bands` were ever short — a
    /// malformed driver should dim the field, not trap.
    static func bandArguments(_ uniforms: BurnBarKernelUniforms) -> [Shader.Argument] {
        let edges = uniforms.edges
        return (0..<BurnBarKernelMath.bandCount).map { index -> Shader.Argument in
            let candidate = index < uniforms.bands.count ? uniforms.bands[index] : uniforms.bands.last
            guard let band = candidate else { return .float4(0.0, 0.0, 0.0, 1.0) }
            let edge = index < edges.count ? edges[index] : 1
            return .float4(band.color.r, band.color.g, band.color.b, edge)
        }
    }

    /// The no-Metal substrate: the same ribbons, same order, no optics.
    static func gradientStops(_ uniforms: BurnBarKernelUniforms) -> [Gradient.Stop] {
        let edges = uniforms.edges
        var stops: [Gradient.Stop] = []
        var start = 0.0
        for (index, band) in uniforms.bands.enumerated() {
            let edge = index < edges.count ? edges[index] : 1
            // Place each ribbon at the centre of its own share so the gradient reads
            // as the same weighting the shader draws.
            stops.append(Gradient.Stop(color: band.color.color, location: CGFloat((start + edge) / 2)))
            start = edge
        }
        return stops
    }
}

// MARK: - Occlusion

/// What the field needs to know about the window it is living in.
struct BurnBarKernelWindowState: Equatable, Sendable {
    /// Whether anything the field draws can actually be seen.
    var isVisible: Bool
    /// The refresh rate of the display the window is on, in Hz.
    var refreshHz: Double

    /// Before the probe has a window: assume visible, assume 60 Hz. Assuming hidden
    /// would leave previews and detached hosts drawing a permanently frozen field.
    static let unknown = BurnBarKernelWindowState(isVisible: true, refreshHz: 60)
}

/// Reports whether the hosting window can actually be seen, and how fast its display
/// refreshes.
///
/// A backdrop behind a fully covered or minimised window is pure waste, and
/// `NSWindow.occlusionState` is the only signal that catches "another app's window is
/// on top of us" — `scenePhase` and `isVisible` both stay happy through it. The policy
/// itself is `OcclusionVisibilityPolicy`, shared verbatim with the WebGL backdrop so
/// the swap cannot change when the field sleeps.
private struct BurnBarKernelVisibilityProbe: NSViewRepresentable {
    let onChange: (BurnBarKernelWindowState) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.detach()
    }

    /// A zero-size, hit-test-transparent probe. It exists only to have a `window`.
    final class ProbeView: NSView {
        var onChange: ((BurnBarKernelWindowState) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastPublished: BurnBarKernelWindowState?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            // Detached from any window there is nothing to observe, and the policy
            // already answers `false` for a nil window — no second code path needed.
            guard let window else {
                publishCurrentState()
                return
            }
            let names: [NSNotification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
                // Dragging to a second display changes the frame budget, not just the
                // geometry — a 60 Hz cadence on a 120 Hz panel is a different loop.
                NSWindow.didChangeScreenNotification
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.publishCurrentState() }
                }
            }
            publishCurrentState()
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        private func publishCurrentState() {
            let refresh = window?.screen?.maximumFramesPerSecond ?? 0
            publish(
                BurnBarKernelWindowState(
                    isVisible: OcclusionVisibilityPolicy.shouldBackdropBeActive(window: window),
                    // A detached or off-screen window reports 0; 60 is the safe floor.
                    refreshHz: refresh > 0 ? Double(refresh) : 60
                )
            )
        }

        private func publish(_ state: BurnBarKernelWindowState) {
            guard lastPublished != state else { return }
            lastPublished = state
            // Deferred one turn: `viewDidMoveToWindow` runs inside SwiftUI's own
            // update pass, and writing `@State` from there is the "Modifying state
            // during view update" warning.
            Task { @MainActor [weak self] in
                self?.onChange?(state)
            }
        }
    }
}
