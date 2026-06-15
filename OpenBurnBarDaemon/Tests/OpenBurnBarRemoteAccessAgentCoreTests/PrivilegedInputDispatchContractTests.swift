import Darwin
import Foundation
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
            peerAuditToken: Data(repeating: 0xAB, count: MemoryLayout<audit_token_t>.size),
            presentingEscrowDeviceId: "iphone-a",
            requiredAttestationHashBlake3: "attest-a"
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(PrivilegedInputDispatchEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func test_dispatchEnvelope_decodesLegacyPayloadWithoutPresenterBinding() throws {
        let json = """
        {
          "request": {
            "operation": "input",
            "kind": "click"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(PrivilegedInputDispatchEnvelope.self, from: json)

        XCTAssertEqual(decoded.request.operation, "input")
        XCTAssertEqual(decoded.request.kind, "click")
        XCTAssertNil(decoded.presentingEscrowDeviceId)
        XCTAssertNil(decoded.requiredAttestationHashBlake3)
    }
}
