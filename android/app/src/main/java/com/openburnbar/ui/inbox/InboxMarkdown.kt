package com.openburnbar.ui.inbox

// MARK: - Inline markdown for inbox bodies
//
// The Mac renders an item body with
// `AttributedString(markdown:options: .inlineOnlyPreservingWhitespace)` — bold,
// italic, inline code, and links, with line breaks left intact and no block
// constructs. This is the Android half of that same contract.
//
// A dedicated parser rather than a dependency or a reused renderer:
//   • The repo ships no general markdown renderer. `HermesRichBubble` resolves
//     Hermes *atoms*, mentions, and code — not markdown emphasis — and
//     `HermesAtomMarkdownParser` extracts links only.
//   • The lane budget forbids new dependencies, and a full CommonMark engine
//     would render block constructs the Mac deliberately does not.
//
// The parse is a pure function over strings so it is exercised by JVM unit
// tests; only the mapping to `AnnotatedString` needs Compose.

/** One styled run of an item body. */
internal data class InboxMarkdownSpan(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    /** Non-null when this run came from `[label](url)`. */
    val linkURL: String? = null,
)

internal object InboxMarkdown {
    private const val BOLD = "**"
    private const val CODE = '`'
    private const val ESCAPE = '\\'

    /**
     * Splits inline markdown into styled runs, preserving every character that
     * is not a delimiter — including newlines, so the Mac's line breaks survive.
     *
     * Unterminated delimiters are emitted as literal text rather than swallowing
     * the rest of the body: a stray asterisk in a model-written brief must not
     * blank the item.
     */
    fun parse(source: String): List<InboxMarkdownSpan> {
        if (source.isEmpty()) return emptyList()
        val spans = mutableListOf<InboxMarkdownSpan>()
        val literal = StringBuilder()
        var index = 0

        fun flushLiteral() {
            if (literal.isNotEmpty()) {
                spans.add(InboxMarkdownSpan(literal.toString()))
                literal.clear()
            }
        }

        while (index < source.length) {
            val advance = matchAt(source, index)
            if (advance == null) {
                // A backslash escapes the delimiter that follows it, so a body
                // can talk about `**` without turning bold on.
                if (source[index] == ESCAPE && index + 1 < source.length) {
                    literal.append(source[index + 1])
                    index += 2
                } else {
                    literal.append(source[index])
                    index += 1
                }
                continue
            }
            flushLiteral()
            spans.add(advance.span)
            index = advance.nextIndex
        }
        flushLiteral()
        return spans
    }

    private data class Advance(val span: InboxMarkdownSpan, val nextIndex: Int)

    private fun matchAt(source: String, index: Int): Advance? = matchBold(source, index)
        ?: matchCode(source, index)
        ?: matchLink(source, index)
        ?: matchItalic(source, index)

    private fun matchBold(source: String, index: Int): Advance? {
        if (!source.startsWith(BOLD, index)) return null
        val close = source.indexOf(BOLD, index + BOLD.length)
        if (close <= index + BOLD.length) return null
        val body = source.substring(index + BOLD.length, close)
        return Advance(InboxMarkdownSpan(body, bold = true), close + BOLD.length)
    }

    private fun matchCode(source: String, index: Int): Advance? {
        if (source[index] != CODE) return null
        val close = source.indexOf(CODE, index + 1)
        if (close <= index + 1) return null
        return Advance(InboxMarkdownSpan(source.substring(index + 1, close), code = true), close + 1)
    }

    /**
     * `*text*` / `_text_`. Runs only within a line: an unmatched marker should
     * not reach across a paragraph break and italicise half the body.
     */
    private fun matchItalic(source: String, index: Int): Advance? {
        val marker = source[index]
        if (marker != '*' && marker != '_') return null
        val close = source.indexOf(marker, index + 1)
        if (close <= index + 1) return null
        val body = source.substring(index + 1, close)
        if (body.contains('\n')) return null
        return Advance(InboxMarkdownSpan(body, italic = true), close + 1)
    }

    private fun matchLink(source: String, index: Int): Advance? {
        if (source[index] != '[') return null
        val labelClose = source.indexOf(']', index + 1)
        if (labelClose < 0) return null
        if (labelClose + 1 >= source.length || source[labelClose + 1] != '(') return null
        val urlClose = source.indexOf(')', labelClose + 2)
        if (urlClose < 0) return null
        val label = source.substring(index + 1, labelClose)
        val url = source.substring(labelClose + 2, urlClose).trim()
        if (label.isEmpty() || url.isEmpty()) return null
        return Advance(InboxMarkdownSpan(label, linkURL = url), urlClose + 1)
    }
}
