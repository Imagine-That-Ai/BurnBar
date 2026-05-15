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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Restore
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.RemoteMcpClientRecord
import com.openburnbar.data.stores.RemoteMcpClientStore
import com.openburnbar.ui.components.AuroraBackdrop
import com.openburnbar.ui.pro.CloudBadge
import com.openburnbar.ui.pro.CloudBadgePickerSheet
import com.openburnbar.ui.pro.CloudBadgeSize
import com.openburnbar.ui.pro.CloudBadgeWithHalo
import com.openburnbar.ui.theme.AuroraColors
import java.text.SimpleDateFormat
import java.util.Locale

// ── Cloud Store View (Android) ──
//
// Parity with the iOS `CloudStoreView`. Aurora language throughout — warm
// `AuroraBackdrop` over a `LazyColumn`, glass cards with ember-tinted
// hairlines, primary-gradient capsule CTAs, SF-Rounded-equivalent type.
// No obsidian, no serif foundry-coin chrome. The hero brand mark is the
// user's chosen `CloudBadge` (tappable to open the badge picker), and the
// member card mirrors the You-tab aurora-burst certificate row exactly.

private object Pal {
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CloudStoreView(
    onClose: () -> Unit = {},
    subscriptionStore: HostedQuotaSubscriptionStore = viewModel(),
    remoteMcpClientStore: RemoteMcpClientStore = viewModel()
) {
    val context = LocalContext.current
    val isActive by subscriptionStore.isActive.collectAsState()
    val isLoading by subscriptionStore.isLoading.collectAsState()
    val error by subscriptionStore.error.collectAsState()
    val productDetails by subscriptionStore.productDetails.collectAsState()
    val expirationDate by subscriptionStore.expirationDate.collectAsState()
    val purchaseDate by subscriptionStore.purchaseDate.collectAsState()
    val remoteMcpClients by remoteMcpClientStore.clients.collectAsState()
    val remoteMcpLoading by remoteMcpClientStore.isLoading.collectAsState()
    val remoteMcpError by remoteMcpClientStore.error.collectAsState()
    val revokingRemoteMcpClientId by remoteMcpClientStore.revokingClientId.collectAsState()

    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }

    DisposableEffect(isActive) {
        if (isActive) remoteMcpClientStore.startListening() else remoteMcpClientStore.stopListening()
        onDispose { remoteMcpClientStore.stopListening() }
    }

    val priceText = productDetails?.formattedPrice ?: "$4.99"

    Box(modifier = Modifier.fillMaxSize()) {
        AuroraBackdrop()

        Scaffold(
            containerColor = Color.Transparent,
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            "OpenBurnBar Cloud",
                            fontWeight = FontWeight.SemiBold,
                            color = Pal.textPrimary
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onClose) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(32.dp)
                                    .clip(CircleShape)
                                    .background(Pal.surface.copy(alpha = 0.6f))
                                    .border(0.6.dp, Pal.border, CircleShape)
                            ) {
                                Icon(
                                    Icons.Filled.Close,
                                    contentDescription = "Close",
                                    tint = Pal.textSecondary,
                                    modifier = Modifier.size(14.dp)
                                )
                            }
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent
                    )
                )
            }
        ) { innerPadding ->
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentPadding = PaddingValues(
                    start = 16.dp, end = 16.dp,
                    top = 12.dp, bottom = if (isActive) 28.dp else 140.dp
                ),
                verticalArrangement = Arrangement.spacedBy(20.dp)
            ) {
                item { CloudPosterHero(isActive = isActive) }

                item {
                    if (isActive) {
                        CloudAuroraMemberCard(
                            expirationDateMs = expirationDate,
                            purchaseDateMs = purchaseDate
                        )
                    } else {
                        CloudPlanGlassCard(priceText = priceText)
                    }
                }

                item { CloudCapabilityLineup(isActive = isActive) }
                item {
                    CloudRemoteMcpCard(
                        isActive = isActive,
                        clients = remoteMcpClients,
                        isLoading = remoteMcpLoading,
                        error = remoteMcpError,
                        revokingClientId = revokingRemoteMcpClientId,
                        onRevoke = remoteMcpClientStore::revoke
                    )
                }
                item { CloudComparisonCard() }
                item { CloudTrustCard() }

                if (error != null) {
                    item { CloudErrorCard(message = error!!) }
                }

                if (!isActive) {
                    item { Spacer(Modifier.height(8.dp)) }
                }
            }
        }

        // Floating action bar for free users — anchored to the bottom edge,
        // mirrors the iOS `CloudStoreActionBar`.
        if (!isActive) {
            CloudStoreActionBar(
                priceText = priceText,
                isLoading = isLoading,
                onPurchase = {
                    val activity = context as? android.app.Activity
                    activity?.let(subscriptionStore::purchase)
                },
                onRestore = { subscriptionStore.restorePurchases() },
                modifier = Modifier.align(Alignment.BottomCenter)
            )
        }
    }
}

