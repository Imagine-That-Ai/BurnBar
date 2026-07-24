package com.openburnbar.wallpaper.livingthemes

import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

data class LivingThemeRequest(
    val theme: LiveTheme,
    val maxFps: Int,
)

object LivingThemeIntent {
    private val supportedHosts = setOf("living-theme", "live-wallpaper")

    fun parse(rawURL: String?): LivingThemeRequest? {
        val uri = runCatching { URI(rawURL) }.getOrNull() ?: return null
        if (uri.scheme?.lowercase() != "burnbar" || uri.host?.lowercase() !in supportedHosts) {
            return null
        }
        val query =
            uri.rawQuery.orEmpty()
                .split("&")
                .mapNotNull { pair ->
                    val parts = pair.split("=", limit = 2)
                    if (parts.isEmpty()) return@mapNotNull null
                    val key = URLDecoder.decode(parts[0], StandardCharsets.UTF_8)
                    val value =
                        URLDecoder.decode(
                            parts.getOrElse(1) { "" },
                            StandardCharsets.UTF_8,
                        )
                    key to value
                }
                .toMap()
        val rawTheme = query["theme"] ?: query["kernel"]
        val theme = LiveTheme.entries.firstOrNull { it.id == rawTheme?.trim()?.lowercase() } ?: return null
        val fps =
            when (query["quality"]?.lowercase()) {
                "cinema" -> 60
                "atelier" -> 30
                else -> LivingThemePrefs.DEFAULT_FPS
            }
        return LivingThemeRequest(theme, fps)
    }
}
