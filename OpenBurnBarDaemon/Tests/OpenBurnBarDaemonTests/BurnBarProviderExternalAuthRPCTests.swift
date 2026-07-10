import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class BurnBarProviderExternalAuthRPCTests: XCTestCase {
    func testStartStatusAndCancelUseTypedDaemonService() async throws {
        let service = ProviderExternalAuthRPCStub()
        let server = BurnBarDaemonServer(providerExternalAuthService: service)

        let start: BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse> = try await request(
            server: server,
            method: .providerExternalAuthStart,
            params: BurnBarProviderExternalAuthStartRequest(
                providerID: "openai",
                authMethodID: "openai-codex-oauth"
            )
        )
        XCTAssertNil(start.error)
        XCTAssertEqual(start.result?.flow.state, .awaitingUser)

        let status: BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse> = try await request(
            server: server,
            method: .providerExternalAuthStatus,
            params: BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                authMethodID: "openai-codex-oauth",
                flowID: "flow-1"
            )
        )
        XCTAssertNil(status.error)
        XCTAssertEqual(status.result?.flow.flowID, "flow-1")

        let cancel: BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse> = try await request(
            server: server,
            method: .providerExternalAuthCancel,
            params: BurnBarProviderExternalAuthFlowRequest(flowID: "flow-1")
        )
        XCTAssertNil(cancel.error)
        XCTAssertEqual(cancel.result?.flow.state, .cancelled)

        let calls = await service.calls
        XCTAssertEqual(calls, [
            "start:openai:openai-codex-oauth",
            "status:openai:openai-codex-oauth:flow-1",
            "cancel:flow-1"
        ])
    }

    func testUnknownFlowMapsToSanitizedInvalidParamsError() async throws {
        let server = BurnBarDaemonServer(providerExternalAuthService: ProviderExternalAuthRPCStub())
        let response: BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse> = try await request(
            server: server,
            method: .providerExternalAuthStatus,
            params: BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                authMethodID: "openai-codex-oauth",
                flowID: "unknown"
            )
        )

        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.invalidParams)
        XCTAssertEqual(response.error?.message, "The provider sign-in flow is not active.")
    }

    private func request<Params: Codable & Sendable>(
        server: BurnBarDaemonServer,
        method: BurnBarRPCMethod,
        params: Params
    ) async throws -> BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse> {
        let data = try JSONEncoder().encode(BurnBarRPCRequestEnvelopeWithParams(
            id: UUID().uuidString,
            method: method,
            authToken: "test-token",
            params: params
        ))
        let response = try await server.handleConfigRPC(
            method: method,
            decoder: JSONDecoder(),
            requestData: data
        )
        return try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarProviderExternalAuthResponse>.self,
            from: response
        )
    }
}

private actor ProviderExternalAuthRPCStub: BurnBarProviderExternalAuthServing {
    private(set) var calls: [String] = []

    func start(
        _ request: BurnBarProviderExternalAuthStartRequest
    ) async -> BurnBarProviderExternalAuthResponse {
        calls.append("start:\(request.providerID):\(request.authMethodID)")
        return response(state: .awaitingUser)
    }

    func status(
        _ request: BurnBarProviderExternalAuthStatusRequest
    ) async throws -> BurnBarProviderExternalAuthResponse {
        if request.flowID == "unknown" {
            throw BurnBarProviderExternalAuthServiceError.invalidFlow
        }
        calls.append(
            "status:\(request.providerID):\(request.authMethodID ?? "nil"):\(request.flowID ?? "nil")"
        )
        return response(state: .awaitingUser)
    }

    func cancel(
        _ request: BurnBarProviderExternalAuthFlowRequest
    ) async throws -> BurnBarProviderExternalAuthResponse {
        calls.append("cancel:\(request.flowID)")
        return response(state: .cancelled)
    }

    private func response(
        state: BurnBarProviderExternalAuthState
    ) -> BurnBarProviderExternalAuthResponse {
        let terminal = state == .cancelled
        return BurnBarProviderExternalAuthResponse(flow: BurnBarProviderExternalAuthFlowSnapshot(
            flowID: "flow-1",
            providerID: "openai",
            providerDisplayName: "OpenAI",
            authMethodID: "openai-codex-oauth",
            authMethodDisplayName: "Sign in with ChatGPT",
            cliDisplayName: "Codex",
            state: state,
            availability: .available,
            cliInstalled: true,
            connected: false,
            problem: terminal
                ? BurnBarProviderExternalAuthProblem(
                    code: .cancelled,
                    message: "Provider sign-in was cancelled.",
                    recoverable: true
                )
                : nil,
            startedAt: "2026-07-10T12:00:00Z",
            expiresAt: "2026-07-10T12:05:00Z",
            completedAt: terminal ? "2026-07-10T12:01:00Z" : nil,
            updatedAt: "2026-07-10T12:00:00Z"
        ))
    }
}
