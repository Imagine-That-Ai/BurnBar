package com.openburnbar.ui.you

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.menubar.SuppressionStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.smartdisplay.SmartDisplayView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

private enum class YouSubScreen { Root, SmartDisplays, MenuBarPrefs }

@Composable
fun YouView(
    userStore: UserStore = viewModel(),
    syncStore: CloudSyncHealthStore = viewModel(),
    devicesStore: DevicesStore = viewModel()
) {
    var subScreen by rememberSaveable { mutableStateOf(YouSubScreen.Root) }

    AnimatedContent(
        targetState = subScreen,
        transitionSpec = { fadeIn() togetherWith fadeOut() },
        label = "you-subscreen"
    ) { screen ->
        when (screen) {
            YouSubScreen.Root -> YouRoot(
                userStore = userStore,
                syncStore = syncStore,
                devicesStore = devicesStore,
                onOpenSmartDisplays = { subScreen = YouSubScreen.SmartDisplays },
                onOpenMenuBarPrefs = { subScreen = YouSubScreen.MenuBarPrefs }
            )
            YouSubScreen.SmartDisplays -> SmartDisplayView(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.MenuBarPrefs -> MenuBarPrefsView(onBack = { subScreen = YouSubScreen.Root })
        }
    }
}

@Composable
private fun YouRoot(
    userStore: UserStore,
    syncStore: CloudSyncHealthStore,
    devicesStore: DevicesStore,
    onOpenSmartDisplays: () -> Unit,
    onOpenMenuBarPrefs: () -> Unit
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

        SettingsRow(icon = Icons.Filled.Cloud, title = "Cloud Sync", subtitle = syncHealth.label) {}

        ConnectedDevicesRow(devices = devices) {}

        SettingsRow(
            icon = Icons.Filled.Tv,
            title = "Smart Displays",
            subtitle = "Pixel Clock · Home Assistant",
            onClick = onOpenSmartDisplays
        )

        SettingsRow(
            icon = Icons.Filled.Notifications,
            title = "Quick-Glance Notification",
            subtitle = "BurnBar persistent cost glance",
            onClick = onOpenMenuBarPrefs
        )

        SettingsRow(
            icon = Icons.Filled.Settings,
            title = "Settings",
            subtitle = "Appearance, budget, notifications"
        ) {}

        Spacer(modifier = Modifier.height(AuroraSpacing.xxxl.dp))
    }
}

@Composable
private fun MenuBarPrefsView(onBack: () -> Unit) {
    val context = LocalContext.current
    val isDark = isSystemInDarkTheme()
    var suppressed by remember {
        mutableStateOf(SuppressionStore.suppressed(context))
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

        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onBack) { Text("Back") }
        }

        AuroraGlassCard(modifier = Modifier.fillMaxWidth()) {
            Text("Quick-glance bar", style = AuroraType.title,
                 color = MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(AuroraSpacing.sm.dp))
            Text(
                text = "BurnBar runs a persistent notification with today's cost — the Android equivalent of the iOS menu-bar label. Tap the notification to open the dashboard; pull down the Quick Settings tile for an at-a-glance popover.",
                style = AuroraType.body,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(Modifier.height(AuroraSpacing.md.dp))

            AuroraSettingsToggle(
                icon = Icons.Filled.Notifications,
                label = "Show quick-glance notification",
                subtitle = if (suppressed) "Hidden — re-enable to see today's cost in the shade"
                           else "Live cost glance in the notification shade",
                checked = !suppressed,
                onCheckedChange = { showOn ->
                    suppressed = !showOn
                    SuppressionStore.setSuppressed(context, suppressed)
                }
            )
        }
    }
}

@Composable
private fun SettingsRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit = {}
) {
    Surface(
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
                Text(subtitle, fontSize = AuroraTypography.caption.sp,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
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
