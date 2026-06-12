// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.store

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.HostedQuotaProductDetails
import com.openburnbar.data.stores.RemoteMcpClientRecord
import com.openburnbar.ui.components.liquidGlassInteractive
import com.openburnbar.ui.pro.CloudBadgePickerSheet
import com.openburnbar.ui.pro.CloudBadgeSize
import com.openburnbar.ui.pro.CloudBadgeWithHalo
import com.openburnbar.ui.theme.AuroraColors
import java.text.SimpleDateFormat
import java.util.Locale

internal object CloudStorePal {
    // Aliases for readability inside this file.
    val ember = AuroraColors.ember
    val emberDark = AuroraColors.emberDark
    val amber = AuroraColors.amber
    val amberDark = AuroraColors.amberDark
    val blaze = AuroraColors.blaze
    val whimsy = AuroraColors.whimsyDark
    val aureate = AuroraColors.hermesAureateDark
    val mercury = AuroraColors.hermesMercuryDark
    val textPrimary = AuroraColors.darkTextPrimary
    val textSecondary = AuroraColors.darkTextSecondary
    val textMuted = AuroraColors.darkTextMuted
    val surface = AuroraColors.darkSurface
    val border = AuroraColors.darkBorderSubtle
    val success = AuroraColors.successDark
}

internal data class CloudStoreScreenState(
    val isActive: Boolean,
    val isLoading: Boolean,
    val error: String?,
    val priceText: String,
    val expirationDateMs: Long?,
    val purchaseDateMs: Long?,
    val productDetailsByID: Map<String, HostedQuotaProductDetails>,
    val remoteMcpClients: List<RemoteMcpClientRecord>,
    val remoteMcpLoading: Boolean,
    val remoteMcpError: String?,
    val revokingRemoteMcpClientId: String?,
)

internal data class CloudStoreScreenActions(
    val onClose: () -> Unit,
    val onPurchase: (String) -> Unit,
    val onRestore: () -> Unit,
    val onDefaultPurchase: () -> Unit,
    val onRevoke: (RemoteMcpClientRecord) -> Unit,
)

