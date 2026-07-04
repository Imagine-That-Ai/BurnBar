package com.openburnbar.data.memory

import com.google.firebase.auth.FirebaseAuth
import com.openburnbar.data.cloud.CloudConversationSearchService
import com.openburnbar.data.cloud.CloudVaultSealedText
import com.openburnbar.data.cloud.PensieveVectorCloak
import com.openburnbar.data.firebase.FunctionsRepository
import com.openburnbar.data.security.LLMSafeContent

/** Sealed Pensieve recall for Hermes prompt injection on Android (F1). */
class MobilePensieveRecallService(
    private val functions: FunctionsRepository = FunctionsRepository(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val cloudSearch: CloudConversationSearchService = CloudConversationSearchService(functions),
) {
    suspend fun recallSection(query: String, tokenBudget: Int = DEFAULT_TOKEN_BUDGET): String {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return ""
        val uid = auth.currentUser?.uid ?: return ""
        val vaultKey = cloudSearch.unlockVaultKeyOrNull() ?: return ""
        val hits =
            runCatching {
                search(trimmed, vaultKey, uid, limit = 8)
            }.getOrDefault(emptyList())
        if (hits.isEmpty()) return ""
        var spent = 0
        val blocks = mutableListOf<String>()
        val overhead = 120
        for (hit in hits) {
            val wrapped = LLMSafeContent.wrapUntrusted(hit.text, "pensieve:${hit.id}")
            val cost = maxOf(1, hit.text.length / 3) + overhead
            if (cost > tokenBudget - spent) continue
            spent += cost
            blocks.add(wrapped)
        }
        return blocks.joinToString("\n\n")
    }

    private suspend fun search(query: String, vaultKey: ByteArray, uid: String, limit: Int): List<RecallHit> {
        val (modelVersion, vector) = PensieveVectorCloak.embedAndCloak(query, vaultKey, isQuery = true)
        val raw = functions.searchKnowledge(queryVector = vector, embeddingModelVersion = modelVersion, limit = limit)
        val hits = raw["hits"].asObjectList() ?: return emptyList()
        return hits.mapNotNull { decodeHit(it, uid, vaultKey) }
    }

    private fun decodeHit(raw: Map<String, Any?>, uid: String, vaultKey: ByteArray): RecallHit? {
        val vectorId = (raw["vectorId"] as? String) ?: (raw["chunkId"] as? String) ?: return null
        val id = vectorId
        val sealed = decodeSealed(raw["ciphertext"]) ?: return null
        val text = PensieveVectorCloak.openKnowledgeHitText(sealed, vaultKey, uid, vectorId) ?: return null
        val score = (raw["score"] as? Number)?.toDouble() ?: 0.0
        return RecallHit(id = id, text = text, score = score)
    }

    private fun decodeSealed(raw: Any?): CloudVaultSealedText? {
        val dict = raw as? Map<*, *> ?: return null
        val algorithm = dict["algorithm"] as? String ?: return null
        val nonce = dict["nonce"] as? String ?: return null
        val ciphertext = dict["ciphertext"] as? String ?: return null
        val tag = dict["tag"] as? String ?: return null
        val keyVersion = (dict["keyVersion"] as? Number)?.toInt() ?: 1
        val schemaVersion = (dict["schemaVersion"] as? Number)?.toInt()
        val aad = dict["aad"] as? String
        return CloudVaultSealedText(
            schemaVersion = schemaVersion,
            algorithm = algorithm,
            keyVersion = keyVersion,
            nonce = nonce,
            ciphertext = ciphertext,
            tag = tag,
            aad = aad,
        )
    }

    private data class RecallHit(val id: String, val text: String, val score: Double)

    private fun Any?.asObjectList(): List<Map<String, Any?>>? =
        (this as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.entries?.associate { (k, v) -> k.toString() to v }
        }

    companion object {
        const val DEFAULT_TOKEN_BUDGET: Int = 900
    }
}
