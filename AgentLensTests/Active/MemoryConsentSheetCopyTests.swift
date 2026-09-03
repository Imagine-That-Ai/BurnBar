import XCTest
@testable import OpenBurnBar

/// The consent copy is a promise: the base sheet must no longer claim that
/// nothing ever leaves the device unconditionally, and the cloud-models sheet
/// must say who receives what and that BurnBar receives nothing.
final class MemoryConsentSheetCopyTests: XCTestCase {
    func testBaseConsentPointsAtTheCloudModelsSwitch() {
        XCTAssertEqual(
            MemoryConsentSheet.privacyBullet,
            "Nothing leaves your device unless you turn on cloud models in Settings → Privacy."
        )
    }

    func testCloudModelsConsentNamesTheBlindness() {
        let bullets = MemoryCloudModelsConsentSheet.bullets
        XCTAssertEqual(bullets.count, 4)
        XCTAssertTrue(bullets.contains { $0.contains("BurnBar never receives") })
        XCTAssertTrue(bullets.contains { $0.contains("Never sends raw transcripts") })
        XCTAssertTrue(bullets.contains { $0.contains("Off by default") })
    }
}
