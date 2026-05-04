import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

@MainActor
final class MercuryEnvelopeCardTests: XCTestCase {

    func test_rendersWithoutCrash() throws {
        let card = MercuryEnvelopeCard {
            Text("Encrypted")
        }
        XCTAssertNoThrow(try card.inspect())
    }

    func test_glyphIsAccessibilityHidden() throws {
        let glyph = MercuryGlyph(size: 14)
        XCTAssertNoThrow(try glyph.inspect())
    }
}
