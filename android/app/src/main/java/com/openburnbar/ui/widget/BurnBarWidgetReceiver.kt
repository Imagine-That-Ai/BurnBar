package com.openburnbar.ui.widget

import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver

/**
 * Manifest-pinned receiver for the 2×2 Small widget. Kept under the original
 * `BurnBarWidgetReceiver` class name so any widgets users had pinned before
 * the Glance migration continue to bind without manual re-pin.
 *
 * The actual rendering is implemented by [BurnBarSmallWidget].
 */
class BurnBarWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BurnBarSmallWidget
}
