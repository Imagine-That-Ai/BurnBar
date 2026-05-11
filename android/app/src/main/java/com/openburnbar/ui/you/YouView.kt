package com.openburnbar.ui.you

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CloudSyncHealth
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography

@Composable
fun YouView(
    userStore: UserStore = viewModel(),
    syncStore: CloudSyncHealthStore = viewModel(),
    devicesStore: DevicesStore = viewModel()
) {
    val isDark = isSystemInDarkTheme()
    val user by userStore.user.collectAsState()
    val syncHealth by syncStore.health.collectAsState()
    val devices by devicesStore.devices.collectAsState()

    LaunchedEffect(Unit) {
        syncStore.refresh()
        devicesStore.load()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(if (isDark) AuroraColors.darkBackground else AuroraColors.lightBackground)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.lg.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.lg.dp)
    ) {
        Spacer(modifier = Modifier.height(AuroraSpacing.lg.dp))

        IdentityHero(
            displayName = user.displayName ?: "BurnBar User",
            email = user.email,
            photoUrl = user.photoUrl,
            syncHealth = syncHealth,
            connectionsCount = devices.count { it.trustState == com.openburnbar.data.stores.DeviceTrustState.TRUSTED }
        )

        SettingsRow(icon = Icons.Filled.Cloud, title = "Cloud Sync", subtitle = syncHealth.label) {
            // Navigate to cloud sync details
        }

        ConnectedDevicesRow(devices = devices) {
            // Navigate to devices
        }

        SettingsRow(icon = Icons.Filled.Settings, title = "Settings", subtitle = "Appearance, budget, notifications") {
            // Navigate to settings
        }

        Spacer(modifier = Modifier.height(AuroraSpacing.xxxl.dp))
    }
}

@Composable
private fun SettingsRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    androidx.compose.material3.Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = androidx.compose.foundation.shape.RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(24.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.md.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, fontSize = AuroraTypography.body.sp, fontWeight = FontWeight.SemiBold)
                Text(subtitle, fontSize = AuroraTypography.caption.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
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