internal const val CLOUD_STORE_LIST_TAG = "cloud-store.list"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CloudStoreScaffold(state: CloudStoreScreenState, actions: CloudStoreScreenActions) {
    val isActive = state.isActive
    val isLoading = state.isLoading
    val priceText = state.priceText
    Box(modifier = Modifier.fillMaxSize()) {
        Scaffold(
            containerColor = Color.Transparent,
            topBar = { CloudStoreTopBar(onClose = actions.onClose) },
        ) { innerPadding ->
            CloudStoreLazyContent(
                innerPadding = innerPadding,
                state = state,
                onPurchase = actions.onPurchase,
                onRestore = actions.onRestore,
                onRevoke = actions.onRevoke,
            )
        }

        if (!isActive) {
            CloudStoreActionBar(
                priceText = priceText,
                isLoading = isLoading,
                onPurchase = actions.onDefaultPurchase,
                onRestore = actions.onRestore,
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CloudStoreTopBar(onClose: () -> Unit) {
    TopAppBar(
        title = {
            Text(
                "OpenBurnBar Cloud",
                fontWeight = FontWeight.SemiBold,
                color = CloudStorePal.textPrimary,
            )
        },
        navigationIcon = {
            IconButton(onClick = onClose) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier =
                    Modifier
                        .size(32.dp)
                        .liquidGlassInteractive(shape = CircleShape, isDark = true),
                ) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = "Close",
                        tint = CloudStorePal.textSecondary,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        },
        colors =
        TopAppBarDefaults.topAppBarColors(
            containerColor = Color.Transparent,
            scrolledContainerColor = Color.Transparent,
        ),
    )
}

@Composable
internal fun CloudStoreLazyContent(
    innerPadding: PaddingValues,
    state: CloudStoreScreenState,
    onPurchase: (String) -> Unit,
    onRestore: () -> Unit,
    onRevoke: (RemoteMcpClientRecord) -> Unit,
) {
    LazyColumn(
        modifier =
        Modifier
            .fillMaxSize()
            .testTag(CLOUD_STORE_LIST_TAG)
            .padding(innerPadding),
        contentPadding =
        PaddingValues(
            start = 16.dp,
            end = 16.dp,
            top = 12.dp,
            bottom = if (state.isActive) 28.dp else 140.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        cloudStoreLazyListItems(
            state = state,
            onPurchase = onPurchase,
            onRestore = onRestore,
            onRevoke = onRevoke,
        )
    }
}

internal fun LazyListScope.cloudStoreLazyListItems(
    state: CloudStoreScreenState,
    onPurchase: (String) -> Unit,
    onRestore: () -> Unit,
    onRevoke: (RemoteMcpClientRecord) -> Unit,
) {
    item { CloudPosterHero(isActive = state.isActive) }
    item {
        if (state.isActive) {
            CloudAuroraMemberCard(
                expirationDateMs = state.expirationDateMs,
                purchaseDateMs = state.purchaseDateMs,
                onRestore = onRestore,
            )
        } else {
            CloudPlanGlassCard(priceText = state.priceText)
        }
    }
    cloudPaidTierLazyItems(
        isActive = state.isActive,
        prices = state.productDetailsByID,
        isLoading = state.isLoading,
        onPurchase = onPurchase,
    )
    item { CloudCapabilityLineup(isActive = state.isActive) }
    item {
        CloudRemoteMcpCard(
            isActive = state.isActive,
            clients = state.remoteMcpClients,
            isLoading = state.remoteMcpLoading,
            error = state.remoteMcpError,
            revokingClientId = state.revokingRemoteMcpClientId,
            onRevoke = onRevoke,
        )
    }
    item { CloudComparisonCard() }
    item { CloudTrustCard() }
    state.error?.let { message ->
        item { CloudErrorCard(message = message) }
    }
    if (!state.isActive) {
        item { Spacer(Modifier.height(8.dp)) }
    }
}

// ── Aurora-glass card wrapper ──
//
// The single chrome primitive every Cloud card uses. UltraThinMaterial in
// spirit (matches iOS `.ultraThinMaterial`) — Android renders it via the
// surface tint plus the warm `cardGradient` overlay and an ember-tinted
// hairline border. Drop-in replacement for the old `MercuryFoilCard`.

@Composable
internal fun AuroraGlassCard(modifier: Modifier = Modifier, cornerRadius: Int = 20, content: @Composable BoxScope.() -> Unit) {
    val shape = RoundedCornerShape(cornerRadius.dp)
    Box(
        modifier =
        modifier
            .fillMaxWidth()
            .shadow(elevation = 10.dp, shape = shape, ambientColor = Color.Black, spotColor = Color.Black)
            .clip(shape)
            .background(CloudStorePal.surface.copy(alpha = 0.78f), shape)
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        CloudStorePal.ember.copy(alpha = 0.06f),
                        CloudStorePal.amber.copy(alpha = 0.04f),
                        CloudStorePal.blaze.copy(alpha = 0.03f),
                    ),
                ),
                shape = shape,
            )
            .border(
                width = 0.6.dp,
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        CloudStorePal.ember.copy(alpha = 0.30f),
                        CloudStorePal.border.copy(alpha = 0.50f),
                        CloudStorePal.blaze.copy(alpha = 0.22f),
                    ),
                ),
                shape = shape,
            ),
        content = content,
    )
}

// ── Hero ──

