import XCTest
@testable import OpenBurnBarMobile

final class ModelPurposeClassifierTests: XCTestCase {
    private struct GoldenFixture: Decodable {
        let name: String
        let signals: GoldenSignals
        let expected: String?
        let minConfidence: Double?
        let expectedFingerprint: String?
        let expectedSignal: String?
    }

    private struct GoldenSignals: Decodable {
        let fileExtensions: [String]?
        let keywords: [String]?
        let model: String?
        let appSurface: String?
        let hasErrorOutput: Bool?
        let hasCodeExecution: Bool?
        let hasSearchResults: Bool?
        let hasMultiStepPlanning: Bool?
    }

    func test_classifierGoldens_matchSharedFixture() throws {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)
        let fixtures = try JSONDecoder().decode([GoldenFixture].self, from: data)

        for fixture in fixtures {
            if fixture.expectedFingerprint != nil {
                continue
            }
            var signals = ModelPurposeClassifier.Signals(
                fileExtensions: fixture.signals.fileExtensions ?? [],
                keywords: fixture.signals.keywords ?? []
            )
            signals.model = fixture.signals.model
            signals.appSurface = fixture.signals.appSurface
            signals.hasErrorOutput = fixture.signals.hasErrorOutput ?? false
            signals.hasCodeExecution = fixture.signals.hasCodeExecution ?? false
            signals.hasSearchResults = fixture.signals.hasSearchResults ?? false
            signals.hasMultiStepPlanning = fixture.signals.hasMultiStepPlanning ?? false

            let result = ModelPurposeClassifier.classify(signals)
            if let expected = fixture.expected {
                XCTAssertEqual(result.category.rawValue, expected, fixture.name)
            }
            if let min = fixture.minConfidence {
                XCTAssertGreaterThanOrEqual(result.confidence, min, fixture.name)
            }
        }
    }

    func testModelBiasTieOrderMatchesCanonicalFixture() {
        let result = ModelPurposeClassifier.classifyModelBiasTieOrder()
        XCTAssertEqual(result.category, .research)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.2)
    }

    func test_deployKeyword_classifiesBackend() {
        let result = ModelPurposeClassifier.classify(
            ModelPurposeClassifier.Signals(keywords: ["deploy"])
        )
        XCTAssertEqual(result.category, .backend)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.5)
    }

    private func fixtureURL() throws -> URL {
        let monorepo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/classifier-goldens.json")
        if FileManager.default.fileExists(atPath: monorepo.path) {
            return monorepo
        }
        throw NSError(
            domain: "ModelPurposeClassifierTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing tests/fixtures/classifier-goldens.json"]
        )
    }
}