// ── Aurora-glass card wrapper ──
//
// The single chrome primitive every Cloud card uses. UltraThinMaterial in
// spirit (matches iOS `.ultraThinMaterial`) — Android renders it via the
// surface tint plus the warm `cardGradient` overlay and an ember-tinted
// hairline border. Drop-in replacement for the old `MercuryFoilCard`.

@Composable
private fun AuroraGlassCard(
    modifier: Modifier = Modifier,
    cornerRadius: Int = 20,
    content: @Composable BoxScope.() -> Unit
) {
    val shape = RoundedCornerShape(cornerRadius.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .shadow(elevation = 10.dp, shape = shape, ambientColor = Color.Black, spotColor = Color.Black)
            .clip(shape)
            .background(Pal.surface.copy(alpha = 0.78f), shape)
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Pal.ember.copy(alpha = 0.06f),
                        Pal.amber.copy(alpha = 0.04f),
                        Pal.blaze.copy(alpha = 0.03f)
                    )
                ),
                shape = shape
            )
            .border(
                width = 0.6.dp,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Pal.ember.copy(alpha = 0.30f),
                        Pal.border.copy(alpha = 0.50f),
                        Pal.blaze.copy(alpha = 0.22f)
                    )
                ),
                shape = shape
            ),
        content = content
    )
}

// ── Hero ──

@Composable
private fun CloudPosterHero(isActive: Boolean) {
    var showBadgePicker by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Box(modifier = Modifier.clickable { showBadgePicker = true }) {
            CloudBadgeWithHalo(size = CloudBadgeSize.Large)
        }
        Text(
            "OPENBURNBAR",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 2.4.sp,
            color = Pal.textMuted
        )
        Text(
            "Cloud",
            style = TextStyle(
                fontFamily = FontFamily.SansSerif,
                fontWeight = FontWeight.Bold,
                fontSize = 36.sp,
                lineHeight = 42.sp,
                brush = Brush.linearGradient(listOf(Pal.ember, Pal.amber))
            )
        )
        Text(
            text = if (isActive) {
                "Your quota, your conversations, your agents — synced across every device."
            } else {
                "Hosted Codex refresh. Chat that follows you. Mac AI anywhere. From $4.99/mo."
            },
            fontSize = 14.sp,
            color = Pal.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 20.dp)
        )
    }

    if (showBadgePicker) {
        CloudBadgePickerSheet(onDismiss = { showBadgePicker = false })
    }
}

// ── Member card — aurora burst (matches You-tab) ──

