@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.widget

import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.cornerRadius
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
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
import com.openburnbar.data.widget.BurnBarWidgetSnapshot

@Composable
internal fun SmallContent(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier =
        GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.background)
            .cornerRadius(20.dp)
            .padding(14.dp)
            .clickable(openDashboardAction()),
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
        SmallTokenRow(snap = snap)
        Spacer(modifier = GlanceModifier.height(8.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            WidgetMetricBadge(label = "reqs", value = snap.heroTotalRequests.toString())
            Spacer(modifier = GlanceModifier.width(6.dp))
            WidgetMetricBadge(label = "window", value = snap.windowKey)
        }
    }
}

@Composable
private fun SmallTokenRow(snap: BurnBarWidgetSnapshot) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            text = "${formatTokensCompact(snap.heroTotalTokens)} tokens",
            style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, color = WidgetTheme.textSubtle),
            maxLines = 1,
        )
        val first = snap.topProviders.firstOrNull()
        if (!first.isNullOrBlank()) {
            Spacer(modifier = GlanceModifier.width(4.dp))
            Text(
                text = "· $first",
                style = TextStyle(fontSize = 11.sp, color = WidgetTheme.textFaint),
                maxLines = 1,
            )
        }
    }
}
