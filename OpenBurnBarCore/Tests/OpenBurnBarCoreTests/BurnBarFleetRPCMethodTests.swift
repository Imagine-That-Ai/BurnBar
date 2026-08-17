import XCTest
@testable import OpenBurnBarKernel

final class BurnBarFleetRPCMethodTests: XCTestCase {
    func test_fleetMethodWireStrings() {
        XCTAssertEqual(BurnBarRPCMethod.fleetSnapshot.rawValue, "daemon.fleet.snapshot")
        XCTAssertEqual(BurnBarRPCMethod.fleetOrchestratorGet.rawValue, "daemon.fleet.orchestrator.get")
        XCTAssertEqual(BurnBarRPCMethod.fleetOrchestratorSet.rawValue, "daemon.fleet.orchestrator.set")
        XCTAssertEqual(BurnBarRPCMethod.fleetDirectiveRecord.rawValue, "daemon.fleet.directive.record")
    }

    func test_fleetAgentRosterIsTenDeclaredIds() {
        XCTAssertEqual(BurnBarFleetAgentID.declaredRoster.count, 10)
        XCTAssertFalse(BurnBarFleetAgentID.declaredRoster.contains { if case .unknown = $0 { return true }; return false })
    }

    func test_unknownFleetIdRoundTripsLosslessly() throws {
        let encoded = try JSONEncoder().encode(BurnBarFleetAgentID.unknown("aider"))
        let decoded = try JSONDecoder().decode(BurnBarFleetAgentID.self, from: encoded)
        XCTAssertEqual(decoded, .unknown("aider"))
        XCTAssertEqual(decoded.wireValue, "aider")
    }

    func test_designationPreservesAbsentNullAndPresentSessionRef() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let absent = BurnBarOrchestratorDesignation.agent(id: .hermes, sessionRef: .absent)
        let absentJSON = try encoder.encode(absent)
        let absentText = String(data: absentJSON, encoding: .utf8) ?? ""
        XCTAssertFalse(absentText.contains("sessionRef"))
        XCTAssertEqual(try decoder.decode(BurnBarOrchestratorDesignation.self, from: absentJSON), absent)

        let explicitNull = try decoder.decode(
            BurnBarOrchestratorDesignation.self,
            from: Data(#"{"kind":"agent","id":"hermes","sessionRef":null}"#.utf8)
        )
        XCTAssertEqual(explicitNull, .agent(id: .hermes, sessionRef: .null))

        let present = BurnBarOrchestratorDesignation.agent(id: .hermes, sessionRef: .present("sess-1"))
        XCTAssertEqual(try decoder.decode(BurnBarOrchestratorDesignation.self, from: try encoder.encode(present)), present)
    }

    func test_incompatibleSnapshotSchemaVersionFailsTyped() {
        let payload = Data([
            "{",
            "\"schemaVersion\":2,",
            "\"generatedAt\":\"2026-08-12T01:01:05.000Z\",",
            "\"cadenceSeconds\":15,",
            "\"machine\":{\"memoryTotalBytes\":1,",
            "\"thermal\":{\"kind\":\"unavailable\",\"reason\":\"none\"},",
            "\"power\":{\"kind\":\"unavailable\",\"reason\":\"none\"}},",
            "\"agents\":[],\"repos\":[],\"runningCount\":0,\"countsByAgent\":{},",
            "\"orchestrator\":{\"designation\":{\"kind\":\"none\"},\"pendingDirectives\":0},",
            "\"probeHealth\":[],\"persistenceHealth\":{\"kind\":\"ok\"}}"
        ].joined().utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: payload)) { error in
            guard case BurnBarFleetContractError.incompatibleSchemaVersion(let found, _) = error else {
                return XCTFail("expected incompatibleSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 2)
        }
    }
}
