package com.openburnbar.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore

/**
 * Lock-screen rectangular widget — iOS `RectangularLockScreenView`
 * equivalent. Cost + tokens on the left, top-provider pill on the right.
 */
object BurnBarLockRectangularWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        BurnBarWidgetSnapshotStore.bind(context)
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.preview
        provideContent { RectangularContent(snap) }
    }
}

class BurnBarLockRectangularWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BurnBarLockRectangularWidget
}

@Composable
private fun RectangularContent(snap: BurnBarWidgetSnapshot) {
    Row(
        modifier = GlanceModifier
            .fillMaxSize()
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .clickable(openDashboardAction()),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(
                text = formatCost(snap.heroTotalCost),
                style = TextStyle(
                    fontSize = 19.sp,
                    fontWeight = FontWeight.Bold,
                    color = ColorProvider(WidgetTheme.ember)
                ),
                maxLines = 1
            )
            Text(
                text = "${formatTokensCompact(snap.heroTotalTokens)} tokens",
                style = TextStyle(
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = WidgetTheme.textSubtle
                ),
                maxLines = 1
            )
        }
        Spacer(modifier = GlanceModifier.width(6.dp))
        val top = snap.topProviders.firstOrNull()
        if (!top.isNullOrBlank()) {
            WidgetProviderPill(name = top, tokens = snap.topProviderTokens.firstOrNull())
        }
    }
}
