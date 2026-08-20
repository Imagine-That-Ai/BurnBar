import XCTest
import GRDB
@testable import OpenBurnBar

/// The floating chat panel is a portrait column. These tests pin that shape so a
/// stored landscape size, or a wide resize drag, can never bring the horizontal
/// slab back.
@MainActor
final class ChatPanelGeometryTests: XCTestCase {

    // MARK: - Shape invariant

    func test_defaultSizeIsPortrait() {
        XCTAssertTrue(
            ChatPanelGeometry.isPortrait(ChatPanelGeometry.defaultSize),
            "The shipped default must satisfy the same rule we enforce on user geometry"
        )
        XCTAssertGreaterThan(
            ChatPanelGeometry.defaultSize.height,
            ChatPanelGeometry.defaultSize.width,
            "Default panel should read as a vertical column"
        )
    }

    func test_ratioCapKeepsTheColumnTallerThanItIsWide() {
        XCTAssertLessThan(
            ChatPanelGeometry.maxWidthToHeightRatio,
            1,
            "A cap of 1 or more would permit a square or landscape panel"
        )
    }

    func test_clampAlwaysProducesAPortraitSize() {
        let proposals: [CGSize] = [
            CGSize(width: 720, height: 440),   // the landscape slab users ended up with
            CGSize(width: 2_000, height: 300), // absurdly wide
            CGSize(width: 10, height: 10),     // collapsed
            CGSize(width: 380, height: 640),   // already good
            CGSize(width: 520, height: 980),   // both maxima
            CGSize(width: -50, height: -50)    // nonsense
        ]

        for proposal in proposals {
            let clamped = ChatPanelGeometry.clamp(proposal)
            XCTAssertTrue(
                ChatPanelGeometry.isPortrait(clamped),
                "clamp(\(proposal)) returned \(clamped), which is not portrait"
            )
            XCTAssertTrue(
                ChatPanelGeometry.heightRange.contains(clamped.height),
                "clamp(\(proposal)) height \(clamped.height) escaped \(ChatPanelGeometry.heightRange)"
            )
            XCTAssertTrue(
                ChatPanelGeometry.widthRange.contains(clamped.width),
                "clamp(\(proposal)) width \(clamped.width) escaped \(ChatPanelGeometry.widthRange)"
            )
        }
    }

    func test_clampIsIdempotent() {
        let once = ChatPanelGeometry.clamp(CGSize(width: 900, height: 500))
        let twice = ChatPanelGeometry.clamp(once)
        XCTAssertEqual(once, twice, "Re-clamping a clamped size must not drift")
    }

    func test_clampPreservesASizeAlreadyInsideTheEnvelope() {
        let inside = CGSize(width: 400, height: 700)
        XCTAssertEqual(ChatPanelGeometry.clamp(inside), inside)
    }

    // MARK: - Restoring persisted geometry

    func test_storedLandscapeGeometryIsRetiredForTheDefault() {
        // 720x440 is the exact geometry found persisted in a real profile; it
        // survived earlier redesigns because restore honored whatever was stored.
        let restored = ChatPanelGeometry.restored(width: 720, height: 440)
        XCTAssertEqual(restored, ChatPanelGeometry.defaultSize)
    }

    func test_missingGeometryFallsBackToTheDefault() {
        XCTAssertEqual(ChatPanelGeometry.restored(width: 0, height: 0), ChatPanelGeometry.defaultSize)
        XCTAssertEqual(ChatPanelGeometry.restored(width: 380, height: 0), ChatPanelGeometry.defaultSize)
        XCTAssertEqual(ChatPanelGeometry.restored(width: 0, height: 640), ChatPanelGeometry.defaultSize)
    }

    func test_aDeliberatePortraitSizeIsKept() {
        let restored = ChatPanelGeometry.restored(width: 420, height: 820)
        XCTAssertEqual(restored, CGSize(width: 420, height: 820), "User's own portrait sizing must survive relaunch")
    }

    func test_outOfRangePortraitGeometryIsPulledIntoRangeNotDiscarded() {
        let restored = ChatPanelGeometry.restored(width: 320, height: 2_400)
        XCTAssertEqual(restored.height, ChatPanelGeometry.heightRange.upperBound)
        XCTAssertTrue(ChatPanelGeometry.isPortrait(restored))
    }

    // MARK: - Controller wiring

    func test_controllerStartsPortraitEvenWhenDefaultsHoldALandscapeSlab() throws {
        let widthKey = ChatSessionController.udPanelW
        let heightKey = ChatSessionController.udPanelH
        let priorWidth = UserDefaults.standard.object(forKey: widthKey)
        let priorHeight = UserDefaults.standard.object(forKey: heightKey)
        defer {
            UserDefaults.standard.set(priorWidth, forKey: widthKey)
            UserDefaults.standard.set(priorHeight, forKey: heightKey)
        }

        UserDefaults.standard.set(720.0, forKey: widthKey)
        UserDefaults.standard.set(440.0, forKey: heightKey)

        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), runMigrations: false))
        let controller = ChatSessionController(dataStore: store, settingsManager: SettingsManager())

        XCTAssertEqual(controller.panelWidth, ChatPanelGeometry.defaultSize.width)
        XCTAssertEqual(controller.panelHeight, ChatPanelGeometry.defaultSize.height)
        XCTAssertTrue(
            ChatPanelGeometry.isPortrait(CGSize(width: controller.panelWidth, height: controller.panelHeight))
        )
    }
}
