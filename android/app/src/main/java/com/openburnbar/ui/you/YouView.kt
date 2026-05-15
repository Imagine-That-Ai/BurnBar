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
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Chat
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
import android.content.Intent
import androidx.core.net.toUri
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.pro.MembershipBand
import com.openburnbar.ui.pro.MembershipBandVariant
import com.openburnbar.ui.pro.MercuryCrest
import com.openburnbar.ui.pro.MercuryCrestSize
import com.openburnbar.ui.pro.ProLayout
import com.openburnbar.ui.pro.ProPalette
import com.openburnbar.ui.pro.ProTypography
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import java.text.SimpleDateFormat
import java.util.Locale
import com.openburnbar.menubar.SuppressionStore
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.components.AuroraSettingsToggle
import com.openburnbar.ui.settings.SettingsRootScreen
import com.openburnbar.ui.smartdisplay.SmartDisplayView
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

private enum class YouSubScreen { Root, SmartDisplays, MenuBarPrefs, ChatTiles, Settings }

@Composable
fun YouView(
    userStore: UserStore = viewModel(),
    syncStore: CloudSyncHealthStore = viewModel(),
    devicesStore: DevicesStore = viewModel(),
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel()
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
                subscriptionStore = subscriptionStore,
                onOpenSmartDisplays = { subScreen = YouSubScreen.SmartDisplays },
                onOpenMenuBarPrefs = { subScreen = YouSubScreen.MenuBarPrefs },
                onOpenChatTiles = { subScreen = YouSubScreen.ChatTiles },
                onOpenSettings = { subScreen = YouSubScreen.Settings }
            )
            YouSubScreen.SmartDisplays -> SmartDisplayView(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.MenuBarPrefs -> MenuBarPrefsView(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.ChatTiles -> com.openburnbar.ui.hermes.ChatTilesSettingsScreen(onBack = { subScreen = YouSubScreen.Root })
            YouSubScreen.Settings -> SettingsRootScreen(
                onBack = { subScreen = YouSubScreen.Root },
                onMenuBarPrefs = { onBack -> MenuBarPrefsView(onBack = onBack) },
            )
        }
    }
}

@Composable
private fun YouRoot(
    userStore: UserStore,
    syncStore: CloudSyncHealthStore,
    devicesStore: DevicesStore,
    subscriptionStore: HostedQuotaSubscriptionStore,
    onOpenSmartDisplays: () -> Unit,
    onOpenMenuBarPrefs: () -> Unit,
    onOpenChatTiles: () -> Unit,
    onOpenSettings: () -> Unit
) {
    val isDark = isSystemInDarkTheme()
    val context = LocalContext.current
    val user by userStore.user.collectAsState()
    val syncHealth by syncStore.health.collectAsState()
    val devices by devicesStore.devices.collectAsState()
    val isCloudMember by subscriptionStore.isActive.collectAsState()
    val cloudPurchaseDate by subscriptionStore.purchaseDate.collectAsState()
    val cloudExpirationDate by subscriptionStore.expirationDate.collectAsState()

    LaunchedEffect(Unit) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
        syncStore.refresh()
        devicesStore.load()
    }

    val openCloud: () -> Unit = {
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW, "burnbar://cloud".toUri())
                .setPackage(context.packageName)
            context.startActivity(intent)
        }
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

        // Pro vocabulary — Cloud membership row. Members see a MercuryCrest
        // certificate; free users see a foil MembershipBand inviting them.
        if (isCloudMember) {
            CloudMemberCrestRow(
                purchaseDateMs = cloudPurchaseDate,
                expirationDateMs = cloudExpirationDate,
                onTap = openCloud
            )
        } else {
            MembershipBand(
                title = "OpenBurnBar Cloud",
                detail = "Your agents, unbound — hosted refresh, backup, Hermes anywhere.",
                variant = MembershipBandVariant.Upsell,
                ctaLabel = "BECOME A MEMBER",
                onClick = openCloud
            )
        }

        SettingsRow(icon = Icons.Filled.Cloud, title = "Cloud Sync", subtitle = syncHealth.label) {}

        ConnectedDevicesRow(devices = devices) {}

        SettingsRow(
            icon = Icons.Filled.Tv,
            title = "Smart Displays",
            subtitle = "Google Smart Display · Pixel Clock",
            onClick = onOpenSmartDisplays
        )

        SettingsRow(
            icon = Icons.Filled.Notifications,
            title = "Quick-Glance Notification",
            subtitle = "BurnBar persistent cost glance",
            onClick = onOpenMenuBarPrefs
        )

        SettingsRow(
            icon = Icons.Filled.Chat,
            title = "Chat tiles",
            subtitle = "Which assistants appear in the Chat tab pill",
            onClick = onOpenChatTiles
        )

        SettingsRow(
            icon = Icons.Filled.Settings,
            title = "Settings",
            subtitle = "Search across cloud sync, devices, displays, Hermes",
            onClick = onOpenSettings
        )

        HermesSquarePhaseAToggleRow()

        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))

        AuroraSecondaryButton(
            onClick = { userStore.signOut() },
            modifier = Modifier.fillMaxWidth()
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.Logout,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Text("Sign Out", fontWeight = FontWeight.SemiBold)
        }

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

@Composable
private fun CloudMemberCrestRow(
    purchaseDateMs: Long?,
    expirationDateMs: Long?,
    onTap: () -> Unit
) {
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val dayMonth = SimpleDateFormat("MMM d", Locale.getDefault())
    val meta = when {
        purchaseDateMs != null -> "Member since ${monthYear.format(java.util.Date(purchaseDateMs))}"
        expirationDateMs != null -> "Through ${dayMonth.format(java.util.Date(expirationDateMs))}"
        else -> "Active"
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 10.dp,
                shape = RoundedCornerShape(ProLayout.cardRadiusDp.dp),
                ambientColor = ProPalette.aureate,
                spotColor = ProPalette.aureate
            )
            .clip(RoundedCornerShape(ProLayout.cardRadiusDp.dp))
            .background(ProPalette.obsidian, RoundedCornerShape(ProLayout.cardRadiusDp.dp))
            .border(
                width = 1.dp,
                brush = Brush.linearGradient(ProPalette.aureateStrokeStops),
                shape = RoundedCornerShape(ProLayout.cardRadiusDp.dp)
            )
            .clickable(onClick = onTap)
            .padding(horizontal = 12.dp, vertical = 14.dp)
    ) {
        MercuryCrest(size = MercuryCrestSize.Large, shimmer = true)
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "Cloud Member",
                style = ProTypography.titleSerif,
                color = ProPalette.mercury
            )
            Text(
                meta,
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.7f)
            )
        }
        Icon(
            Icons.AutoMirrored.Filled.NavigateNext,
            null,
            tint = ProPalette.aureate,
            modifier = Modifier.size(18.dp)
        )
    }
}
