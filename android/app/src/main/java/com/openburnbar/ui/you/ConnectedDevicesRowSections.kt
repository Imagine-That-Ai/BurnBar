@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletMac
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.data.stores.DeviceTrustState
import com.openburnbar.ui.theme.AuroraColors

@Composable
internal fun ConnectedDevicesPlatformIcons(devices: List<DeviceRecord>) {
    val icons = devices.take(4).map { platformIcon(it.platform) }
    Box(
        modifier = Modifier.width((icons.size.coerceAtLeast(1) * 16).coerceAtMost(64).dp),
        contentAlignment = Alignment.CenterEnd,
    ) {
        icons.forEachIndexed { index, icon ->
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(20.dp).offset(x = (-index * 8).dp),
                tint =
                when (devices.getOrNull(index)?.trustState) {
                    DeviceTrustState.TRUSTED -> AuroraColors.success
                    DeviceTrustState.REVOKED -> AuroraColors.error
                    else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                },
            )
        }
    }
}

private fun platformIcon(platform: String): ImageVector =
    when (platform.lowercase()) {
        "ios", "iphone", "android" -> Icons.Filled.PhoneAndroid
        "ipad" -> Icons.Filled.TabletMac
        else -> Icons.Filled.Computer
    }
