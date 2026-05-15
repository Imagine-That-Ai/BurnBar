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
import com.openburnbar.ui.pro.CloudBadgePickerSheet
import com.openburnbar.ui.pro.CloudBadgeSize
import com.openburnbar.ui.pro.CloudBadgeWithHalo
import com.openburnbar.ui.pro.MembershipBand
import com.openburnbar.ui.pro.MembershipBandVariant
import com.openburnbar.ui.pro.MercuryCrest
import com.openburnbar.ui.pro.MercuryCrestSize
import com.openburnbar.ui.pro.ProLayout
import com.openburnbar.ui.pro.ProPalette
import com.openburnbar.ui.pro.ProTypography
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
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
    // Status line — sentinel / far-future dates show monthly recurrence,
    // near-term renewals show relative time, neither shows "73 years".
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val nowMs = System.currentTimeMillis()
    val meta: String = when {
        expirationDateMs != null && expirationDateMs - nowMs in 1..(90L * 24 * 60 * 60 * 1000) -> {
            val days = ((expirationDateMs - nowMs) / (24L * 60 * 60 * 1000)).coerceAtLeast(0).toInt()
            val rel = if (days <= 1) "tomorrow" else "in $days days"
            if (purchaseDateMs != null) "Member since ${monthYear.format(java.util.Date(purchaseDateMs))} · renews $rel"
            else "Active · renews $rel"
        }
        expirationDateMs != null -> {
            if (purchaseDateMs != null) "Member since ${monthYear.format(java.util.Date(purchaseDateMs))} · renews monthly"
            else "Active · renews monthly"
        }
        purchaseDateMs != null -> "Member since ${monthYear.format(java.util.Date(purchaseDateMs))}"
        else -> "Active"
    }

    val shape = RoundedCornerShape(22.dp)
    var showBadgePicker by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 22.dp,
                shape = shape,
                ambientColor = AuroraColors.ember,
                spotColor = AuroraColors.ember
            )
            .clip(shape)
            .clickable(onClick = onTap)
    ) {
        MemberAuroraBackdrop(shape = shape)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .border(
                    width = 1.2.dp,
                    brush = Brush.linearGradient(
                        colors = listOf(
                            AuroraColors.hermesAureateDark,
                            AuroraColors.amber,
                            AuroraColors.ember,
                            AuroraColors.hermesAureateDark
                        )
                    ),
                    shape = shape
                )
                .padding(horizontal = 18.dp, vertical = 18.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(72.dp)
                        .clickable { showBadgePicker = true }
                ) {
                    CloudBadgeWithHalo(size = CloudBadgeSize.Medium)
                }
                Spacer(Modifier.width(16.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(
                                    brush = Brush.horizontalGradient(
                                        colors = listOf(AuroraColors.ember, AuroraColors.amber)
                                    )
                                )
                                .padding(horizontal = 8.dp, vertical = 2.dp)
                        ) {
                            Text(
                                "PRO",
                                color = androidx.compose.ui.graphics.Color.White,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Black,
                                letterSpacing = 1.6.sp
                            )
                        }
                        Spacer(Modifier.width(6.dp))
                        Text(
                            "CLOUD MEMBER",
                            color = AuroraColors.darkTextMuted,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Black,
                            letterSpacing = 1.8.sp
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    Text(
                        "Cloud Member",
                        style = TextStyle(
                            fontFamily = FontFamily.SansSerif,
                            fontWeight = FontWeight.Bold,
                            fontSize = 26.sp,
                            lineHeight = 30.sp,
                            brush = Brush.linearGradient(
                                colors = listOf(AuroraColors.ember, AuroraColors.amber)
                            )
                        )
                    )
                    Text(
                        meta,
                        color = AuroraColors.darkTextSecondary,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
                Icon(
                    Icons.AutoMirrored.Filled.NavigateNext,
                    contentDescription = null,
                    tint = AuroraColors.amber,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }

    if (showBadgePicker) {
        com.openburnbar.ui.pro.CloudBadgePickerSheet(
            onDismiss = { showBadgePicker = false }
        )
    }
}

/// Multi-stop aurora burst behind the member card — ember + amber + blaze
/// with a kiss of whimsy purple for color contrast, drifting aurora ribbon
/// across the top edge, radial halo behind the badge.
@Composable
private fun BoxScope.MemberAuroraBackdrop(shape: RoundedCornerShape) {
    Box(
        modifier = Modifier
            .matchParentSize()
            .clip(shape)
            .background(AuroraColors.darkSurface)
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        AuroraColors.ember.copy(alpha = 0.50f),
                        AuroraColors.amber.copy(alpha = 0.38f),
                        AuroraColors.blaze.copy(alpha = 0.30f),
                        AuroraColors.whimsy.copy(alpha = 0.22f)
                    )
                )
            )
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        AuroraColors.hermesAureateDark.copy(alpha = 0.35f),
                        AuroraColors.amber.copy(alpha = 0.55f),
                        AuroraColors.ember.copy(alpha = 0.30f),
                        androidx.compose.ui.graphics.Color.Transparent
                    ),
                    start = androidx.compose.ui.geometry.Offset(0f, 0f),
                    end = androidx.compose.ui.geometry.Offset(1200f, 220f)
                )
            )
            .background(
                brush = Brush.radialGradient(
                    colors = listOf(
                        AuroraColors.amber.copy(alpha = 0.45f),
                        AuroraColors.ember.copy(alpha = 0.20f),
                        androidx.compose.ui.graphics.Color.Transparent
                    ),
                    center = androidx.compose.ui.geometry.Offset(96f, 96f),
                    radius = 240f
                )
            )
    )
}