@Composable
private fun CloudAuroraMemberCard(
    expirationDateMs: Long?,
    purchaseDateMs: Long?
) {
    val shape = RoundedCornerShape(26.dp)
    var showBadgePicker by remember { mutableStateOf(false) }

    val ribbonPhase = rememberInfiniteTransition(label = "memberRibbon").animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 18_000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "memberRibbonPhase"
    ).value

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .shadow(
                elevation = 26.dp,
                shape = shape,
                ambientColor = Pal.ember,
                spotColor = Pal.ember
            )
            .clip(shape)
    ) {
        MemberAuroraBackdrop(shape = shape, ribbonPhase = ribbonPhase)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .border(
                    width = 1.3.dp,
                    brush = Brush.linearGradient(
                        colors = listOf(
                            Pal.aureate,
                            Pal.amber,
                            Pal.ember,
                            Pal.aureate
                        )
                    ),
                    shape = shape
                )
                .padding(horizontal = 20.dp, vertical = 22.dp)
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Box(modifier = Modifier.clickable { showBadgePicker = true }) {
                    CloudBadgeWithHalo(size = CloudBadgeSize.Large)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .clip(CircleShape)
                            .background(
                                brush = Brush.horizontalGradient(
                                    colors = listOf(Pal.ember, Pal.amber)
                                )
                            )
                            .padding(horizontal = 9.dp, vertical = 3.dp)
                    ) {
                        Text(
                            "PRO",
                            color = Color.White,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Black,
                            letterSpacing = 1.8.sp
                        )
                    }
                    Spacer(Modifier.width(7.dp))
                    Text(
                        "OPENBURNBAR CLOUD",
                        color = Pal.textMuted,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Black,
                        letterSpacing = 2.0.sp
                    )
                }
                Text(
                    "Member",
                    style = TextStyle(
                        fontFamily = FontFamily.SansSerif,
                        fontWeight = FontWeight.Bold,
                        fontSize = 36.sp,
                        lineHeight = 40.sp,
                        brush = Brush.linearGradient(listOf(Pal.ember, Pal.amber))
                    )
                )
                Spacer(Modifier.height(2.dp))

                // Status pill
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Pal.success.copy(alpha = 0.14f))
                        .border(0.5.dp, Pal.success.copy(alpha = 0.45f), CircleShape)
                        .padding(horizontal = 12.dp, vertical = 6.dp)
                ) {
                    Icon(
                        Icons.Filled.VerifiedUser,
                        contentDescription = null,
                        tint = Pal.success,
                        modifier = Modifier.size(13.dp)
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        "Active",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Pal.textPrimary
                    )
                    Spacer(Modifier.width(6.dp))
                    Text("·", color = Pal.textMuted)
                    Spacer(Modifier.width(6.dp))
                    Text(
                        membershipStatusLine(expirationDateMs, purchaseDateMs),
                        fontSize = 11.sp,
                        color = Pal.textSecondary
                    )
                }

                // "Change badge" + Manage
                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.padding(top = 8.dp).fillMaxWidth()
                ) {
                    AuroraPrimaryButton(
                        text = "Manage",
                        icon = Icons.Filled.OpenInNew,
                        onClick = {
                            // Member-card manage tap — open Play subscription
                            // mgmt as a sensible Android equivalent of the
                            // iOS "Settings → Apple ID → Subscriptions" link.
                            // Currently a no-op placeholder until Play deep
                            // link wiring lands.
                        },
                        modifier = Modifier.weight(1f)
                    )
                    AuroraSecondaryButton(
                        text = "Change badge",
                        onClick = { showBadgePicker = true },
                        modifier = Modifier.weight(1f)
                    )
                }
            }
        }
    }

    if (showBadgePicker) {
        CloudBadgePickerSheet(onDismiss = { showBadgePicker = false })
    }
}

@Composable
private fun BoxScope.MemberAuroraBackdrop(shape: RoundedCornerShape, ribbonPhase: Float) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .clip(shape)
            .background(Pal.surface)
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Pal.ember.copy(alpha = 0.50f),
                        Pal.amber.copy(alpha = 0.38f),
                        Pal.blaze.copy(alpha = 0.30f),
                        Pal.whimsy.copy(alpha = 0.22f)
                    )
                )
            )
            .background(
                brush = Brush.linearGradient(
                    colors = listOf(
                        Pal.aureate.copy(alpha = 0.32f),
                        Pal.amber.copy(alpha = 0.50f),
                        Pal.ember.copy(alpha = 0.28f),
                        Color.Transparent
                    ),
                    start = androidx.compose.ui.geometry.Offset(ribbonPhase * 600f, 0f),
                    end = androidx.compose.ui.geometry.Offset(ribbonPhase * 600f + 900f, 220f)
                )
            )
            .background(
                brush = Brush.radialGradient(
                    colors = listOf(
                        Pal.amber.copy(alpha = 0.45f),
                        Pal.ember.copy(alpha = 0.20f),
                        Color.Transparent
                    ),
                    center = androidx.compose.ui.geometry.Offset(220f, 200f),
                    radius = 360f
                )
            )
    )
}

