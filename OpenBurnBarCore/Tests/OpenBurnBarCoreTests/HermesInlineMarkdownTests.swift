import XCTest
@testable import OpenBurnBarCore

/// Phase-3 coverage: inline markdown emphasis, heading/bullet normalization,
/// and the `plainText` flattening used by notification banners and thread
/// previews. The first test is the literal device-test repro — Hermes
/// replying `**Hello!**` used to surface raw asterisks in the reply banner.
final class HermesInlineMarkdownTests: XCTestCase {

    private func bodyRuns(_ text: String) -> [(text: String, style: HermesInlineStyle)] {
        HermesAtomParser.parse(text).compactMap { run in
            if case let .body(style) = run.kind { return (run.text, style) }
            return nil
        }
    }

    // MARK: - Bold (the screenshot repro)

    func testBoldHelloRendersWithoutAsterisks() {
        let runs = HermesAtomParser.parse("**Hello!**")
        XCTAssertEqual(runs.count, 1)
        guard case let .body(style) = runs[0].kind else {
            XCTFail("expected body run")
            return
        }
        XCTAssertEqual(runs[0].text, "Hello!")
        XCTAssertEqual(style, .bold)
    }

    func testBoldMidSentence() {
        let runs = bodyRuns("This is **important** stuff.")
        XCTAssertEqual(runs.map(\.text), ["This is ", "important", " stuff."])
        XCTAssertEqual(runs.map(\.style), [[], .bold, []])
    }

    func testDoubleUnderscoreBold() {
        let runs = bodyRuns("__heavy__ lifting")
        XCTAssertEqual(runs.map(\.text), ["heavy", " lifting"])
        XCTAssertEqual(runs[0].style, .bold)
    }

    // MARK: - Italic

    func testAsteriskItalic() {
        let runs = bodyRuns("an *emphasized* word")
        XCTAssertEqual(runs.map(\.text), ["an ", "emphasized", " word"])
        XCTAssertEqual(runs[1].style, .italic)
    }

