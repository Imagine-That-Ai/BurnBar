@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.widget

import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.openburnbar.data.assistants.AssistantQuickPromptCatalog
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.models.AgentProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshot

@Composable
internal fun LargeContent(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier =
        GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.background)
            .cornerRadius(22.dp)
            .padding(16.dp)
            .clickable(openDashboardAction()),
    ) {
        LargeHeaderRow(windowKey = snap.windowKey)
        Spacer(modifier = GlanceModifier.height(8.dp))
        LargeHeroMetricsRow(snap = snap)
        Spacer(modifier = GlanceModifier.height(8.dp))
        LargeSparklineSection(dailyPoints = snap.dailyPoints)
        Spacer(modifier = GlanceModifier.height(8.dp))
        LargeModelChipsSection(topModels = snap.topModels)
        LargeProviderRowsSection(snap = snap)
        LargeAskChipSection()
    }
}

@Composable
private fun LargeHeaderRow(windowKey: String) {
    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "BURN BAR",
            style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Bold, color = WidgetTheme.textFaint),
            modifier = GlanceModifier.defaultWeight(),
        )
        Text(
            text = windowKey.uppercase(),
            style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Bold, color = WidgetTheme.textFaint),
        )
    }
}

@Composable
private fun LargeHeroMetricsRow(snap: BurnBarWidgetSnapshot) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(
            text = formatCost(snap.heroTotalCost),
            style = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.Bold, color = ColorProvider(WidgetTheme.ember)),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.width(10.dp))
        Text(
            text = formatTokensCompact(snap.heroTotalTokens),
            style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, color = WidgetTheme.text),
            maxLines = 1,
        )
        Text(
            text = " tokens",
            style = TextStyle(fontSize = 11.sp, color = WidgetTheme.textSubtle),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.defaultWeight())
        WidgetMetricBadge(label = "requests", value = snap.heroTotalRequests.toString())
    }
}

@Composable
private fun LargeSparklineSection(dailyPoints: List<Double>) {
    if (dailyPoints.size < 2) return
    Box(
        modifier =
        GlanceModifier
            .fillMaxWidth()
            .height(52.dp),
    ) {
        val bitmap =
            renderSparklineBitmap(
                values = dailyPoints,
                widthPx = 600,
                heightPx = 130,
            )
        Image(
            provider = ImageProvider(bitmap),
            contentDescription = null,
            modifier = GlanceModifier.fillMaxSize(),
            contentScale = ContentScale.Fit,
        )
    }
}

@Composable
private fun LargeModelChipsSection(topModels: List<String>) {
    if (topModels.isEmpty()) return
    Row {
        topModels.take(4).forEach { model ->
            WidgetModelChip(model = model)
            Spacer(modifier = GlanceModifier.width(4.dp))
        }
    }
    Spacer(modifier = GlanceModifier.height(8.dp))
}

@Composable
private fun LargeProviderRowsSection(snap: BurnBarWidgetSnapshot) {
    val totalTokens = snap.topProviderTokens.sum().coerceAtLeast(1L)
    snap.topProviders.take(3).forEachIndexed { i, providerName ->
        val tokens = snap.topProviderTokens.getOrNull(i) ?: 0L
        ProviderRow(
            rank = i + 1,
            name = providerName,
            tokens = tokens,
            totalTokens = totalTokens,
        )
        Spacer(modifier = GlanceModifier.height(6.dp))
    }
}

@Composable
private fun LargeAskChipSection() {
    Spacer(modifier = GlanceModifier.height(6.dp))
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        WidgetAskChip(
            label = "Ask Hermes",
            assistant = ASK_CHIP_ASSISTANT_HERMES,
            glyph = AssistantRuntimeID.HERMES.glyph,
            accent = WidgetTheme.amber,
            prominent = true,
            modifier = GlanceModifier.defaultWeight(),
        )
        Spacer(modifier = GlanceModifier.width(6.dp))
        WidgetAskChip(
            label = "Ask Pi",
            assistant = ASK_CHIP_ASSISTANT_PI,
            glyph = AssistantRuntimeID.PI.glyph,
            accent = WidgetTheme.whimsy,
            prominent = true,
            modifier = GlanceModifier.defaultWeight(),
        )
    }
    Spacer(modifier = GlanceModifier.height(5.dp))
    Row(modifier = GlanceModifier.fillMaxWidth()) {
        AssistantQuickPromptCatalog.hermesShortlist.take(3).forEachIndexed { idx, prompt ->
            if (idx > 0) Spacer(modifier = GlanceModifier.width(5.dp))
            WidgetAskChip(
                label = prompt.chipLabel,
                assistant =
                if (prompt.preferredAssistant == AssistantRuntimeID.PI) {
                    ASK_CHIP_ASSISTANT_PI
                } else {
                    ASK_CHIP_ASSISTANT_HERMES
                },
                prompt = prompt.fullPrompt,
                accent = WidgetTheme.amber,
                prominent = false,
                modifier = GlanceModifier.defaultWeight(),
            )
        }
    }
}

@Composable
internal fun ProviderRow(rank: Int, name: String, tokens: Long, totalTokens: Long) {
    val agent = AgentProvider.fromKey(name) ?: AgentProvider.fromKey(name.lowercase())
    val accent = agent?.let { androidx.compose.ui.graphics.Color(it.brandColor) } ?: WidgetTheme.ember
    val pct = if (totalTokens > 0) tokens.toFloat() / totalTokens.toFloat() else 0f

    Row(
        modifier = GlanceModifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = rank.toString(),
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Bold, color = WidgetTheme.textFaint),
        )
        Spacer(modifier = GlanceModifier.width(8.dp))
        Text(
            text = agent?.displayName ?: name,
            style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, color = WidgetTheme.text),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.defaultWeight())
        Text(
            text = formatTokensCompact(tokens),
            style = TextStyle(fontSize = 11.sp, color = WidgetTheme.textSubtle),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.width(8.dp))
        WidgetProgressBar(progress = pct, accent = accent, trackWidthDp = 90)
    }
}
