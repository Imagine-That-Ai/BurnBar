import OpenBurnBarUI
import SwiftUI
import XCTest
@testable import OpenBurnBar

/// The material's rules.
///
/// `GlassSpec.resolved(for:)` and `BurnBarAmbient.from(...)` are pure value functions
/// precisely so the design system's two load-bearing invariants can be pinned without
/// mounting a window — the same contract `LivingSpaceBudgetTests` and
/// `DashboardHomeLayoutTests` keep.
final class BurnBarMaterialTests: XCTestCase {

    // MARK: - The navigation-layer rule

    /// WWDC25 s219: Liquid Glass belongs to the navigation layer, not the content
    /// layer. Wallet's cards are opaque foil; Health's rings are opaque. This is the
    /// rule made structural: a content surface cannot be glass no matter what spec its
    /// call site passes, which is what stops charts and tables turning into fog.
    /// The rule is that content must not COMPETE with the navigation layer — not that
    /// content must be flat. Zeroing every axis produced opaque cardboard, which is a
    /// different failure from the fog it replaced.
    ///
    /// What content actually guarantees: a near-opaque legibility substrate, and optics
    /// strictly quieter than the same theme's chrome. The lens is driven by the edge
    /// height field, so rim refraction costs nothing in the middle where the text is.
    func test_contentIsQuieterThanChromeAndAlwaysLegible() {
        for spec in [GlassSpec.focus, .bento, .canvas, .atlas, .ask, .cockpit, .ledger, .stream] {
            let content = spec.resolved(for: .content)

            // The legibility guarantee — the one axis content may not trade away.
            XCTAssertGreaterThanOrEqual(content.scrim, 0.82, "content must stay readable")

            // Strictly quieter than chrome on every optical axis.
            XCTAssertLessThan(content.lensing, spec.lensing + 0.0001)
            XCTAssertLessThan(content.dispersion, spec.dispersion + 0.0001)
            XCTAssertLessThan(content.specular, spec.specular)
            XCTAssertLessThan(content.thickness, spec.thickness + 0.0001)

            // …but not dead. A surface with no optics at all is cardboard.
            if spec.lensing > 0 {
                XCTAssertGreaterThan(content.lensing, 0, "content keeps rim optics")
            }
        }
    }

    /// Chrome is the one layer that keeps its optics untouched.
    func test_chromeRolePreservesTheSpec() {
        XCTAssertEqual(GlassSpec.canvas.resolved(for: .chrome), GlassSpec.canvas)
    }

    /// Instruments are a middle tier: legible enough for live readouts, still glass.
    ///
    /// Scaled, not clamped. `min(lensing, 0.22)` mapped eight of the nine specs onto the
    /// identical value, so every theme's instrument looked the same — a clamp that
    /// swallows its input is a constant wearing a formula's clothes.
    func test_instrumentRoleScalesRatherThanCollapsing() {
        let canvas = GlassSpec.canvas.resolved(for: .instrument)
        let ledger = GlassSpec.ledger.resolved(for: .instrument)

        // Still far below the chrome tier — a readout must stay legible.
        XCTAssertLessThan(canvas.lensing, GlassSpec.canvas.lensing / 2)
        XCTAssertGreaterThanOrEqual(canvas.scrim, 0.45)
        XCTAssertGreaterThan(canvas.scrim, GlassSpec.canvas.scrim,
                             "a readout needs more substrate than a dimensional object")

        // …and the themes remain telling apart, which the clamp destroyed.
        XCTAssertGreaterThan(canvas.lensing, ledger.lensing,
                             "Canvas must still read thicker than Ledger on an instrument")
        XCTAssertNotEqual(canvas.scrim, ledger.scrim)
    }

    /// The clamp bug in general form: no role may map distinct specs onto one value.
    /// This is the regression guard for "seven personalities" actually existing on the
    /// roles that ship — `.content` is what every `DashboardSection` uses.
    func test_noRoleCollapsesDistinctThemesOntoOneMaterial() {
        for role in [SurfaceRole.chrome, .content, .instrument] {
            let resolved = DashboardLayout.allCases.map { $0.glassSpec.resolved(for: role) }
            XCTAssertEqual(
                Set(resolved.map(\.specular)).count, resolved.count,
                "\(role) collapsed distinct themes onto one specular value"
            )
        }
    }

    // MARK: - Seven personalities, one system

    /// The themes must be genuinely distinct, or "seven personalities" is a claim
    /// rather than a design. Ledger is the precision pane and Canvas the dimensional
    /// object, so they should sit at opposite ends of every physical axis.
    func test_themesOccupyDistinctPhysicalRanges() {
        XCTAssertLessThan(GlassSpec.ledger.lensing, GlassSpec.canvas.lensing)
        XCTAssertLessThan(GlassSpec.ledger.thickness, GlassSpec.canvas.thickness)
        XCTAssertLessThan(GlassSpec.ledger.scatter, GlassSpec.bento.scatter)
        XCTAssertGreaterThan(GlassSpec.ledger.scrim, GlassSpec.canvas.scrim,
                             "Ledger trades spectacle for legibility; Canvas does the reverse")
        XCTAssertGreaterThan(GlassSpec.bento.dispersion, GlassSpec.focus.dispersion,
                             "Bento's tiles are jewels; Focus is calm")
        XCTAssertGreaterThan(GlassSpec.atlas.ambience, GlassSpec.ledger.ambience,
                             "Atlas floats in the lighting environment; Ledger resists it")
    }

