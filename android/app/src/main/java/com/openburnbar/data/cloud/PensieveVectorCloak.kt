package com.openburnbar.data.cloud

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Kotlin port of `PensieveVectorCloak.swift` deterministic embed + cloak path (F1 Android).
 * Produces byte-compatible cloaked query vectors for the `searchKnowledge` callable.
 */
object PensieveVectorCloak {
    const val DETERMINISTIC_MODEL_VERSION: String = "hashing-bow-v1"
    const val EMBEDDING_DIM: Int = 384
    private const val BGE_QUERY_INSTRUCTION: String = "Represent this sentence for searching relevant passages: "
    private const val CLOAK_REFLECTIONS: Int = 24
    private val CLOAK_SALT: ByteArray = "OpenBurnBar-Pensieve-Cloak-Salt-v1".toByteArray(Charsets.UTF_8)

    private val reflectionCache = mutableMapOf<Triple<String, String, Int>, Array<DoubleArray>>()

    fun deterministicEmbed(text: String, isQuery: Boolean = false): DoubleArray {
        val prepared = (if (isQuery) BGE_QUERY_INSTRUCTION else "") + text.lowercase()
        val acc = DoubleArray(EMBEDDING_DIM)
        val tokens =
            prepared.split(Regex("[^A-Za-z0-9]+"))
                .filter { it.length >= 2 }
        for (token in tokens) {
            val digest = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8))
            val index = ((digest[0].toInt() and 0xFF shl 8) or (digest[1].toInt() and 0xFF)) % EMBEDDING_DIM
            val sign = if ((digest[2].toInt() and 1) == 0) 1.0 else -1.0
            acc[index] += sign
        }
        return l2Normalize(acc)
    }

    fun embedAndCloak(
        text: String,
        vaultKey: ByteArray,
        isQuery: Boolean = false,
        modelVersion: String = DETERMINISTIC_MODEL_VERSION,
    ): Pair<String, List<Double>> {
        val raw = deterministicEmbed(text, isQuery)
        return modelVersion to cloak(raw, vaultKey, modelVersion)
    }

    fun cloak(vector: DoubleArray, vaultKey: ByteArray, modelVersion: String = DETERMINISTIC_MODEL_VERSION): List<Double> {
        val reflections = deriveReflections(vaultKey, modelVersion, vector.size)
        val x = vector.copyOf()
        for (v in reflections) {
            var dot = 0.0
            for (i in x.indices) dot += v[i] * x[i]
            val c = 2.0 * dot
            for (i in x.indices) x[i] -= c * v[i]
        }
        return x.toList()
    }

    fun openKnowledgeHitText(
        sealed: CloudVaultSealedText,
        vaultKey: ByteArray,
        uid: String?,
        vectorId: String?,
    ): String? =
        runCatching {
            val aad =
                if (uid != null && vectorId != null) {
                    CloudVaultAADContext(
                        uid = uid,
                        collection = "cloud_search_knowledge",
                        docID = vectorId,
                        field = "sealedCiphertext",
                    )
                } else {
                    null
                }
            CloudVaultCrypto.openText(sealed, vaultKey, aad)
        }.getOrNull()

    private fun deriveReflections(vaultKey: ByteArray, modelVersion: String, dim: Int): Array<DoubleArray> {
        val keyHash = sha256Hex(vaultKey).take(32)
        val cacheKey = Triple(keyHash, modelVersion, dim)
        reflectionCache[cacheKey]?.let { return it }
        val info = "OpenBurnBar-Pensieve-Cloak-$modelVersion-v1".toByteArray(Charsets.UTF_8)
        val byteLen = CLOAK_REFLECTIONS * dim * 2 * 4 + 64
        val keystream = CloudVaultCryptoSearch.hkdfSha256(vaultKey, CLOAK_SALT, info, byteLen)
        val uniform = UniformStream(keystream)
        val vectors = Array(CLOAK_REFLECTIONS) {
            val v = DoubleArray(dim)
            var normSq = 0.0
            for (i in 0 until dim) {
                val g = uniform.nextGaussian()
                v[i] = g
                normSq += g * g
            }
            val norm = sqrt(normSq)
            if (norm == 0.0) v[0] = 1.0 else for (i in 0 until dim) v[i] /= norm
            v
        }
        reflectionCache[cacheKey] = vectors
        return vectors
    }

    private fun l2Normalize(vector: DoubleArray): DoubleArray {
        var normSq = 0.0
        for (v in vector) normSq += v * v
        val norm = sqrt(normSq)
        if (norm <= 0.0) return vector
        return DoubleArray(vector.size) { vector[it] / norm }
    }

    private fun sha256Hex(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    private class UniformStream(bytes: ByteArray) {
        private val data = bytes
        private var offset = 0

        fun next(): Double {
            if (offset + 4 > data.size) offset = 0
            // Unsigned 32-bit (Swift UInt32). Signed Int shifts produce negatives and NaNs in Box-Muller.
            val u =
                ((data[offset].toLong() and 0xFF) shl 24) or
                    ((data[offset + 1].toLong() and 0xFF) shl 16) or
                    ((data[offset + 2].toLong() and 0xFF) shl 8) or
                    (data[offset + 3].toLong() and 0xFF)
            offset += 4
            return (u.toDouble() + 0.5) / 4_294_967_296.0
        }

        fun nextGaussian(): Double {
            val u1 = next()
            val u2 = next()
            return sqrt(-2.0 * ln(u1)) * cos(2.0 * Math.PI * u2)
        }
    }
}
