package com.openburnbar.data.hermes

internal object HermesAtomEntityParser {
    fun parseEntities(source: String): List<HermesAtomRun> {
        val output = mutableListOf<HermesAtomRun>()
        val buffer = StringBuilder()
        var i = 0
        while (i < source.length) {
            i = consumeEntityToken(source, i, buffer, output)
        }
        if (buffer.isNotEmpty()) {
            output.addAll(scanRegexAtoms(buffer.toString()))
        }
        return output
    }

    private fun consumeEntityToken(source: String, index: Int, buffer: StringBuilder, output: MutableList<HermesAtomRun>): Int {
        val ch = source[index]
        if (ch == '`') {
            if (buffer.isNotEmpty()) {
                output.addAll(scanRegexAtoms(buffer.toString()))
                buffer.clear()
            }
            val match = matchInlineCode(source, index)
            return if (match != null) {
                output.add(HermesAtomRun.Code(match.body))
                match.endIndex
            } else {
                buffer.append('`')
                index + 1
            }
        }
        if (ch == '@') {
            val prev: Char = if (index == 0) ' ' else source[index - 1]
            val isMentionBoundary = prev.isWhitespace() || prev == '(' || prev == '[' || prev == '{'
            if (isMentionBoundary) {
                val match = matchMention(source, index)
                if (match != null) {
                    if (buffer.isNotEmpty()) {
                        output.addAll(scanRegexAtoms(buffer.toString()))
                        buffer.clear()
                    }
                    output.add(HermesAtomRun.Mention(match.handle))
                    return match.endIndex
                }
            }
        }
        buffer.append(ch)
        return index + 1
    }

    private data class InlineCodeMatch(val body: String, val endIndex: Int)

    private fun matchInlineCode(source: String, start: Int): InlineCodeMatch? {
        var idx = start + 1
        val body = StringBuilder()
        while (idx < source.length) {
            val c = source[idx]
            if (c == '`') {
                if (body.isEmpty()) return null
                return InlineCodeMatch(body.toString(), idx + 1)
            }
            if (c == '\n') return null
            body.append(c)
            idx += 1
        }
        return null
    }

    private data class MentionMatch(val handle: String, val endIndex: Int)

    private fun matchMention(source: String, start: Int): MentionMatch? {
        var idx = start + 1
        val handle = StringBuilder("@")
        while (idx < source.length) {
            val c = source[idx]
            val isHandleCharacter = c.isLetter() || c.isDigit() || c == '_' || c == '-' || c == '.'
            if (isHandleCharacter) {
                handle.append(c)
                idx += 1
            } else {
                break
            }
        }
        if (handle.length <= 1) return null
        return MentionMatch(handle.toString(), idx)
    }

    private fun scanRegexAtoms(source: String): List<HermesAtomRun> {
        if (source.isEmpty()) return emptyList()
        val modelAlt = knownModelIDs.joinToString("|") { Regex.escape(it) }
        val pattern = Regex("(\\$\\d{1,3}(?:,\\d{3})*(?:\\.\\d+)?)|($modelAlt)")
        val matches = pattern.findAll(source).toList()
        if (matches.isEmpty()) return listOf(HermesAtomRun.Text(source))

        val output = mutableListOf<HermesAtomRun>()
        var cursor = 0
        for (match in matches) {
            val range = match.range
            if (range.first > cursor) {
                output.add(HermesAtomRun.Text(source.substring(cursor, range.first)))
            }
            val matched = source.substring(range.first, range.last + 1)
            val cost = parseCost(matched)
            when {
                cost != null ->
                    output.add(
                        HermesAtomRun.Atom(HermesAtom.Cost(cost, HermesAtomWindow.TODAY), matched),
                    )
                knownModelIDs.contains(matched) ->
                    output.add(
                        HermesAtomRun.Atom(HermesAtom.Model(matched), matched),
                    )
                else -> output.add(HermesAtomRun.Text(matched))
            }
            cursor = range.last + 1
        }
        if (cursor < source.length) {
            output.add(HermesAtomRun.Text(source.substring(cursor)))
        }
        return output
    }

    private fun parseCost(matched: String): Double? {
        if (!matched.startsWith("$")) return null
        val trimmed = matched.drop(1).replace(",", "")
        return trimmed.toDoubleOrNull()
    }

    private val knownModelIDs: List<String> =
        listOf(
            "claude-sonnet-4.7",
            "claude-sonnet-4.6",
            "claude-sonnet-4.5",
            "claude-opus-4.7",
            "claude-opus-4.6",
            "claude-haiku-4.7",
            "gpt-5.5",
            "gpt-5",
            "gpt-4.6",
            "gpt-4o",
            "gpt-4o-mini",
            "o1-preview",
            "o1-mini",
            "minimax-m2.7",
            "minimax-m2",
            "kimi-k1.7",
            "kimi-k1.5",
            "glm-5",
            "glm-4.6",
            "deepseek-v3.5",
            "gemini-3-pro",
            "gemini-3-flash",
        )
}
