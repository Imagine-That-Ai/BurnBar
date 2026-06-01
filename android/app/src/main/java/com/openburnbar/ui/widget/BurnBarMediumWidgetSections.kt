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
import com.openburnbar.data.hermes.AssistantRuntimeID
import com.openburnbar.data.widget.BurnBarWidgetSnapshot

@Composable
internal fun MediumContent(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier =
        GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.background)
            .cornerRadius(20.dp),
    ) {
        Row(
            modifier =
            GlanceModifier
                .fillMaxWidth()
                .defaultWeight()
                .clickable(openDashboardAction()),
        ) {
            MediumMetricPanel(snap = snap)
            MediumDivider()
            MediumSparklinePanel(snap = snap)
        }
        MediumAskChipRow()
    }
}

@Composable
private fun MediumMetricPanel(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier =
        GlanceModifier
            .fillMaxHeight()
            .width(150.dp)
            .padding(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = "BURN BAR",
            style = TextStyle(fontSize = 10.sp, fontWeight = FontWeight.Bold, color = WidgetTheme.textFaint),
        )
        Spacer(modifier = GlanceModifier.defaultWeight())
        Text(
            text = formatCost(snap.heroTotalCost),
            style = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold, color = ColorProvider(WidgetTheme.ember)),
            maxLines = 1,
        )
        Spacer(modifier = GlanceModifier.height(2.dp))
        Text(
            text = "${formatTokensCompact(snap.heroTotalTokens)} tokens",
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = WidgetTheme.textSubtle),
            maxLines = 1,
        )
        val top = snap.topProviders.firstOrNull()
        val tokens = snap.topProviderTokens.firstOrNull()
        if (!top.isNullOrBlank()) {
            Spacer(modifier = GlanceModifier.height(6.dp))
            WidgetProviderPill(name = top, tokens = tokens)
        }
    }
}

@Composable
private fun MediumDivider() {
    Box(
        modifier =
        GlanceModifier
            .fillMaxHeight()
            .width(1.dp)
            .background(WidgetTheme.accentAmber),
    ) {}
}

@Composable
private fun MediumSparklinePanel(snap: BurnBarWidgetSnapshot) {
    Box(
        modifier =
        GlanceModifier
            .fillMaxHeight()
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (snap.dailyPoints.size >= 2) {
            val bitmap = renderSparklineBitmap(values = snap.dailyPoints, widthPx = 320, heightPx = 140)
            Image(
                provider = ImageProvider(bitmap),
                contentDescription = null,
                modifier = GlanceModifier.fillMaxSize(),
                contentScale = ContentScale.Fit,
            )
        } else {
            Text(
                text = "No history yet",
                style = TextStyle(fontSize = 11.sp, color = WidgetTheme.textFaint),
            )
        }
    }
}

@Composable
private fun MediumAskChipRow() {
    Row(
        modifier =
        GlanceModifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
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
}
