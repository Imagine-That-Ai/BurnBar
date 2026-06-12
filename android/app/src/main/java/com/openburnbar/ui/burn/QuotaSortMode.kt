package com.openburnbar.ui.burn

import com.openburnbar.data.models.QuotaBucket

enum class QuotaSortMode(val label: String) {
    URGENCY("Urgency"),
    SPEND("Spend"),
    ALPHABETICAL("A \u2192 Z"),
    RECENTLY_REFRESHED("Recently refreshed");

    companion object {
        fun fromString(s: String?): QuotaSortMode = values().firstOrNull { it.name.equals(s, true) } ?: URGENCY
    }
}

val QuotaBucket.isEstimated: Boolean
    get() = meta?.get("isEstimated")?.toString()?.lowercase() == "true"
        || meta?.get("estimated")?.toString()?.lowercase() == "true"
