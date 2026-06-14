package com.openburnbar.wallpaper

import android.content.SharedPreferences
import com.openburnbar.data.models.AgentProvider

internal object BurnBarWallpaperGlyphSettings {
    const val KEY = "provider_glyphs"

    private const val ALL_SENTINEL = "__all__"
    private const val NONE_SENTINEL = "__none__"

    fun read(prefs: SharedPreferences): Set<AgentProvider> {
        val raw = prefs.getString(KEY, ALL_SENTINEL)?.trim().orEmpty()
        if (raw.isEmpty() || raw == ALL_SENTINEL) {
            return AgentProvider.swarmGlyphProviders.toSet()
        }
        if (raw == NONE_SENTINEL) {
            return emptySet()
        }

        val providers =
            raw
                .split(',')
                .mapNotNull { AgentProvider.fromKey(it.trim()) }
                .toSet()
        return providers.ifEmpty { AgentProvider.swarmGlyphProviders.toSet() }
    }

    fun write(prefs: SharedPreferences, providers: Set<AgentProvider>) {
        val ordered = AgentProvider.swarmGlyphProviders.filter { providers.contains(it) }
        val encoded =
            when {
                ordered.isEmpty() -> NONE_SENTINEL
                ordered == AgentProvider.swarmGlyphProviders -> ALL_SENTINEL
                else -> ordered.joinToString(separator = ",") { it.key }
            }
        prefs.edit().putString(KEY, encoded).apply()
    }
}