private fun membershipStatusLine(expirationMs: Long?, purchaseMs: Long?): String {
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val nowMs = System.currentTimeMillis()
    return when {
        expirationMs != null && expirationMs - nowMs in 1..(90L * 24 * 60 * 60 * 1000) -> {
            val days = ((expirationMs - nowMs) / (24L * 60 * 60 * 1000)).coerceAtLeast(0).toInt()
            val rel = if (days <= 1) "tomorrow" else "in $days days"
            if (purchaseMs != null) "Member since ${monthYear.format(java.util.Date(purchaseMs))} · renews $rel"
            else "Renews $rel"
        }
        expirationMs != null -> {
            if (purchaseMs != null) "Member since ${monthYear.format(java.util.Date(purchaseMs))} · renews monthly"
            else "Renews monthly"
        }
        purchaseMs != null -> "Member since ${monthYear.format(java.util.Date(purchaseMs))}"
        else -> "Renews monthly"
    }
}

// ── Plan tile (free users) ──

@Composable
private fun CloudPlanGlassCard(priceText: String) {
    AuroraGlassCard {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "MEMBERSHIP",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 2.4.sp,
                    color = Pal.ember
                )
                Spacer(Modifier.weight(1f))
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Pal.surface.copy(alpha = 0.6f), CircleShape)
                        .border(0.6.dp, Pal.border, CircleShape)
                        .padding(horizontal = 10.dp, vertical = 4.dp)
                ) {
                    Text(
                        "MONTHLY",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.4.sp,
                        color = Pal.textSecondary
                    )
                }
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    priceText,
                    style = TextStyle(
                        fontFamily = FontFamily.SansSerif,
                        fontWeight = FontWeight.Bold,
                        fontSize = 32.sp,
                        brush = Brush.linearGradient(listOf(Pal.ember, Pal.amber))
                    )
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "/ month",
                    fontSize = 14.sp,
                    color = Pal.textSecondary,
                    modifier = Modifier.padding(bottom = 4.dp)
                )
            }
            Text(
                "Billed monthly through Google Play. Manage or cancel anytime in Play Store.",
                fontSize = 12.sp,
                color = Pal.textSecondary
            )
        }
    }
}

// ── Aurora buttons ──

@Composable
private fun AuroraPrimaryButton(
    text: String,
    icon: ImageVector? = null,
    isLoading: Boolean = false,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .height(46.dp)
            .shadow(
                elevation = 14.dp,
                shape = CircleShape,
                ambientColor = Pal.ember,
                spotColor = Pal.ember
            )
            .clip(CircleShape)
            .background(
                brush = Brush.linearGradient(listOf(Pal.ember, Pal.amber)),
                shape = CircleShape
            )
            .border(
                width = 1.dp,
                color = Pal.amber.copy(alpha = 0.55f),
                shape = CircleShape
            )
            .clickable(enabled = !isLoading, onClick = onClick)
            .padding(horizontal = 18.dp)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            if (isLoading) {
                CircularProgressIndicator(
                    color = Color.White,
                    strokeWidth = 2.dp,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(8.dp))
            } else if (icon != null) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
            }
            Text(
                text,
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp
            )
        }
    }
}

@Composable
private fun AuroraSecondaryButton(
    text: String,
    icon: ImageVector? = null,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.height(46.dp),
        shape = CircleShape,
        colors = ButtonDefaults.outlinedButtonColors(
            contentColor = Pal.textPrimary,
            containerColor = Pal.surface.copy(alpha = 0.55f)
        ),
        border = androidx.compose.foundation.BorderStroke(
            width = 0.6.dp,
            color = Pal.border
        ),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 0.dp)
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

// ── Capability lineup ──

