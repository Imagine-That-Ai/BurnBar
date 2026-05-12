package com.openburnbar.menubar

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * Quick Settings tile that mirrors the iOS menu-bar popover: tap the tile,
 * the QuickGlanceActivity opens with the same compact summary content.
 */
@RequiresApi(Build.VERSION_CODES.N)
class MenuBarTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        val snap = MenuBarController.snapshot.value
        qsTile?.apply {
            label = "BurnBar"
            contentDescription = "Open BurnBar quick glance"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                subtitle = MenuBarController.formatCost(snap.costToday)
            }
            state = if (snap.streaming) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            updateTile()
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, QuickGlanceActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            data = Uri.parse("burnbar://quickglance")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pi = PendingIntent.getActivity(
                this, 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            startActivityAndCollapse(pi)
        } else {
            // Older API path uses the deprecated Intent overload; suppression
            // is intentional because the PendingIntent variant is API 34+.
            startActivityAndCollapse(intent)
        }
    }
}
