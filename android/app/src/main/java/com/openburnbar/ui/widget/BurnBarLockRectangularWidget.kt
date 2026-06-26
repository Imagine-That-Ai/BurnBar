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
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
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
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.unavailable
        provideContent { RectangularContent(snap) }
    }
}

class BurnBarLockRectangularWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BurnBarLockRectangularWidget
}

@Composable
private fun RectangularContent(snap: BurnBarWidgetSnapshot) {
    val presentation = snap.lockScreenPresentation()
    Row(
        modifier =
        GlanceModifier
            .fillMaxSize()
            .padding(horizontal = 10.dp, vertical = 8.dp)
            .clickable(openDashboardAction()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = GlanceModifier.defaultWeight()) {
            Text(
                text = presentation.title,
                style =
                TextStyle(
                    fontSize = 19.sp,
                    fontWeight = FontWeight.Bold,
                    color = ColorProvider(WidgetTheme.ember),
                ),
                maxLines = 1,
            )
            Text(
                text = presentation.detail,
                style =
                TextStyle(
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = WidgetTheme.textSubtle,
                ),
                maxLines = 1,
            )
        }
    }
}
