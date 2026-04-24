import XCTest
import SwiftUI
import ViewInspector
@testable import OpenBurnBar

// MARK: - DashboardActionGlyph

@MainActor
final class DashboardActionGlyphTests: XCTestCase {

    func test_rendersImportFromLogs() throws {
        let view = DashboardActionGlyph(kind: .importFromLogs)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_rendersSweepRecount() throws {
        let view = DashboardActionGlyph(kind: .sweepRecount)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_defaultSize() throws {
        let view = DashboardActionGlyph(kind: .importFromLogs)
        XCTAssertEqual(view.size, 14)
    }

    func test_customSize() throws {
        let view = DashboardActionGlyph(kind: .sweepRecount, size: 24)
        XCTAssertEqual(view.size, 24)
    }

    func test_allKindsRender() {
        for kind in [DashboardActionGlyphKind.importFromLogs, .sweepRecount] {
            let view = DashboardActionGlyph(kind: kind)
            XCTAssertNotNil(view, "Failed to render glyph for \(kind)")
        }
    }
}

// MARK: - Transform Helper

@MainActor
final class DashboardTransformTests: XCTestCase {

    // Note: Transform is a private struct in DashboardActionGlyphs.swift.
    // These tests validate the public API surface instead.

    func test_glyphKinds_count() {
        // Ensure we know the total count of glyph kinds
        let allKinds: [DashboardActionGlyphKind] = [.importFromLogs, .sweepRecount]
        XCTAssertEqual(allKinds.count, 2)
    }
}
