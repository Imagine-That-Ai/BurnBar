package com.openburnbar.ui.widget

import android.content.Context
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
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
import com.openburnbar.MainActivity
import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore

/**
 * 2×2 home-screen widget — iOS `HeroSmallView` equivalent. Aurora gradient
 * background, "BURN BAR" header, big gradient cost, tokens · top provider
 * sub-line, request/window metric badges. Single-tap opens the dashboard.
 */
object BurnBarSmallWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        BurnBarWidgetSnapshotStore.bind(context)
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.preview
        provideContent { SmallContent(snap) }
    }
}

// Note: the Small widget's manifest-pinned receiver is `BurnBarWidgetReceiver`
// (in BurnBarWidget.kt) to preserve binding for already-pinned widgets.
// We don't declare a duplicate receiver here.

@Composable
private fun SmallContent(snap: BurnBarWidgetSnapshot) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .background(WidgetTheme.background)
            .cornerRadius(20.dp)
            .padding(14.dp)
            .clickable(openDashboardAction()),
        verticalAlignment = Alignment.Top
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "BURN BAR",
                style = TextStyle(
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = WidgetTheme.textFaint
                )
            )
        }
        Spacer(modifier = GlanceModifier.defaultWeight())
        Text(
            text = formatCost(snap.heroTotalCost),
            style = TextStyle(
                fontSize = 26.sp,
                fontWeight = FontWeight.Bold,
                color = ColorProvider(WidgetTheme.ember)
            ),
            maxLines = 1
        )
        Spacer(modifier = GlanceModifier.height(2.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "${formatTokensCompact(snap.heroTotalTokens)} tokens",
                style = TextStyle(
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = WidgetTheme.textSubtle
                ),
                maxLines = 1
            )
            val first = snap.topProviders.firstOrNull()
            if (!first.isNullOrBlank()) {
                Spacer(modifier = GlanceModifier.width(4.dp))
                Text(
                    text = "· $first",
                    style = TextStyle(
                        fontSize = 11.sp,
                        color = WidgetTheme.textFaint
                    ),
                    maxLines = 1
                )
            }
        }
        Spacer(modifier = GlanceModifier.height(8.dp))
        Row(modifier = GlanceModifier.fillMaxWidth()) {
            WidgetMetricBadge(label = "reqs", value = snap.heroTotalRequests.toString())
            Spacer(modifier = GlanceModifier.width(6.dp))
            WidgetMetricBadge(label = "window", value = snap.windowKey)
        }
    }
}

/**
 * Build a Glance click action that opens the dashboard via the existing
 * `burnbar://` deep link. All five widgets re-use this so taps land on the
 * Pulse tab consistent with how iOS handles widget taps.
 */
internal fun openDashboardAction() =
    actionStartActivity<MainActivity>()
