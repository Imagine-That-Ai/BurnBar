package com.openburnbar.data.hermes

internal object HermesAtomMarkdownParser {
    internal sealed class LinkChunk {
        data class Body(val text: String) : LinkChunk()

        data class Link(val atom: HermesAtom, val label: String) : LinkChunk()
    }

    fun extractMarkdownLinks(source: String): List<LinkChunk> {
        val output = mutableListOf<LinkChunk>()
        var bodyStart = 0
        var i = 0
        while (i < source.length) {
            val linkMatch = markdownLinkAt(source, i, bodyStart, output)
            if (linkMatch != null) {
                i = linkMatch.nextIndex
                bodyStart = linkMatch.bodyStart
            } else {
                i += 1
            }
        }
        if (bodyStart < source.length) {
            output.add(LinkChunk.Body(source.substring(bodyStart)))
        }
        return output
    }

    private data class MarkdownLinkAdvance(val nextIndex: Int, val bodyStart: Int)

    private fun markdownLinkAt(source: String, index: Int, bodyStart: Int, output: MutableList<LinkChunk>): MarkdownLinkAdvance? {
        if (source[index] != '[') return null
        val escaped = index > 0 && source[index - 1] == '\\'
        if (escaped) return null
        val match = matchMarkdownLink(source, index) ?: return null
        if (bodyStart < index) {
            output.add(LinkChunk.Body(source.substring(bodyStart, index)))
        }
        output.add(LinkChunk.Link(match.atom, match.label))
        return MarkdownLinkAdvance(nextIndex = match.endIndex, bodyStart = match.endIndex)
    }

    private data class MarkdownLinkMatch(val atom: HermesAtom, val label: String, val endIndex: Int)

    private fun matchMarkdownLink(source: String, start: Int): MarkdownLinkMatch? {
        val labelClose = parseMarkdownLinkLabelClose(source, start) ?: return null
        val urlClose = parseMarkdownLinkUrlClose(source, labelClose) ?: return null
        val urlText = source.substring(labelClose + 2, urlClose)
        val atom = HermesAtomURL.decode(urlText) ?: return null
        val cleaned = source.substring(start + 1, labelClose).trim()
        val resolved = if (cleaned.isEmpty()) atom.fallbackLabel else cleaned
        return MarkdownLinkMatch(atom = atom, label = resolved, endIndex = urlClose + 1)
    }

    private fun parseMarkdownLinkLabelClose(source: String, start: Int): Int? {
        var idx = start + 1
        var depth = 1
        while (idx < source.length) {
            when (val c = source[idx]) {
                '\n' -> return null
                '[' -> depth += 1
                ']' -> {
                    depth -= 1
                    if (depth == 0) return if (idx < source.length) idx else null
                }
            }
            idx += 1
        }
        return null
    }

    private fun parseMarkdownLinkUrlClose(source: String, labelClose: Int): Int? {
        val openParen = labelClose + 1
        if (openParen >= source.length || source[openParen] != '(') return null
        var urlIdx = openParen + 1
        while (urlIdx < source.length) {
            when (source[urlIdx]) {
                ')' -> return urlIdx
                '\n' -> return null
            }
            urlIdx += 1
        }
        return null
    }
}
