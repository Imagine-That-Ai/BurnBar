import XCTest
@testable import OpenBurnBarCore

@MainActor
final class PretextEnginePolicyTests: XCTestCase {
    func testPrepareRejectsEmptyAndOversizedInputBeforeBridgeCall() async {
        do {
            _ = try await PretextEngine.shared.prepare(text: "", font: "14px -apple-system")
            XCTFail("Expected empty text to be rejected")
        } catch let error as PretextError {
            XCTAssertTrue(error.description.contains("input rejected"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            let huge = String(repeating: "x", count: 32_769)
            _ = try await PretextEngine.shared.prepare(text: huge, font: "14px -apple-system")
            XCTFail("Expected oversized text to be rejected")
        } catch let error as PretextError {
            XCTAssertTrue(error.description.contains("exceeds"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLayoutRejectsPathologicalDimensionsBeforeBridgeCall() async {
        do {
            _ = try await PretextEngine.shared.layout(
                handle: PretextHandle(id: 1),
                maxWidth: .infinity,
                lineHeight: 18
            )
            XCTFail("Expected infinite width to be rejected")
        } catch let error as PretextError {
            XCTAssertTrue(error.description.contains("max width"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRichInlineRejectsHugeItemListBeforeBridgeCall() async {
        let items = Array(
            repeating: PretextRichInlineItem(text: "x", font: "14px -apple-system"),
            count: 513
        )
        do {
            _ = try await PretextEngine.shared.prepareRichInline(items: items)
            XCTFail("Expected huge rich-inline list to be rejected")
        } catch let error as PretextError {
            XCTAssertTrue(error.description.contains("item count"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
