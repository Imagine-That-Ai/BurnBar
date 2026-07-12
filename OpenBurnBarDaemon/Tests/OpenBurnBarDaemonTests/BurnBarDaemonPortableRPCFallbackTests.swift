#if !os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarDaemonPortableRPCFallbackTests: XCTestCase {
    func testSessionGrantReadinessReportsBrokerUnavailable() async throws {
        let server = makeServer()
        let request = BurnBarRPCRequestEnvelope(
            id: "portable-readiness",
            method: .computerUseSessionGrantReadiness
        )

        let data = try await server.handleComputerUseRPC(
            method: .computerUseSessionGrantReadiness,
            decoder: JSONDecoder(),
            requestData: try JSONEncoder().encode(request)
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<ComputerUseSessionGrantReadinessResponse>.self,
            from: data
        )

        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.available, false)
        XCTAssertEqual(response.result?.reason, .brokerUnavailable)
    }

    func testSessionGrantAcquireFailsClosedOffLinux() async throws {
        let server = makeServer()
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "portable-acquire",
            method: BurnBarRPCMethod.computerUseSessionGrantAcquire,
            params: ComputerUseSessionGrantAcquireRequest(sessionRequest: sessionRequest())
        )

        let response = try await errorResponse(
            server: server,
            method: .computerUseSessionGrantAcquire,
            request: request
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(response.error?.message, "The paired-phone Linux authority broker is unavailable on this platform.")
    }

    func testSessionGrantStatusFailsClosedOffLinux() async throws {
        let server = makeServer()
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "portable-status",
            method: BurnBarRPCMethod.computerUseSessionGrantStatus,
            params: ComputerUseSessionGrantStatusRequest(challengeId: "not-retained")
        )

        let response = try await errorResponse(
            server: server,
            method: .computerUseSessionGrantStatus,
            request: request
        )

        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
        XCTAssertEqual(response.error?.message, "The paired-phone Linux authority broker is unavailable on this platform.")
    }

    func testEveryLinuxAuthMethodReturnsMethodNotFoundOffLinux() async throws {
        let server = makeServer()
        for method in [
            BurnBarRPCMethod.linuxAuthStatus,
            .linuxAuthBegin,
            .linuxAuthCancel,
            .linuxAuthRotateIdentity,
            .linuxAuthSignOut
        ] {
            let request = BurnBarRPCRequestEnvelope(id: "portable-\(method.rawValue)", method: method)
            let data = try await server.handleLinuxAuthRPC(
                method: method,
                decoder: JSONDecoder(),
                requestData: try JSONEncoder().encode(request)
            )
            let response = try JSONDecoder().decode(
                BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self,
                from: data
            )

            XCTAssertEqual(response.id, request.id)
            XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.methodNotFound)
            XCTAssertEqual(response.error?.message, "Linux authentication is unavailable on this platform.")
        }
    }

    private func makeServer() -> BurnBarDaemonServer {
        BurnBarDaemonServer(configuration: BurnBarDaemonConfiguration(
            socketPath: "/tmp/obb-portable-rpc-\(UUID().uuidString.prefix(8)).sock",
            socketAuthToken: "test-token",
            startsMissionControlBackgroundLoops: false
        ))
    }

    private func sessionRequest() -> ComputerUseSessionStartRequest {
        ComputerUseSessionStartRequest(
            mode: ComputerUseMode.browser.rawValue,
            trustMode: ComputerUseTrustMode.manual.rawValue,
            clientID: BurnBarClientID(rawValue: "portable-test-client")
        )
    }

    private func errorResponse<Params: Codable & Sendable>(
        server: BurnBarDaemonServer,
        method: BurnBarRPCMethod,
        request: BurnBarRPCRequestEnvelopeWithParams<Params>
    ) async throws -> BurnBarRPCResponseEnvelope<BurnBarEmptyResult> {
        let data = try await server.handleComputerUseRPC(
            method: method,
            decoder: JSONDecoder(),
            requestData: try JSONEncoder().encode(request)
        )
        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<BurnBarEmptyResult>.self, from: data)
    }
}
#endif
