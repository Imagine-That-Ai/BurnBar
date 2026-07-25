import Foundation
import XCTest
import OpenBurnBarCore

#if canImport(Darwin)

final class HermesStreamingMarkdownRendererTests: XCTestCase {

    private let corpus = """
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
        for seed in [UInt64(1), 7, 42, 1_337] {
            var rng = SplitMix64(seed: seed)
            let renderer = HermesStreamingMarkdownRenderer()
            var accumulated = ""
            var remaining = Substring(corpus)
            var step = 0
            while !remaining.isEmpty {
                let size = 1 + Int(rng.next() % 9)
                accumulated += String(remaining.prefix(size))
                remaining = remaining.dropFirst(size)
                step += 1
                assertRendersEqual(
                    renderer.attributedString(for: accumulated, suffix: "▍"),
                    HermesInlineMarkdown.attributedString(accumulated + "▍"),
                    "seed \(seed) step \(step)"
                )
            }
            assertRendersEqual(
                renderer.attributedString(for: accumulated),
                HermesInlineMarkdown.attributedString(accumulated),
                "seed \(seed) final render"
            )
        }
    }

    func test_largeStream_andMemoizedRendersStayEquivalent() {
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
        assertRendersEqual(
            renderer.attributedString(for: accumulated),
            HermesInlineMarkdown.attributedString(accumulated),
            "4000-chunk stream"
        )
        let text = "## Header\nbody **bold** line\ntail without newline"
        let first = renderer.attributedString(for: text, suffix: "▍")
        let second = renderer.attributedString(for: text, suffix: "▍")
        assertRendersEqual(first, second, "memoized render")
        assertRendersEqual(
            renderer.attributedString(for: text),
            HermesInlineMarkdown.attributedString(text),
            "suffix dropped"
        )
    }

    /// A same-length replacement of text the cache has already CONSUMED (not
    /// just the pending tail) must rebuild. The structural checks all pass for
    /// `old\n` → `new\n` — identical length, newline still immediately before
    /// the consumed boundary, tail still empty — so a boundary-only validity
    /// check reported "unchanged" and kept rendering the replaced text.
    func test_sameLengthConsumedPrefixReplacement_rebuilds() {
        let renderer = HermesStreamingMarkdownRenderer()
        _ = renderer.attributedString(for: "old\n")
        assertRendersEqual(
            renderer.attributedString(for: "new\n"),
            HermesInlineMarkdown.attributedString("new\n"),
            "same-length consumed-prefix replacement"
        )

        // Multi-line, still equal length and still ending on a newline.
        _ = renderer.attributedString(for: "aaa\nbbb\n")
        assertRendersEqual(
            renderer.attributedString(for: "xxx\nyyy\n"),
            HermesInlineMarkdown.attributedString("xxx\nyyy\n"),
            "same-length multi-line consumed-prefix replacement"
        )

        // The stale prefix must not survive into later appends either: the
        // replacement is same-length, and the text then grows normally.
        _ = renderer.attributedString(for: "old\nab")
        assertRendersEqual(
            renderer.attributedString(for: "new\nabc"),
            HermesInlineMarkdown.attributedString("new\nabc"),
            "append after a same-length consumed-prefix replacement"
        )

        // Emphasis differences that keep byte length identical must also be
        // reflected, since the divergence is in attributes as well as text.
        _ = renderer.attributedString(for: "**bold** line\n")
        assertRendersEqual(
            renderer.attributedString(for: "*ital*ic line\n"),
            HermesInlineMarkdown.attributedString("*ital*ic line\n"),
            "same-length consumed-prefix replacement changing emphasis"
        )
    }

    func test_replacement_shrink_sameLengthAndUnicodeInputsResetSafely() {
        let renderer = HermesStreamingMarkdownRenderer()
        _ = renderer.attributedString(for: "**partial** answer\nthat was strea", suffix: "▍")
        let replacement = "Hermes returned no text. Try again or switch models."
        assertRendersEqual(
            renderer.attributedString(for: replacement),
            HermesInlineMarkdown.attributedString(replacement),
            "replacement after reset"
        )
        let shorter = "line one\n"
        _ = renderer.attributedString(for: "line one\nline two\nline three tail")
        assertRendersEqual(
            renderer.attributedString(for: shorter),
            HermesInlineMarkdown.attributedString(shorter),
            "shrunken text"
        )
        _ = renderer.attributedString(for: "stable line\npartial AAA")
        let swapped = "stable line\npartial BBB"
        assertRendersEqual(
            renderer.attributedString(for: swapped),
            HermesInlineMarkdown.attributedString(swapped),
            "same-length tail replacement"
        )
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

        let text = "café ☕️ **重要** line 🧪\n- 箇条書き `コード` @身元\nnaïve tail 🎯 end"
        var accumulated = ""
        for character in text {
            accumulated.append(character)
            assertRendersEqual(
                renderer.attributedString(for: accumulated, suffix: "▍"),
                HermesInlineMarkdown.attributedString(accumulated + "▍"),
                "multibyte prefix of \(accumulated.count) chars"
            )
        }
    }
}

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

#endif
