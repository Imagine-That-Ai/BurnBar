import XCTest
@testable import OpenBurnBarCore

final class SwarmLogoShapeTests: XCTestCase {
    func testDefaultCycleIncludesBurnBarLogoShape() {
        XCTAssertTrue(SwarmFormationMode.defaultCycle.contains(.shapeBurnBarLogo))
        XCTAssertTrue(SwarmFormationMode.defaultCycle.contains(.shapeGrok))
        XCTAssertTrue(SwarmFormationMode.defaultCycle.contains(.shapeRouterFlow))
    }

    func testDefaultCycleExcludesBrandShapesWhenRequested() {
        let cycle = SwarmFormationMode.defaultCycle(for: SwarmFormationMode.showcaseProviders, excludeBrandShapes: true)
        XCTAssertFalse(cycle.contains(.shapeBurnBarLogo))
        XCTAssertFalse(cycle.contains(.shapeDollar))
        XCTAssertFalse(cycle.contains(.shapeCode))
        XCTAssertFalse(cycle.contains(.shapeRings))
        XCTAssertFalse(cycle.contains(.shapeRouterFlow))

        XCTAssertTrue(cycle.contains(.swarm))
        XCTAssertTrue(cycle.contains(where: {
            if case .shapeProviderLogo = $0 { return true }
            return false
        }))
    }

    func testInspectionCycleExcludesBrandShapesWhenRequested() {
        let cycle = SwarmFormationMode.inspectionCycle(for: SwarmFormationMode.showcaseProviders, excludeBrandShapes: true)
        XCTAssertFalse(cycle.contains(.shapeBurnBarLogo))
        XCTAssertFalse(cycle.contains(.shapeDollar))
        XCTAssertFalse(cycle.contains(.shapeCode))
        XCTAssertFalse(cycle.contains(.shapeRings))
        XCTAssertFalse(cycle.contains(.shapeRouterFlow))

        XCTAssertTrue(cycle.contains(.swarm))
        XCTAssertTrue(cycle.contains(where: {
            if case .shapeProviderLogo = $0 { return true }
            return false
        }))
    }

    func testInspectionCycleIncludesEveryProviderLogoGrokAndMultiProviderFormations() {
        XCTAssertEqual(Set(SwarmFormationMode.showcaseProviders), Set(AgentProvider.allCases))

        for provider in AgentProvider.allCases {
            XCTAssertTrue(
                SwarmFormationMode.inspectionCycle.contains(.shapeProviderLogo([provider])),
                "Missing singleton provider logo shape for \(provider.rawValue)"
            )
        }

        XCTAssertTrue(SwarmFormationMode.inspectionCycle.contains(.shapeProviderLogo([.xAI])))
        XCTAssertTrue(SwarmFormationMode.inspectionCycle.contains(.shapeGrok))
        XCTAssertTrue(SwarmFormationMode.inspectionCycle.contains(.shapeProviderLogo([.deepSeek])))
        XCTAssertTrue(SwarmFormationMode.inspectionCycle.contains(.shapeProviderLogo([.minimax])))
        XCTAssertTrue(SwarmFormationMode.inspectionCycle.contains(.shapeProviderLogo([.zai])))
        // Multi-provider formations are now capped at pairs (group size 2)
        // so the per-glyph particle budget stays readable on iPhone.
        XCTAssertTrue(SwarmFormationMode.providerLogoGroups.contains([.factory, .claudeCode]))
        XCTAssertTrue(SwarmFormationMode.providerLogoGroups.contains([.codex, .openCode]))
        XCTAssertTrue(SwarmFormationMode.providerLogoGroups.contains([.openClaw, .hermes]))
        XCTAssertTrue(SwarmFormationMode.providerLogoGroups.allSatisfy { $0.count <= 2 })
    }

    func testProviderGlyphSelectionFiltersInspectionAndDefaultCycles() {
        let providers: [AgentProvider] = [.codex, .openClaw]
        let inspection = SwarmFormationMode.inspectionCycle(for: providers)
        let defaultCycle = SwarmFormationMode.defaultCycle(for: providers)

        XCTAssertTrue(inspection.contains(.shapeProviderLogo([.codex])))
        XCTAssertTrue(inspection.contains(.shapeProviderLogo([.openClaw])))
        XCTAssertFalse(inspection.contains(.shapeProviderLogo([.claudeCode])))
        XCTAssertFalse(inspection.contains(.shapeGrok))
        XCTAssertTrue(defaultCycle.contains(.shapeProviderLogo([.codex, .openClaw])))
        XCTAssertFalse(defaultCycle.contains(.shapeGrok))
    }

    func testProviderGlyphSelectionEncodingPreservesNoneAllAndProviderOrder() {
        XCTAssertEqual(
            SwarmProviderGlyphSelection.decode(SwarmProviderGlyphSelection.allSentinel),
            SwarmProviderGlyphSelection.allProviders
        )
        XCTAssertEqual(
            SwarmProviderGlyphSelection.decode(SwarmProviderGlyphSelection.noneSentinel),
            []
        )
        XCTAssertEqual(
            SwarmProviderGlyphSelection.decode("openclaw,codex,claudecode"),
            [.claudeCode, .codex, .openClaw]
        )
        XCTAssertEqual(
            SwarmProviderGlyphSelection.encode([.openClaw, .codex]),
            "codex,openclaw"
        )
    }

