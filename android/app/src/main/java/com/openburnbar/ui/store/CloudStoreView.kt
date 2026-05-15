package com.openburnbar.ui.store

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.openburnbar.data.stores.HostedQuotaSubscriptionStore
import com.openburnbar.data.stores.RemoteMcpClientRecord
import com.openburnbar.data.stores.RemoteMcpClientStore
import com.openburnbar.ui.pro.FoilCTAButton
import com.openburnbar.ui.pro.MercuryCrest
import com.openburnbar.ui.pro.MercuryCrestSize
import com.openburnbar.ui.pro.MercuryFoilCard
import com.openburnbar.ui.pro.ProLayout
import com.openburnbar.ui.pro.ProPalette
import com.openburnbar.ui.pro.ProPosterScaffold
import com.openburnbar.ui.pro.ProTypography
import com.openburnbar.ui.theme.AuroraColors
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import java.text.SimpleDateFormat
import java.util.Locale

// ── Cloud Store View (Android — Pro Poster) ──
//
// The Pro destination. Wears the "luxury island in utilitarian sea"
// vocabulary — obsidian + mercury foil + serif display. Same world as the
// iOS poster so a member who buys on iPhone walks here and finds parity.
//
// Surfaces:
//   • Free   — serif hero, MercuryFoilCard plan tile, capability lineup,
//              comparison, trust, foil CTA action bar.
//   • Member — serif hero, MercuryCrest + member certificate card,
//              capabilities with checks, comparison, trust, no CTA.

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
    val reduceMotion = LocalAuroraReduceMotion.current

    LaunchedEffect(context) {
        subscriptionStore.initialize(context)
        subscriptionStore.load()
    }

    DisposableEffect(isActive) {
        if (isActive) remoteMcpClientStore.startListening() else remoteMcpClientStore.stopListening()
        onDispose { remoteMcpClientStore.stopListening() }
    }

    val priceText = productDetails?.formattedPrice ?: "$4.99"

    ProPosterScaffold {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = {
                        Text(
                            "OpenBurnBar Cloud",
                            fontFamily = FontFamily.Serif,
                            fontWeight = FontWeight.SemiBold,
                            color = ProPalette.mercury
                        )
                    },
                    navigationIcon = {
                        IconButton(onClick = onClose) {
                            Icon(
                                Icons.Filled.Close,
                                null,
                                tint = ProPalette.mercury.copy(alpha = 0.78f)
                            )
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = Color.Transparent,
                        scrolledContainerColor = Color.Transparent
                    )
                )
            },
            containerColor = Color.Transparent
        ) { innerPadding ->
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
                contentPadding = PaddingValues(20.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp)
            ) {
                item { CloudPosterHero(reduceMotion = reduceMotion, isActive = isActive) }

                item {
                    if (isActive) {
                        CloudMemberCard(
                            expirationDate = expirationDate,
                            purchaseDate = purchaseDate
                        )
                    } else {
                        CloudPlanTile(priceText = priceText)
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
                    item {
                        val activity = context as? android.app.Activity
                        FoilCTAButton(
                            title = "Become a Member",
                            subtitle = "$priceText / month · Apple-verified, billed monthly",
                            isLoading = isLoading,
                            onClick = { activity?.let(subscriptionStore::purchase) }
                        )
                    }
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = "Restore Purchases",
                                fontSize = 12.sp,
                                color = ProPalette.mercury.copy(alpha = 0.7f),
                                modifier = Modifier.clip(RoundedCornerShape(6.dp))
                            )
                            Spacer(Modifier.weight(1f))
                            Text(
                                "Privacy · Terms",
                                fontSize = 11.sp,
                                color = ProPalette.aureate
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudPosterHero(reduceMotion: Boolean, isActive: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        MercuryCrest(size = MercuryCrestSize.Large, shimmer = !reduceMotion)
        Spacer(Modifier.height(4.dp))
        Text(
            "OPENBURNBAR",
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 3.6.sp,
            color = ProPalette.aureate
        )
        Text(
            "Cloud",
            style = ProTypography.displaySerif,
            color = ProPalette.mercury
        )
        Text(
            text = if (isActive) {
                "Your agents, unbound. Renewing on schedule."
            } else {
                "Your agents, unbound — hosted refresh, conversation backup, Hermes anywhere."
            },
            fontSize = 13.sp,
            color = ProPalette.mercury.copy(alpha = 0.72f),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 16.dp)
        )
    }
}

@Composable
private fun CloudPlanTile(priceText: String) {
    MercuryFoilCard {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "MEMBERSHIP",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 2.4.sp,
                    color = ProPalette.aureate
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "MONTHLY",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.4.sp,
                    color = ProPalette.mercury,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(ProPalette.obsidianElevated, CircleShape)
                        .border(0.7.dp, Brush.linearGradient(ProPalette.aureateStrokeStops), CircleShape)
                        .padding(horizontal = 10.dp, vertical = 4.dp)
                )
            }
            Row(verticalAlignment = Alignment.Bottom) {
                Text(
                    priceText,
                    style = ProTypography.priceMono,
                    color = ProPalette.mercury
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "/ month",
                    fontSize = 13.sp,
                    color = ProPalette.mercury.copy(alpha = 0.65f),
                    modifier = Modifier.padding(bottom = 2.dp)
                )
            }
            Text(
                "Billed monthly through Google Play. Manage or cancel anytime in Play Store.",
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.65f)
            )
        }
    }
}

