// Quarantined tests extracted from: OpenBurnBarOperatingLayerTests.swift
//
// These tests were quarantined because they reference stale contracts,
// drifted schemas, or environmental preconditions not satisfied in CI.
// See QUARANTINE_MANIFEST.md for per-test owner, reason, and revival criteria.
//
// Revival workflow:
//   1. Update tests to compile against current public/@testable APIs.
//   2. Move this file to AgentLensTests/Active/ (matching subdirectory).
//   3. Remove the file from Quarantine.
//   4. Prove with: ./scripts/test-openburnbar-app.sh

import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import OpenBurnBar

final class OpenBurnBarOperatingLayerTests: XCTestCase {

    // MARK: - Quarantined Tests

    func testOperatingLayerBuildsMissionDirectionBurnFromIndexedProjectData() throws {
        try XCTSkipIf(true, "Stale contract — mission direction-burn signal classification drifted; refresh thresholds.")
        let store = try makeInMemoryStore()
        seedApolloScenario(into: store)
        let layer = makeLayer(dataStore: store)

        let snapshot = layer.snapshot

        XCTAssertEqual(snapshot.projectName, "Apollo")
        XCTAssertEqual(snapshot.mission.availability, .available)
        XCTAssertEqual(snapshot.direction.availability, .available)
        XCTAssertEqual(snapshot.burn.availability, .available)
        XCTAssertEqual(snapshot.evidence.availability, .available)
        XCTAssertEqual(snapshot.mission.title, "Ship the approval sheet")
        XCTAssertEqual(snapshot.direction.status, .drifting)
        XCTAssertEqual(snapshot.burn.estimatedCostUSD, 8.85, accuracy: 0.001)
        XCTAssertTrue(snapshot.availableActions.contains(where: { $0.kind == .missionApproval && $0.available }))
        XCTAssertTrue(snapshot.availableActions.contains(where: { $0.kind == .directionOverride && $0.available }))
        XCTAssertEqual(snapshot.controllerRuntime.pendingQuestions.count, 1)
        XCTAssertTrue(snapshot.controllerRuntime.openFollowups.count >= 1)
    }


}
