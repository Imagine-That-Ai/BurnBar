import OpenBurnBarCore
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// What the usage field is allowed to say.
///
/// `BurnBarKernelMath` is a pure value function precisely so the mapping from *usage*
/// to *appearance* can be pinned without a window, a GPU, or a frame — the same
/// contract `BurnBarMaterialTests` keeps for the glass material. If the field ever
/// stops being a truthful picture of spend, it fails here rather than in someone's
/// peripheral vision.
final class BurnBarKernelFieldTests: XCTestCase {

    // MARK: - Helpers

    private func driver(
        _ pairs: [(AgentProvider, Double)],
        mode: SwarmColorDriver.Mode = .active,
        pressure: Double = 0,
        burn: Double = 0
    ) -> SwarmColorDriver {
        SwarmColorDriver(
            mode: mode,
            providers: pairs.map {
                SwarmColorDriver.ProviderWeight(provider: $0.0, weight: $0.1, quotaPressure: pressure)
            },
            totalBurnRateUSD: burn
        )
    }

    // MARK: - The ribbons are the spend

    /// The field's whole claim is that ribbon width *is* share of spend. If that
    /// stops being literally true the backdrop becomes decoration.
    func test_ribbonWidthIsShareOfSpend() {
        let bands = BurnBarKernelMath.bands(
            for: driver([(.claudeCode, 0.7), (.codex, 0.3)])
        )
        XCTAssertEqual(bands[0].share, 0.7, accuracy: 1e-12)
        XCTAssertEqual(bands[1].share, 0.3, accuracy: 1e-12)
        XCTAssertEqual(bands[0].color, DesignSystemColors.providerRGBA(for: .claudeCode))
        XCTAssertEqual(bands[1].color, DesignSystemColors.providerRGBA(for: .codex))
    }

    /// Shares are a distribution: non-negative and summing to one, whatever went in.
    func test_sharesAlwaysFormADistribution() {
        let cases: [[(AgentProvider, Double)]] = [
            [],
            [(.claudeCode, 1)],
            [(.claudeCode, 0.5), (.codex, 0.5)],
            [(.claudeCode, 0.2), (.codex, 0.2), (.factory, 0.2), (.cursor, 0.2), (.openAI, 0.2)],
            [(.claudeCode, 0.01), (.codex, 0.99)],
            [(.claudeCode, 0), (.codex, 0)]
        ]
        for pairs in cases {
            let bands = BurnBarKernelMath.bands(for: driver(pairs))
            XCTAssertEqual(bands.count, BurnBarKernelMath.bandCount, "\(pairs.count) providers")
            XCTAssertEqual(bands.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-12)
            for band in bands {
                XCTAssertGreaterThanOrEqual(band.share, 0)
            }
        }
    }

    /// `SwarmColorDriver.ProviderWeight` clamps each weight to 0…1 but nothing clamps
    /// the *total*, and `resolveColor(for:)` clamps its lookup index to just under 1.
    /// So a driver whose weights sum above one answers with the first provider for
    /// every band unless the shares are renormalised first — the field would show one
    /// colour while the fleet burned two. This is that bug, pinned.
    func test_weightsSummingAboveOneStillResolveDistinctProviders() {
        let bands = BurnBarKernelMath.bands(
            for: driver([(.claudeCode, 1.0), (.codex, 1.0)])
        )
        XCTAssertEqual(bands[0].share, 0.5, accuracy: 1e-12)
        XCTAssertEqual(bands[1].share, 0.5, accuracy: 1e-12)
        XCTAssertEqual(bands[0].color, DesignSystemColors.providerRGBA(for: .claudeCode))
        XCTAssertEqual(bands[1].color, DesignSystemColors.providerRGBA(for: .codex))
        XCTAssertNotEqual(bands[0].color, bands[1].color)
    }

    /// Twelve providers would be twelve invisible slivers. Three legible ribbons plus
    /// a collapsed tail is the most a backdrop can say — and the tail must still carry
    /// the whole of its spend.
    func test_longTailCollapsesIntoOneRibbonCarryingItsWholeShare() {
        let pairs: [(AgentProvider, Double)] = [
            (.claudeCode, 0.30), (.codex, 0.25), (.factory, 0.20),
            (.cursor, 0.10), (.openAI, 0.08), (.geminiCLI, 0.07)
        ]
        let bands = BurnBarKernelMath.bands(for: driver(pairs))

        XCTAssertEqual(bands.count, BurnBarKernelMath.bandCount)
        XCTAssertEqual(bands[0].share, 0.30, accuracy: 1e-12)
        XCTAssertEqual(bands[1].share, 0.25, accuracy: 1e-12)
        XCTAssertEqual(bands[2].share, 0.20, accuracy: 1e-12)
        XCTAssertEqual(bands[3].share, 0.25, accuracy: 1e-12, "tail keeps 0.10 + 0.08 + 0.07")

        // The collapsed colour is a weighted blend, so it must lie strictly between
        // the tail members rather than snapping to whichever happened to be first.
        let cursor = DesignSystemColors.providerRGBA(for: .cursor)
        let gemini = DesignSystemColors.providerRGBA(for: .geminiCLI)
        XCTAssertNotEqual(bands[3].color, cursor)
        XCTAssertNotEqual(bands[3].color, gemini)
    }