@Composable
private fun CloudMemberCard(expirationDate: Long?, purchaseDate: Long?) {
    val sdf = SimpleDateFormat("MMM d", Locale.getDefault())
    val monthYear = SimpleDateFormat("MMM yyyy", Locale.getDefault())
    val reduceMotion = LocalAuroraReduceMotion.current

    MercuryFoilCard {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(22.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            MercuryCrest(size = MercuryCrestSize.Medium, shimmer = !reduceMotion)
            Text(
                "CLOUD",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 3.0.sp,
                color = ProPalette.aureate
            )
            Text(
                "Member",
                style = ProTypography.titleSerif,
                color = ProPalette.mercury
            )
            if (expirationDate != null) {
                Text(
                    "Renews ${sdf.format(java.util.Date(expirationDate))}",
                    fontSize = 13.sp,
                    color = ProPalette.mercury.copy(alpha = 0.85f)
                )
            } else {
                Text(
                    "Active",
                    fontSize = 13.sp,
                    color = ProPalette.aureate
                )
            }
            if (purchaseDate != null) {
                Text(
                    "Member since ${monthYear.format(java.util.Date(purchaseDate))}",
                    fontSize = 11.sp,
                    color = ProPalette.mercury.copy(alpha = 0.6f)
                )
            }
        }
    }
}

@Composable
private fun CloudCapabilityLineup(isActive: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "WHAT'S INCLUDED",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 2.4.sp,
                color = ProPalette.aureate
            )
            Spacer(Modifier.weight(1f))
            if (isActive) {
                Icon(
                    Icons.Filled.VerifiedUser,
                    null,
                    tint = ProPalette.aureate,
                    modifier = Modifier.size(14.dp)
                )
            }
        }
        CapabilityRow(
            icon = Icons.Filled.Cloud,
            title = "Hosted Codex quota",
            detail = "Refresh Codex quota from any signed-in device. We run the runner; you get the dial."
        )
        CapabilityRow(
            icon = Icons.Filled.Sync,
            title = "Conversation backup & resume",
            detail = "Encrypted in transit, restored across iPhone, iPad, and Mac. Pick up exactly where you left off."
        )
        CapabilityRow(
            icon = Icons.Filled.Description,
            title = "Full session-log sync",
            detail = "Every tool call, every chunk, every cost line — mirrored to the cloud and searchable on every device."
        )
        CapabilityRow(
            icon = Icons.Filled.Wifi,
            title = "Hermes remote relay",
            detail = "Reach your Mac's Hermes from anywhere over a verified WebSocket. App Check + Apple JWS, end-to-end."
        )
    }
}