@Composable
internal fun CloudPosterHero(isActive: Boolean) {
    var showBadgePicker by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(modifier = Modifier.clickable { showBadgePicker = true }) {
            CloudBadgeWithHalo(size = CloudBadgeSize.Large)
        }
        Text(
            "OPENBURNBAR",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 2.4.sp,
            color = CloudStorePal.textMuted,
        )
        Text(
            "Cloud",
            style =
            TextStyle(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.Bold,
                fontSize = 36.sp,
                lineHeight = 42.sp,
                brush = Brush.linearGradient(listOf(CloudStorePal.ember, CloudStorePal.amber)),
            ),
        )
        Text(
            text =
            if (isActive) {
                "Your quota, your conversations, your agents — synced across every device."
            } else {
                "Sync, encrypted history, and agent memory across every device. From $7.99/mo."
            },
            fontSize = 14.sp,
            color = CloudStorePal.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 20.dp),
        )
    }

    if (showBadgePicker) {
        CloudBadgePickerSheet(onDismiss = { showBadgePicker = false })
    }
}

// ── Member card — aurora burst (matches You-tab) ──

@Composable
internal fun CloudAuroraMemberCard(expirationDateMs: Long?, purchaseDateMs: Long?, onRestore: () -> Unit) {
    val shape = RoundedCornerShape(26.dp)
    var showBadgePicker by remember { mutableStateOf(false) }

    val ribbonPhase =
        rememberInfiniteTransition(label = "memberRibbon").animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec =
            infiniteRepeatable(
                animation = tween(durationMillis = 18_000, easing = LinearEasing),
                repeatMode = RepeatMode.Reverse,
            ),
            label = "memberRibbonPhase",
        ).value

    Box(
        modifier =
        Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 26.dp,
                shape = shape,
                ambientColor = CloudStorePal.ember,
                spotColor = CloudStorePal.ember,
            )
            .clip(shape),
    ) {
        MemberAuroraBackdrop(shape = shape, ribbonPhase = ribbonPhase)
        Box(
            modifier =
            Modifier
                .fillMaxWidth()
                .border(
                    width = 1.3.dp,
                    brush =
                    Brush.linearGradient(
                        colors =
                        listOf(
                            CloudStorePal.aureate,
                            CloudStorePal.amber,
                            CloudStorePal.ember,
                            CloudStorePal.aureate,
                        ),
                    ),
                    shape = shape,
                )
                .padding(horizontal = 20.dp, vertical = 22.dp),
        ) {
            CloudAuroraMemberCardContent(
                expirationDateMs = expirationDateMs,
                purchaseDateMs = purchaseDateMs,
                onRestore = onRestore,
                onShowBadgePicker = { showBadgePicker = true },
            )
        }
    }

    if (showBadgePicker) {
        CloudBadgePickerSheet(onDismiss = { showBadgePicker = false })
    }
}

@Composable
internal fun CloudAuroraMemberCardContent(
    expirationDateMs: Long?,
    purchaseDateMs: Long?,
    onRestore: () -> Unit,
    onShowBadgePicker: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(modifier = Modifier.clickable(onClick = onShowBadgePicker)) {
            CloudBadgeWithHalo(size = CloudBadgeSize.Large)
        }
        CloudAuroraMemberProRow()
        Text(
            "Member",
            style =
            TextStyle(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.Bold,
                fontSize = 36.sp,
                lineHeight = 40.sp,
                brush = Brush.linearGradient(listOf(CloudStorePal.ember, CloudStorePal.amber)),
            ),
        )
        Spacer(Modifier.height(2.dp))
        CloudMemberStatusPill(expirationDateMs = expirationDateMs, purchaseDateMs = purchaseDateMs)
        CloudMemberActionRow(onRestore = onRestore, onShowBadgePicker = onShowBadgePicker)
    }
}

@Composable
internal fun CloudAuroraMemberProRow() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier =
            Modifier
                .clip(CircleShape)
                .background(
                    brush =
                    Brush.horizontalGradient(
                        colors = listOf(CloudStorePal.ember, CloudStorePal.amber),
                    ),
                )
                .padding(horizontal = 9.dp, vertical = 3.dp),
        ) {
            Text(
                "PRO",
                color = Color.White,
                fontSize = 10.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 1.8.sp,
            )
        }
        Spacer(Modifier.width(7.dp))
        Text(
            "OPENBURNBAR CLOUD",
            color = CloudStorePal.textMuted,
            fontSize = 11.sp,
            fontWeight = FontWeight.Black,
            letterSpacing = 2.0.sp,
        )
    }
}

