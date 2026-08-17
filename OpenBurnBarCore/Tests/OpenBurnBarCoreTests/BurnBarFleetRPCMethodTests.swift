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
}
