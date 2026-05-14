import XCTest

final class AppStoreReviewComplianceTests: XCTestCase {
    func testMobileInfoPlistDeclaresCameraUsageDescriptionForTakePhotoFlow() throws {
        let plistURL = repoRoot()
            .appendingPathComponent("OpenBurnBarMobile")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let description = try XCTUnwrap(plist["NSCameraUsageDescription"] as? String)

        XCTAssertTrue(description.localizedCaseInsensitiveContains("Take Photo"))
        XCTAssertTrue(description.localizedCaseInsensitiveContains("Hermes chat"))
    }

    func testAppStoreMetadataContainsSubscriptionDisclosureAndLegalLinks() throws {
        let ascURL = repoRoot()
            .appendingPathComponent("tools")
            .appendingPathComponent("app-store-connect")
            .appendingPathComponent("asc-api.js")
        let metadata = try String(contentsOf: ascURL, encoding: .utf8)

        XCTAssertTrue(metadata.contains("OpenBurnBar Cloud Monthly"))
        XCTAssertTrue(metadata.contains("1 month, auto-renews monthly"))
        XCTAssertTrue(metadata.contains("Hosted Codex quota refresh"))
        XCTAssertTrue(metadata.contains("Privacy Policy: ${LEGAL_URLS.privacy}"))
        XCTAssertTrue(metadata.contains("Terms of Use: ${LEGAL_URLS.terms}"))
        XCTAssertTrue(metadata.contains("Guideline 2.1(a) camera crash fix"))
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "BurnBar", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
    }
}