    func testUnderscoreItalicRespectsWordBoundaries() {
        // `snake_case_name` must never italicize.
        let runs = bodyRuns("use snake_case_name here")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "use snake_case_name here")
        XCTAssertEqual(runs[0].style, [])
    }

    func testUnderscoreItalicAtWordBoundary() {
        let runs = bodyRuns("an _emphasized_ word")
        XCTAssertEqual(runs.map(\.text), ["an ", "emphasized", " word"])
        XCTAssertEqual(runs[1].style, .italic)
    }

    func testTripleAsteriskBoldItalic() {
        let runs = bodyRuns("***loud*** noises")
        XCTAssertEqual(runs.map(\.text), ["loud", " noises"])
        XCTAssertEqual(runs[0].style, [.bold, .italic])
    }

    // MARK: - Strikethrough

    func testStrikethrough() {
        let runs = bodyRuns("that idea is ~~dead~~ parked")
        XCTAssertEqual(runs.map(\.text), ["that idea is ", "dead", " parked"])
        XCTAssertEqual(runs[1].style, .strikethrough)
    }

    // MARK: - Nesting

    func testNestedItalicInsideBold() {
        let runs = bodyRuns("**bold with *nested* inside**")
        XCTAssertEqual(runs.map(\.text), ["bold with ", "nested", " inside"])
        XCTAssertEqual(runs.map(\.style), [.bold, [.bold, .italic], .bold])
    }

    // MARK: - Literal fallbacks (unmatched / math)

    func testUnmatchedMarkersStayLiteral() {
        let runs = bodyRuns("a ** b stays literal")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "a ** b stays literal")
    }

    func testMultiplicationStaysLiteral() {
        // `* ` openers (whitespace after) never start emphasis.
        let runs = bodyRuns("2 * 3 * 4 = 24")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "2 * 3 * 4 = 24")
    }

    func testSpansDoNotCrossLines() {
        let runs = bodyRuns("dangling **bold\nnever closes**")
        XCTAssertTrue(runs.allSatisfy { $0.style.isEmpty })
        XCTAssertEqual(runs.map(\.text).joined(), "dangling **bold\nnever closes**")
    }

    // MARK: - Headings

    func testHeadingLineRendersBoldWithoutHashes() {
        let runs = bodyRuns("### Summary\nAll good.")
        XCTAssertEqual(runs.map(\.text), ["Summary", "\nAll good."])
        XCTAssertEqual(runs.map(\.style), [.bold, []])
    }

    func testHashWithoutSpaceIsLiteral() {
        let runs = bodyRuns("#hashtag stays")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "#hashtag stays")
    }

    func testHeadingOnlyAtLineStart() {
        let runs = bodyRuns("see issue # 42 today")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].text, "see issue # 42 today")
    }

    // MARK: - Bullets

    func testBulletMarkersBecomeGlyphs() {
        let runs = bodyRuns("- one\n- two")
        XCTAssertEqual(runs.map(\.text).joined(), "• one\n• two")
    }

    func testIndentedBulletKeepsIndent() {
        let runs = bodyRuns("  - nested item")
        XCTAssertEqual(runs.map(\.text).joined(), "  • nested item")
    }

    func testHorizontalRuleStaysLiteral() {
        // `---` has no space after the marker — not a bullet.
        let runs = bodyRuns("---")
        XCTAssertEqual(runs.map(\.text).joined(), "---")
    }

    // MARK: - Interplay with phases 1–2

    func testBoldAroundCostAtomKeepsAtom() {
        let runs = HermesAtomParser.parse("**Total:** $2.34 today")
        guard case let .body(style) = runs[0].kind else {
            XCTFail("expected body run first")
            return
        }
        XCTAssertEqual(runs[0].text, "Total:")
        XCTAssertEqual(style, .bold)
        XCTAssertEqual(runs.compactMap(\.atom).count, 1)
    }

    func testCodeSpanContentIsNeverEmphasized() {
        let runs = HermesAtomParser.parse("run `**not bold**` now")
        let codes = runs.filter { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(codes.map(\.text), ["**not bold**"])
    }

    func testEmphasisAfterAtomChip() {
        let runs = HermesAtomParser.parse(
            "Open [session abc](burnbar://session?id=abc) — it is **done**."
        )
        guard case let .body(style) = runs[2].kind else {
            XCTFail("expected body run after atom")
            return
        }
        XCTAssertEqual(runs[2].text, " — it is ")
        XCTAssertEqual(style, [])
        guard case let .body(boldStyle) = runs[3].kind else {
            XCTFail("expected bold run")
            return
        }
        XCTAssertEqual(runs[3].text, "done")
        XCTAssertEqual(boldStyle, .bold)
    }

    func testHeadingDirectlyAfterNewlineFollowingChip() {
        // An atom chip ends mid-line; the heading on the NEXT line must
        // still normalize.
        let runs = HermesAtomParser.parse(
            "See [session abc](burnbar://session?id=abc)\n## Next steps\nShip it."
        )
        let bodies = runs.compactMap { run -> (String, HermesInlineStyle)? in
            if case let .body(style) = run.kind { return (run.text, style) }
            return nil
        }
        XCTAssertTrue(bodies.contains(where: { $0.0 == "Next steps" && $0.1 == .bold }))
    }

    // MARK: - plainText flattening (notification previews)

    func testPlainTextStripsBoldMarkers() {
        XCTAssertEqual(HermesAtomParser.plainText("**Hello!**"), "Hello!")
    }

    func testPlainTextFlattensMixedMarkdown() {
        XCTAssertEqual(
            HermesAtomParser.plainText("### Done\n- *one*\n- `two`"),
            "Done\n• one\n• two"
        )
    }

    func testPlainTextKeepsAtomLabels() {
        XCTAssertEqual(
            HermesAtomParser.plainText("Spent [$2.34 today](burnbar://burn?window=today&amount=2.34)."),
            "Spent $2.34 today."
        )
    }

    func testPlainTextLeavesPlainProseUntouched() {
        let prose = "No markdown here, just words."
        XCTAssertEqual(HermesAtomParser.plainText(prose), prose)
    }

    // MARK: - AttributedString rendering (cards / banners)

    func testAttributedStringDropsMarkersAndAppliesIntents() {
        let attributed = HermesInlineMarkdown.attributedString("**Hello!** and *more*")
        XCTAssertEqual(String(attributed.characters), "Hello! and more")
        let runs = attributed.runs.compactMap { run -> InlinePresentationIntent? in
            run.inlinePresentationIntent
        }
        XCTAssertTrue(runs.contains(.stronglyEmphasized))
        XCTAssertTrue(runs.contains(.emphasized))
    }

    func testAttributedStringRendersCodeIntent() {
        let attributed = HermesInlineMarkdown.attributedString("run `git status` now")
        XCTAssertEqual(String(attributed.characters), "run git status now")
        let intents = attributed.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains(.code))
    }
}
