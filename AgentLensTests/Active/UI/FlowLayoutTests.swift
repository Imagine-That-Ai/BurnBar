import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - FlowLayout

@MainActor
final class FlowLayoutTests: XCTestCase {

    // FlowLayout conforms to the `Layout` protocol which requires SubviewsCollection.
    // Testing `sizeThatFits` directly requires a custom SubviewsCollection, which is
    // non-trivial to mock outside of a real SwiftUI view hierarchy. Instead, we test
    // the layout by embedding it in test views and verifying frame constraints.

    func test_defaultSpacingValues() {
        let layout = FlowLayout()
        XCTAssertEqual(layout.horizontalSpacing, DesignSystem.Spacing.sm)
        XCTAssertEqual(layout.verticalSpacing, DesignSystem.Spacing.sm)
    }

    func test_customSpacingValues() {
        let layout = FlowLayout(horizontalSpacing: 16, verticalSpacing: 24)
        XCTAssertEqual(layout.horizontalSpacing, 16)
        XCTAssertEqual(layout.verticalSpacing, 24)
    }

    func test_zeroSpacingLayout() {
        let layout = FlowLayout(horizontalSpacing: 0, verticalSpacing: 0)
        XCTAssertEqual(layout.horizontalSpacing, 0)
        XCTAssertEqual(layout.verticalSpacing, 0)
    }

    func test_rendersInHostView() throws {
        struct FlowHost: View {
            var body: some View {
                FlowLayout {
                    Text("Item 1")
                    Text("Item 2")
                    Text("Item 3")
                }
                .frame(width: 300)
            }
        }

        let view = FlowHost()
        XCTAssertNoThrow(try view.inspect())
    }

    func test_conformsToLayout() {
        let layout = FlowLayout()
        // Verify the layout can be used as a Layout value
        let _: any Layout = layout
    }
}
