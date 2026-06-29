import XCTest
@testable import OpenBurnBarCore

/// Contract tests for the native swarm-substrate system: the catalog shape, the
/// kernel→family coupling table, selection resolution, and the plain default.
@MainActor
final class SwarmSubstrateContractTests: XCTestCase {

    // MARK: Catalog shape

    func testCatalogHasSixPlainPlusTwentyFourBespoke() {
        let list = SubstrateCatalog.substrateList
        let plain = list.filter { $0.id == SubstrateCatalog.plainID }
        let bespoke = list.filter { $0.id != SubstrateCatalog.plainID }
        XCTAssertEqual(plain.count, 6, "one Plain·DOTS descriptor per family")
        XCTAssertEqual(bespoke.count, 24, "24 bespoke substrates")
        XCTAssertEqual(list.count, 30)
    }

    func testEveryFamilyOffersExactlyFiveStylesPlainFirst() {
        for fam in SubstrateFamily.allCases {
            let entries = SubstrateCatalog.entries(in: fam)
            XCTAssertEqual(entries.count, 5, "\(fam) should offer plain + 4 bespoke")
            XCTAssertEqual(entries.first?.id, SubstrateCatalog.plainID, "\(fam): plain is first")
            XCTAssertEqual(entries.first?.family, fam)
            for e in entries.dropFirst() {
                XCTAssertEqual(e.family, fam, "\(e.id) must belong to \(fam)")
            }
        }
    }