    func testStaticGlyphAndProviderShapesUseAdmireHold() {
        XCTAssertTrue(SwarmFormationMode.shapeDollar.requiresSettledAdmireHold)
        XCTAssertTrue(SwarmFormationMode.shapeCode.requiresSettledAdmireHold)
        XCTAssertTrue(SwarmFormationMode.shapeBurnBarLogo.requiresSettledAdmireHold)
        XCTAssertTrue(SwarmFormationMode.shapeProviderLogo([.codex]).requiresSettledAdmireHold)
        XCTAssertTrue(SwarmFormationMode.shapeGrok.requiresSettledAdmireHold)
        XCTAssertFalse(SwarmFormationMode.swarm.requiresSettledAdmireHold)
        XCTAssertFalse(SwarmFormationMode.shapeRouterFlow.requiresSettledAdmireHold)
    }

    func testVisuallyInspectedProvidersUseRealBundledLogoAssets() {
        XCTAssertEqual(AgentProvider.openClaw.bundledLogoName, "OpenClawLogo")
        XCTAssertEqual(AgentProvider.hermes.bundledLogoName, "HermesLogo")
        XCTAssertEqual(AgentProvider.codex.bundledLogoName, "CodexLogo")
        XCTAssertEqual(AgentProvider.antigravity.bundledLogoName, "AntigravityLogo")
    }

    func testBurnBarLogoShapeContainsFlameAndBarGraphRoles() throws {
        let points = SwarmLogoShape.generatePoints()
        let roles = Set(points.map(\.role))

        XCTAssertGreaterThan(points.count, 280)
        XCTAssertLessThan(points.count, 460)
        XCTAssertTrue(roles.isSuperset(of: [
            "logo-flame-outer",
            "logo-flame-inner",
            "logo-flame-spark",
            "logo-bar-1",
            "logo-bar-2",
            "logo-bar-3",
            "logo-bar-4",
            "logo-bar-5"
        ]))
        XCTAssertEqual(try XCTUnwrap(points.first).progress, 0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(points.last).progress, 1, accuracy: 0.000_001)
    }

    func testBurnBarLogoShapeKeepsLogoProportions() throws {
        let bounds = try bounds(for: SwarmLogoShape.generatePoints())

        XCTAssertGreaterThan(bounds.width, 1.1)
        XCTAssertGreaterThan(bounds.height, 1.5)
        XCTAssertGreaterThan(bounds.maxY, 0.75)
        XCTAssertLessThan(bounds.minY, -0.75)
        XCTAssertEqual(bounds.midX, 0, accuracy: 0.08)
    }

    func testBurnBarLogoFlamePointsUp() throws {
        let points = SwarmLogoShape.generatePoints()
        let flameBounds = try bounds(for: points, role: "logo-flame-outer")
        let barBounds = try bounds(for: points.filter { $0.role.hasPrefix("logo-bar-") })

        XCTAssertLessThan(flameBounds.minY, barBounds.minY)
        XCTAssertLessThan(flameBounds.midY, barBounds.midY)
        XCTAssertLessThan(flameBounds.maxY, barBounds.maxY)
    }

    func testBurnBarLogoCanvasTargetsKeepFlameAboveBars() throws {
        let points = SwarmLogoShape.generatePoints()
        let flameBounds = try canvasBounds(for: points, role: "logo-flame-outer")
        let barBounds = try canvasBounds(for: points.filter { $0.role.hasPrefix("logo-bar-") })

        XCTAssertLessThan(flameBounds.minY, barBounds.minY)
        XCTAssertLessThan(flameBounds.midY, barBounds.midY)
        XCTAssertLessThan(flameBounds.maxY, barBounds.maxY)
    }

    func testBurnBarLogoBarsRiseLeftToRight() throws {
        let points = SwarmLogoShape.generatePoints()
        let barBounds = try (1...5).map { index in
            try bounds(for: points, role: "logo-bar-\(index)")
        }
        let tops = barBounds.map(\.minY)

        XCTAssertGreaterThan(tops[0], tops[1])
        XCTAssertGreaterThan(tops[1], tops[2])
        XCTAssertGreaterThan(tops[2], tops[3])
        XCTAssertGreaterThan(tops[3], tops[4])

        XCTAssertEqual(barBounds[0].maxY, barBounds[1].maxY, accuracy: 0.04)
        XCTAssertEqual(barBounds[1].maxY, barBounds[2].maxY, accuracy: 0.01)
        XCTAssertEqual(barBounds[2].maxY, barBounds[3].maxY, accuracy: 0.05)
    }

    private func bounds(for points: [SwarmLogoShape.Point], role: String? = nil) throws -> CGRect {
        let filtered = role.map { selectedRole in
            points.filter { $0.role == selectedRole }
        } ?? points
        return try bounds(for: filtered)
    }

    private func bounds(for points: [SwarmLogoShape.Point]) throws -> CGRect {
        let filtered = points
        XCTAssertFalse(filtered.isEmpty)

        let minX = try XCTUnwrap(filtered.map(\.point.x).min())
        let maxX = try XCTUnwrap(filtered.map(\.point.x).max())
        let minY = try XCTUnwrap(filtered.map(\.point.y).min())
        let maxY = try XCTUnwrap(filtered.map(\.point.y).max())
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func canvasBounds(for points: [SwarmLogoShape.Point], role: String? = nil) throws -> CGRect {
        let filtered = role.map { selectedRole in
            points.filter { $0.role == selectedRole }
        } ?? points
        XCTAssertFalse(filtered.isEmpty)

        let center = CGPoint(x: 400, y: 300)
        let scale: CGFloat = 120
        let canvasPoints = filtered.map {
            CGPoint(
                x: center.x + $0.point.x * scale,
                y: center.y + $0.point.y * scale
            )
        }

        let minX = try XCTUnwrap(canvasPoints.map(\.x).min())
        let maxX = try XCTUnwrap(canvasPoints.map(\.x).max())
        let minY = try XCTUnwrap(canvasPoints.map(\.y).min())
        let maxY = try XCTUnwrap(canvasPoints.map(\.y).max())
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
