package com.openburnbar.wallpaper

import android.content.SharedPreferences
import com.openburnbar.data.models.AgentProvider

internal object BurnBarWallpaperGlyphSettings {
    const val key = "provider_glyphs"

    private const val allSentinel = "__all__"
    private const val noneSentinel = "__none__"

    fun read(prefs: SharedPreferences): Set<AgentProvider> {
        val raw = prefs.getString(key, allSentinel)?.trim().orEmpty()
        if (raw.isEmpty() || raw == allSentinel) {
            return AgentProvider.swarmGlyphProviders.toSet()
        }
        if (raw == noneSentinel) {
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
                ordered.isEmpty() -> noneSentinel
                ordered == AgentProvider.swarmGlyphProviders -> allSentinel
                else -> ordered.joinToString(separator = ",") { it.key }
            }
        prefs.edit().putString(key, encoded).apply()
    }
}
