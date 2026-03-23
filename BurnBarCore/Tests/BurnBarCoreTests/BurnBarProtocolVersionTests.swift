import XCTest
@testable import BurnBarCore

final class BurnBarProtocolVersionTests: XCTestCase {
    func test_currentProtocolVersion_isSupported() {
        XCTAssertTrue(BurnBarProtocolVersion.supported.contains(BurnBarProtocolVersion.current))
    }

    func test_protocolNegotiation_returnsNewestSharedVersion() {
        XCTAssertEqual(BurnBarProtocolVersion.negotiate(with: [0, 1]), 1)
    }

    func test_protocolNegotiation_returnsNilWithoutOverlap() {
        XCTAssertNil(BurnBarProtocolVersion.negotiate(with: [0]))
    }

    func test_rpcEnvelope_roundTripsWithSharedProtocolVersion() throws {
        let response = BurnBarRPCResponseEnvelope(
            id: "health-1",
            result: BurnBarHealthResponse(ok: true, daemonVersion: "0.1.0", protocolVersion: BurnBarProtocolVersion.current)
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(BurnBarRPCResponseEnvelope<BurnBarHealthResponse>.self, from: data)

        XCTAssertEqual(decoded.id, "health-1")
        XCTAssertEqual(decoded.protocolVersion, BurnBarProtocolVersion.current)
        XCTAssertEqual(decoded.result?.ok, true)
        XCTAssertNil(decoded.error)
    }

    func test_rpcEnvelopeWithParams_roundTripsTypedRequests() throws {
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "config-1",
            method: .configUpdate,
            params: BurnBarConfigUpdateRequest(
                snapshot: BurnBarProviderConfigurationSnapshot(
                    providers: [
                        BurnBarProviderSettings(
                            providerID: "zai",
                            isEnabled: true,
                            baseURL: "https://api.z.ai/api/coding/paas/v4",
                            preferredModelIDs: ["glm-5"]
                        )
                    ]
                )
            )
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(
            BurnBarRPCRequestEnvelopeWithParams<BurnBarConfigUpdateRequest>.self,
            from: data
        )

        XCTAssertEqual(decoded.method, .configUpdate)
        XCTAssertEqual(decoded.params.snapshot.providers.first?.providerID, "zai")
    }
}