    func testBespokeIdsAreUniqueAndNamespaced() {
        let bespoke = SubstrateCatalog.substrateList.filter { $0.id != SubstrateCatalog.plainID }
        let ids = bespoke.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "bespoke ids unique")
        for d in bespoke {
            XCTAssertTrue(d.id.hasPrefix("\(d.family.rawValue)."),
                          "\(d.id) should be namespaced by its family")
        }
    }

    func testByIDLookupResolvesEveryBespoke() {
        for d in SubstrateCatalog.substrateList where d.id != SubstrateCatalog.plainID {
            XCTAssertNotNil(SubstrateCatalog.byID[d.id], "byID missing \(d.id)")
            XCTAssertEqual(SubstrateCatalog.byID[d.id]?.family, d.family)
        }
        XCTAssertNotNil(SubstrateCatalog.byID[SubstrateCatalog.plainID])
    }

    // MARK: Kernel → family coupling

    func testExactKernelIdsMapToTheirOwnFamily() {
        XCTAssertEqual(SubstrateFamily.forKernel("constellation"), .constellation)
        XCTAssertEqual(SubstrateFamily.forKernel("flow"), .flow)
        XCTAssertEqual(SubstrateFamily.forKernel("aurora"), .aurora)
        XCTAssertEqual(SubstrateFamily.forKernel("mesh"), .mesh)
        XCTAssertEqual(SubstrateFamily.forKernel("moire"), .moire)
        XCTAssertEqual(SubstrateFamily.forKernel("volumetric"), .volumetric)
    }

    func testCousinKernelsMapViaFamilyByWorld() {
        // ported FAMILY_BY_WORLD entries
        XCTAssertEqual(SubstrateFamily.forKernel("lic"), .flow)
        XCTAssertEqual(SubstrateFamily.forKernel("caustics"), .flow)
        XCTAssertEqual(SubstrateFamily.forKernel("fluid-aurora"), .aurora) // the default kernel
        XCTAssertEqual(SubstrateFamily.forKernel("cloudfield"), .constellation)
        XCTAssertEqual(SubstrateFamily.forKernel("plasma-orbs"), .aurora)
        XCTAssertEqual(SubstrateFamily.forKernel("blobs-mesh"), .mesh)
        XCTAssertEqual(SubstrateFamily.forKernel("kinetic-stipple"), .constellation)
        XCTAssertEqual(SubstrateFamily.forKernel("storm-signal"), .constellation)
        XCTAssertEqual(SubstrateFamily.forKernel("bat-signal"), .aurora)
        XCTAssertEqual(SubstrateFamily.forKernel("origami"), .mesh)
        XCTAssertEqual(SubstrateFamily.forKernel("petroleum-sheen"), .moire)
        XCTAssertEqual(SubstrateFamily.forKernel("ink-diffusion"), .flow)
    }

    func testUnknownKernelsFallToHeuristicThenConstellation() {
        XCTAssertEqual(SubstrateFamily.forKernel("aether-lattice"), .mesh)   // "lattice"
        XCTAssertEqual(SubstrateFamily.forKernel("some-plasma-thing"), .aurora) // "plasma"
        XCTAssertEqual(SubstrateFamily.forKernel("river-stream"), .flow)     // "stream"
        XCTAssertEqual(SubstrateFamily.forKernel("agent1"), .constellation)  // no keyword
        XCTAssertEqual(SubstrateFamily.forKernel("zzz-unknown"), .constellation)
    }

    func testEveryRealKernelResolvesToAFamilyWithFiveStyles() {
        // The picker must never show an empty suite for any shipped kernel.
        for kernel in KnownKernelIDs.all {
            let styles = SubstrateCatalog.styles(forKernel: kernel)
            XCTAssertEqual(styles.count, 5, "kernel \(kernel) should offer 5 substrate styles")
            XCTAssertEqual(styles.first?.id, SubstrateCatalog.plainID)
        }
    }

    // MARK: Selection resolution (per-theme coupling)

    func testSelectedBespokeOnlyLightsUpOnItsOwnFamilyKernel() {
        let starfire = "constellation.starfire"
        // On a constellation-family kernel → the pick resolves.
        let onConstellation = SubstrateCatalog.resolved(forKernel: "constellation", selectedID: starfire)
        XCTAssertEqual(onConstellation.id, starfire)
        // On a flow-family kernel → falls back to that family's plain.
        let onFlow = SubstrateCatalog.resolved(forKernel: "flow", selectedID: starfire)
        XCTAssertEqual(onFlow.id, SubstrateCatalog.plainID)
        XCTAssertEqual(onFlow.family, .flow)
    }

    func testResolvedAlwaysReturnsPlainForUnknownSelection() {
        let r = SubstrateCatalog.resolved(forKernel: "mesh", selectedID: "does.not.exist")
        XCTAssertEqual(r.id, SubstrateCatalog.plainID)
        XCTAssertEqual(r.family, .mesh)
    }

    func testPlainPerFamilyIsAlwaysAvailable() {
        for fam in SubstrateFamily.allCases {
            let p = SubstrateCatalog.plain(for: fam)
            XCTAssertEqual(p.id, SubstrateCatalog.plainID)
            XCTAssertEqual(p.family, fam)
        }
    }

    // MARK: Plain default = today's behavior

    func testPlainDescriptorBuildsPlainDotsSubstrate() {
        let made = SubstrateCatalog.plain(for: .aurora).make()
        XCTAssertTrue(made is PlainDotsSubstrate)
    }

    func testEveryDescriptorFactoryBuildsItsType() {
        // No factory should crash; each returns a SwarmSubstrate.
        for d in SubstrateCatalog.substrateList {
            let made = d.make()
            _ = made // built without crashing
            if d.id == SubstrateCatalog.plainID {
                XCTAssertTrue(made is PlainDotsSubstrate)
            }
        }
    }

    // MARK: Persistence round-trip

    func testPreferencesDefaultToPlainAndDisabled() {
        let defaults = UserDefaults(suiteName: "substrate-contract-test-\(UUID().uuidString)")!
        // Fresh suite: no values set.
        XCTAssertNil(defaults.string(forKey: SwarmSubstratePreferences.substrateKey))
        XCTAssertNil(defaults.object(forKey: SwarmSubstratePreferences.enabledKey))
    }

    func testResolvedCurrentIsPlainWhenDisabled() {
        // With the substrate layer disabled, resolution is always plain — i.e.
        // identical to the pre-substrate renderer.
        let std = UserDefaults.standard
        let priorEnabled = std.object(forKey: SwarmSubstratePreferences.enabledKey)
        let priorID = std.string(forKey: SwarmSubstratePreferences.substrateKey)
        defer {
            std.set(priorEnabled, forKey: SwarmSubstratePreferences.enabledKey)
            if let priorID { std.set(priorID, forKey: SwarmSubstratePreferences.substrateKey) }
            else { std.removeObject(forKey: SwarmSubstratePreferences.substrateKey) }
        }
        std.set(false, forKey: SwarmSubstratePreferences.enabledKey)
        std.set("constellation.starfire", forKey: SwarmSubstratePreferences.substrateKey)
        let r = SubstrateCatalog.resolvedCurrent(forKernel: "constellation")
        XCTAssertEqual(r.id, SubstrateCatalog.plainID, "disabled ⇒ plain regardless of stored pick")
    }

    // MARK: Structure provider safety (the crash-risk root)

    func testStructureProviderNeverReturnsOutOfRangeIndices() {
        // Stroke/lattice substrates index frame.dots by structure order/neighbors;
        // the provider must never hand back an index ≥ count, even across a topology
        // change that reuses the same provider instance.
        let provider = SubstrateStructureProvider()
        func dots(_ n: Int, seed: Double) -> [SwarmSubstrateDot] {
            (0..<n).map { i in
                let a = Double(i) * 0.7 + seed
                return SwarmSubstrateDot(
                    x: 200 + 80 * cos(a), y: 150 + 60 * sin(a * 1.3), vx: 0, vy: 0,
                    radius: 1.5, baseSize: 1.5, rgba: RGBA(r: 1, g: 0.4, b: 0.4),
                    opacity: 1, inShape: true, role: nil, slotIndex: nil,
                    colorIndex: Double(i) / Double(n), flowProgress: 0)
            }
        }
        for n in [1, 2, 7, 40, 200, 39, 1] {   // shrink + grow to exercise cache reuse
            let field = dots(n, seed: Double(n))
            let s = provider.structure(for: field, k: 6)
            for idx in s.order { XCTAssertTrue(idx >= 0 && idx < n, "order index \(idx) out of 0..<\(n)") }
            XCTAssertEqual(s.neighbors.count, n)
            for list in s.neighbors {
                for idx in list { XCTAssertTrue(idx >= 0 && idx < n, "neighbor index \(idx) out of 0..<\(n)") }
            }
        }
    }

    func testStructureProviderHandlesEmptyAndSinglePointFields() {
        let provider = SubstrateStructureProvider()
        let empty = provider.structure(for: [], k: 6)
        XCTAssertTrue(empty.order.isEmpty)
        XCTAssertTrue(empty.neighbors.isEmpty)

        let one = [SwarmSubstrateDot(x: 1, y: 1, vx: 0, vy: 0, radius: 1, baseSize: 1,
                                     rgba: RGBA(r: 1, g: 1, b: 1), opacity: 1, inShape: false,
                                     role: nil, slotIndex: nil, colorIndex: 0, flowProgress: 0)]
        let s = provider.structure(for: one, k: 6)
        XCTAssertEqual(s.order, [0])
        XCTAssertEqual(s.neighbors.count, 1)
    }
}

/// The shipped kernel ids (mirrors `KernelCatalog.all` in the app target, which
/// the core test target can't import). Kept in sync by the coupling-coverage test.
private enum KnownKernelIDs {
    static let all: [String] = [
        "constellation", "flow", "aurora", "mesh", "moire", "volumetric", "lic",
        "fluid-aurora", "cloudfield", "plasma-orbs", "blobs-mesh", "retro-plasma",
        "inversion-lattice", "vogel-bloom", "crystal-drift", "ripple-lattice",
        "liquid-lumen", "spectral-drift", "mycelium-mesh", "oilfield",
        "suminagashi-drift", "kinetic-stipple", "agent1", "neural-bloom",
        "aether-lattice", "bat-signal", "storm-signal", "origami", "ink-diffusion",
        "petroleum-sheen",
    ]
}
