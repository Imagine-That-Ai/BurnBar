package com.openburnbar.menubar

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.openburnbar.MainActivity
import com.openburnbar.ui.components.AuroraBadge
import com.openburnbar.ui.components.AuroraBadgeTone
import com.openburnbar.ui.components.AuroraBottomSheet
import com.openburnbar.ui.components.AuroraButton
import com.openburnbar.ui.components.AuroraSparkline
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTheme
import com.openburnbar.ui.theme.AuroraType

/**
 * Quick-glance popover hosted as a transparent activity. Tapping the system
 * Quick Settings tile (or the persistent notification's expanded action) lands
 * here. Once the sheet is dismissed the activity finishes itself.
 *
 * Visual analog of the iOS `MenuBarPopoverView` — concise summary, sparkline,
 * recent providers, "Open Dashboard" CTA.
 */
class QuickGlanceActivity : ComponentActivity() {

    @androidx.compose.material3.ExperimentalMaterial3Api
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AuroraTheme {
                QuickGlanceContent(onClose = { finish() }, onOpenDashboard = {
                    startActivity(Intent(this@QuickGlanceActivity, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                        data = Uri.parse("burnbar://dashboard")
                    })
                    finish()
                })
            }
        }
    }
}

@androidx.compose.runtime.Composable
@androidx.compose.material3.ExperimentalMaterial3Api
private fun QuickGlanceContent(
    onClose: () -> Unit,
    onOpenDashboard: () -> Unit
) {
    val snap by MenuBarController.snapshot.collectAsState()
    AuroraBottomSheet(onDismissRequest = onClose) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.lg.dp),
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(text = "BurnBar", style = AuroraType.caption,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(
                        text = MenuBarController.formatCost(snap.costToday),
                        style = AuroraType.displayLarge,
                        color = AuroraColors.ember
                    )
                }
                AuroraBadge(
                    text = if (snap.streaming) "Hermes thinking…" else "Today",
                    tone = if (snap.streaming) AuroraBadgeTone.Info else AuroraBadgeTone.Accent
                )
            }

            if (snap.sparkline.size >= 2) {
                Box(modifier = Modifier.fillMaxWidth().height(72.dp)) {
                    AuroraSparkline(data = snap.sparkline)
                }
            }

            if (snap.recentProviders.isNotEmpty()) {
                Text(
                    text = "Recent",
                    style = AuroraType.caption,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
                    modifier = Modifier.heightIn(max = 200.dp)
                ) {
                    items(snap.recentProviders.take(5)) { provider ->
                        Text(text = provider, style = AuroraType.body)
                    }
                }
            }

            AuroraButton(onClick = onOpenDashboard, modifier = Modifier.fillMaxWidth()) {
                Text("Open Dashboard")
            }
        }
    }
}