@Composable
private fun CapabilityRow(icon: ImageVector, title: String, detail: String) {
    Row(
        verticalAlignment = Alignment.Top,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(ProLayout.bandRadiusDp.dp))
            .background(ProPalette.obsidianElevated, RoundedCornerShape(ProLayout.bandRadiusDp.dp))
            .border(
                0.7.dp,
                Brush.linearGradient(ProPalette.aureateStrokeStops),
                RoundedCornerShape(ProLayout.bandRadiusDp.dp)
            )
            .padding(14.dp)
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
                .size(32.dp)
                .clip(CircleShape)
                .background(ProPalette.obsidian, CircleShape)
                .border(0.9.dp, Brush.linearGradient(ProPalette.aureateStrokeStops), CircleShape)
        ) {
            Icon(icon, null, tint = ProPalette.aureate, modifier = Modifier.size(15.dp))
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = ProTypography.headlineSerif,
                color = ProPalette.mercury
            )
            Text(
                detail,
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.70f)
            )
        }
    }
}

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

    MercuryFoilCard {
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
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 2.4.sp,
                    color = ProPalette.aureate
                )
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (isActive) Icons.Filled.VerifiedUser else Icons.Filled.Cloud,
                        null,
                        tint = if (isActive) ProPalette.aureate else ProPalette.mercury.copy(alpha = 0.62f),
                        modifier = Modifier.size(14.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (isActive) "Included" else "Cloud only",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isActive) ProPalette.aureate else ProPalette.mercury.copy(alpha = 0.62f)
                    )
                }
            }

            Text(
                "Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted hosted session-memory search. Direct HTTP for hosted clients; a local shim keeps decrypted snippets on-device for stdio.",
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.72f)
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
            color = ProPalette.mercury.copy(alpha = 0.55f)
        )
        Text(
            value,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            color = ProPalette.mercury,
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(ProPalette.obsidianElevated.copy(alpha = 0.86f), RoundedCornerShape(8.dp))
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
                color = ProPalette.mercury
            )
            Spacer(Modifier.weight(1f))
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = ProPalette.aureate
                )
            }
        }

        when {
            error != null -> Text(
                error,
                fontSize = 11.sp,
                color = AuroraColors.error
            )
            clients.isEmpty() && !isLoading -> Text(
                "No MCP clients are connected yet.",
                fontSize = 12.sp,
                color = ProPalette.mercury.copy(alpha = 0.62f)
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
                TextButton(
                    onClick = {
                        showConfirm = false
                        onRevoke()
                    }
                ) {
                    Text("Revoke", color = AuroraColors.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showConfirm = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(ProPalette.obsidianElevated.copy(alpha = 0.72f), RoundedCornerShape(8.dp))
            .border(
                0.5.dp,
                if (client.isRevoked) ProPalette.mercury.copy(alpha = 0.22f) else ProPalette.aureate.copy(alpha = 0.28f),
                RoundedCornerShape(8.dp)
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp)
    ) {
        Row(verticalAlignment = Alignment.Top) {
            Icon(
                if (client.isRevoked) Icons.Filled.Close else Icons.Filled.VerifiedUser,
                null,
                tint = if (client.isRevoked) ProPalette.mercury.copy(alpha = 0.45f) else ProPalette.aureate,
                modifier = Modifier.size(16.dp)
            )
            Spacer(Modifier.width(8.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    client.displayName,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = ProPalette.mercury
                )
                Text(
                    "${client.displayType} · ${client.modeSummary}",
                    fontSize = 11.sp,
                    color = ProPalette.mercury.copy(alpha = 0.70f)
                )
                Text(
                    client.scopeSummary,
                    fontSize = 10.sp,
                    color = ProPalette.mercury.copy(alpha = 0.54f)
                )
            }
            if (client.isRevoked) {
                Text("Revoked", fontSize = 10.sp, color = ProPalette.mercury.copy(alpha = 0.48f))
            } else {
                IconButton(
                    enabled = !isRevoking,
                    onClick = { showConfirm = true },
                    modifier = Modifier.size(28.dp)
                ) {
                    if (isRevoking) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            strokeWidth = 2.dp,
                            color = ProPalette.aureate
                        )
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
            color = ProPalette.mercury.copy(alpha = 0.54f)
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

@Composable
private fun CloudComparisonCard() {
    val rows = listOf(
        Triple("Quota refresh", "Local-only", "On-demand, anywhere"),
        Triple("Chat backup", "Metadata only", "Full content"),
        Triple("Session logs", "Manifest only", "Search metadata"),
        Triple("Hermes Remote Relay", "Local network", "Anywhere")
    )

    MercuryFoilCard {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                "FREE VS CLOUD",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 2.4.sp,
                color = ProPalette.aureate
            )
            Spacer(Modifier.height(10.dp))
            Row {
                Text(
                    "Capability",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.0.sp,
                    color = ProPalette.mercury.copy(alpha = 0.55f),
                    modifier = Modifier.weight(1f)
                )
                Text(
                    "FREE",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.4.sp,
                    color = ProPalette.mercury.copy(alpha = 0.55f),
                    modifier = Modifier.width(80.dp),
                    textAlign = TextAlign.End
                )
                Text(
                    "CLOUD",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.4.sp,
                    color = ProPalette.aureate,
                    modifier = Modifier.width(90.dp),
                    textAlign = TextAlign.End
                )
            }
            HorizontalDivider(
                modifier = Modifier.padding(vertical = 8.dp),
                color = ProPalette.aureate.copy(alpha = 0.35f)
            )
            rows.forEachIndexed { index, (label, free, cloud) ->
                Row(modifier = Modifier.padding(vertical = 6.dp)) {
                    Text(
                        label,
                        fontSize = 13.sp,
                        color = ProPalette.mercury,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        free,
                        fontSize = 11.sp,
                        color = ProPalette.mercury.copy(alpha = 0.55f),
                        modifier = Modifier.width(80.dp),
                        textAlign = TextAlign.End
                    )
                    Text(
                        cloud,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = ProPalette.mercury,
                        modifier = Modifier.width(90.dp),
                        textAlign = TextAlign.End
                    )
                }
                if (index < rows.size - 1) {
                    HorizontalDivider(color = ProPalette.mercury.copy(alpha = 0.18f))
                }
            }
        }
    }
}

@Composable
private fun CloudTrustCard() {
    val bullets = listOf(
        Triple(Icons.Filled.VerifiedUser, "Apple-verified", "Every transaction JWS is checked against Apple's root certificates server-side."),
        Triple(Icons.Filled.Backup, "UID-bound", "Each purchase is bound to your Firebase UID via a signed appAccountToken."),
        Triple(Icons.Filled.Cloud, "Cancel anytime", "Managed by Apple in Settings → Apple ID. We never store payment details.")
    )

    MercuryFoilCard {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            Text(
                "THE TRUST MODEL",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 2.4.sp,
                color = ProPalette.aureate
            )
            bullets.forEach { (icon, title, detail) ->
                Row(verticalAlignment = Alignment.Top) {
                    Icon(
                        icon,
                        null,
                        tint = ProPalette.aureate,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(
                            title,
                            style = ProTypography.headlineSerif,
                            color = ProPalette.mercury
                        )
                        Text(
                            detail,
                            fontSize = 12.sp,
                            color = ProPalette.mercury.copy(alpha = 0.70f)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CloudErrorCard(message: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(AuroraColors.error.copy(alpha = 0.18f), RoundedCornerShape(10.dp))
            .border(0.5.dp, AuroraColors.error.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
            .padding(12.dp)
    ) {
        Text(message, color = AuroraColors.error, fontSize = 12.sp)
    }
}