@Composable
private fun CloudCapabilityLineup(isActive: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "WHAT'S INCLUDED",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = Pal.ember
            )
            Spacer(Modifier.weight(1f))
            if (isActive) {
                Icon(
                    Icons.Filled.VerifiedUser,
                    null,
                    tint = Pal.amber,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
        CapabilityRow(
            icon = Icons.Filled.Cloud,
            tint = Pal.ember,
            title = "Hosted Codex quota",
            detail = "Refresh Codex quota from any signed-in device. We run the runner; you get the dial.",
            isActive = isActive
        )
        CapabilityRow(
            icon = Icons.Filled.Sync,
            tint = Pal.amber,
            title = "Conversation backup & resume",
            detail = "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off.",
            isActive = isActive
        )
        CapabilityRow(
            icon = Icons.Filled.Description,
            tint = Pal.blaze,
            title = "Full session-log sync",
            detail = "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device.",
            isActive = isActive
        )
        CapabilityRow(
            icon = Icons.Filled.Wifi,
            tint = Pal.whimsy,
            title = "Hermes remote relay",
            detail = "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end.",
            isActive = isActive
        )
    }
}

@Composable
private fun CapabilityRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    detail: String,
    isActive: Boolean
) {
    AuroraGlassCard(cornerRadius = 16) {
        Row(
            verticalAlignment = Alignment.Top,
            modifier = Modifier
                .fillMaxWidth()
                .padding(14.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(
                        brush = Brush.linearGradient(listOf(tint, tint.copy(alpha = 0.7f)))
                    )
            ) {
                Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        title,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Pal.textPrimary
                    )
                    if (isActive) {
                        Spacer(Modifier.width(6.dp))
                        Icon(
                            Icons.Filled.VerifiedUser,
                            null,
                            tint = Pal.success,
                            modifier = Modifier.size(13.dp)
                        )
                    }
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    detail,
                    fontSize = 12.sp,
                    color = Pal.textSecondary
                )
            }
        }
    }
}

// ── Remote MCP card ──

@Composable
private fun CloudRemoteMcpCard(
    isActive: Boolean,
    clients: List<RemoteMcpClientRecord>,
    isLoading: Boolean,
    error: String?,
    revokingClientId: String?,
    onRevoke: (RemoteMcpClientRecord) -> Unit
) {
    val endpoint = "https://mcp.openburnbar.com/mcp"
    val stdioCommand = "openburnbar-mcp-remote mcp serve"
    val doctorCommand = "openburnbar mcp doctor"

    AuroraGlassCard {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "REMOTE MCP",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 2.4.sp,
                    color = Pal.ember
                )
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (isActive) Icons.Filled.VerifiedUser else Icons.Filled.Cloud,
                        null,
                        tint = if (isActive) Pal.success else Pal.textMuted,
                        modifier = Modifier.size(14.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (isActive) "Included" else "Cloud only",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isActive) Pal.success else Pal.textMuted
                    )
                }
            }

            Text(
                "Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP for hosted clients; a local shim keeps decrypted snippets on-device for stdio.",
                fontSize = 12.sp,
                color = Pal.textSecondary
            )

            RemoteMcpCommandRow(label = "Endpoint", value = endpoint)
            RemoteMcpCommandRow(label = "Stdio shim", value = stdioCommand)
            RemoteMcpCommandRow(label = "Doctor", value = doctorCommand)

            if (isActive) {
                RemoteMcpConnectedClientsSection(
                    clients = clients,
                    isLoading = isLoading,
                    error = error,
                    revokingClientId = revokingClientId,
                    onRevoke = onRevoke
                )
            }
        }
    }
}

@Composable
private fun RemoteMcpCommandRow(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            label.uppercase(Locale.getDefault()),
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.2.sp,
            color = Pal.textMuted
        )
        Text(
            value,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            color = Pal.textPrimary,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(Pal.surface.copy(alpha = 0.72f), RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 7.dp)
        )
    }
}

