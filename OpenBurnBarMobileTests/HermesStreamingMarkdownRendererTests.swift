import XCTest
import Foundation
import OpenBurnBarCore

// MARK: - Hermes Streaming Markdown Renderer Equivalence
//
// remediation(chat-streaming-o2): the incremental renderer must be
// indistinguishable from the one-shot parser for EVERY prefix of a stream,
// under arbitrary chunk boundaries. These tests feed a markdown corpus that
// exercises every construct the pipeline understands (emphasis, headings,
// bullets, code spans, mentions, burnbar links, cost atoms, model ids,
// multi-line prose) through randomized chunkings and assert byte-for-byte
// attributed equality with `HermesInlineMarkdown.attributedString` at every
// step — including the streaming caret suffix — plus the reset semantics
// for replaced or shrunken text.

final class HermesStreamingMarkdownRendererTests: XCTestCase {

    private static let corpus = """
    ## Burn summary for @alberto
    Your **top model** was `claude-opus-4.7` at $12.34 today.
    - *first* bullet with ~~struck~~ text
    - second bullet with a [session](burnbar://window?value=7d) link
    Plain paragraph line with ***bold italics*** and snake_case_name intact.

    ### Costs
    gpt-5.5 burned $1,234.56 across `two` sessions — @ops was notified.
    Final line without trailing newline
    """

    private func assertRendersEqual(
        _ produced: AttributedString,
        _ expected: AttributedString,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            String(produced.characters),
            String(expected.characters),
            "characters diverged — \(message)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            NSAttributedString(produced),
            NSAttributedString(expected),
            "attributes diverged — \(message)",
            file: file,
            line: line
        )
    }

    func test_incrementalRender_matchesOneShotParse_atEveryChunkBoundary() {
        // Deterministic pseudo-random chunk sizes across several seeds so
        // chunk boundaries land inside markers, spans, links, and newlines.
        for seed in [UInt64(1), 7, 42, 1_337] {
            var rng = SplitMix64(seed: seed)
            let renderer = HermesStreamingMarkdownRenderer()
            var accumulated = ""
            var remaining = Substring(Self.corpus)
            var step = 0
            while !remaining.isEmpty {
                let size = 1 + Int(rng.next() % 9)
                accumulated += String(remaining.prefix(size))
                remaining = remaining.dropFirst(size)
                step += 1
                let produced = renderer.attributedString(for: accumulated, suffix: "▍")
                let expected = HermesInlineMarkdown.attributedString(accumulated + "▍")
                assertRendersEqual(produced, expected, "seed \(seed) step \(step)")
            }
            // Stream finished: caret dropped, text unchanged.
            let final = renderer.attributedString(for: accumulated)
            assertRendersEqual(
                final,
                HermesInlineMarkdown.attributedString(accumulated),
                "seed \(seed) final render"
            )
        }
    }

    func test_largeStream_thousandsOfChunks_matchesOneShotParse() {
        let renderer = HermesStreamingMarkdownRenderer()
        var accumulated = ""
        for index in 0..<4_000 {
            let token: String
            switch index % 7 {
            case 0: token = "**bold\(index)** "
            case 1: token = "line with `code\(index)`\n"
            case 2: token = "- bullet \(index)\n"
            case 3: token = "$\(index % 100).50 spent "
            default: token = "word\(index) "
            }
            accumulated += token
            _ = renderer.attributedString(for: accumulated, suffix: "▍")
        }
        // Correctness at scale: the fully streamed render equals the
        // one-shot parse of the final text.
        assertRendersEqual(
            renderer.attributedString(for: accumulated),
            HermesInlineMarkdown.attributedString(accumulated),
            "4000-chunk stream"
        )
    }

    func test_replacedText_resetsAndRendersReplacement() {
        let renderer = HermesStreamingMarkdownRenderer()
        _ = renderer.attributedString(for: "**partial** answer\nthat was strea", suffix: "▍")
        // Error path rewrites the whole message text.
        let replacement = "Hermes returned no text. Try again or switch models."
        assertRendersEqual(
            renderer.attributedString(for: replacement),
            HermesInlineMarkdown.attributedString(replacement),
            "replacement after reset"
        )
    }

    func test_shrunkenText_resetsAndRendersCorrectly() {
        let renderer = HermesStreamingMarkdownRenderer()
        _ = renderer.attributedString(for: "line one\nline two\nline three tail")
        let shorter = "line one\n"
        assertRendersEqual(
            renderer.attributedString(for: shorter),
            HermesInlineMarkdown.attributedString(shorter),
            "shrunken text"
        )
    }

    func test_sameLengthReplacementOnPartialLine_isDetected() {
        let renderer = HermesStreamingMarkdownRenderer()
        _ = renderer.attributedString(for: "stable line\npartial AAA")
        // Same total byte length, different pending-tail bytes — the cached
        // region verification must catch it and rebuild.
        let swapped = "stable line\npartial BBB"
        assertRendersEqual(
            renderer.attributedString(for: swapped),
            HermesInlineMarkdown.attributedString(swapped),
            "same-length tail replacement"
        )
    }

    func test_emptyText_andSuffixOnlyRenders() {
        let renderer = HermesStreamingMarkdownRenderer()
        assertRendersEqual(
            renderer.attributedString(for: ""),
            HermesInlineMarkdown.attributedString(""),
            "empty text"
        )
        assertRendersEqual(
            renderer.attributedString(for: "", suffix: "▍"),
            HermesInlineMarkdown.attributedString("▍"),
            "suffix-only render"
        )
    }

    func test_repeatedRenderWithUnchangedText_returnsMemoizedEqualValue() {
        let renderer = HermesStreamingMarkdownRenderer()
        let text = "## Header\nbody **bold** line\ntail without newline"
        let first = renderer.attributedString(for: text, suffix: "▍")
        let second = renderer.attributedString(for: text, suffix: "▍")
        assertRendersEqual(first, second, "memoized render")
        // Suffix change with unchanged text re-renders just the tail.
        assertRendersEqual(
            renderer.attributedString(for: text),
            HermesInlineMarkdown.attributedString(text),
            "suffix dropped"
        )
    }

    func test_multiByteContent_chunkedAtArbitraryUTF8Boundaries() {
        // Emoji + CJK + combining marks across line boundaries; chunk sizes
        // in CHARACTERS so appends always form valid strings while their
        // UTF-8 lengths vary per step.
        let text = "café ☕️ **重要** line 🧪\n- 箇条書き `コード` @身元\nnaïve tail 🎯 end"
        let renderer = HermesStreamingMarkdownRenderer()
        var accumulated = ""
        for character in text {
            accumulated.append(character)
            let produced = renderer.attributedString(for: accumulated, suffix: "▍")
            let expected = HermesInlineMarkdown.attributedString(accumulated + "▍")
            assertRendersEqual(produced, expected, "multibyte prefix of \(accumulated.count) chars")
        }
    }
}

/// Small deterministic RNG so chunk-boundary coverage is reproducible.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
