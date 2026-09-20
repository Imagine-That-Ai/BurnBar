import XCTest
@testable import OpenBurnBarMobile
import OpenBurnBarCore

@MainActor
final class InboxHomeChromeTests: XCTestCase {
    func testInboxHomeDoesNotShowASecondTitle() {
        XCTAssertEqual(InboxHomeChromePolicy.navigationTitle, "Inbox")
        XCTAssertFalse(
            InboxHomeChromePolicy.showsInPageHeadlineWhenHosted,
            "InboxHomeView owns the large title; the list must not repeat it."
        )
    }

    func testCompactIPhoneCanvasDefaultsMeshOff() {
        XCTAssertEqual(CompactIPhoneCanvas.auroraMeshStorageKey, "compactAuroraMeshEnabled")
        XCTAssertTrue(
            CompactIPhoneCanvas.usesQuietCanvas(
                compactAuroraMeshEnabled: false,
                isCompact: true,
                isEditorial: false
            )
        )
        XCTAssertTrue(
            CompactIPhoneCanvas.usesQuietCanvas(
                compactAuroraMeshEnabled: true,
                isCompact: false,
                isEditorial: false
            ),
            "iPad never gets the ember mesh from the iPhone opt-in."
        )
        XCTAssertFalse(
            CompactIPhoneCanvas.usesQuietCanvas(
                compactAuroraMeshEnabled: true,
                isCompact: true,
                isEditorial: false
            )
        )
    }
}
