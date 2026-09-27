import Foundation
import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// The pure, view-free half of `BurnBarKernelField` (Views/Dashboard/Components).
// It lives in Theme because `BurnBarFieldContext` feeds the same uniforms to the
// glass material: keeping it under Views made Theme depend on Views, which put
// Theme on the app-wide dependency cycle (docs/SERVICES_DECOMPOSITION_PROGRAM.md).

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

// MARK: - Occlusion

/// What the field needs to know about the window it is living in.
struct BurnBarKernelWindowState: Equatable, Sendable {
    /// Whether anything the field draws can actually be seen.
    var isVisible: Bool
    /// The refresh rate of the display the window is on, in Hz.
    var refreshHz: Double
    var isScrolling = false

    /// Before the probe has a window: assume visible, assume 60 Hz. Assuming hidden
    /// would leave previews and detached hosts drawing a permanently frozen field.
    static let unknown = BurnBarKernelWindowState(isVisible: true, refreshHz: 60)
}

extension BurnBarKernelMath {
    /// The `bandCount` ribbon arguments the shader reads: RGB plus the ribbon's
    /// cumulative upper edge. Missing ribbons repeat the last one.
    static func bandArguments(_ uniforms: BurnBarKernelUniforms) -> [Shader.Argument] {
        let edges = uniforms.edges
        return (0..<BurnBarKernelMath.bandCount).map { index -> Shader.Argument in
            let candidate = index < uniforms.bands.count ? uniforms.bands[index] : uniforms.bands.last
            guard let band = candidate else { return .float4(0.0, 0.0, 0.0, 1.0) }
            let edge = index < edges.count ? edges[index] : 1
            return .float4(band.color.r, band.color.g, band.color.b, edge)
        }
    }
}
