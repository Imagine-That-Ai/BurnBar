import Darwin
import OpenBurnBarComputerUseCore
import XCTest

final class PrivilegedInputDispatchContractTests: XCTestCase {
    func test_dispatchEnvelope_roundTrip() throws {
        let request = PrivilegedInputDispatchRequest(
            operation: "input",
            kind: "click",
            displayX: 10,
            displayY: 20
        )
        let envelope = PrivilegedInputDispatchEnvelope(
            request: request,
            peerAuditToken: Data(repeating: 0xAB, count: MemoryLayout<audit_token_t>.size)
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(PrivilegedInputDispatchEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }
}
