// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.you

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.ShoppingBag
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.openburnbar.data.stores.CloudSyncHealth
import com.openburnbar.data.stores.CloudSyncHealthStore
import com.openburnbar.data.stores.DeviceRecord
import com.openburnbar.data.stores.DeviceTrustState
import com.openburnbar.data.stores.DevicesStore
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.UserStore
import com.openburnbar.ui.components.AuroraSecondaryButton
import com.openburnbar.ui.pro.CloudBadgePickerSheet
import com.openburnbar.ui.pro.CloudBadgeSize
import com.openburnbar.ui.pro.CloudBadgeWithHalo
import com.openburnbar.ui.pro.MembershipBand
import com.openburnbar.ui.pro.MembershipBandVariant
import com.openburnbar.ui.settings.rememberWebsiteBackground
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraTypography
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal data class YouRootStores(
    val userStore: UserStore,
    val syncStore: CloudSyncHealthStore,
    val devicesStore: DevicesStore,
    val subscriptionStore: HostedQuotaSubscriptionStore,
)

internal data class YouRootNavigation(
    val onOpenSmartDisplays: () -> Unit,
    val onOpenMenuBarPrefs: () -> Unit,
    val onOpenChatTiles: () -> Unit,
    val onOpenSettings: () -> Unit,
    val onOpenControlCenter: () -> Unit,
)

internal data class YouRootScrollState(
    val displayName: String,
    val email: String?,
    val photoUrl: String?,
    val syncHealthLabel: String,
    val syncHealth: CloudSyncHealth,
    val trustedConnectionsCount: Int,
    val devices: List<DeviceRecord>,
    val isCloudMember: Boolean,
    val cloudPurchaseDate: Long?,
    val cloudExpirationDate: Long?,
    val openCloud: () -> Unit,
)

@Composable
internal fun YouRoot(stores: YouRootStores, navigation: YouRootNavigation) {
    val userStore = stores.userStore
    val syncStore = stores.syncStore
    val devicesStore = stores.devicesStore
    val subscriptionStore = stores.subscriptionStore
    val context = LocalContext.current
    val useWebsiteBackground by rememberWebsiteBackground()
    val isDark = isSystemInDarkTheme()
    val user by userStore.user.collectAsState()
    val syncHealth by syncStore.health.collectAsState()
    val devices by devicesStore.devices.collectAsState()
    val isCloudMember by subscriptionStore.isActive.collectAsState()
    val cloudPurchaseDate by subscriptionStore.purchaseDate.collectAsState()
    val cloudExpirationDate by subscriptionStore.expirationDate.collectAsState()

    YouRootStartupEffects(
        subscriptionStore = subscriptionStore,
        syncStore = syncStore,
        devicesStore = devicesStore,
        context = context,
    )

    YouRootScrollColumn(useWebsiteBackground = useWebsiteBackground, isDark = isDark) {
        YouRootScrollContent(
            state =
            YouRootScrollState(
                displayName = user.displayName ?: "BurnBar User",
                email = user.email,
                photoUrl = user.photoUrl,
                syncHealthLabel = syncHealth.label,
                syncHealth = syncHealth,
                trustedConnectionsCount = devices.count { it.trustState == DeviceTrustState.TRUSTED },
                devices = devices,
                isCloudMember = isCloudMember,
                cloudPurchaseDate = cloudPurchaseDate,
                cloudExpirationDate = cloudExpirationDate,
                openCloud = youRootOpenCloudHandler(context),
            ),
            navigation = navigation,
            onSignOut = { userStore.signOut() },
        )
    }
}

@Composable
private fun YouRootStartupEffects(
    subscriptionStore: HostedQuotaSubscriptionStore,
    syncStore: CloudSyncHealthStore,
    devicesStore: DevicesStore,
    context: android.content.Context,
) {
    LaunchedEffect(Unit) {
        subscriptionStore.initialize(context)
        devicesStore.initialize(context)
        subscriptionStore.load()
        syncStore.refresh()
        devicesStore.load()
    }
}

private fun youRootOpenCloudHandler(context: android.content.Context): () -> Unit = {
    runCatching {
        val intent =
            Intent(Intent.ACTION_VIEW, "burnbar://cloud".toUri())
                .setPackage(context.packageName)
        context.startActivity(intent)
    }
}

