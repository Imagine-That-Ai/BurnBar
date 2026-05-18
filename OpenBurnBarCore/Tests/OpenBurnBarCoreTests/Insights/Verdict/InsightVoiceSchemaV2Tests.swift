import XCTest
@testable import OpenBurnBarCore

final class InsightVoiceSchemaV2Tests: XCTestCase {

    func testSchemaIsValidJSON() throws {
        let data = Data(InsightVoiceSchemaV2.jsonSchema.utf8)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            return XCTFail("schema should decode to an object at the root")
        }
        XCTAssertEqual(dict["$id"] as? String,
                       "https://burnbar.ai/insights/voice-v2.schema.json")
        XCTAssertEqual(dict["type"] as? String, "object")
    }

    func testBannedPhrasesIncludeCorePhrasesFromPlan() {
        let needles = [
            "based on the data",
            "it seems that",
            "leveraging",
            "significant",
            "substantial",
            "notable",
            "robust",
            "in conclusion",
            "delve into",
            "harness the power"
        ]
        for needle in needles {
            XCTAssertTrue(
                InsightVoiceSchemaV2.bannedPhrases.contains(needle),
                "banned-phrase list is missing \(needle.debugDescription)"
            )
        }
    }

    func testAllowedActionIntentsMatchEnumCases() {
        let enumCases = Set(VerdictAcceptAction.Intent.allCases.map(\.rawValue))
        XCTAssertEqual(InsightVoiceSchemaV2.allowedActionIntents, enumCases)
    }

    func testSchemaDocumentEnumeratesAllBulletTypes() throws {
        let data = Data(InsightVoiceSchemaV2.jsonSchema.utf8)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = dict["properties"] as? [String: Any],
              let bullets = properties["bullets"] as? [String: Any],
              let items = bullets["items"] as? [String: Any],
              let bulletProps = items["properties"] as? [String: Any],
              let typeField = bulletProps["type"] as? [String: Any],
              let enumList = typeField["enum"] as? [String]
        else {
            return XCTFail("schema shape changed; update test")
        }
        let allTypes = Set(VerdictBulletType.allCases.map(\.rawValue))
        XCTAssertEqual(Set(enumList), allTypes)
    }
}
