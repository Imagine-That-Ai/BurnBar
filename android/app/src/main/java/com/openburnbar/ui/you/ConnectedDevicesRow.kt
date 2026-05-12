package com.openburnbar.ui.you

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.TabletMac
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.data.stores.DeviceTrustState
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun ConnectedDevicesRow(
    devices: List<DeviceRecord>,
    onClick: () -> Unit = {}
) {
    val deviceCount = devices.size

    AuroraGlassCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Filled.Devices,
                contentDescription = null,
                modifier = Modifier.size(22.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Connected Devices",
                    fontSize = AuroraTypography.headline.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "$deviceCount device${if (deviceCount != 1) "s" else ""} connected",
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Overlapping platform icons
            if (devices.isNotEmpty()) {
                val icons = devices.take(4).map { platformIcon(it.platform) }
                Box(modifier = Modifier.width(((icons.size.coerceAtLeast(1) * 16).coerceAtMost(64)).dp), contentAlignment = Alignment.CenterEnd) {
                    icons.forEachIndexed { index, icon ->
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            modifier = Modifier
                                .size(20.dp)
                                .offset(x = (-index * 8).dp),
                            tint = when (devices.getOrNull(index)?.trustState) {
                                DeviceTrustState.TRUSTED -> AuroraColors.success
                                DeviceTrustState.REVOKED -> AuroraColors.error
                                else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                            }
                        )
                    }
                }
            }

            Icon(
                imageVector = Icons.AutoMirrored.Filled.NavigateNext,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
            )
        }
    }
}

private fun platformIcon(platform: String): ImageVector = when (platform.lowercase()) {
    "ios", "iphone" -> Icons.Filled.PhoneAndroid
    "ipad" -> Icons.Filled.TabletMac
    "android" -> Icons.Filled.PhoneAndroid
    else -> Icons.Filled.Computer
}
