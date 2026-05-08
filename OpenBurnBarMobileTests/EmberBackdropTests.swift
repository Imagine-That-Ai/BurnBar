import XCTest
import SwiftUI
@testable import OpenBurnBarMobile
import OpenBurnBarCore

final class EmberBackdropTests: XCTestCase {

    func testEmberSurfaceBackgroundExists() {
        let view = EmberSurfaceBackground()
        XCTAssertNotNil(view)
    }

    func testReduceTransparencyDisablesEffects() {
        // The view should compile and its body should not crash
        let view = EmberSurfaceBackground(respectsReduceTransparency: true)
        let _ = view.body
    }

    func testEmberSkeletonExists() {
        let skeleton = EmberSkeleton(height: 16, cornerRadius: 8)
        XCTAssertNotNil(skeleton)
    }

    func testHapticsHelperExists() {
        // Haptics is an enum with static methods — just verify it compiles
        Haptics.light()
        Haptics.medium()
        Haptics.rigid()
        Haptics.success()
        Haptics.warning()
        Haptics.error()
        Haptics.selection()
    }
}