    /// A zero-width ribbon has to cross-fade to *itself*. Padding with anything else
    /// makes the shader's chained `mix` flash a colour no provider owns.
    func test_unusedRibbonsInheritTheLastRealColour() {
        let bands = BurnBarKernelMath.bands(for: driver([(.claudeCode, 1)]))
        XCTAssertEqual(bands[0].share, 1, accuracy: 1e-12)
        for band in bands.dropFirst() {
            XCTAssertEqual(band.share, 0)
            XCTAssertEqual(band.color, bands[0].color, "padding must not introduce a new hue")
        }
    }

    /// Quota pressure reaches the field as colour, not as a legend. The driver owns
    /// that tint; the field must not lose it on the way to the GPU.
    func test_quotaPressureTintsTheRibbonTowardWarning() {
        let healthy = BurnBarKernelMath.bands(for: driver([(.claudeCode, 1)], pressure: 0))[0].color
        let exhausted = BurnBarKernelMath.bands(for: driver([(.claudeCode, 1)], pressure: 1))[0].color

        XCTAssertNotEqual(healthy, exhausted)
        XCTAssertGreaterThan(exhausted.r, healthy.r, "warning red is redder")
        XCTAssertLessThan(exhausted.g, healthy.g, "and less green")
    }

    /// Nothing spent means no provider has earned a ribbon, so the field wears the
    /// house colour rather than an arbitrary vendor's.
    func test_idleFieldWearsTheHouseEmber() {
        let bands = BurnBarKernelMath.bands(for: driver([]))
        XCTAssertEqual(bands.count, BurnBarKernelMath.bandCount)
        XCTAssertEqual(bands[1].color, DesignSystemColors.providerRGBA(for: .openBurnBar))
        for band in bands {
            XCTAssertGreaterThan(band.color.r, band.color.b, "ember is warm")
        }
    }

    // MARK: - Edges

    /// The shader indexes ribbons by cumulative upper edge, chained through three
    /// `mix`es. That is only correct if the edges are non-decreasing and the last one
    /// reaches exactly 1 — otherwise the final ribbon stops short of the far side.
    func test_edgesAreMonotonicAndReachOne() {
        let bands = BurnBarKernelMath.bands(
            for: driver([(.claudeCode, 0.4), (.codex, 0.35), (.factory, 0.25)])
        )
        let edges = BurnBarKernelMath.edges(for: bands)

        XCTAssertEqual(edges.count, bands.count)
        XCTAssertEqual(edges.last, 1)
        for (previous, next) in zip(edges, edges.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }
        XCTAssertEqual(edges[0], 0.4, accuracy: 1e-12)
        XCTAssertEqual(edges[1], 0.75, accuracy: 1e-12)
    }

    func test_edgesOfNothingAreNothing() {
        XCTAssertTrue(BurnBarKernelMath.edges(for: []).isEmpty)
    }

    // MARK: - Intensity

