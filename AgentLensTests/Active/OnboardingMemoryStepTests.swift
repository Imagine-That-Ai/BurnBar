import XCTest
@testable import OpenBurnBar

/// The first-run memory step. Two things must hold forever:
///
///   1. It is *optional*. A step that can strand somebody on their first
///      launch is worse than no step, so it must sit inside the normal
///      forward/back walk and never be the last thing before `.complete`
///      without a way past it.
///   2. Its copy stays defensible against `tools/openburnbar-mcp/README.md`.
///      Memories are written by a connected agent calling
///      `burnbar_memorize` / `burnbar_remember`; automatic collection is an
///      opt-in hook; nothing is pruned on the member's behalf. These pins
///      make a copy edit that quietly over-claims fail here first.
final class OnboardingMemoryStepTests: XCTestCase {

    // MARK: Placement

    func testMemoryStepSitsBetweenTheTourAndTheChatEngineStep() {
        XCTAssertEqual(OnboardingWizardStep.tour.nextAvailable, .memory)
        XCTAssertEqual(OnboardingWizardStep.memory.nextAvailable, .chatEngine)
        XCTAssertEqual(OnboardingWizardStep.memory.previousAvailable, .tour)
    }

    func testMemoryStepIsNeitherTheFirstNorTheLastStep() {
        let available = OnboardingWizardStep.availableCases
        XCTAssertTrue(available.contains(.memory))
        XCTAssertNotEqual(available.first, .memory)
        XCTAssertNotEqual(available.last, .memory)
        XCTAssertNotNil(OnboardingWizardStep.memory.nextAvailable, "the step must always have a way forward")
        XCTAssertNotNil(OnboardingWizardStep.memory.previousAvailable, "the step must always have a way back")
    }

    // MARK: Copy

    func testEveryFactHasASymbolATitleAndABody() {
        let facts = OnboardingMemoryContent.facts
        XCTAssertEqual(facts.count, 4)
        XCTAssertEqual(facts.map(\.id), Array(0 ..< facts.count), "ids identify rows in a ForEach")
        for fact in facts {
            XCTAssertFalse(fact.symbol.isEmpty, "fact \(fact.id) needs a glyph")
            XCTAssertFalse(fact.title.isEmpty, "fact \(fact.id) needs a title")
            XCTAssertFalse(fact.body.isEmpty, "fact \(fact.id) needs a body")
            XCTAssertTrue(fact.title.hasSuffix("."), "fact \(fact.id) reads as a sentence")
        }
        XCTAssertFalse(OnboardingMemoryContent.title.isEmpty)
        XCTAssertFalse(OnboardingMemoryContent.subtitle.isEmpty)
        XCTAssertFalse(OnboardingMemoryContent.skipNote.isEmpty)
    }

    /// The four things a first-time member has to be told, in the order the
    /// step tells them: where it lives, that nothing happens unasked, that a
    /// connected agent is what does the remembering, and that nobody prunes
    /// their memories for them.
    func testTheFourLoadBearingClaimsArePresent() {
        let facts = OnboardingMemoryContent.facts
        XCTAssertTrue(facts[0].title.localizedCaseInsensitiveContains("this Mac"))
        XCTAssertTrue(facts[1].title.localizedCaseInsensitiveContains("until you say yes"))
        XCTAssertTrue(facts[2].title.localizedCaseInsensitiveContains("connected agent"))
        XCTAssertTrue(facts[3].title.localizedCaseInsensitiveContains("pruned"))
    }

    /// Automatic collection is opt-in, and in-app extraction is consent-gated,
    /// so the copy must never promise collection that just happens.
    func testCollectionCopyDoesNotPromiseUnaskedCollection() {
        let body = OnboardingMemoryContent.facts[1].body
        XCTAssertTrue(body.localizedCaseInsensitiveContains("no memories"))
        XCTAssertTrue(body.localizedCaseInsensitiveContains("consent"))
        for overClaim in ["automatically remembers", "always on", "no setup", "everything you do"] {
            XCTAssertFalse(
                allCopy.localizedCaseInsensitiveContains(overClaim),
                "over-claim in first-run memory copy: \(overClaim)"
            )
        }
    }

    /// There is no background pruner: `expires_at` is optional and set by the
    /// writer, and removal goes through review / forget / bulk delete.
    func testPruningCopyPointsAtTheRealControls() {
        let body = OnboardingMemoryContent.facts[3].body
        XCTAssertTrue(body.localizedCaseInsensitiveContains("until you remove them"))
        XCTAssertTrue(body.localizedCaseInsensitiveContains("expir"))
        XCTAssertTrue(body.contains("Settings \u{203A} Data & Privacy"))
    }

    /// Skipping must cost the member nothing, and the note has to name the
    /// two places the same controls live afterwards.
    func testSkipNoteNamesWhereEverythingLivesAfterwards() {
        let note = OnboardingMemoryContent.skipNote
        // "Connections › Apps" was this assertion until the installer moved to
        // Agents › CLIs in #2555; the copy moved and the test did not, so this
        // case has been red on main since. Pinned to the shipped string now.
        XCTAssertTrue(note.contains("Settings \u{203A} Agents \u{203A} CLIs"))
        XCTAssertTrue(note.contains("Settings \u{203A} General \u{203A} Search & Memory"))
        XCTAssertTrue(note.contains("Settings \u{203A} Devices & Sync \u{203A} Memory Sync"))
    }

    /// The step reuses the Settings installer, so every client it can wire is
    /// reachable from first run — no second, drifting list.
    func testTheStepOffersEveryWiringTargetTheAppSupports() {
        XCTAssertEqual(
            Set(MCPClientWiringTarget.allCases.map(\.displayName)),
            ["Claude Code", "Cursor", "Codex CLI", "Factory Droid", "Antigravity CLI", "Gemini CLI", "Muse"]
        )
    }

    private var allCopy: String {
        ([OnboardingMemoryContent.title, OnboardingMemoryContent.subtitle, OnboardingMemoryContent.skipNote]
            + OnboardingMemoryContent.facts.flatMap { [$0.title, $0.body] })
            .joined(separator: "\n")
    }
}
