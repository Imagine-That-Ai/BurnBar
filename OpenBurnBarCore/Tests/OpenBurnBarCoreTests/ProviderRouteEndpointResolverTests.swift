import XCTest
@testable import OpenBurnBarCore

final class ProviderRouteEndpointResolverTests: XCTestCase {
    func testResolveMimoTokenPlanUsesRegionalHost() {
        let resolved = ProviderRouteEndpointResolver.resolve(
            providerID: "mimo",
            apiKey: "tp-test-key",
            defaultBaseURL: "https://api.xiaomimimo.com/v1",
            slot: ProviderRouteEndpointResolver.SlotContext(
                endpointProfileID: "mimo.token-plan.sgp",
                region: .sgp
            )
        )

        XCTAssertEqual(resolved.endpointProfileID, "mimo.token-plan.sgp")
        XCTAssertEqual(resolved.baseURL, "https://token-plan-sgp.xiaomimimo.com/v1")
    }

    func testResolveMimoPaygFromKeyPrefix() {
        let resolved = ProviderRouteEndpointResolver.resolve(
            providerID: "mimo",
            apiKey: "sk-test-key",
            defaultBaseURL: "https://token-plan-sgp.xiaomimimo.com/v1",
            slot: ProviderRouteEndpointResolver.SlotContext()
        )

        XCTAssertEqual(resolved.endpointProfileID, "mimo.payg.global")
        XCTAssertEqual(resolved.baseURL, "https://api.xiaomimimo.com/v1")
    }

    func testResolveMiniMaxTokenPlanFromCodingPlanKey() {
        let resolved = ProviderRouteEndpointResolver.resolve(
            providerID: "minimax",
            apiKey: "sk-cp-test-key",
            defaultBaseURL: "https://api.minimax.io/v1",
            slot: ProviderRouteEndpointResolver.SlotContext()
        )

        XCTAssertEqual(resolved.endpointProfileID, "minimax.token-plan")
        XCTAssertEqual(resolved.baseURL, "https://api.minimax.io/v1")
    }

    func testResolveMiniMaxPaygFromOpenPlatformKey() {
        let resolved = ProviderRouteEndpointResolver.resolve(
            providerID: "minimax",
            apiKey: "sk-api-test-key",
            defaultBaseURL: "https://api.minimax.io/v1",
            slot: ProviderRouteEndpointResolver.SlotContext()
        )

        XCTAssertEqual(resolved.endpointProfileID, "minimax.payg")
        XCTAssertEqual(resolved.baseURL, "https://api.minimax.io/v1")
    }

    func testMiniMaxTokenPlanProfileUsesRegistryQuotaURL() {
        XCTAssertEqual(
            ProviderEndpointProfileRegistry.minimaxTokenPlan.quotaRemainsURL,
            "https://www.minimax.io/v1/token_plan/remains"
        )
    }
}
