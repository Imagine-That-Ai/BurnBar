package com.openburnbar.data.cloud

internal object CloudVaultSearchChunker {
    const val MAX_EXTRACTED_TOKENS: Int = 4_096

    fun chunkUtf8String(text: String, maxBytes: Int, reservedText: String): List<String> {
        require(maxBytes >= String(Character.toChars(Character.MAX_CODE_POINT)).toByteArray(Charsets.UTF_8).size) {
            "CloudVault search chunks must fit one UTF-8 code point"
        }
        val reservedTokens = conservativeTokenCount(reservedText)
        require(reservedTokens < MAX_EXTRACTED_TOKENS) {
            "CloudVault search context exceeds the native token limit"
        }
        val maxChunkTokens = MAX_EXTRACTED_TOKENS - reservedTokens
        if (text.isEmpty()) return listOf(text)

        val chunks = mutableListOf<String>()
        var current = StringBuilder()
        var currentBytes = 0
        var currentTokens = 0
        var insideToken = false

        for (codePoint in text.codePoints().toArray()) {
            val scalar = String(Character.toChars(codePoint))
            val scalarBytes = scalar.toByteArray(Charsets.UTF_8).size
            val isTokenCharacter = Character.isLetterOrDigit(codePoint)
            var startsToken = isTokenCharacter && !insideToken

            if (current.isNotEmpty() &&
                (currentBytes + scalarBytes > maxBytes || (startsToken && currentTokens == maxChunkTokens))
            ) {
                chunks += current.toString()
                current = StringBuilder()
                currentBytes = 0
                currentTokens = 0
                insideToken = false
                startsToken = isTokenCharacter
            }

            current.append(scalar)
            currentBytes += scalarBytes
            if (startsToken) currentTokens += 1
            insideToken = isTokenCharacter
        }

        if (current.isNotEmpty()) chunks += current.toString()
        return chunks.ifEmpty { listOf(text) }
    }

    internal fun conservativeTokenCount(text: String): Int {
        var count = 0
        var insideToken = false
        for (codePoint in text.codePoints().toArray()) {
            val isTokenCharacter = Character.isLetterOrDigit(codePoint)
            if (isTokenCharacter && !insideToken) count += 1
            insideToken = isTokenCharacter
        }
        return count
    }
}