@Composable
private fun RemoteMcpConnectedClientsSection(
    clients: List<RemoteMcpClientRecord>,
    isLoading: Boolean,
    error: String?,
    revokingClientId: String?,
    onRevoke: (RemoteMcpClientRecord) -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Connected clients",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = Pal.textPrimary
            )
            Spacer(Modifier.weight(1f))
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = Pal.ember
                )
            }
        }

        when {
            error != null -> Text(error, fontSize = 11.sp, color = AuroraColors.error)
            clients.isEmpty() && !isLoading -> Text(
                "No MCP clients are connected yet.",
                fontSize = 12.sp,
                color = Pal.textMuted
            )
            else -> clients.forEach { client ->
                RemoteMcpClientRow(
                    client = client,
                    isRevoking = revokingClientId == client.id,
                    onRevoke = { onRevoke(client) }
                )
            }
        }
    }
}

@Composable
private fun RemoteMcpClientRow(
    client: RemoteMcpClientRecord,
    isRevoking: Boolean,
    onRevoke: () -> Unit
) {
    var showConfirm by remember { mutableStateOf(false) }

    if (showConfirm) {
        AlertDialog(
            onDismissRequest = { showConfirm = false },
            title = { Text("Revoke MCP client?") },
            text = { Text("This immediately blocks ${client.displayName} and revokes its outstanding grants.") },
            confirmButton = {
                TextButton(onClick = { showConfirm = false; onRevoke() }) {
                    Text("Revoke", color = AuroraColors.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirm = false }) { Text("Cancel") }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(Pal.surface.copy(alpha = 0.60f), RoundedCornerShape(10.dp))
            .border(
                0.5.dp,
                if (client.isRevoked) Pal.border else Pal.ember.copy(alpha = 0.30f),
                RoundedCornerShape(10.dp)
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp)
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                if (client.isRevoked) Icons.Filled.Close else Icons.Filled.VerifiedUser,
                null,
                tint = if (client.isRevoked) Pal.textMuted else Pal.success,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(8.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(client.displayName, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Pal.textPrimary)
                Text("${client.displayType} · ${client.modeSummary}", fontSize = 11.sp, color = Pal.textSecondary)
                Text(client.scopeSummary, fontSize = 10.sp, color = Pal.textMuted)
            }
            if (client.isRevoked) {
                Text("Revoked", fontSize = 10.sp, color = Pal.textMuted)
            } else {
                IconButton(
                    enabled = !isRevoking,
                    onClick = { showConfirm = true },
                    modifier = Modifier.size(28.dp)
                ) {
                    if (isRevoking) {
                        CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = Pal.ember)
                    } else {
                        Icon(Icons.Filled.Close, "Revoke ${client.displayName}", tint = AuroraColors.error)
                    }
                }
            }
        }
        Text(
            when {
                client.lastUsedAt != null -> "Used ${relativeAge(client.lastUsedAt)}"
                client.createdAt != null -> "Added ${relativeAge(client.createdAt)}"
                else -> "Awaiting first use"
            },
            fontSize = 10.sp,
            color = Pal.textMuted
        )
    }
}

private fun relativeAge(date: java.util.Date): String {
    val elapsedMs = (System.currentTimeMillis() - date.time).coerceAtLeast(0L)
    val minutes = elapsedMs / 60_000L
    val hours = minutes / 60L
    val days = hours / 24L
    return when {
        days > 0 -> "$days d ago"
        hours > 0 -> "$hours h ago"
        minutes > 0 -> "$minutes min ago"
        else -> "just now"
    }
}

// ── Comparison ──

