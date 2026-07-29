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
import com.openburnbar.data.stores.DeviceTrustState
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun ConnectedDevicesRow(devices: List<DeviceRecord>, onClick: () -> Unit = {}) {
    AuroraGlassCard {
        Row(
            modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Devices, contentDescription = null, modifier = Modifier.size(22.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Connected Devices",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    connectedDevicesSubtitle(devices),
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (devices.isNotEmpty()) ConnectedDevicesPlatformIcons(devices)
            Icon(
                Icons.AutoMirrored.Filled.NavigateNext,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            )
        }
    }
}

internal fun connectedDevicesSubtitle(devices: List<DeviceRecord>): String {
    if (devices.isEmpty()) return "Tap to register this device"
    val trusted = devices.count { it.trustState == DeviceTrustState.TRUSTED }
    val pending = devices.count { it.trustState == DeviceTrustState.PENDING }
    val revoked = devices.count { it.trustState == DeviceTrustState.REVOKED }
    return buildList {
        add("$trusted trusted")
        add("$pending pending")
        if (revoked > 0) add("$revoked revoked")
    }.joinToString(" · ")
}
