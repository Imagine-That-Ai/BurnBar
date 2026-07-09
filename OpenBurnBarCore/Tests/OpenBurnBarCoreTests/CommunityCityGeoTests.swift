import XCTest
@testable import OpenBurnBarFirestoreModels

final class CommunityCityGeoTests: XCTestCase {
    private struct Golden: Decodable {
        let name: String
        let cityName: String
        let countryCode: String
        let regionCode: String
        let expected: String
    }

    func test_cityKeyGoldens_matchSharedFixture() throws {
        let url = try fixtureURL()
        let data = try Data(contentsOf: url)
        let goldens = try JSONDecoder().decode([Golden].self, from: data)

        for golden in goldens {
            let actual = CommunityCityGeo.canonicalizeCityKey(
                cityName: golden.cityName,
                countryCode: golden.countryCode,
                regionCode: golden.regionCode
            )
            XCTAssertEqual(actual, golden.expected, golden.name)
        }
    }

    func test_slugifyCity_truncationDoesNotEndWithHyphen() {
        let long = "alpha-beta-gamma-delta-epsilon-zeta-eta-theta-iota-kappa"
        let slug = CommunityCityGeo.slugifyCity(long)
        XCTAssertFalse(slug.hasSuffix("-"), "slug must not end with hyphen after truncation")
        XCTAssertLessThanOrEqual(slug.count, 40)
    }

    private func fixtureURL() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/city-key-goldens.json")
        if FileManager.default.fileExists(atPath: repo.path) {
            return repo
        }
        throw NSError(
            domain: "CommunityCityGeoTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing tests/fixtures/city-key-goldens.json"]
        )
    }
}
