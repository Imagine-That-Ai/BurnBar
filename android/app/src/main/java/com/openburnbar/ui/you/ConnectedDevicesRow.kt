// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun ConnectedDevicesRow(devices: List<DeviceRecord>, onClick: () -> Unit = {}) {
    val deviceCount = devices.size
    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Devices, contentDescription = null, modifier = Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text("Connected Devices", fontSize = AuroraTypography.headline.sp, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurface)
                Text("$deviceCount device${if (deviceCount != 1) "s" else ""} connected", fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (devices.isNotEmpty()) ConnectedDevicesPlatformIcons(devices)
            Icon(Icons.AutoMirrored.Filled.NavigateNext, contentDescription = null, modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
        }
    }
}
