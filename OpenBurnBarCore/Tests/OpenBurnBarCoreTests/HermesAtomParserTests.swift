import XCTest
@testable import OpenBurnBarCore

final class HermesAtomParserTests: XCTestCase {

    // MARK: - Markdown link extraction (Phase 1)

    func testParsesSingleMarkdownLink() {
        let runs = HermesAtomParser.parse("Today you spent [$2.34 today](burnbar://burn?window=today&amount=2.34) on chat.")
        // Expect: body, atom, body
        XCTAssertEqual(runs.count, 3)
        if case .body = runs[0].kind {} else { XCTFail("first run should be body") }
        guard case let .atom(atom, label) = runs[1].kind else {
            XCTFail("second run should be atom")
            return
        }
        XCTAssertEqual(label, "$2.34 today")
        if case .cost(let amount, let window) = atom {
            XCTAssertEqual(amount, 2.34, accuracy: 0.001)
            XCTAssertEqual(window, .today)
        } else {
            XCTFail("atom should be a cost")
        }
        if case .body = runs[2].kind {} else { XCTFail("third run should be body") }
    }

    func testParsesMultipleAtomsInSequence() {
        let text = "Open [session abc](burnbar://session?id=abc) using [Claude Sonnet 4.7](burnbar://model?id=claude-sonnet-4.7)."
        let runs = HermesAtomParser.parse(text)
        let atoms = runs.compactMap { $0.atom }
        XCTAssertEqual(atoms.count, 2)
        if case .session(let id) = atoms[0] {
            XCTAssertEqual(id, "abc")
        } else {
            XCTFail("first atom should be session")
        }
        if case .model(let id) = atoms[1] {
            XCTAssertEqual(id, "claude-sonnet-4.7")
        } else {
            XCTFail("second atom should be model")
        }
    }

    func testMalformedURLBecomesBody() {
        // burnbar://session without `id` is not decodable.
        let text = "See [session](burnbar://session) for details."
        let runs = HermesAtomParser.parse(text)
        // No atom should be produced; the entire string remains body.
        XCTAssertTrue(runs.allSatisfy { $0.atom == nil })
        let reconstructed = runs.map(\.text).joined()
        XCTAssertEqual(reconstructed, text)
    }

    func testNonBurnbarSchemeIsIgnored() {
        let text = "Visit [example](https://example.com) please."
        let runs = HermesAtomParser.parse(text)
        XCTAssertTrue(runs.allSatisfy { $0.atom == nil })
        let reconstructed = runs.map(\.text).joined()
        XCTAssertEqual(reconstructed, text)
    }

    func testEscapedLinkSyntaxIsLiteral() {
        let text = #"Use \[label](burnbar://session?id=abc) literally."#
        let runs = HermesAtomParser.parse(text)
        XCTAssertTrue(runs.allSatisfy { $0.atom == nil })
    }

    func testEmptyLabelFallsBackToAtomLabel() {
        let text = "Open [](burnbar://session?id=abc) here."
        let runs = HermesAtomParser.parse(text)
        let atoms = runs.compactMap { run -> (HermesAtom, String)? in
            if case let .atom(atom, label) = run.kind { return (atom, label) }
            return nil
        }
        XCTAssertEqual(atoms.count, 1)
        // Fallback uses first 8 chars of the session id.
        XCTAssertEqual(atoms[0].1, "session abc")
    }

    // MARK: - Regex fallback (Phase 2)

    func testDetectsDollarAmountInProse() {
        let runs = HermesAtomParser.parse("You spent $2.34 today.")
        let atoms = runs.compactMap { $0.atom }
        XCTAssertEqual(atoms.count, 1)
        if case let .cost(amount, _) = atoms[0] {
            XCTAssertEqual(amount, 2.34, accuracy: 0.001)
        } else {
            XCTFail("expected cost atom")
        }
    }

    func testDetectsCommaSeparatedDollarAmount() {
        let runs = HermesAtomParser.parse("Total: $1,234.56 today.")
        let atoms = runs.compactMap { $0.atom }
        XCTAssertEqual(atoms.count, 1)
        if case let .cost(amount, _) = atoms[0] {
            XCTAssertEqual(amount, 1234.56, accuracy: 0.001)
        } else {
            XCTFail("expected cost atom")
        }
    }

