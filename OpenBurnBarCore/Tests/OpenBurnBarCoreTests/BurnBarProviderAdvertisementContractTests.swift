import XCTest
@testable import OpenBurnBarCore

/// Coverage for bulk advertisement muting — the provider-level "turn them all
/// off, then cherry-pick a few back on" flow.
final class BurnBarProviderAdvertisementContractTests: XCTestCase {

    private func settings() -> BurnBarProviderSettings {
        BurnBarProviderSettings(
            providerID: "minimax",
            isEnabled: true,
            baseURL: "https://api.minimax.io",
            preferredModelIDs: ["MiniMax-M2", "MiniMax-M2.1", "MiniMax-M2.5"]
        )
    }

    func testBulkDisableHidesEveryModel() {
        var s = settings()
        s.setModelsAdvertisement(modelIDs: ["MiniMax-M2", "MiniMax-M2.1", "MiniMax-M2.5"], isEnabled: false)
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2"))
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2.1"))
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2.5"))
    }

    func testBulkDisableThenSelectivelyReenableOne() {
        var s = settings()
        s.setModelsAdvertisement(modelIDs: ["MiniMax-M2", "MiniMax-M2.1", "MiniMax-M2.5"], isEnabled: false)
        s.setModelAdvertisement(modelID: "MiniMax-M2.1", isEnabled: true)
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2"))
        XCTAssertTrue(s.isModelAdvertisementEnabled("MiniMax-M2.1"))
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2.5"))
    }

    func testBulkEnableClearsAllDisables() {
        var s = settings()
        s.setModelsAdvertisement(modelIDs: ["MiniMax-M2", "MiniMax-M2.1"], isEnabled: false)
        s.setModelsAdvertisement(modelIDs: ["MiniMax-M2", "MiniMax-M2.1"], isEnabled: true)
        XCTAssertTrue(s.isModelAdvertisementEnabled("MiniMax-M2"))
        XCTAssertTrue(s.isModelAdvertisementEnabled("MiniMax-M2.1"))
    }

    func testBulkIsCaseInsensitiveAndIgnoresBlanks() {
        var s = settings()
        s.setModelsAdvertisement(modelIDs: ["minimax-m2", "  ", ""], isEnabled: false)
        XCTAssertFalse(s.isModelAdvertisementEnabled("MiniMax-M2"))
        // Blanks were ignored — only one entry recorded.
        XCTAssertEqual(s.disabledAdvertisedModelIDs.count, 1)
    }
}
