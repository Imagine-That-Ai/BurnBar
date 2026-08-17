import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel

final class AgentProviderFleetMappingTests: XCTestCase {
    func test_everyDeclaredFleetIdMaps() {
        for fleetID in BurnBarFleetAgentID.declaredRoster {
            XCTAssertNotNil(AgentProvider(fleetAgentID: fleetID), "\(fleetID.wireValue) must map")
        }
    }

    func test_unknownFleetIDDoesNotMap() {
        XCTAssertNil(AgentProvider(fleetAgentID: .unknown("aider")))
    }
}
