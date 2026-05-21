import XCTest
@testable import OpenBurnBarCore

final class HermesSourceLinkExtractorTests: XCTestCase {
    func testExtractsMarkdownHTTPLinksInOrder() {
        let links = HermesSourceLinkExtractor.extract(
            from: "Read [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) and [SwiftUI](https://developer.apple.com/xcode/swiftui/)."
        )

        XCTAssertEqual(links.map(\.title), ["Apple HIG", "SwiftUI"])
        XCTAssertEqual(links.map(\.displayHost), ["developer.apple.com", "developer.apple.com"])
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://developer.apple.com/design/human-interface-guidelines/",
            "https://developer.apple.com/xcode/swiftui/"
        ])
    }

    func testExtractsRawURLsAndTrimsSentencePunctuation() {
        let links = HermesSourceLinkExtractor.extract(
            from: "Source: https://example.com/docs/runtime?mode=ios). Next sentence."
        )

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].title, "example.com")
        XCTAssertEqual(links[0].url.absoluteString, "https://example.com/docs/runtime?mode=ios")
    }

    func testIgnoresBurnBarAtomLinksAndDeduplicatesRawCopy() {
        let text = "Open [session](burnbar://session?id=abc), then see [Docs](https://example.com/docs) or https://example.com/docs."
        let links = HermesSourceLinkExtractor.extract(from: text)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].title, "Docs")
        XCTAssertEqual(links[0].url.absoluteString, "https://example.com/docs")
    }

    func testCollapseExternalLinksForDisplayPreservesBurnBarAtoms() {
        let text = "See [Docs](https://example.com/docs) and [session](burnbar://session?id=abc), or https://openburnbar.com/release."
        let collapsed = HermesSourceLinkExtractor.collapseExternalLinksForDisplay(in: text)

        XCTAssertEqual(
            collapsed,
            "See Docs and [session](burnbar://session?id=abc), or openburnbar.com."
        )
    }
}
