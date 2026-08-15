import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

extension BurnBarHTTPGatewayServerTests {
    func testGatewayRejectsForgedSafariAttributionBeforeProviderContact() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"GLM 5 Turbo"}]}"#
        )
        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(
                session: session
            ),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: [
                "Content-Type": "application/json",
                "Origin": "http://127.0.0.1:5173",
                "User-Agent": "openburnbar-safari-extension",
                "X-OpenBurnBar-Client": "openburnbar-safari-extension",
                "X-OpenBurnBar-Correlation-ID":
                    "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
                "X-OpenBurnBar-Attribution-Capability": "00"
            ],
            body: Data(
                #"{"model":"glm-5-turbo","messages":[{"role":"user","content":"hi"}]}"#
                    .utf8
            )
        )

        XCTAssertEqual(
            response.statusCode,
            401,
            String(decoding: body, as: UTF8.self)
        )
        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Access-Control-Allow-Origin"),
            "http://127.0.0.1:5173"
        )
        XCTAssertTrue(
            String(decoding: body, as: UTF8.self)
                .contains(#""code":"gateway_attribution_rejected""#)
        )
        XCTAssertEqual(
            GatewayUpstreamURLProtocol.recordedRequests().map(\.path),
            [],
            "Rejected Safari attribution must not reach model discovery or provider execution."
        )
        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        XCTAssertTrue(routeLog.isEmpty)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        XCTAssertTrue(usage.isEmpty)
    }

    func testGatewayRejectsForgedSafariAttributionBeforeModelCatalogDiscovery()
        async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body:
                #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"GLM 5 Turbo"}]}"#
        )
        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(
                session: session
            ),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        for path in ["/v1/models", "/v1/models/catalog"] {
            let (response, body) = try await sendGatewayRequest(
                port: harness.port,
                method: "GET",
                path: path,
                headers: [
                    "Origin": "http://127.0.0.1:5173",
                    "X-OpenBurnBar-Client":
                        GatewayRequestAttribution.safariClientSource,
                    "X-OpenBurnBar-Correlation-ID":
                        "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51",
                    "X-OpenBurnBar-Attribution-Capability": "00"
                ]
            )

            XCTAssertEqual(
                response.statusCode,
                401,
                String(decoding: body, as: UTF8.self)
            )
            XCTAssertEqual(
                response.value(
                    forHTTPHeaderField: "Access-Control-Allow-Origin"
                ),
                "http://127.0.0.1:5173"
            )
            XCTAssertTrue(
                String(decoding: body, as: UTF8.self)
                    .contains(#""code":"gateway_attribution_rejected""#)
            )
        }
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests(), [])
        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        XCTAssertTrue(routeLog.isEmpty)
        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        XCTAssertTrue(usage.isEmpty)
    }
}
