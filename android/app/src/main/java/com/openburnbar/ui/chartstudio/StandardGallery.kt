package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest

/**
 * Always-available, Hermes-free content shown in Chart Studio's upper third:
 * three "quick fact" pills + a small grid of curated chart specs computed
 * purely from the digest. Mirrors iOS `StandardGallery`.
 */
object StandardGallery {

    data class QuickFact(
        val label: String,
        val value: String,
        val detail: String,
        val sparkline: List<Float> = emptyList()
    )

    data class GalleryItem(
        val title: String,
        val subtitle: String,
        val rendering: ChartStudioRendering
    )

    fun quickFacts(digest: TrendDataDigest): List<QuickFact> {
        val today = digest.totals.firstOrNull { it.window == "today" }
        val week = digest.totals.firstOrNull { it.window == "7d" }
        val topProvider = digest.providers.firstOrNull()
        val cacheRate = (digest.cache.cacheHitRate * 100).toInt()
        val dailyPoints = digest.daily.takeLast(7).map { it.total.toFloat() }

        return buildList {
            if (today != null) {
                add(
                    QuickFact(
                        label = "Today",
                        value = "$${"%.2f".format(today.costUsd)}",
                        detail = "${formatTokens(today.tokens)} tokens",
                        sparkline = dailyPoints
                    )
                )
            }
            if (topProvider != null && topProvider.sharePct > 0) {
                add(
                    QuickFact(
                        label = topProvider.provider,
                        value = "${topProvider.sharePct.toInt()}%",
                        detail = "$${"%.2f".format(topProvider.costUsd)} share",
                    )
                )
            }
            if (digest.cache.totalCacheReadTokens > 0) {
                add(
                    QuickFact(
                        label = "Cache",
                        value = "$cacheRate%",
                        detail = "≈ $${"%.2f".format(digest.cache.estSavingsUsd)} saved"
                    )
                )
            }
            if (week != null && size < 3) {
                add(
                    QuickFact(
                        label = "This week",
                        value = "$${"%.2f".format(week.costUsd)}",
                        detail = "${formatTokens(week.tokens)} tokens",
                        sparkline = dailyPoints
                    )
                )
            }
        }.take(3)
    }

    fun galleryItems(digest: TrendDataDigest): List<GalleryItem> {
        val items = mutableListOf<GalleryItem>()

        if (digest.daily.isNotEmpty()) {
            items += GalleryItem(
                title = "Spend last 14 days",
                subtitle = "Stacked by provider",
                rendering = stackedAreaSpec(digest)
            )
        }

        if (digest.providers.isNotEmpty()) {
            items += GalleryItem(
                title = "Provider share",
                subtitle = "Where your tokens land",
                rendering = donutSpec(digest)
            )
        }

        if (digest.models.isNotEmpty()) {
            items += GalleryItem(
                title = "Top models",
                subtitle = "By total cost",
                rendering = barSpec(digest)
            )
        }

        if (digest.hourly.any { it.tokens > 0 }) {
            items += GalleryItem(
                title = "Hour of day",
                subtitle = "Where your day burns brightest",
                rendering = hourlyHeatmapSpec(digest)
            )
        }

        if (digest.recentSessions.isNotEmpty()) {
            items += GalleryItem(
                title = "Cache constellation",
                subtitle = "Session duration vs hit rate",
                rendering = scatterSpec(digest)
            )
        }

        return items.take(6)
    }

    // ── Spec builders ──

    private fun stackedAreaSpec(digest: TrendDataDigest): ChartStudioRendering {
        val days = digest.daily.takeLast(14)
        val providerKeys = days.flatMap { it.perProvider.keys }.distinct().take(4)
        val series = providerKeys.map { key ->
            SeriesSpec(
                name = key.replaceFirstChar { it.uppercaseChar() },
                providerKey = key,
                data = days.map { DataPoint(x = it.date, y = it.perProvider[key] ?: 0.0) }
            )
        }
        return ChartStudioRendering.Native(
            ChartSpec(
                chart = ChartKind.STACKED_AREA,
                title = null,
                subtitle = null,
                xAxis = AxisSpec(type = "time"),
                yAxis = AxisSpec(format = "currency"),
                series = series
            )
        )
    }

    private fun donutSpec(digest: TrendDataDigest): ChartStudioRendering {
        val data = digest.providers.take(5).map {
            DataPoint(x = it.providerKey, y = it.costUsd, label = it.provider)
        }
        return ChartStudioRendering.Native(
            ChartSpec(
                chart = ChartKind.DONUT,
                title = null,
                subtitle = null,
                legend = true,
                series = listOf(SeriesSpec(name = "Providers", data = data))
            )
        )
    }

    private fun barSpec(digest: TrendDataDigest): ChartStudioRendering {
        val data = digest.models.take(5).map {
            DataPoint(x = it.model.take(14), y = it.costUsd)
        }
        return ChartStudioRendering.Native(
            ChartSpec(
                chart = ChartKind.BAR,
                title = null,
                subtitle = null,
                xAxis = AxisSpec(type = "category"),
                yAxis = AxisSpec(format = "currency"),
                series = listOf(SeriesSpec(name = "Cost", data = data, color = "F45B69"))
            )
        )
    }

    private fun hourlyHeatmapSpec(digest: TrendDataDigest): ChartStudioRendering {
        val data = digest.hourly.map {
            DataPoint(x = it.hour.toString(), y = it.tokens.toDouble())
        }
        return ChartStudioRendering.Native(
            ChartSpec(
                chart = ChartKind.HEATMAP,
                title = null,
                subtitle = null,
                legend = false,
                series = listOf(SeriesSpec(name = "Tokens", data = data, color = "F28C38"))
            )
        )
    }

    private fun scatterSpec(digest: TrendDataDigest): ChartStudioRendering {
        val data = digest.recentSessions.map {
            DataPoint(x = it.durationSec.toString(), y = it.cacheHitRate, label = it.model)
        }
        return ChartStudioRendering.Native(
            ChartSpec(
                chart = ChartKind.SCATTER,
                title = null,
                subtitle = null,
                xAxis = AxisSpec(label = "Duration (s)"),
                yAxis = AxisSpec(label = "Cache hit rate"),
                series = listOf(SeriesSpec(name = "Sessions", data = data, color = "6A5ACD")),
                rules = listOf(
                    RuleSpec(orientation = "horizontal", value = 0.75, color = "38D898", label = "Ideal 75%", dashed = true)
                )
            )
        )
    }

    private fun formatTokens(n: Long): String = when {
        n >= 1_000_000_000 -> "%.1fB".format(n / 1_000_000_000.0)
        n >= 1_000_000     -> "%.1fM".format(n / 1_000_000.0)
        n >= 1_000         -> "%.1fK".format(n / 1_000.0)
        else               -> n.toString()
    }
}
