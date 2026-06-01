@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest
import org.json.JSONArray
import org.json.JSONObject

internal fun TrendDataDigest.toCompactJson(): String {
    val root = JSONObject()
    root.put("displayMode", displayMode.key)
    root.put("windowDescription", windowDescription)
    root.put("totals", totals.toCompactJsonArray())
    root.put("providers", providers.take(6).toProviderCompactJsonArray())
    root.put("models", models.take(6).toModelCompactJsonArray())
    root.put("daily", daily.takeLast(14).toDailyCompactJsonArray())
    root.put("hourly", hourly.toHourlyCompactJsonArray())
    root.put("cache", cache.toCompactJsonObject())
    return root.toString()
}

private fun List<TrendDataDigest.WindowTotals>.toCompactJsonArray(): JSONArray {
    val arr = JSONArray()
    for (t in this) {
        arr.put(
            JSONObject().apply {
                put("window", t.window)
                put("costUsd", round(t.costUsd, 4))
                put("tokens", t.tokens)
                put("requests", t.requests)
            },
        )
    }
    return arr
}

private fun List<TrendDataDigest.ProviderSlice>.toProviderCompactJsonArray(): JSONArray {
    val arr = JSONArray()
    for (p in this) {
        arr.put(
            JSONObject().apply {
                put("provider", p.provider)
                put("providerKey", p.providerKey)
                put("costUsd", round(p.costUsd, 4))
                put("tokens", p.tokens)
                put("requests", p.requests)
                put("sharePct", round(p.sharePct, 1))
            },
        )
    }
    return arr
}

private fun List<TrendDataDigest.ModelSlice>.toModelCompactJsonArray(): JSONArray {
    val arr = JSONArray()
    for (m in this) {
        arr.put(
            JSONObject().apply {
                put("model", m.model)
                put("provider", m.provider)
                put("providerKey", m.providerKey)
                put("costUsd", round(m.costUsd, 4))
                put("tokens", m.tokens)
                put("requests", m.requests)
                put("sharePct", round(m.sharePct, 1))
            },
        )
    }
    return arr
}

private fun List<TrendDataDigest.DailySeries>.toDailyCompactJsonArray(): JSONArray {
    val arr = JSONArray()
    for (d in this) {
        arr.put(
            JSONObject().apply {
                put("date", d.date)
                put("total", round(d.total, 4))
                val perProv = JSONObject()
                for ((k, v) in d.perProvider) perProv.put(k, round(v, 4))
                put("perProvider", perProv)
            },
        )
    }
    return arr
}

private fun List<TrendDataDigest.HourBucket>.toHourlyCompactJsonArray(): JSONArray {
    val arr = JSONArray()
    for (h in this) {
        arr.put(
            JSONObject().apply {
                put("hour", h.hour)
                put("costUsd", round(h.costUsd, 4))
                put("tokens", h.tokens)
            },
        )
    }
    return arr
}

private fun TrendDataDigest.CacheAggregate.toCompactJsonObject(): JSONObject =
    JSONObject().apply {
        put("totalCacheReadTokens", totalCacheReadTokens)
        put("totalCacheCreationTokens", totalCacheCreationTokens)
        put("totalInputTokens", totalInputTokens)
        put("cacheHitRate", round(cacheHitRate, 3))
        put("estSavingsUsd", round(estSavingsUsd, 3))
    }

internal fun round(v: Double, places: Int): Double {
    val mult = Math.pow(10.0, places.toDouble())
    return Math.round(v * mult) / mult
}