@Composable
private fun YouRootScrollColumn(useWebsiteBackground: Boolean, isDark: Boolean, content: @Composable () -> Unit) {
    Column(
        modifier =
        Modifier
            .fillMaxSize()
            .background(
                if (useWebsiteBackground) {
                    androidx.compose.ui.graphics.Color.Transparent
                } else if (isDark) {
                    AuroraColors.darkBackground
                } else {
                    AuroraColors.lightBackground
                },
            )
            .verticalScroll(rememberScrollState())
            .padding(horizontal = AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
        content = { content() },
    )
}

@Composable
private fun YouRootScrollContent(state: YouRootScrollState, navigation: YouRootNavigation, onSignOut: () -> Unit) {
    Spacer(modifier = Modifier.height(AuroraSpacing.LG.dp))

    IdentityHero(
        displayName = state.displayName,
        email = state.email,
        photoUrl = state.photoUrl,
        syncHealth = state.syncHealth,
        connectionsCount = state.trustedConnectionsCount,
    )

    YouRootMembershipSection(
        isCloudMember = state.isCloudMember,
        cloudPurchaseDate = state.cloudPurchaseDate,
        cloudExpirationDate = state.cloudExpirationDate,
        openCloud = state.openCloud,
    )

    YouRootSettingsRows(
        syncHealthLabel = state.syncHealthLabel,
        devices = state.devices,
        navigation = navigation,
        openCloud = state.openCloud,
    )

    YouRootSignOutButton(onSignOut = onSignOut)
}

@Composable
private fun YouRootSignOutButton(onSignOut: () -> Unit) {
    Spacer(modifier = Modifier.height(AuroraSpacing.MD.dp))

    AuroraSecondaryButton(onClick = onSignOut, modifier = Modifier.fillMaxWidth()) {
        Icon(
            imageVector = Icons.AutoMirrored.Filled.Logout,
            contentDescription = null,
            modifier = Modifier.size(18.dp),
        )
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text("Sign Out", fontWeight = FontWeight.SemiBold)
    }

    Spacer(modifier = Modifier.height(AuroraSpacing.XXXL.dp))
}

@Composable
private fun YouRootMembershipSection(isCloudMember: Boolean, cloudPurchaseDate: Long?, cloudExpirationDate: Long?, openCloud: () -> Unit) {
    if (isCloudMember) {
        CloudMemberCrestRow(
            purchaseDateMs = cloudPurchaseDate,
            expirationDateMs = cloudExpirationDate,
            onTap = openCloud,
        )
    } else {
        MembershipBand(
            title = "OpenBurnBar Cloud",
            detail = "Your agents, unbound — hosted refresh, backup, Hermes anywhere.",
            variant = MembershipBandVariant.Upsell,
            ctaLabel = "BECOME A MEMBER",
            onClick = openCloud,
        )
    }
}

@Composable
private fun YouRootSettingsRows(syncHealthLabel: String, devices: List<DeviceRecord>, navigation: YouRootNavigation, openCloud: () -> Unit) {
    YouSettingsRow(
        icon = Icons.Filled.ShoppingBag,
        title = "Store & Top-ups",
        subtitle = "Manage plans and purchase credits",
        onClick = openCloud,
    )
    YouSettingsRow(icon = Icons.Filled.Cloud, title = "Cloud Sync", subtitle = syncHealthLabel) {}
    ConnectedDevicesRow(devices = devices) {}
    YouSettingsRow(
        icon = Icons.Filled.Tv,
        title = "Smart Displays",
        subtitle = "Google Smart Display · Pixel Clock",
        onClick = navigation.onOpenSmartDisplays,
    )
    YouSettingsRow(
        icon = Icons.Filled.Notifications,
        title = "Quick-Glance Notification",
        subtitle = "BurnBar persistent cost glance",
        onClick = navigation.onOpenMenuBarPrefs,
    )
    YouSettingsRow(
        icon = Icons.AutoMirrored.Filled.Chat,
        title = "Chat tiles",
        subtitle = "Which assistants appear in the Chat tab pill",
        onClick = navigation.onOpenChatTiles,
    )
    YouSettingsRow(
        icon = Icons.Filled.Settings,
        title = "Settings",
        subtitle = "Search across cloud sync, devices, displays, Hermes",
        onClick = navigation.onOpenSettings,
    )
    YouSettingsRow(
        icon = Icons.Filled.Shield,
        title = "Data & Privacy",
        subtitle = "See, export, and delete everything BurnBar holds",
        onClick = navigation.onOpenControlCenter,
    )
}

@Composable
internal fun CloudMemberCrestRow(purchaseDateMs: Long?, expirationDateMs: Long?, onTap: () -> Unit) {
    val meta = cloudMemberCrestMeta(purchaseDateMs, expirationDateMs)
    var showBadgePicker by remember { mutableStateOf(false) }

    CloudMemberCrestCard(
        meta = meta,
        onTap = onTap,
        onBadgeTap = { showBadgePicker = true },
    )

    if (showBadgePicker) {
        CloudBadgePickerSheet(onDismiss = { showBadgePicker = false })
    }
}

internal fun cloudMemberCrestMeta(purchaseDateMs: Long?, expirationDateMs: Long?): String {
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val nowMs = System.currentTimeMillis()
    return when {
        expirationDateMs != null && expirationDateMs - nowMs in 1..90L * 24 * 60 * 60 * 1000 -> {
            val days = ((expirationDateMs - nowMs) / (24L * 60 * 60 * 1000)).coerceAtLeast(0).toInt()
            val rel = if (days <= 1) "tomorrow" else "in $days days"
            if (purchaseDateMs != null) {
                "Member since ${monthYear.format(Date(purchaseDateMs))} · renews $rel"
            } else {
                "Active · renews $rel"
            }
        }
        expirationDateMs != null -> {
            if (purchaseDateMs != null) {
                "Member since ${monthYear.format(Date(purchaseDateMs))} · renews monthly"
            } else {
                "Active · renews monthly"
            }
        }
        purchaseDateMs != null -> "Member since ${monthYear.format(Date(purchaseDateMs))}"
        else -> "Active"
    }
}

@Composable
private fun CloudMemberCrestCard(meta: String, onTap: () -> Unit, onBadgeTap: () -> Unit) {
    val shape = RoundedCornerShape(22.dp)

    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 22.dp,
                shape = shape,
                ambientColor = AuroraColors.ember,
                spotColor = AuroraColors.ember,
            )
            .clip(shape)
            .clickable(onClick = onTap),
    ) {
        MemberAuroraBackdrop(shape = shape)
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .border(
                    width = 1.2.dp,
                    brush =
                    Brush.linearGradient(
                        colors =
                        listOf(
                            AuroraColors.hermesAureateDark,
                            AuroraColors.amber,
                            AuroraColors.ember,
                            AuroraColors.hermesAureateDark,
                        ),
                    ),
                    shape = shape,
                )
                .padding(horizontal = 18.dp, vertical = 18.dp),
        ) {
            CloudMemberCrestInnerRow(meta = meta, onBadgeTap = onBadgeTap)
        }
    }
}