    func testDetectsKnownModelID() {
        let runs = HermesAtomParser.parse("I tested with claude-sonnet-4.7 on this run.")
        let atoms = runs.compactMap { $0.atom }
        XCTAssertEqual(atoms.count, 1)
        if case let .model(id) = atoms[0] {
            XCTAssertEqual(id, "claude-sonnet-4.7")
        } else {
            XCTFail("expected model atom")
        }
    }

    func testIgnoresUnknownModelID() {
        let runs = HermesAtomParser.parse("Tried xyz-99-banana but it failed.")
        XCTAssertTrue(runs.allSatisfy { $0.atom == nil })
    }

    // MARK: - Mentions and code

    func testParsesMention() {
        let runs = HermesAtomParser.parse("Ping @maya on this thread.")
        let mentions = runs.compactMap { run -> String? in
            if case let .mention(handle) = run.kind { return handle }
            return nil
        }
        XCTAssertEqual(mentions, ["@maya"])
    }

    func testEmailIsNotMention() {
        let runs = HermesAtomParser.parse("Email me at maya@example.com please.")
        let mentions = runs.compactMap { run -> String? in
            if case let .mention(handle) = run.kind { return handle }
            return nil
        }
        XCTAssertTrue(mentions.isEmpty, "should not detect email as mention")
    }

    func testParsesInlineCode() {
        let runs = HermesAtomParser.parse("Look at the `parseRuns` function.")
        let codes = runs.compactMap { run -> String? in
            if case .code = run.kind { return run.text }
            return nil
        }
        XCTAssertEqual(codes, ["parseRuns"])
    }

    func testUnclosedBacktickIsBody() {
        let runs = HermesAtomParser.parse("Opened ` but no close")
        XCTAssertTrue(runs.allSatisfy { run in
            if case .code = run.kind { return false }
            return true
        })
    }

    // MARK: - Mixed content + ordering

    func testMixedAtomsMentionsCodePreservesOrder() {
        let text = "Hi @maya — open [$2.34 today](burnbar://burn?window=today&amount=2.34) and run `git status`."
        let runs = HermesAtomParser.parse(text)
        var seenKinds: [String] = []
        for run in runs {
            switch run.kind {
            case .body:    seenKinds.append("body")
            case .mention: seenKinds.append("mention")
            case .atom:    seenKinds.append("atom")
            case .code:    seenKinds.append("code")
            }
        }
        XCTAssertEqual(seenKinds, ["body", "mention", "body", "atom", "body", "code", "body"])
    }

    func testLayoutPreservesBodyAndMentionCharacters() {
        // For body+mention (no atoms, no code spans), concatenation should
        // equal the original input. Code spans strip their surrounding
        // backticks by design — they're presentation chrome, not source
        // text.
        let text = "Look @maya — jump in."
        let runs = HermesAtomParser.parse(text)
        let reconstructed = runs.map(\.text).joined()
        XCTAssertEqual(reconstructed, text)
    }

    func testCodeSpanRunStripsBackticks() {
        let text = "Run `git status` first."
        let runs = HermesAtomParser.parse(text)
        // Reconstructing prose should drop the backticks since `text` field
        // on a code run is the inner body — the span is rendered with
        // chrome by the view layer.
        let reconstructed = runs.map(\.text).joined()
        XCTAssertEqual(reconstructed, "Run git status first.")
    }

    // MARK: - URL codec round-trip

    func testURLCodecRoundTrip() {
        let inputs: [HermesAtom] = [
            .cost(amount: 2.34, window: .today),
            .session(id: "abc-123"),
            .provider(token: "anthropic"),
            .model(id: "claude-sonnet-4.7"),
            .window(.sevenDays),
            .tool(name: "ReadFile"),
            .project(id: "BurnBar"),
            .tokens(value: 12_400, scope: .session),
            .quota(provider: "anthropic", percent: 78),
            .runtime(profile: "hermes")
        ]
        for atom in inputs {
            let url = HermesAtomURL.encode(atom)
            guard let decoded = HermesAtomURL.decode(url) else {
                XCTFail("failed to decode \(url)")
                continue
            }
            XCTAssertEqual(decoded, atom)
        }
    }

