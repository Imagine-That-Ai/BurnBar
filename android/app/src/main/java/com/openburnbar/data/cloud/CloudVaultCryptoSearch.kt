package com.openburnbar.data.cloud

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

internal object CloudVaultCryptoSearch {
    private const val BITS_PER_BYTE = 8
    private const val BYTE_MASK = 0xff
    private const val GCM_TAG_BYTES = 16
    private const val SHA256_DIGEST_BYTES = 32
    private const val SEMANTIC_VECTOR_DIMENSIONS = 64
    private const val DEFAULT_TOKEN_HASH_LIMIT = 250
    private const val DEFAULT_SEMANTIC_HASH_LIMIT = 24
    private const val MIN_TOKEN_LENGTH_FOR_PREFIX = 5
    private const val MIN_STEM_SUFFIX_OVERHEAD = 3
    private const val SEMANTIC_TOKEN_WEIGHT = 2.4
    private const val SEMANTIC_STEM_WEIGHT = 1.8
    private const val SEMANTIC_PREFIX_WEIGHT = 0.8
    private const val SEMANTIC_BIGRAM_WEIGHT = 1.3
    private const val SEARCH_SALT = "OpenBurnBar-CloudSearch-Salt-v1"
    private const val SEARCH_INFO = "OpenBurnBar-CloudSearch-TokenHash-v1"
    private const val SEMANTIC_SEARCH_SALT = "OpenBurnBar-CloudSearch-Semantic-Salt-v1"
    private const val SEMANTIC_SEARCH_INFO = "OpenBurnBar-CloudSearch-SemanticHash-v1"

    private val stopwords =
        setOf(
            "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
            "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
            "into", "onto", "can", "could", "should", "would",
        )

    fun tokenHashes(text: String, vaultKey: ByteArray, limit: Int = DEFAULT_TOKEN_HASH_LIMIT): List<String> {
        val searchKey = hkdfSha256(vaultKey, SEARCH_SALT.toByteArray(), SEARCH_INFO.toByteArray(), SHA256_DIGEST_BYTES)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
        return normalizedTokens(text)
            .distinct()
            .take(limit)
            .map { token ->
                mac.doFinal(token.toByteArray()).take(GCM_TAG_BYTES).joinToString("") {
                    "%02x".format(it.toInt() and BYTE_MASK)
                }
            }
    }

    fun semanticHashes(text: String, vaultKey: ByteArray, limit: Int = DEFAULT_SEMANTIC_HASH_LIMIT): List<String> {
        val tokens = normalizedTokens(text)
        if (tokens.isEmpty() || limit <= 0) return emptyList()
        val searchKey =
            hkdfSha256(
                vaultKey,
                SEMANTIC_SEARCH_SALT.toByteArray(),
                SEMANTIC_SEARCH_INFO.toByteArray(),
                SHA256_DIGEST_BYTES,
            )
        val features = semanticFeatures(tokens)
        if (features.isEmpty()) return emptyList()

        val mac = Mac.getInstance("HmacSHA256")
        val dimensions = SEMANTIC_VECTOR_DIMENSIONS
        val accumulator = DoubleArray(dimensions)
        for (feature in features) {
            mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
            val bytes = mac.doFinal(feature.name.toByteArray())
            val index = (bytes[0].toInt() and BYTE_MASK shl BITS_PER_BYTE or (bytes[1].toInt() and BYTE_MASK)) % dimensions
            val sign = if (bytes[2].toInt() and 1 == 0) 1.0 else -1.0
            accumulator[index] += sign * feature.weight
        }

        val hashes = mutableListOf<String>()
        val seen = linkedSetOf<String>()

        fun appendBucket(bucket: String) {
            if (hashes.size >= limit) return
            mac.init(SecretKeySpec(searchKey, "HmacSHA256"))
            val hash =
                mac.doFinal(bucket.toByteArray())
                    .take(GCM_TAG_BYTES)
                    .joinToString("") { "%02x".format(it.toInt() and BYTE_MASK) }
            if (seen.add(hash)) hashes += hash
        }

        val bandSize = BITS_PER_BYTE
        val bandCount = dimensions / bandSize
        for (band in 0 until bandCount) {
            var value = 0
            for (bit in 0 until bandSize) {
                val index = band * bandSize + bit
                if (accumulator[index] >= 0) value = value or (1 shl bit)
            }
            appendBucket("simhash:v1:band:$band:%02x".format(value))
        }

        for (feature in features.take(maxOf(0, limit - hashes.size))) {
            appendBucket("feature:v1:${feature.name}")
        }
        return hashes
    }

    fun normalizedTokens(text: String): List<String> = text.lowercase()
        .split(Regex("[^a-z0-9]+"))
        .filter { it.length >= 2 && it !in stopwords }

    private data class SemanticFeature(val name: String, val weight: Double)

    private fun semanticFeatures(tokens: List<String>): List<SemanticFeature> {
        val features = mutableListOf<SemanticFeature>()
        val seen = linkedSetOf<String>()

        fun append(name: String, weight: Double) {
            if (name.isBlank() || !seen.add(name)) return
            features += SemanticFeature(name, weight)
        }

        for (token in tokens) {
            append("token:$token", SEMANTIC_TOKEN_WEIGHT)
            val stem = simpleSemanticStem(token)
            if (stem != token) append("stem:$stem", SEMANTIC_STEM_WEIGHT)
            if (token.length >= MIN_TOKEN_LENGTH_FOR_PREFIX) {
                append("prefix:${token.take(MIN_TOKEN_LENGTH_FOR_PREFIX)}", SEMANTIC_PREFIX_WEIGHT)
            }
        }
        if (tokens.size >= 2) {
            for (index in 0 until tokens.lastIndex) {
                append("bigram:${tokens[index]}_${tokens[index + 1]}", SEMANTIC_BIGRAM_WEIGHT)
            }
        }
        return features
    }

    private fun simpleSemanticStem(token: String): String {
        val suffixes = listOf("ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s")
        for (suffix in suffixes) {
            if (token.length > suffix.length + MIN_STEM_SUFFIX_OVERHEAD && token.endsWith(suffix)) {
                val stem = token.dropLast(suffix.length)
                return if (suffix == "ies" || suffix == "ied") stem + "y" else stem
            }
        }
        return token
    }

    internal fun hkdfSha256(input: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val effectiveSalt = if (salt.isEmpty()) ByteArray(SHA256_DIGEST_BYTES) else salt
        val extractMac = Mac.getInstance("HmacSHA256")
        extractMac.init(SecretKeySpec(effectiveSalt, "HmacSHA256"))
        val prk = extractMac.doFinal(input)
        val output = ByteArray(length)
        var previous = ByteArray(0)
        var written = 0
        var counter = 1
        while (written < length) {
            val expandMac = Mac.getInstance("HmacSHA256")
            expandMac.init(SecretKeySpec(prk, "HmacSHA256"))
            expandMac.update(previous)
            expandMac.update(info)
            expandMac.update(counter.toByte())
            previous = expandMac.doFinal()
            val copy = minOf(previous.size, length - written)
            System.arraycopy(previous, 0, output, written, copy)
            written += copy
            counter += 1
        }
        return output
    }
}
