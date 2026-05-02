import Foundation
import XCTest
@testable import OpenBurnBarCore

final class BurnBarRunCreateMetadataTests: XCTestCase {
    func testJSONRoundTripPreservesKeysAndTypes() throws {
        let original = BurnBarRunCreateMetadata([
            "requiresApproval": .bool(true),
            "inputTokens": .number(12),
            "missionExecution": .bool(false),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BurnBarRunCreateMetadata.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.boolValue(forKey: "requiresApproval"), true)
        XCTAssertEqual(decoded.intValue(forKey: "inputTokens"), 12)
    }

    func testTypedKeySubscript() {
        var m = BurnBarRunCreateMetadata()
        m[.missionExecution] = .bool(true)
        XCTAssertEqual(m[.missionExecution], .bool(true))
        m[.missionExecution] = nil
        XCTAssertNil(m[.missionExecution])
    }
}
