import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarTextExpansion

final class TextExpansionTests: XCTestCase {
    func testTriggerNormalizationAndValidation() {
        XCTAssertEqual(TextExpansionTrigger.canonicalName("&&Confident"), "confident")
        XCTAssertEqual(TextExpansionTrigger.activationToken(for: "confident"), "&&confident")
        XCTAssertNil(TextExpansionTrigger.validationError(for: "confident_reply"))
        XCTAssertNil(TextExpansionTrigger.validationError(for: "follow-up_2"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "too short"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "with space"))
        XCTAssertNotNil(TextExpansionTrigger.validationError(for: "bad$"))
    }

    func testStaticExpansionReplacesTokenAndPreservesBoundary() {
        let snippet = TextExpansionSnippet(
            title: "Confident",
            trigger: "confident",
            body: "I'm confident this is the right next step."
        )

        let result = TextExpansionMatcher.expandStaticIfAvailable(
            in: "Send &&confident ",
            snippets: [snippet],
            surface: .inAppThread
        )

        XCTAssertEqual(result?.text, "Send I'm confident this is the right next step. ")
        XCTAssertEqual(result?.match.token, "&&confident")
        XCTAssertEqual(result?.match.boundary, " ")
    }

    func testStaticExpansionTreatsSentencePunctuationAsBoundary() {
        let snippet = TextExpansionSnippet(title: "Thanks", trigger: "thanks", body: "Thank you")

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "Send &&thanks.",
            snippets: [snippet],
            surface: .inAppThread
        )?.text, "Send Thank you.")
    }

    func testDoesNotExpandPrefixCollisionBeforeBoundary() {
        let short = TextExpansionSnippet(title: "Pro", trigger: "pro", body: "professional")
        let long = TextExpansionSnippet(title: "Proposal", trigger: "proposal", body: "proposal draft")

        XCTAssertNil(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&pro",
            snippets: [short, long],
            surface: .inAppThread
        ))

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&pro ",
            snippets: [short, long],
            surface: .inAppThread
        )?.text, "professional ")
    }

    func testUnambiguousTokenCanExpandWithoutBoundary() {
        let snippet = TextExpansionSnippet(title: "Confident", trigger: "confident", body: "Ready.")

        XCTAssertEqual(TextExpansionMatcher.expandStaticIfAvailable(
            in: "&&confident",
            snippets: [snippet],
            surface: .inAppThread
        )?.text, "Ready.")
    }

    func testLLMModeReturnsPreviewMatchInsteadOfExpanding() {
        let snippet = TextExpansionSnippet(
            title: "Contextual",
            trigger: "ctx",
            body: "Make this fit.",
            mode: .llmRewrite
        )

        let match = TextExpansionMatcher.match(
            in: "Please &&ctx ",
            snippets: [snippet],
            surface: .inAppThread
        )

        XCTAssertEqual(match?.token, "&&ctx")
        XCTAssertEqual(match?.requiresPreview, true)
        XCTAssertNil(TextExpansionMatcher.expandStaticIfAvailable(
            in: "Please &&ctx ",
            snippets: [snippet],
            surface: .inAppThread
        ))
    }

    #if canImport(AppKit)
    func testKeyEventCharactersFallsBackToAmpersandForShiftedSeven() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "&",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 26
        )
        XCTAssertEqual(TextExpansionKeyEventCharacters.characters(from: event!), "&")
    }

    func testKeyEventCharactersPrefersLayoutResolvedShiftedSymbol() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "&",
            charactersIgnoringModifiers: "7",
            isARepeat: false,
            keyCode: 26
        )
        XCTAssertEqual(TextExpansionKeyEventCharacters.characters(from: event!), "&")
    }

    func testUSKeyboardMapResolvesShiftedNumberRowSymbols() {
        // Shift+7 (keyCode 26) must resolve to "&" so the `&&` trigger prefix can build up
        // even when an event carries no unicode payload — the original global-tap bug.
        XCTAssertEqual(TextExpansionKeyEventCharacters.usKeyboardCharacter(keyCode: 26, shift: true), "&")
        XCTAssertEqual(TextExpansionKeyEventCharacters.usKeyboardCharacter(keyCode: 26, shift: false), "7")
        XCTAssertEqual(TextExpansionKeyEventCharacters.usKeyboardCharacter(keyCode: 49, shift: false), " ")
        XCTAssertEqual(TextExpansionKeyEventCharacters.usKeyboardCharacter(keyCode: 0, shift: false), "a")
    }

    func testCGEventCharacterExtractionPrefersUnicodePayload() throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 26, keyDown: true) else {
            throw XCTSkip("CGEvent creation unavailable in this environment")
        }
        event.flags = .maskShift
        var unicode: [UniChar] = Array("&".utf16)
        event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
        XCTAssertEqual(TextExpansionKeyEventCharacters.characters(fromCGEvent: event), "&")
    }
    #endif

    func testGlobalReplacementPlannerDeletesBoundaryCharacterAfterPassThrough() {
        let snippet = TextExpansionSnippet(title: "Audit", trigger: "audit", body: "Audit body")
        let match = TextExpansionMatch(
            snippet: snippet,
            token: "&&audit",
            replacementRange: "&&audit".startIndex..<"&&audit".endIndex,
            boundary: " ",
            requiresPreview: false
        )

        XCTAssertEqual(
            TextExpansionGlobalReplacementPlanner.plan(for: match),
            TextExpansionGlobalReplacementPlanner.Plan(deleteCount: 8, replacement: "Audit body ")
        )

        let unambiguous = TextExpansionMatch(
            snippet: snippet,
            token: "&&audit",
            replacementRange: "&&audit".startIndex..<"&&audit".endIndex,
            boundary: nil,
            requiresPreview: false
        )
        XCTAssertEqual(
            TextExpansionGlobalReplacementPlanner.plan(for: unambiguous),
            TextExpansionGlobalReplacementPlanner.Plan(deleteCount: 7, replacement: "Audit body")
        )
    }

    func testGlobalTapPolicySkipsOpenBurnBarAndSecureSurfaces() {
        let ownBundle = "com.openburnbar.app"
        let policy = TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: ownBundle,
            focusedSurfaceDenied: false
        )
        XCTAssertTrue(policy.shouldInterceptKeystrokes)

        XCTAssertFalse(TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: ownBundle,
            ownBundleIdentifier: ownBundle,
            focusedSurfaceDenied: false
        ).shouldInterceptKeystrokes)

        XCTAssertFalse(TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: true,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: ownBundle,
            focusedSurfaceDenied: true
        ).shouldInterceptKeystrokes)

        XCTAssertFalse(TextExpansionGlobalTapPolicy(
            globalExpansionEnabled: false,
            accessibilityTrusted: true,
            frontmostBundleIdentifier: "com.apple.TextEdit",
            ownBundleIdentifier: ownBundle,
            focusedSurfaceDenied: false
        ).shouldInterceptKeystrokes)
    }

    func testScopeBlocksUnavailableSurfaces() {
        let snippet = TextExpansionSnippet(
            title: "Thread Only",
            trigger: "thread",
            body: "Thread text",
            scope: TextExpansionScope(surfaces: [.inAppThread], threadIDs: ["abc"])
        )

        XCTAssertNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .macGlobal
        ))
        XCTAssertNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .inAppThread,
            threadID: "other"
        ))
        XCTAssertNotNil(TextExpansionMatcher.match(
            in: "&&thread ",
            snippets: [snippet],
            surface: .inAppThread,
            threadID: "abc"
        ))
    }

    func testKeyboardComposerMakeSnippetValidatesAndCreates() {
        let existing = [
            TextExpansionSnippet(title: "Already", trigger: "already", body: "Existing")
        ]

        // 1. Success case
        let successResult = TextExpansionKeyboardComposer.makeSnippet(
            rawTrigger: "&&hello",
            body: "World!",
            title: "Hello Snippet",
            existing: existing
        )
        switch successResult {
        case .success(let snippet):
            XCTAssertEqual(snippet.trigger, "hello")
            XCTAssertEqual(snippet.body, "World!")
            XCTAssertEqual(snippet.title, "Hello Snippet")
            XCTAssertTrue(snippet.isEnabled)
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }

        // 2. Duplicate trigger
        let duplicateResult = TextExpansionKeyboardComposer.makeSnippet(
            rawTrigger: "&&already",
            body: "New Body",
            existing: existing
        )
        XCTAssertEqual(duplicateResult, .failure(.duplicateTrigger))

        // 3. Empty body
        let emptyBodyResult = TextExpansionKeyboardComposer.makeSnippet(
            rawTrigger: "&&new",
            body: "   \n  ",
            existing: existing
        )
        XCTAssertEqual(emptyBodyResult, .failure(.emptyBody))

        // 4. Invalid trigger (e.g. contains space)
        let invalidTriggerResult = TextExpansionKeyboardComposer.makeSnippet(
            rawTrigger: "&&invalid trigger",
            body: "Body",
            existing: existing
        )
        XCTAssertEqual(invalidTriggerResult, .failure(.invalidTrigger("Use lowercase letters, numbers, hyphen, or underscore.")))
    }

    func testTextExpansionUsageStoreRankingAndIncrementing() {
        let snippetA = TextExpansionSnippet(title: "Alpha", trigger: "alpha", body: "Body A")
        let snippetB = TextExpansionSnippet(title: "Beta", trigger: "beta", body: "Body B")
        let snippetC = TextExpansionSnippet(title: "Gamma", trigger: "gamma", body: "Body C")

        let snippets = [snippetB, snippetC, snippetA]

        var log = TextExpansionUsageLog()

        // Initial rank (no usage): should fall back to case-insensitive alphabetical by title: Alpha, Beta, Gamma
        let ranked1 = TextExpansionUsageStore.rank(snippets, using: log)
        XCTAssertEqual(ranked1.map(\.title), ["Alpha", "Beta", "Gamma"])

        // Increment Beta's usage
        let dateB = Date()
        log = log.incrementing(snippetB.id, at: dateB)
        XCTAssertEqual(log.record(for: snippetB.id)?.count, 1)
        XCTAssertEqual(log.record(for: snippetB.id)?.lastUsedAt, dateB)

        // Rank now: Beta should be first because of higher usage count
        let ranked2 = TextExpansionUsageStore.rank(snippets, using: log)
        XCTAssertEqual(ranked2.map(\.title), ["Beta", "Alpha", "Gamma"])

        // Increment Gamma's usage count to match Beta's count, but with a newer timestamp
        let dateC = dateB.addingTimeInterval(10)
        log = log.incrementing(snippetC.id, at: dateC)

        // Rank now: Gamma and Beta have count 1, but Gamma is newer, so Gamma, Beta, Alpha
        let ranked3 = TextExpansionUsageStore.rank(snippets, using: log)
        XCTAssertEqual(ranked3.map(\.title), ["Gamma", "Beta", "Alpha"])
    }
}