    /// Energy rides the driver's existing burn-rate curve rather than a second one, so
    /// the field and the ember swarm cannot disagree about what "busy" means.
    func test_energyRisesWithBurnRateAndStaysNormalised() {
        let quiet = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], burn: 0))
        let busy = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], burn: 2.5))
        let saturated = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], burn: 500))

        XCTAssertLessThan(quiet, busy)
        XCTAssertLessThan(busy, saturated)
        for value in [quiet, busy, saturated] {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
        XCTAssertEqual(saturated, 1, accuracy: 1e-12, "the curve saturates rather than clipping late")
    }

    /// Subscription agents cost nothing per token. A running fleet at $0/day must
    /// still read as running, or the field lies to exactly the users who pay flat.
    func test_activeAtZeroSpendStillReadsAsAlive() {
        let active = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], mode: .active, burn: 0))
        let idle = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], mode: .idle, burn: 0))

        XCTAssertGreaterThanOrEqual(active, 0.25)
        XCTAssertEqual(idle, 0, accuracy: 1e-12)
    }

    /// Idle is a portrait of the day's footprint, not live activity, and must read
    /// quieter at the identical burn rate.
    func test_idleReadsQuieterThanActiveAtTheSameBurnRate() {
        let active = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], mode: .active, burn: 5))
        let idle = BurnBarKernelMath.energy(for: driver([(.claudeCode, 1)], mode: .idle, burn: 5))
        XCTAssertGreaterThan(active, idle)
    }

    // MARK: - Pressure and turbulence

    /// A provider you barely use being exhausted must not set the mood of the whole
    /// window. Pressure is weighted by spend for the same reason the colours are.
    func test_pressureIsWeightedByShare() {
        let lopsided = SwarmColorDriver(
            mode: .active,
            providers: [
                SwarmColorDriver.ProviderWeight(provider: .claudeCode, weight: 0.9, quotaPressure: 0),
                SwarmColorDriver.ProviderWeight(provider: .codex, weight: 0.1, quotaPressure: 1)
            ],
            totalBurnRateUSD: 1
        )
        XCTAssertEqual(BurnBarKernelMath.pressure(for: lopsided), 0.1, accuracy: 1e-12)
        XCTAssertEqual(BurnBarKernelMath.pressure(for: driver([])), 0)
    }

    /// Churn tracks pressure monotonically, and exhaustion reaches maximum turbulence
    /// in *either* mode: a quota you have burned through still blocks you at 3am with
    /// nothing running.
    func test_turbulenceTracksPressureAndPeaksInBothModes() {
        for mode in [SwarmColorDriver.Mode.active, .idle] {
            let calm = BurnBarKernelMath.turbulence(pressure: 0, mode: mode)
            let half = BurnBarKernelMath.turbulence(pressure: 0.5, mode: mode)
            let spent = BurnBarKernelMath.turbulence(pressure: 1, mode: mode)

            XCTAssertLessThan(calm, half)
            XCTAssertLessThan(half, spent)
            XCTAssertEqual(spent, 1, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(calm, 0)
        }
        XCTAssertGreaterThan(
            BurnBarKernelMath.turbulence(pressure: 0, mode: .active),
            BurnBarKernelMath.turbulence(pressure: 0, mode: .idle),
            "idle air is nearly still"
        )
    }

    /// Out-of-range input must not drive the shader into undefined territory.
    func test_turbulenceClampsWildPressure() {
        XCTAssertEqual(BurnBarKernelMath.turbulence(pressure: 9, mode: .active), 1, accuracy: 1e-12)
        XCTAssertEqual(
            BurnBarKernelMath.turbulence(pressure: -4, mode: .idle),
            BurnBarKernelMath.turbulence(pressure: 0, mode: .idle),
            accuracy: 1e-12
        )
    }

    // MARK: - Accessibility

    /// Reduce Transparency is not Reduce Motion: it asks for less translucent texture
    /// under content, not for the information to disappear. The colours survive; the
    /// structure collapses.
    func test_reduceTransparencyCollapsesStructureNotColour() {
        let normal = BurnBarKernelMath.uniforms(for: driver([(.claudeCode, 0.6), (.codex, 0.4)]))
        let reduced = BurnBarKernelMath.uniforms(
            for: driver([(.claudeCode, 0.6), (.codex, 0.4)]),
            reduceTransparency: true
        )

        XCTAssertLessThan(reduced.detail, normal.detail)
        XCTAssertGreaterThan(reduced.detail, 0, "the field still draws")
        XCTAssertEqual(reduced.bands, normal.bands, "same providers, same widths, same order")
        XCTAssertEqual(reduced.energy, normal.energy)
    }

    // MARK: - Time

    /// The reason the shader orbits instead of translating. A `Float` has 24 mantissa
    /// bits, so a linearly growing time is quantised to ~16 ms after a day of uptime
    /// and ~125 ms after a week — visible stutter in an app that lives in the menu bar
    /// for weeks. A wrapped phase is always below 2π, so it never degrades.
    func test_phaseStaysBoundedForAbsurdUptime() {
        for period in [BurnBarKernelMath.driftPeriod, BurnBarKernelMath.swirlPeriod, BurnBarKernelMath.pulsePeriod] {
            for time in [0.0, 1, 3_600, 86_400, 604_800, 1_000_000_000] {
                let phase = BurnBarKernelMath.phase(at: time, period: period)
                XCTAssertGreaterThanOrEqual(phase, 0)
                XCTAssertLessThan(phase, 2 * .pi)
                // The value the GPU actually receives must still resolve the phase to
                // far better than a frame.
                XCTAssertEqual(Double(Float(phase)), phase, accuracy: 1e-6)
            }
        }
    }

    /// Wrapping must be seamless: `cos`/`sin` of a phase that returns to 0 is exactly
    /// where it started, which is what makes the motion eternal rather than glitching
    /// once per period.
    func test_phaseWrapsCleanlyAndRunsForward() {
        let period = BurnBarKernelMath.pulsePeriod
        XCTAssertEqual(BurnBarKernelMath.phase(at: 0, period: period), 0)
        XCTAssertEqual(BurnBarKernelMath.phase(at: period, period: period), 0, accuracy: 1e-12)
        XCTAssertEqual(BurnBarKernelMath.phase(at: period / 2, period: period), .pi, accuracy: 1e-12)
        XCTAssertEqual(
            BurnBarKernelMath.phase(at: 5 * period + 3, period: period),
            BurnBarKernelMath.phase(at: 3, period: period),
            accuracy: 1e-9
        )
        // Dates before the reference epoch are ordinary input, not an error.
        XCTAssertEqual(
            BurnBarKernelMath.phase(at: -period / 4, period: period),
            1.5 * .pi,
            accuracy: 1e-12
        )
        XCTAssertEqual(BurnBarKernelMath.phase(at: 12, period: 0), 0, "a zero period cannot divide")
    }

    /// The frozen pose has to be the *authored* one, not whichever frame the clock
    /// stopped on — Reduce Motion should look designed, not paused.
    func test_restingPoseIsPhaseZeroOnEveryLayer() {
        let resting = Date(timeIntervalSinceReferenceDate: 0)
        let phases = BurnBarKernelMath.phases(at: resting.timeIntervalSinceReferenceDate)
        XCTAssertEqual(phases, SIMD3<Double>(0, 0, 0))
    }

    /// The three layers must not share a period, or they lock into one visible pulse.
    func test_driftPeriodsAreDistinct() {
        let periods = [
            BurnBarKernelMath.driftPeriod,
            BurnBarKernelMath.swirlPeriod,
            BurnBarKernelMath.pulsePeriod
        ]
        XCTAssertEqual(Set(periods).count, periods.count)
        for period in periods {
            XCTAssertGreaterThan(period, 0)
        }
    }

    // MARK: - What reaches the GPU

    /// The shader's arity is fixed. Packing must satisfy it by construction, so a
    /// malformed driver dims the field instead of trapping.
    func test_shaderAlwaysReceivesAFullSetOfRibbons() {
        let cases: [[(AgentProvider, Double)]] = [
            [],
            [(.claudeCode, 1)],
            [(.claudeCode, 0.5), (.codex, 0.5)]
        ]
        for pairs in cases {
            let uniforms = BurnBarKernelMath.uniforms(for: driver(pairs))
            XCTAssertEqual(
                BurnBarKernelField.bandArguments(uniforms).count,
                BurnBarKernelMath.bandCount
            )
        }
    }

    /// The no-Metal substrate draws the same ribbons in the same order.
    func test_gradientFallbackKeepsRibbonOrder() {
        let uniforms = BurnBarKernelMath.uniforms(
            for: driver([(.claudeCode, 0.6), (.codex, 0.4)])
        )
        let stops = BurnBarKernelField.gradientStops(uniforms)

        XCTAssertEqual(stops.count, BurnBarKernelMath.bandCount)
        for (previous, next) in zip(stops, stops.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.location, next.location)
        }
        XCTAssertLessThanOrEqual(stops.last?.location ?? 0, 1)
    }

    /// A host with no window yet — SwiftUI previews, a probe that has not mounted —
    /// must still draw a *moving* field. Defaulting to hidden would freeze every
    /// preview and read as a bug rather than as power saving.
    func test_unknownWindowStateStillDraws() {
        XCTAssertTrue(BurnBarKernelWindowState.unknown.isVisible)
        XCTAssertEqual(BurnBarKernelWindowState.unknown.refreshHz, 60)
    }

    /// The shader has to actually be in the binary the app ships, under the name the
    /// view asks for. `ShaderLibrary` resolves by string at render time, so a rename
    /// or a missing build-phase membership fails silently as a blank rectangle — this
    /// is the only place that can catch it before someone looks at the window.
    ///
    /// Both shaders are checked because Xcode links every `.metal` in the target into
    /// one `default.metallib`: adding a second source file must not displace the first.
    func test_usageFieldIsCompiledIntoTheDefaultMetalLibrary() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "default", withExtension: "metallib"),
            "the app bundle must ship a compiled default.metallib"
        )
        let library = try Data(contentsOf: url)
        for symbol in ["burnBarUsageField", "burnBarGlassLens"] {
            XCTAssertNotNil(
                library.range(of: Data(symbol.utf8)),
                "\(symbol) is missing from default.metallib"
            )
        }
    }
}
