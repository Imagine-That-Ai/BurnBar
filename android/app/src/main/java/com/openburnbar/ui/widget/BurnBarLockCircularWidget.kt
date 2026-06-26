package com.openburnbar.ui.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.provideContent
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.fillMaxSize
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore

/**
 * Lock-screen circular widget — iOS `CircularLockScreenView` equivalent.
 * Gradient progress ring (cost vs a $10/day reference) + centered cost +
 * tokens below. Drawn as a bitmap because Glance doesn't expose a native
 * arc primitive.
 */
object BurnBarLockCircularWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        BurnBarWidgetSnapshotStore.bind(context)
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.unavailable
        provideContent { CircularContent(snap) }
    }
}

class BurnBarLockCircularWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BurnBarLockCircularWidget
}

@Composable
private fun CircularContent(snap: BurnBarWidgetSnapshot) {
    val presentation = snap.lockScreenPresentation()
    Box(
        modifier =
        GlanceModifier
            .fillMaxSize()
            .clickable(openDashboardAction()),
        contentAlignment = Alignment.Center,
    ) {
        val ring = renderRingBitmap(progress = presentation.ringProgress, sizePx = 200)
        Image(
            provider = ImageProvider(ring),
            contentDescription = null,
            modifier = GlanceModifier.fillMaxSize(),
            contentScale = ContentScale.Fit,
        )
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                text = presentation.title,
                style =
                TextStyle(
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    color = ColorProvider(WidgetTheme.ember),
                ),
                maxLines = 1,
            )
            Text(
                text = presentation.detail,
                style =
                TextStyle(
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Medium,
                    color = WidgetTheme.textSubtle,
                ),
                maxLines = 1,
            )
        }
    }
}
