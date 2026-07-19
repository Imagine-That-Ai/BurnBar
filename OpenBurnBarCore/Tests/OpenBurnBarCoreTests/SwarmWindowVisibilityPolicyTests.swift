#if canImport(AppKit)
import AppKit
import XCTest
@testable import OpenBurnBarUI

@MainActor
final class SwarmWindowVisibilityPolicyTests: XCTestCase {
    func testVisibleOnScreenWindowIsActive() {
        XCTAssertTrue(
            SwarmWindowVisibilityPolicy.isActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: .visible
            )
        )
    }

    func testOccludedWindowIsInactive() {
        XCTAssertFalse(
            SwarmWindowVisibilityPolicy.isActive(
                isVisible: true,
                isMiniaturized: false,
                occlusionState: []
            )
        )
    }

    func testOrderedOffWindowIgnoresStaleVisibleBit() {
        XCTAssertFalse(
            SwarmWindowVisibilityPolicy.isActive(
                isVisible: false,
                isMiniaturized: false,
                occlusionState: .visible
            )
        )
    }

    func testMiniaturizedWindowIgnoresStaleVisibleBit() {
        XCTAssertFalse(
            SwarmWindowVisibilityPolicy.isActive(
                isVisible: true,
                isMiniaturized: true,
                occlusionState: .visible
            )
        )
    }
}
#endif
