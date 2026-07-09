import XCTest
@testable import OpenBurnBarMobile

final class ModelPurposeClassifierTests: XCTestCase {
    func testModelBiasTieOrderMatchesCanonicalFixture() {
        let result = ModelPurposeClassifier.classifyModelBiasTieOrder()
        XCTAssertEqual(result.category, .research)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.2)
    }
}