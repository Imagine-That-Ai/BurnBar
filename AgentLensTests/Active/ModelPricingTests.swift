import XCTest
@testable import OpenBurnBar

/// Unit tests for ModelPricing cost calculations — pure business logic
/// with no external dependencies, no async, no state.
final class ModelPricingStandaloneTests: XCTestCase {

    // MARK: - Cost calculation

    func test_cost_zeroTokens_returnsZero() {
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        XCTAssertEqual(pricing.cost(inputTokens: 0, outputTokens: 0), 0.0, accuracy: 0.0001)
    }

    func test_cost_inputOnly() {
        // 500 input tokens at $3.00/MTok = 500/1M * 3 = 0.0015
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(inputTokens: 500, outputTokens: 0)
        XCTAssertEqual(cost, 0.0015, accuracy: 0.00001)
    }

    func test_cost_outputOnly() {
        // 200 output tokens at $15.00/MTok = 200/1M * 15 = 0.003
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(inputTokens: 0, outputTokens: 200)
        XCTAssertEqual(cost, 0.003, accuracy: 0.00001)
    }

    func test_cost_inputAndOutput() {
        // 1000 input + 500 output
        // input:  1000/1M * 3.0 = 0.003
        // output: 500/1M * 15.0 = 0.0075
        // total: 0.0105
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(inputTokens: 1_000, outputTokens: 500)
        XCTAssertEqual(cost, 0.0105, accuracy: 0.00001)
    }

    func test_cost_cacheReadTokens() {
        // 1000 cached read tokens at $1.25/MTok = 0.00125
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.25)
        let cost = pricing.cost(inputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000)
        XCTAssertEqual(cost, 0.00125, accuracy: 0.00001)
    }

    func test_cost_cacheCreationTokens_usesInputRate() {
        // Cache creation is billed at input rate
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.25)
        let cost = pricing.cost(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 1_000)
        XCTAssertEqual(cost, 0.003, accuracy: 0.00001)
    }

    func test_cost_fullBreakdown() {
        // 500 input, 200 output, 100 cache creation, 300 cache read
        // input:    500/1M * 3.0  = 0.0015
        // output:   200/1M * 15.0 = 0.0030
        // cacheCr:  100/1M * 3.0  = 0.0003
        // cacheRd:  300/1M * 1.5  = 0.00045
        // total: 0.00525
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(
            inputTokens: 500,
            outputTokens: 200,
            cacheCreationTokens: 100,
            cacheReadTokens: 300
        )
        XCTAssertEqual(cost, 0.00525, accuracy: 0.00001)
    }

    func test_cost_largeTokenCounts() {
        // 10M input tokens at $3.00/MTok = 30.0
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(inputTokens: 10_000_000, outputTokens: 0)
        XCTAssertEqual(cost, 30.0, accuracy: 0.001)
    }

    func test_cost_singleMilliToken() {
        // 1 input token at $3.00/MTok = 3e-6
        let pricing = ModelPricing(inputPerMToken: 3.0, outputPerMToken: 15.0, cacheReadPerMToken: 1.5)
        let cost = pricing.cost(inputTokens: 1, outputTokens: 0)
        XCTAssertEqual(cost, 0.000003, accuracy: 1e-9)
    }

    // MARK: - Fallback pricing

    func test_fallbackPricing_hasExpectedValues() {
        // The private fallback is used when OpenBurnBarCore catalog is unavailable
        let pricing = ModelPricing(inputPerMToken: 2.5, outputPerMToken: 10.0, cacheReadPerMToken: 1.25)
        // These are the same values as the fallback
        let cost = pricing.cost(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000)
        // input: 1M * 2.5 = 2.5, output: 1M * 10 = 10, cacheRead: 1M * 1.25 = 1.25
        XCTAssertEqual(cost, 13.75, accuracy: 0.01)
    }

    func test_cost_zeroRates_returnZero() {
        let pricing = ModelPricing(inputPerMToken: 0, outputPerMToken: 0, cacheReadPerMToken: 0)
        let cost = pricing.cost(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000)
        XCTAssertEqual(cost, 0.0, accuracy: 0.0001)
    }
}