@Composable
private fun CloudComparisonCard() {
    val rows = listOf(
        Triple("Quota refresh", "Local-only", "On-demand, anywhere"),
        Triple("Chat backup", "Metadata only", "Full content"),
        Triple("Session logs", "Manifest only", "Search metadata"),
        Triple("Hermes Remote Relay", "Local network", "Anywhere")
    )

    AuroraGlassCard {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
            Text(
                "FREE VS CLOUD",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = Pal.ember
            )
            Spacer(Modifier.height(10.dp))
            Row {
                Text(
                    "Capability",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.0.sp,
                    color = Pal.textMuted,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "FREE",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.4.sp,
                    color = Pal.textMuted,
                    modifier = Modifier.width(80.dp),
                    textAlign = TextAlign.End
                )
                Text(
                    "CLOUD",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.4.sp,
                    color = Pal.ember,
                    modifier = Modifier.width(90.dp),
                    textAlign = TextAlign.End
                )
            }
            HorizontalDivider(
                modifier = Modifier.padding(vertical = 8.dp),
                color = Pal.ember.copy(alpha = 0.25f)
            )
            rows.forEachIndexed { index, (label, free, cloud) ->
                Row(modifier = Modifier.padding(vertical = 6.dp)) {
                    Text(label, fontSize = 13.sp, color = Pal.textPrimary, modifier = Modifier.weight(1f))
                    Text(free, fontSize = 11.sp, color = Pal.textMuted, modifier = Modifier.width(80.dp), textAlign = TextAlign.End)
                    Text(
                        cloud,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Pal.textPrimary,
                        modifier = Modifier.width(90.dp),
                        textAlign = TextAlign.End
                    )
                }
                if (index < rows.size - 1) HorizontalDivider(color = Pal.border.copy(alpha = 0.5f))
            }
        }
    }
}

// ── Trust ──

@Composable
private fun CloudTrustCard() {
    val bullets = listOf(
        Triple(Icons.Filled.VerifiedUser, "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        Triple(Icons.Filled.Backup, "UID-bound", "Each purchase is bound to your Firebase UID via a signed appAccountToken."),
        Triple(Icons.Filled.Cloud, "Cancel anytime", "Managed by Apple in Settings → Apple ID. We never store payment details.")
    )
    AuroraGlassCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "THE TRUST MODEL",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = Pal.ember
            )
            bullets.forEach { (icon, title, detail) ->
                Row(verticalAlignment = Alignment.Top) {
                    Icon(icon, null, tint = Pal.amber, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Pal.textPrimary)
                        Text(detail, fontSize = 12.sp, color = Pal.textSecondary)
                    }
                }
            }
        }
    }
}

// ── Action bar (free users) ──

@Composable
private fun CloudStoreActionBar(
    priceText: String,
    isLoading: Boolean,
    onPurchase: () -> Unit,
    onRestore: () -> Unit,
    modifier: Modifier = Modifier
) {
    val uriHandler = LocalUriHandler.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(
                brush = Brush.verticalGradient(
                    colors = listOf(
                        Color.Transparent,
                        Pal.surface.copy(alpha = 0.92f),
                        Pal.surface
                    )
                )
            )
            .padding(horizontal = 16.dp)
            .padding(top = 14.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
            Text(
                "OpenBurnBar Cloud",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Pal.textPrimary
            )
            Text(
                "$priceText / month · billed by Google Play",
                fontSize = 11.sp,
                color = Pal.textSecondary
            )
        }
        AuroraPrimaryButton(
            text = "Become a Member — $priceText/mo",
            isLoading = isLoading,
            onClick = onPurchase,
            modifier = Modifier.fillMaxWidth()
        )
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text(
                text = "Restore Purchases",
                fontSize = 12.sp,
                color = Pal.textSecondary,
                modifier = Modifier.clickable { onRestore() }
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Privacy",
                fontSize = 11.sp,
                color = Pal.ember,
                modifier = Modifier.clickable {
                    uriHandler.openUri("https://openburnbar.com/legal/privacy-policy")
                }
            )
            Spacer(Modifier.width(8.dp))
            Text("·", color = Pal.textMuted, fontSize = 11.sp)
            Spacer(Modifier.width(8.dp))
            Text(
                "Terms",
                fontSize = 11.sp,
                color = Pal.ember,
                modifier = Modifier.clickable {
                    uriHandler.openUri("https://openburnbar.com/legal/terms")
                }
            )
        }
    }
}

// ── Error ──

@Composable
private fun CloudErrorCard(message: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(AuroraColors.error.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
            .border(0.5.dp, AuroraColors.error.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
            .padding(12.dp)
    ) {
        Text(message, color = AuroraColors.error, fontSize = 12.sp)
    }
}
