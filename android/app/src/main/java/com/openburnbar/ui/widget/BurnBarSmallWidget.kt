package com.openburnbar.ui.widget

import android.content.Context
import androidx.glance.GlanceId
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.provideContent
import com.openburnbar.data.widget.BurnBarWidgetSnapshot
import com.openburnbar.data.widget.BurnBarWidgetSnapshotStore

object BurnBarSmallWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        BurnBarWidgetSnapshotStore.bind(context)
        val snap = BurnBarWidgetSnapshotStore.read(context) ?: BurnBarWidgetSnapshot.preview
        provideContent { SmallContent(snap) }
    }
}