    /// Every axis is a normalised 0…1 physical quantity. A spec outside that range
    /// would drive the shader into undefined territory.
    func test_specClampsEveryAxis() {
        let wild = GlassSpec(
            lensing: 4, thickness: -2, scrim: 9, specular: -1, ambience: 3, dispersion: -5, scatter: 7
        )
        for value in [wild.lensing, wild.thickness, wild.scrim, wild.specular, wild.ambience,
                      wild.dispersion, wild.scatter] {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - Every theme has a material, and they are all different

    /// The mapping must be total. A layout with no spec would silently fall back to
    /// `.standard` and that theme would quietly lose its personality.
    func test_everyLayoutMapsToASpec() {
        let specs = DashboardLayout.allCases.map(\.glassSpec)
        XCTAssertEqual(specs.count, DashboardLayout.allCases.count)
        XCTAssertFalse(specs.contains(.standard),
                       "no layout may fall through to the neutral default")
    }

    /// Seven themes must be seven materials. If two layouts resolved to the same spec
    /// the user could not tell them apart, which is the failure mode the whole
    /// design system exists to avoid.
    func test_everyLayoutHasADistinctMaterial() {
        var seen: [GlassSpec] = []
        for layout in DashboardLayout.allCases {
            let spec = layout.glassSpec
            XCTAssertFalse(seen.contains(spec), "\(layout) duplicates another theme's material")
            seen.append(spec)
        }
    }

    /// The mapping is the design, so it is pinned: Ledger reads numbers, Canvas holds
    /// objects in space. Swapping them would be a regression no compiler would catch.
    func test_layoutMappingMatchesEachThesis() {
        XCTAssertEqual(DashboardLayout.classic.glassSpec, .ledger)
        XCTAssertEqual(DashboardLayout.aurora.glassSpec, .focus)
        XCTAssertEqual(DashboardLayout.nebula.glassSpec, .bento)
        XCTAssertEqual(DashboardLayout.constellation.glassSpec, .ask)
        XCTAssertEqual(DashboardLayout.atelier.glassSpec, .canvas)
        XCTAssertEqual(DashboardLayout.atlas.glassSpec, GlassSpec.atlas)
        XCTAssertEqual(DashboardLayout.stream.glassSpec, GlassSpec.stream)
        XCTAssertEqual(DashboardLayout.cockpit.glassSpec, GlassSpec.cockpit)
    }

    // MARK: - Ambient light is derived, never configured

    func test_ambientTakesItsKeyLightFromTheDominantProvider() {
        let ambient = BurnBarAmbient.from(
            providerSummaries: [summary(.claudeCode, cost: 40), summary(.codex, cost: 12)],
            totalCostToday: 52
        )
        XCTAssertEqual(ambient.key, ProviderTheme.theme(for: .claudeCode).primaryColor)
        XCTAssertEqual(ambient.counter, ProviderTheme.theme(for: .codex).accentColor)
    }

    /// A single provider must not wash the room in one hue — the composition keeps a
    /// warm/cool axis so plates stay lit from two directions.
    func test_singleProviderKeepsACounterLight() {
        let ambient = BurnBarAmbient.from(
            providerSummaries: [summary(.claudeCode, cost: 40)],
            totalCostToday: 40
        )
        XCTAssertEqual(ambient.counter, DesignSystem.Colors.whimsy)
        XCTAssertNotEqual(ambient.key, ambient.counter)
    }

    /// Energy saturates rather than clipping: a 10× day must read hotter than a 2× day
    /// instead of both pinning at the same maximum.
    func test_energySaturatesWithoutClipping() {
        let quiet = BurnBarAmbient.from(providerSummaries: [summary(.claudeCode, cost: 5)], totalCostToday: 5)
        let busy = BurnBarAmbient.from(providerSummaries: [summary(.claudeCode, cost: 50)], totalCostToday: 50)
        let extreme = BurnBarAmbient.from(providerSummaries: [summary(.claudeCode, cost: 250)], totalCostToday: 250)

        XCTAssertLessThan(quiet.energy, busy.energy)
        XCTAssertLessThan(busy.energy, extreme.energy)
        XCTAssertLessThanOrEqual(extreme.energy, 1.0)
        XCTAssertGreaterThan(quiet.energy, 0)
    }

    /// No spend is a real state on a fresh install, not an error.
    func test_noSpendFallsBackToNeutralLight() {
        XCTAssertEqual(BurnBarAmbient.from(providerSummaries: [], totalCostToday: 0), .neutral)
        XCTAssertEqual(
            BurnBarAmbient.from(providerSummaries: [summary(.claudeCode, cost: 0)], totalCostToday: 0),
            .neutral,
            "a provider with no spend must not become the key light"
        )
    }

    // MARK: - Helpers

    private func summary(_ provider: AgentProvider, cost: Double) -> ProviderSummary {
        ProviderSummary(
            provider: provider,
            totalCost: cost,
            totalTokens: 0,
            totalInputTokens: 0,
            totalOutputTokens: 0,
            sessionCount: 0,
            modelBreakdown: [],
            provenanceConfidence: .unknown,
            provenanceMethod: .unknown,
            hasEstimatedContributions: false,
            cacheEfficiency: .init(inputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)
        )
    }
}
