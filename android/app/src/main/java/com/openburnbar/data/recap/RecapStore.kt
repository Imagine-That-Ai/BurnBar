package com.openburnbar.data.recap

import android.content.Context
import java.io.File
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

class RecapStore(
    context: Context,
    accountID: String? = null,
) {
    private val scopeDir: File = run {
        val scope = accountScope(accountID)
        val dir = File(context.filesDir, "recap/$scope")
        if (!dir.exists()) dir.mkdirs()
        dir
    }

    private val recapsFile = File(scopeDir, "recaps.json")
    private val historyFile = File(scopeDir, "history.json")

    suspend fun saveRecap(recap: MonthlyRecap) = withContext(Dispatchers.IO) {
        val root = readJson(recapsFile)
        val recapsObj = root.optJSONObject("recaps") ?: JSONObject()
        recapsObj.put(recap.window.key, RecapStoreCodec.serializeRecap(recap))
        root.put("recaps", recapsObj)
        writeJson(recapsFile, root)
    }

    suspend fun loadRecap(window: RecapWindow): MonthlyRecap? = withContext(Dispatchers.IO) {
        val root = readJson(recapsFile)
        val recapsObj = root.optJSONObject("recaps") ?: return@withContext null
        val obj = recapsObj.optJSONObject(window.key) ?: return@withContext null
        RecapStoreCodec.deserializeRecap(window, obj)
    }

    suspend fun availableMonths(): List<RecapWindow> = withContext(Dispatchers.IO) {
        val root = readJson(recapsFile)
        val recapsObj = root.optJSONObject("recaps") ?: return@withContext emptyList()
        val keys = recapsObj.keys()
        val list = mutableListOf<RecapWindow>()
        while (keys.hasNext()) {
            val key = keys.next()
            RecapWindow.parse(key)?.let { list.add(it) }
        }
        list.sortedDescending()
    }

    suspend fun saveFacts(facts: RecapFacts) = withContext(Dispatchers.IO) {
        val root = readJson(historyFile)
        val factsObj = root.optJSONObject("facts") ?: JSONObject()
        factsObj.put(facts.window.key, RecapStoreCodec.serializeFacts(facts))
        root.put("facts", factsObj)
        writeJson(historyFile, root)
    }

    suspend fun loadFacts(window: RecapWindow): RecapFacts? = withContext(Dispatchers.IO) {
        val root = readJson(historyFile)
        val factsObj = root.optJSONObject("facts") ?: return@withContext null
        val obj = factsObj.optJSONObject(window.key) ?: return@withContext null
        RecapStoreCodec.deserializeFacts(window, obj)
    }

    suspend fun loadAllFacts(): List<RecapFacts> = withContext(Dispatchers.IO) {
        val root = readJson(historyFile)
        val factsObj = root.optJSONObject("facts") ?: return@withContext emptyList()
        val list = mutableListOf<RecapFacts>()
        val keys = factsObj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val w = RecapWindow.parse(k)
            val o = factsObj.optJSONObject(k)
            if (w != null && o != null) {
                RecapStoreCodec.deserializeFacts(w, o)?.let { list.add(it) }
            }
        }
        list.sortedByDescending { it.window }
    }

    private fun readJson(file: File): JSONObject {
        if (!file.exists()) return JSONObject()
        return try {
            JSONObject(file.readText())
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun writeJson(file: File, json: JSONObject) {
        try {
            file.writeText(json.toString())
        } catch (_: Exception) {
            // Ignore storage write failure
        }
    }

    companion object {
        fun accountScope(accountID: String?): String {
            if (accountID.isNullOrEmpty()) return "local"
            var hash = RecapConstants.HASH_INIT
            for (b in accountID.toByteArray(Charsets.UTF_8)) {
                hash = ((hash shl RecapConstants.HASH_SHIFT) + hash) + b.toLong()
            }
            return String.format(Locale.US, "u%016x", hash)
        }
    }
}

object RecapStoreCodec {

    fun serializeRecap(recap: MonthlyRecap): JSONObject {
        val obj = JSONObject()
        obj.put("window", recap.window.key)
        obj.put("generatedAt", recap.generatedAtEpochMillis)
        obj.put("title", recap.title)
        recap.subtitle?.let { obj.put("subtitle", it) }
        obj.put("closingSentence", recap.closingSentence)
        obj.put("isVoiceAuthored", recap.isVoiceAuthored)
        obj.put("isPartial", recap.isPartial)
        obj.put("sealState", recap.sealState.name)

        val cardsArr = JSONArray()
        for (card in recap.cards) {
            cardsArr.put(serializeCard(card))
        }
        obj.put("cards", cardsArr)
        return obj
    }

    fun serializeCard(card: RecapCard): JSONObject {
        val cObj = JSONObject()
        val cand = card.candidate
        cObj.put("id", cand.id)
        cObj.put("ruleID", cand.ruleID)
        cObj.put("family", cand.family)
        cObj.put("kind", cand.kind.name)
        cObj.put("tone", cand.tone.name)
        cObj.put("headline", cand.headline)
        cObj.put("body", cand.body)
        cObj.put("size", card.size.name)
        cObj.put("visual", cand.visual.name)

        val mArr = JSONArray()
        for (m in cand.metrics) {
            val mObj = JSONObject()
            mObj.put("label", m.label)
            mObj.put("value", m.value)
            mObj.put("unit", m.unit.name)
            mObj.put("formatted", m.formatted)
            mArr.put(mObj)
        }
        cObj.put("metrics", mArr)

        cand.comparison?.let { comp ->
            val compObj = JSONObject()
            compObj.put("basis", comp.basis.name)
            compObj.put("referenceLabel", comp.referenceLabel)
            compObj.put("currentValue", comp.currentValue)
            compObj.put("referenceValue", comp.referenceValue)
            compObj.put("unit", comp.unit.name)
            cObj.put("comparison", compObj)
        }
        return cObj
    }

    fun deserializeRecap(window: RecapWindow, obj: JSONObject): MonthlyRecap? {
        return try {
            val title = obj.getString("title")
            val subtitle = obj.optString("subtitle").takeIf { it.isNotEmpty() }
            val closing = obj.getString("closingSentence")
            val isVoice = obj.optBoolean("isVoiceAuthored", false)
            val isPartial = obj.optBoolean("isPartial", false)
            val seal = try {
                RecapSealState.valueOf(obj.optString("sealState", RecapSealState.PREVIEW.name))
            } catch (_: Exception) {
                RecapSealState.PREVIEW
            }

            val cards = mutableListOf<RecapCard>()
            val cardsArr = obj.optJSONArray("cards") ?: JSONArray()
            for (i in 0 until cardsArr.length()) {
                val cObj = cardsArr.optJSONObject(i) ?: continue
                deserializeCard(cObj, i)?.let { cards.add(it) }
            }

            MonthlyRecap(
                window = window,
                generatedAtEpochMillis = obj.optLong("generatedAt", System.currentTimeMillis()),
                title = title,
                subtitle = subtitle,
                cards = cards,
                closingSentence = closing,
                isVoiceAuthored = isVoice,
                isPartial = isPartial,
                sealState = seal,
            )
        } catch (_: Exception) {
            null
        }
    }

    fun deserializeCard(cObj: JSONObject, index: Int): RecapCard? {
        return try {
            val id = cObj.optString("id", "card-$index")
            val ruleID = cObj.optString("ruleID", "")
            val family = cObj.optString("family", "")
            val kind = parseInsightKind(cObj.optString("kind"))
            val tone = parseTone(cObj.optString("tone"))
            val headline = cObj.optString("headline", "")
            val body = cObj.optString("body", "")
            val size = parseCardSize(cObj.optString("size"))
            val visual = parseVisual(cObj.optString("visual"))

            val metrics = deserializeMetrics(cObj.optJSONArray("metrics"))
            val comparison = deserializeComparison(cObj.optJSONObject("comparison"))

            val cand = RecapCandidate(
                id = id,
                ruleID = ruleID,
                family = family,
                kind = kind,
                tone = tone,
                headline = headline,
                body = body,
                metrics = metrics,
                comparison = comparison,
                visual = visual,
                suggestedSize = size,
            )
            RecapCard(candidate = cand, size = size)
        } catch (_: Exception) {
            null
        }
    }

    fun deserializeMetrics(mArr: JSONArray?): List<RecapMetric> {
        if (mArr == null) return emptyList()
        val metrics = mutableListOf<RecapMetric>()
        for (i in 0 until mArr.length()) {
            val mObj = mArr.optJSONObject(i) ?: continue
            val label = mObj.optString("label", "")
            val value = mObj.optDouble("value", 0.0)
            val unit = parseMetricUnit(mObj.optString("unit"))
            val formatted = mObj.optString("formatted", RecapMetric.format(value, unit))
            metrics.add(RecapMetric(label, value, unit, formatted))
        }
        return metrics
    }

    fun deserializeComparison(compObj: JSONObject?): RecapComparison? {
        if (compObj == null) return null
        return try {
            val basis = parseComparisonBasis(compObj.optString("basis"))
            val refLabel = compObj.optString("referenceLabel", "")
            val currentVal = compObj.optDouble("currentValue", 0.0)
            val refVal = compObj.optDouble("referenceValue", 0.0)
            val unit = parseMetricUnit(compObj.optString("unit"))
            RecapComparison(basis, refLabel, currentVal, refVal, unit)
        } catch (_: Exception) {
            null
        }
    }

    private fun parseInsightKind(s: String) = try {
        RecapInsightKind.valueOf(s)
    } catch (_: Exception) {
        RecapInsightKind.PERSONALITY
    }
    private fun parseTone(s: String) = try {
        RecapTone.valueOf(s)
    } catch (_: Exception) {
        RecapTone.MATTER_OF_FACT
    }
    private fun parseCardSize(s: String) = try {
        RecapCardSize.valueOf(s)
    } catch (_: Exception) {
        RecapCardSize.MEDIUM
    }
    private fun parseVisual(s: String) = try {
        RecapVisual.valueOf(s)
    } catch (_: Exception) {
        RecapVisual.NONE
    }
    private fun parseMetricUnit(s: String) = try {
        RecapMetricUnit.valueOf(s)
    } catch (_: Exception) {
        RecapMetricUnit.COUNT
    }
    private fun parseComparisonBasis(s: String) = try {
        RecapComparison.Basis.valueOf(s)
    } catch (_: Exception) {
        RecapComparison.Basis.PREVIOUS_MONTH
    }

    fun serializeFacts(facts: RecapFacts): JSONObject {
        val obj = JSONObject()
        obj.put("window", facts.window.key)
        obj.put("builtAt", facts.builtAtEpochMillis)
        obj.put("isPartial", facts.isPartial)
        obj.put("totalCostUSD", facts.totalCostUSD)
        obj.put("totalTokens", facts.totalTokens)
        obj.put("sessionCount", facts.sessionCount)
        obj.put("activeDayCount", facts.activeDayCount)
        obj.put("longestActiveStreak", facts.longestActiveStreak)
        obj.put("cacheHitRate", facts.cacheHitRate)
        obj.put("modelConcentration", facts.modelConcentration)
        return obj
    }

    fun deserializeFacts(window: RecapWindow, obj: JSONObject): RecapFacts? {
        return try {
            RecapFacts(
                window = window,
                builtAtEpochMillis = obj.optLong("builtAt", System.currentTimeMillis()),
                isPartial = obj.optBoolean("isPartial", false),
                totalCostUSD = obj.optDouble("totalCostUSD", 0.0),
                totalTokens = obj.optLong("totalTokens", 0L),
                sessionCount = obj.optInt("sessionCount", 0),
                activeDayCount = obj.optInt("activeDayCount", 0),
                longestActiveStreak = obj.optInt("longestActiveStreak", 0),
                cacheHitRate = obj.optDouble("cacheHitRate", 0.0),
                modelConcentration = obj.optDouble("modelConcentration", 0.0),
            )
        } catch (_: Exception) {
            null
        }
    }
}
