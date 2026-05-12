package com.openburnbar.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore

/**
 * 4×4 home-screen widget — iOS `DashboardLargeView` equivalent. Header +
 * hero metrics + sparkline + top-3 provider rows with progress bars +
 * "Updated HH:MM" footer.
 */
object BurnBarLargeWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        BurnBarWidgetSnapshotStore.bind(context)
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.preview
        provideContent { LargeContent(snap) }
    }
}

class BurnBarLargeWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BurnBarLargeWidget
}

@Composable
private fun LargeContent(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.background)
            .cornerRadius(22.dp)
            .padding(16.dp)
            .clickable(openDashboardAction())
    ) {
        // Header row — label + window key
        Row(
            modifier = GlanceModifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = "BURN BAR",
                style = TextStyle(
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = WidgetTheme.textFaint
                ),
                modifier = GlanceModifier.defaultWeight()
            )
            Text(
                text = snap.windowKey.uppercase(),
                style = TextStyle(
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = WidgetTheme.textFaint
                )
            )
        }

        Spacer(modifier = GlanceModifier.height(8.dp))

        // Hero metrics row — cost · tokens · requests badge
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = formatCost(snap.heroTotalCost),
                style = TextStyle(
                    fontSize = 30.sp,
                    fontWeight = FontWeight.Bold,
                    color = ColorProvider(WidgetTheme.ember)
                ),
                maxLines = 1
            )
            Spacer(modifier = GlanceModifier.width(10.dp))
            Text(
                text = formatTokensCompact(snap.heroTotalTokens),
                style = TextStyle(
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = WidgetTheme.text
                ),
                maxLines = 1
            )
            Text(
                text = " tokens",
                style = TextStyle(
                    fontSize = 11.sp,
                    color = WidgetTheme.textSubtle
                ),
                maxLines = 1
            )
            Spacer(modifier = GlanceModifier.defaultWeight())
            WidgetMetricBadge(
                label = "requests",
                value = snap.heroTotalRequests.toString()
            )
        }

        Spacer(modifier = GlanceModifier.height(8.dp))

        // Sparkline (52dp tall)
        if (snap.dailyPoints.size >= 2) {
            Box(
                modifier = GlanceModifier
                    .fillMaxWidth()
                    .height(52.dp)
            ) {
                val bitmap = renderSparklineBitmap(
                    values = snap.dailyPoints,
                    widthPx = 600,
                    heightPx = 130
                )
                Image(
                    provider = ImageProvider(bitmap),
                    contentDescription = null,
                    modifier = GlanceModifier.fillMaxSize(),
                    contentScale = ContentScale.Fit
                )
            }
        }

        Spacer(modifier = GlanceModifier.height(8.dp))

        // Model chips (max 4) — only render if available
        if (snap.topModels.isNotEmpty()) {
            Row {
                snap.topModels.take(4).forEach { model ->
                    WidgetModelChip(model = model)
                    Spacer(modifier = GlanceModifier.width(4.dp))
                }
            }
            Spacer(modifier = GlanceModifier.height(8.dp))
        }

        // Top 3 provider rows
        val totalTokens = snap.topProviderTokens.sum().coerceAtLeast(1L)
        snap.topProviders.take(3).forEachIndexed { i, providerName ->
            val tokens = snap.topProviderTokens.getOrNull(i) ?: 0L
            ProviderRow(
                rank = i + 1,
                name = providerName,
                tokens = tokens,
                totalTokens = totalTokens
            )
            Spacer(modifier = GlanceModifier.height(6.dp))
        }
    }
}

@Composable
private fun ProviderRow(rank: Int, name: String, tokens: Long, totalTokens: Long) {
    val agent = AgentProvider.fromKey(name) ?: AgentProvider.fromKey(name.lowercase())
    val accent = agent?.let { androidx.compose.ui.graphics.Color(it.brandColor) } ?: WidgetTheme.ember
    val pct = if (totalTokens > 0) tokens.toFloat() / totalTokens.toFloat() else 0f

    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = rank.toString(),
            style = TextStyle(
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = WidgetTheme.textFaint
            )
        )
        Spacer(modifier = GlanceModifier.width(8.dp))
        Text(
            text = agent?.displayName ?: name,
            style = TextStyle(
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = WidgetTheme.text
            ),
            maxLines = 1
        )
        Spacer(modifier = GlanceModifier.defaultWeight())
        Text(
            text = formatTokensCompact(tokens),
            style = TextStyle(
                fontSize = 11.sp,
                color = WidgetTheme.textSubtle
            ),
            maxLines = 1
        )
        Spacer(modifier = GlanceModifier.width(8.dp))
        WidgetProgressBar(progress = pct, accent = accent, trackWidthDp = 90)
    }
}