    // MARK: - System prompt builder

    func testSystemPromptIncludesDirectiveByDefault() {
        let prompt = HermesSystemPromptBuilder().build()
        XCTAssertTrue(prompt.contains("burnbar://"))
        XCTAssertTrue(prompt.contains("Atom URL forms"))
    }

    func testSystemPromptCanDisableDirective() {
        let prompt = HermesSystemPromptBuilder(includesAtomDirective: false).build()
        XCTAssertFalse(prompt.contains("burnbar://"))
    }

    func testSystemPromptOrdersPreambleDirectiveContext() {
        let prompt = HermesSystemPromptBuilder(
            dashboardContext: "Today: $2.34",
            includesAtomDirective: true,
            preamble: "You are an assistant."
        ).build()
        let preambleRange = prompt.range(of: "You are an assistant.")
        let directiveRange = prompt.range(of: "Atom URL forms")
        let contextRange = prompt.range(of: "Today: $2.34")
        XCTAssertNotNil(preambleRange)
        XCTAssertNotNil(directiveRange)
        XCTAssertNotNil(contextRange)
        XCTAssertLessThan(preambleRange!.lowerBound, directiveRange!.lowerBound)
        XCTAssertLessThan(directiveRange!.lowerBound, contextRange!.lowerBound)
    }

    // MARK: - Unicode + percent-encoded labels

    func testParsesAtomWithPercentEncodedSessionID() {
        // `abc 123` → `abc%20123` after URL encoding. Decoder should recover
        // the original space-separated identifier.
        let text = "Open [session abc 123](burnbar://session?id=abc%20123) for the diff."
        let runs = HermesAtomParser.parse(text)
        let atoms = runs.compactMap { $0.atom }
        XCTAssertEqual(atoms.count, 1)
        if case let .session(id) = atoms[0] {
            XCTAssertEqual(id, "abc 123")
        } else {
            XCTFail("expected session atom")
        }
    }

    func testParsesAtomWithEmojiInLabel() {
        // Labels are user-visible and may contain emoji or any Unicode
        // grapheme. They must round-trip through the parser unchanged.
        let text = "Tap [\u{1F525} today](burnbar://burn?window=today&amount=1) please."
        let runs = HermesAtomParser.parse(text)
        guard case let .atom(atom, label) = runs[1].kind else {
            XCTFail("expected atom run")
            return
        }
        XCTAssertEqual(label, "\u{1F525} today")
        if case .cost = atom {} else { XCTFail("expected cost atom") }
    }

    func testParsesAtomWithUnicodeProjectID() {
        // Project IDs frequently contain non-ASCII (Cyrillic, CJK, etc.).
        // The decoder treats anything URL-encoded as opaque payload — it
            // should restore the original identifier byte-for-byte.
        let project = "\u{4E2D}\u{6587}\u{9879}\u{76EE}" // 中文项目
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let text = "Open [the project](burnbar://project?id=\(encoded)) please."
        let runs = HermesAtomParser.parse(text)
        guard case let .atom(atom, _) = runs[1].kind, case let .project(id) = atom else {
            XCTFail("expected project atom")
            return
        }
        XCTAssertEqual(id, project)
    }

    // MARK: - URL codec edge cases

    func testURLCodecRejectsForeignScheme() {
        let url = URL(string: "https://example.com/path?atom=1")!
        XCTAssertNil(HermesAtomURL.decode(url))
    }

    func testURLCodecRejectsUnknownHost() {
        let url = URL(string: "burnbar://nonsense?id=abc")!
        XCTAssertNil(HermesAtomURL.decode(url))
    }

    func testURLCodecRejectsEmptySessionID() {
        let url = URL(string: "burnbar://session?id=")!
        XCTAssertNil(HermesAtomURL.decode(url))
    }

    // MARK: - Router contract

    func testNoopNavigatorIsCallableFromAnyContext() {
        // Sanity: the default no-op navigator must not crash when invoked
            // — it only logs. This is the value SwiftUI uses by default.
        let navigator: any HermesAtomNavigator = NoopHermesAtomNavigator()
        let expectation = expectation(description: "open returns")
        Task { @MainActor in
            navigator.open(.session(id: "abc"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