@Composable
internal fun CloudMemberStatusPill(expirationDateMs: Long?, purchaseDateMs: Long?) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .clip(CircleShape)
            .background(CloudStorePal.success.copy(alpha = 0.14f))
            .border(0.5.dp, CloudStorePal.success.copy(alpha = 0.45f), CircleShape)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        Icon(
            Icons.Filled.VerifiedUser,
            contentDescription = null,
            tint = CloudStorePal.success,
            modifier = Modifier.size(13.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            "Active",
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = CloudStorePal.textPrimary,
        )
        Spacer(Modifier.width(6.dp))
        Text("·", color = CloudStorePal.textMuted)
        Spacer(Modifier.width(6.dp))
        Text(
            membershipStatusLine(expirationDateMs, purchaseDateMs),
            fontSize = 11.sp,
            color = CloudStorePal.textSecondary,
        )
    }
}

@Composable
internal fun CloudMemberActionRow(onRestore: () -> Unit, onShowBadgePicker: () -> Unit) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.padding(top = 8.dp).fillMaxWidth(),
    ) {
        AuroraPrimaryButton(
            text = "Restore",
            icon = Icons.Filled.Restore,
            onClick = onRestore,
            modifier = Modifier.weight(1f),
        )
        AuroraSecondaryButton(
            text = "Change badge",
            onClick = onShowBadgePicker,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
internal fun BoxScope.MemberAuroraBackdrop(shape: RoundedCornerShape, ribbonPhase: Float) {
    Box(
        modifier =
        Modifier
            .fillMaxSize()
            .clip(shape)
            .background(CloudStorePal.surface)
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        CloudStorePal.ember.copy(alpha = 0.50f),
                        CloudStorePal.amber.copy(alpha = 0.38f),
                        CloudStorePal.blaze.copy(alpha = 0.30f),
                        CloudStorePal.whimsy.copy(alpha = 0.22f),
                    ),
                ),
            )
            .background(
                brush =
                Brush.linearGradient(
                    colors =
                    listOf(
                        CloudStorePal.aureate.copy(alpha = 0.32f),
                        CloudStorePal.amber.copy(alpha = 0.50f),
                        CloudStorePal.ember.copy(alpha = 0.28f),
                        Color.Transparent,
                    ),
                    start = androidx.compose.ui.geometry.Offset(ribbonPhase * 600f, 0f),
                    end = androidx.compose.ui.geometry.Offset(ribbonPhase * 600f + 900f, 220f),
                ),
            )
            .background(
                brush =
                Brush.radialGradient(
                    colors =
                    listOf(
                        CloudStorePal.amber.copy(alpha = 0.45f),
                        CloudStorePal.ember.copy(alpha = 0.20f),
                        Color.Transparent,
                    ),
                    center = androidx.compose.ui.geometry.Offset(220f, 200f),
                    radius = 360f,
                ),
            ),
    )
}

internal fun membershipStatusLine(expirationMs: Long?, purchaseMs: Long?): String {
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val nowMs = System.currentTimeMillis()
    return when {
        expirationMs != null && expirationMs - nowMs in 1..90L * 24 * 60 * 60 * 1000 -> {
            val days = ((expirationMs - nowMs) / (24L * 60 * 60 * 1000)).coerceAtLeast(0).toInt()
            val rel = if (days <= 1) "tomorrow" else "in $days days"
            if (purchaseMs != null) {
                "Member since ${monthYear.format(java.util.Date(purchaseMs))} · renews $rel"
            } else {
                "Renews $rel"
            }
        }
        expirationMs != null -> {
            if (purchaseMs != null) {
                "Member since ${monthYear.format(java.util.Date(purchaseMs))} · renews monthly"
            } else {
                "Renews monthly"
            }
        }
        purchaseMs != null -> "Member since ${monthYear.format(java.util.Date(purchaseMs))}"
        else -> "Renews monthly"
    }
}
