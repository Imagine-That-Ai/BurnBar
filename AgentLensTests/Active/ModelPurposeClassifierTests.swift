import XCTest
@testable import OpenBurnBar

final class ModelPurposeClassifierTests: XCTestCase {
    private struct GoldenFixture: Decodable {
        let name: String
        let signals: GoldenSignals
        let expected: String?
        let minConfidence: Double?
        let expectedFingerprint: String?
        let expectedSignal: String?
        let corrections: [GoldenCorrection]?
    }

    private struct GoldenSignals: Decodable {
        let fileExtensions: [String]?
        let model: String?
        let appSurface: String?
        let hasCodeExecution: Bool?
        let hasErrorOutput: Bool?
        let hasSearchResults: Bool?
        let hasMultiStepPlanning: Bool?
        let keywords: [String]?
    }

    private struct GoldenCorrection: Decodable {
        let fingerprint: String
        let correctedTo: String
    }

    func test_classifierGoldens() throws {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)
        let fixtures = try JSONDecoder().decode([GoldenFixture].self, from: data)

        for fixture in fixtures {
            let signals = ClassifierSignals(
                fileExtensions: fixture.signals.fileExtensions,
                model: fixture.signals.model,
                appSurface: fixture.signals.appSurface,
                hasCodeExecution: fixture.signals.hasCodeExecution,
                hasErrorOutput: fixture.signals.hasErrorOutput,
                hasSearchResults: fixture.signals.hasSearchResults,
                hasMultiStepPlanning: fixture.signals.hasMultiStepPlanning,
                keywords: fixture.signals.keywords
            )

            if let expectedFingerprint = fixture.expectedFingerprint {
                XCTAssertEqual(
                    ModelPurposeClassifier.signalFingerprint(signals),
                    expectedFingerprint,
                    fixture.name
                )
                continue
            }

            let corrections: [PurposeCorrection] = (fixture.corrections ?? []).compactMap { row in
                guard let cat = ModelPurposeCategory(rawValue: row.correctedTo) else { return nil }
                return PurposeCorrection(fingerprint: row.fingerprint, correctedTo: cat)
            }

            let result = ModelPurposeClassifier.classifyPurpose(signals, corrections: corrections)

            if let expected = fixture.expected {
                XCTAssertEqual(result.category.rawValue, expected, fixture.name)
            }
            if let min = fixture.minConfidence {
                XCTAssertGreaterThanOrEqual(result.confidence, min, fixture.name)
            }
            if let expectedSignal = fixture.expectedSignal {
                XCTAssertTrue(
                    result.contributingSignals.contains(expectedSignal),
                    "\(fixture.name): expected \(expectedSignal) in \(result.contributingSignals)"
                )
            }
        }
    }

    private func fixtureURL() throws -> URL {
        let bundle = Bundle(for: ModelPurposeClassifierTests.self)
        if let url = bundle.url(forResource: "classifier-goldens", withExtension: "json") {
            return url
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/classifier-goldens.json")
        if FileManager.default.fileExists(atPath: repo.path) {
            return repo
        }
        let monorepo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/classifier-goldens.json")
        return monorepo
    }
}