@Composable
private fun CloudMemberCrestInnerRow(meta: String, onBadgeTap: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            contentAlignment = Alignment.Center,
            modifier =
            Modifier
                .size(72.dp)
                .clickable(onClick = onBadgeTap),
        ) {
            CloudBadgeWithHalo(size = CloudBadgeSize.Medium)
        }
        Spacer(Modifier.width(16.dp))
        CloudMemberCrestLabels(meta = meta)
        Icon(
            Icons.AutoMirrored.Filled.NavigateNext,
            contentDescription = null,
            tint = AuroraColors.amber,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun RowScope.CloudMemberCrestLabels(meta: String) {
    Column(modifier = Modifier.weight(1f)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier =
                Modifier
                    .clip(RoundedCornerShape(50))
                    .background(
                        brush =
                        Brush.horizontalGradient(
                            colors = listOf(AuroraColors.ember, AuroraColors.amber),
                        ),
                    )
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) {
                Text(
                    "PRO",
                    color = androidx.compose.ui.graphics.Color.White,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 1.6.sp,
                )
            }
            Spacer(Modifier.width(6.dp))
            Text(
                "CLOUD MEMBER",
                color = AuroraColors.darkTextMuted,
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 1.8.sp,
            )
        }
        Spacer(Modifier.height(2.dp))
        Text(
            "Cloud Member",
            style =
            TextStyle(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.Bold,
                fontSize = 26.sp,
                lineHeight = 30.sp,
                brush =
                Brush.linearGradient(
                    colors = listOf(AuroraColors.ember, AuroraColors.amber),
                ),
            ),
        )
        Text(
            meta,
            color = AuroraColors.darkTextSecondary,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 2.dp),
        )
    }
}

@Composable
internal fun YouSettingsRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, subtitle: String, onClick: () -> Unit = {}) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.LG.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f),
    ) {
        Row(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.MD.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(24.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    title,
                    fontSize = AuroraTypography.body.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    subtitle,
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                imageVector = Icons.AutoMirrored.Filled.NavigateNext,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun BoxScope.MemberAuroraBackdrop(shape: RoundedCornerShape) {
    Box(
        modifier =
        Modifier
            .matchParentSize()
            .clip(shape)
            .background(AuroraColors.darkSurface)
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        AuroraColors.ember.copy(alpha = 0.50f),
                        AuroraColors.amber.copy(alpha = 0.38f),
                        AuroraColors.blaze.copy(alpha = 0.30f),
                        AuroraColors.whimsy.copy(alpha = 0.22f),
                    ),
                ),
            )
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        AuroraColors.hermesAureateDark.copy(alpha = 0.35f),
                        AuroraColors.amber.copy(alpha = 0.55f),
                        AuroraColors.ember.copy(alpha = 0.30f),
                        androidx.compose.ui.graphics.Color.Transparent,
                    ),
                    start = androidx.compose.ui.geometry.Offset(0f, 0f),
                    end = androidx.compose.ui.geometry.Offset(1200f, 220f),
                ),
            )
            .background(
                brush =
                Brush.radialGradient(
                    colors =
                    listOf(
                        AuroraColors.amber.copy(alpha = 0.45f),
                        AuroraColors.ember.copy(alpha = 0.20f),
                        androidx.compose.ui.graphics.Color.Transparent,
                    ),
                    center = androidx.compose.ui.geometry.Offset(96f, 96f),
                    radius = 240f,
                ),
            ),
    )
}
