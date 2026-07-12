import Foundation

// MARK: - Hermes Streaming Markdown Renderer
//
// `HermesInlineMarkdown.attributedString(_:)` re-parses the ENTIRE
// accumulated message on every call. A streaming chat bubble that renders
// through it on every SSE commit therefore does O(n) parse work per commit,
// making a full stream O(n²) in the length of the reply. This renderer
// makes the same render amortized O(1) per appended chunk.
//
// It exploits the fact that the whole Hermes parse pipeline is strictly
// line-independent:
//   - `HermesAtomParser`: markdown links, inline code spans, and mention
//     handles all bail at `\n` (labels/URLs/code never span lines), and the
//     `$cost` / model-id regex alternation can never match across a newline.
//   - `HermesInlineMarkdown`: emphasis spans never cross lines, and the
//     `atLineStart` block-marker state resets to `true` after every `\n`.
//
// Consequently `parse(a + b) == parse(a) + parse(b)` whenever `a` ends with
// a newline, so text up to the last committed newline can be parsed exactly
// once and cached; only the trailing partial line is re-parsed per update.
//
// Correctness contract (verified by `HermesStreamingMarkdownRendererTests`
// against randomized chunkings):
//
//     renderer.attributedString(for: text, suffix: s)
//         == HermesInlineMarkdown.attributedString(text + s)
//
// `AttributedString.inlinePresentationIntent` is Apple-only (same constraint
// as `HermesInlineMarkdown.attributedString`), so the renderer is Apple-only.
#if canImport(Darwin)

/// Incremental, amortized-O(1)-per-chunk renderer for streamed Hermes/agent
/// markdown. Designed to be held in a SwiftUI `@State` box by exactly one
/// message bubble (identity-stable row) and called from `body`; it is a
/// plain non-Sendable class — main-actor use only.
///
/// The renderer is defensive about its append-only assumption: every call
/// re-verifies (in O(partial line), never O(total)) that the cached region
/// still matches the incoming text, and falls back to a full one-shot
/// re-parse — the exact cost the non-cached path paid on *every* call —
/// whenever the text shrank or was replaced (error rewrites, thread swaps).
public final class HermesStreamingMarkdownRenderer {

    /// Styled attributed text for everything up to (and including) the last
    /// consumed `\n` of the previously seen text.
    private var parsedPrefix = AttributedString()
    /// UTF-8 length of the consumed prefix. Always sits immediately after a
    /// newline byte (or at 0), so byte slicing here is UTF-8 safe — no
    /// multi-byte scalar contains 0x0A.
    private var consumedUTF8Count = 0
    /// Text after the last consumed newline — the live partial line. Bounded
    /// in practice by line length (and the parser's own 8 KB line-scan cap
    /// keeps pathological single-line blobs from exploding parse cost).
    private var pendingTail = ""
    /// Memo of the last full render so body re-evaluations without a text
    /// change cost one O(partial line) verification, not a render.
    private var memoKey: MemoKey?
    private var memoValue = AttributedString()

    private struct MemoKey: Equatable {
        var utf8Count: Int
        var suffix: String
    }

    public init() {}

    /// Drop all cached state. The next render re-parses from scratch.
    public func reset() {
        parsedPrefix = AttributedString()
        consumedUTF8Count = 0
        pendingTail = ""
        memoKey = nil
        memoValue = AttributedString()
    }

    /// Render `text + suffix` (the suffix is the streaming caret — kept
    /// separate so appending it never copies the accumulated text) exactly
    /// as `HermesInlineMarkdown.attributedString(text + suffix)` would,
    /// re-parsing only the bytes that arrived since the previous call plus
    /// the trailing partial line.
    public func attributedString(for text: String, suffix: String = "") -> AttributedString {
        var contiguous = text
        contiguous.makeContiguousUTF8()
        let changed = contiguous.withUTF8 { bytes in
            ingest(bytes)
        }
        let key = MemoKey(utf8Count: contiguous.utf8.count, suffix: suffix)
        if !changed, key == memoKey {
            return memoValue
        }
        var rendered = parsedPrefix
        let tailSource = pendingTail + suffix
        if !tailSource.isEmpty {
            rendered.append(HermesInlineMarkdown.attributedString(tailSource))
        }
        memoKey = key
        memoValue = rendered
        return rendered
    }

    /// Fold the current full text into the cache. Returns `false` when the
    /// text is byte-identical to the cached state (memo-eligible), `true`
    /// when new bytes were consumed or the cache was rebuilt.
    private func ingest(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        if bytes.count == consumedUTF8Count + pendingTail.utf8.count,
           cachedRegionMatches(bytes) {
            return false
        }
        if !tryConsume(bytes) {
            // Shrunk or replaced text: rebuild once from scratch.
            reset()
            let consumed = tryConsume(bytes)
            assert(consumed, "consume from an empty cache state cannot fail")
        }
        return true
    }

    /// O(partial line) check that the incoming bytes still agree with the
    /// cached prefix/tail split: the byte before the consumed boundary is
    /// still a newline and the pending tail bytes are unchanged. The parsed
    /// prefix itself is not re-compared byte-for-byte — the boundary + tail
    /// check, combined with the caller-side append-only streaming contract,
    /// makes a silent prefix replacement unreachable in practice, and any
    /// length change at all triggers the full rebuild path.
    private func cachedRegionMatches(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let tailUTF8Count = pendingTail.utf8.count
        guard bytes.count >= consumedUTF8Count + tailUTF8Count else { return false }
        if consumedUTF8Count > 0 {
            guard consumedUTF8Count <= bytes.count,
                  bytes[consumedUTF8Count - 1] == 0x0A else { return false }
        }
        guard tailUTF8Count > 0 else { return true }
        let region = bytes[consumedUTF8Count ..< consumedUTF8Count + tailUTF8Count]
        return pendingTail.utf8.elementsEqual(region)
    }

    /// Consume any bytes beyond the cached state. Parses complete lines
    /// (through the last new `\n`) once into `parsedPrefix` and stages the
    /// remainder as the new pending tail. Returns `false` when the incoming
    /// bytes do not extend the cached state (caller resets and retries).
    private func tryConsume(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard cachedRegionMatches(bytes) else { return false }
        let unconsumed = bytes[consumedUTF8Count...]
        guard unconsumed.count != pendingTail.utf8.count else {
            return true // byte-identical to cached state; nothing new
        }
        guard let lastNewlineIndex = unconsumed.lastIndex(of: 0x0A) else {
            // No complete line yet — everything stays in the pending tail.
            pendingTail = String(decoding: unconsumed, as: UTF8.self)
            return true
        }
        let completedEnd = lastNewlineIndex + 1 // slice keeps absolute indices
        let completed = String(decoding: bytes[consumedUTF8Count ..< completedEnd], as: UTF8.self)
        parsedPrefix.append(HermesInlineMarkdown.attributedString(completed))
        consumedUTF8Count = completedEnd
        pendingTail = String(decoding: bytes[completedEnd...], as: UTF8.self)
        return true
    }
}

#endif
