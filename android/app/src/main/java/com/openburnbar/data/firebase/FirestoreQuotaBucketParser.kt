package com.openburnbar.data.firebase

import com.google.firebase.Timestamp
import com.openburnbar.data.models.QuotaBucket

internal object FirestoreQuotaBucketParser {
    fun parse(raw: Map<*, *>): QuotaBucket? {
        val meta = FirestoreQuotaBucketMeta.normalize(raw["meta"]).toMutableMap()
        mergeMetaFields(raw, meta)
        val name = readName(raw) ?: return null
        val unit = readUnit(raw, meta)?.lowercase()
        val values = FirestoreQuotaBucketValues.resolve(raw, meta, unit)
        return QuotaBucket(
            name = name,
            used = values.used,
            limit = values.limit,
            remaining = values.remaining,
            window = stringValue(raw["window"]) ?: stringValue(raw["windowKind"]),
            resetsAt = raw["resetsAt"] as? Timestamp,
            meta = meta.takeIf { it.isNotEmpty() },
        )
    }

    private fun mergeMetaFields(raw: Map<*, *>, meta: MutableMap<String, Any?>) {
        val rawUnit = stringValue(raw["unit"]) ?: stringValue(meta["unit"])
        if (rawUnit != null && meta["unit"] == null) {
            meta["unit"] = rawUnit
        }
        if (meta["label"] == null) {
            stringValue(raw["label"])?.let { meta["label"] = it }
        }
        if (meta["isEstimated"] == null && raw["isEstimated"] != null) {
            meta["isEstimated"] = stringValue(raw["isEstimated"]) ?: raw["isEstimated"].toString()
        }
        if (meta["usedPercent"] == null) {
            numberValue(raw["usedPercent"])?.let { meta["usedPercent"] = it }
        }
        if (meta["resetsAt"] == null) {
            stringValue(raw["resetsAt"])?.let { meta["resetsAt"] = it }
        }
    }

    private fun readName(raw: Map<*, *>): String? {
        val name =
            stringValue(raw["name"])
                ?: stringValue(raw["key"])
                ?: stringValue(raw["label"])
        return name?.takeIf { it.isNotBlank() }
    }

    private fun readUnit(raw: Map<*, *>, meta: Map<String, Any?>): String? =
        stringValue(raw["unit"]) ?: stringValue(meta["unit"])

    private fun stringValue(value: Any?): String? =
        when (value) {
            is String -> value.takeIf { it.isNotBlank() }
            is Number, is Boolean -> value.toString()
            else -> null
        }

    private fun numberValue(value: Any?): Double? =
        when (value) {
            is Number -> value.toDouble()
            is String -> value.trim().removeSuffix("%").toDoubleOrNull()
            else -> null
        }
}

private object FirestoreQuotaBucketMeta {
    fun normalize(raw: Any?): Map<String, Any?> {
        val map = raw as? Map<*, *> ?: return emptyMap()
        return map.entries
            .mapNotNull { (key, value) ->
                val stringKey = key as? String ?: return@mapNotNull null
                stringKey to value
            }
            .toMap()
    }
}

private object FirestoreQuotaBucketValues {
    data class Resolved(val used: Double, val limit: Double, val remaining: Double)

    fun resolve(raw: Map<*, *>, meta: MutableMap<String, Any?>, unit: String?): Resolved {
        var used = numberValue(raw, "used", "usedValue")
        var limit = numberValue(raw, "limit", "limitValue")
        var remaining = numberValue(raw, "remaining", "remainingValue")
        val usedPercent = numberValue(raw, "usedPercent") ?: numberValue(meta["usedPercent"])

        applyNegativeLimit(used, limit, remaining, meta).also {
            used = it.used
            limit = it.limit
            remaining = it.remaining
        }

        val adjusted = applyPercentAndDerivations(unit, used, limit, remaining, usedPercent)
        return Resolved(adjusted.used, adjusted.limit, adjusted.remaining)
    }

    private fun applyPercentAndDerivations(
        unit: String?,
        used: Double?,
        limit: Double?,
        remaining: Double?,
        usedPercent: Double?,
    ): Resolved {
        var resolvedUsed = used
        var resolvedLimit = normalizePercentLimit(unit, limit, usedPercent, remaining)
        resolvedUsed = deriveUsedFromPercent(resolvedUsed, usedPercent)
        val limitValue = resolvedLimit ?: 0.0
        var resolvedRemaining = remaining
        resolvedRemaining = deriveRemainingFromUsed(unit, resolvedUsed, limitValue, resolvedRemaining, resolvedLimit)
        resolvedUsed = deriveUsedFromRemaining(resolvedUsed, resolvedRemaining, limitValue, resolvedLimit)
        return Resolved(resolvedUsed ?: 0.0, resolvedLimit ?: 0.0, resolvedRemaining ?: 0.0)
    }

    private fun normalizePercentLimit(
        unit: String?,
        limit: Double?,
        usedPercent: Double?,
        remaining: Double?,
    ): Double? {
        val isPercentWithDerivedLimits =
            unit == "percent" && (limit == null || limit == 0.0) &&
                (usedPercent != null || remaining != null)
        return if (isPercentWithDerivedLimits) 100.0 else limit
    }

    private fun deriveUsedFromPercent(used: Double?, usedPercent: Double?): Double? =
        if (used == null && usedPercent != null) usedPercent else used

    private fun deriveRemainingFromUsed(
        unit: String?,
        used: Double?,
        limitValue: Double,
        remaining: Double?,
        limit: Double?,
    ): Double? {
        val canDeriveRemainingFromUsed =
            remaining == null && unit == "percent" && used != null && limitValue > 0.0
        return if (canDeriveRemainingFromUsed) {
            maxOf(0.0, (limit ?: 100.0) - used)
        } else {
            remaining
        }
    }

    private fun deriveUsedFromRemaining(
        used: Double?,
        remaining: Double?,
        limitValue: Double,
        limit: Double?,
    ): Double? {
        val canDeriveUsedFromRemaining = used == null && remaining != null && limitValue > 0.0
        return if (canDeriveUsedFromRemaining) {
            maxOf(0.0, (limit ?: 100.0) - remaining)
        } else {
            used
        }
    }

    private data class LimitTriple(val used: Double?, val limit: Double?, val remaining: Double?)

    private fun applyNegativeLimit(
        used: Double?,
        limit: Double?,
        remaining: Double?,
        meta: MutableMap<String, Any?>,
    ): LimitTriple {
        if (limit == null || limit >= 0.0) return LimitTriple(used, limit, remaining)
        if (remaining != null && remaining > 0.0) {
            val resolvedUsed = maxOf(0.0, used ?: 0.0)
            meta.putIfAbsent("limitKind", "remainingOnly")
            return LimitTriple(resolvedUsed, remaining + resolvedUsed, remaining)
        }
        meta.putIfAbsent("unit", "unlimited")
        meta.putIfAbsent("limitKind", "unlimited")
        return LimitTriple(0.0, 100.0, 100.0)
    }

    private fun numberValue(raw: Map<*, *>, vararg keys: String): Double? {
        for (key in keys) {
            numberValue(raw[key])?.let { return it }
        }
        return null
    }

    private fun numberValue(value: Any?): Double? =
        when (value) {
            is Number -> value.toDouble()
            is String -> value.trim().removeSuffix("%").toDoubleOrNull()
            else -> null
        }
}

internal fun Map<*, *>.toQuotaBucket(): QuotaBucket? = FirestoreQuotaBucketParser.parse(this)
