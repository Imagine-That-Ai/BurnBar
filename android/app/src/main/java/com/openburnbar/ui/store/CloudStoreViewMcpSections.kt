@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures UI structure.

package com.openburnbar.ui.store

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.stores.RemoteMcpClientRecord
import com.openburnbar.ui.theme.AuroraColors
import java.util.Locale

// ── Remote MCP card ──

@Composable
internal fun CloudRemoteMcpCard(
    isActive: Boolean,
    clients: List<RemoteMcpClientRecord>,
    isLoading: Boolean,
    error: String?,
    revokingClientId: String?,
    onRevoke: (RemoteMcpClientRecord) -> Unit,
) {
    val endpoint = "https://mcp.burnbar.ai/mcp"
    val stdioCommand = "openburnbar-mcp-remote mcp serve"
    val doctorCommand = "openburnbar mcp doctor"

    AuroraGlassCard {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "REMOTE MCP",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = 2.4.sp,
                    color = CloudStorePal.ember,
                )
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (isActive) Icons.Filled.VerifiedUser else Icons.Filled.Cloud,
                        null,
                        tint = if (isActive) CloudStorePal.success else CloudStorePal.textMuted,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        if (isActive) "Included" else "Cloud only",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        color = if (isActive) CloudStorePal.success else CloudStorePal.textMuted,
                    )
                }
            }

            Text(
                "Connect Codex, Claude Code, Droid, Kimi, Forge, or any MCP client to encrypted " +
                    "hosted session-memory search. Direct HTTP for hosted clients; a local shim keeps " +
                    "decrypted snippets on-device for stdio.",
                fontSize = 12.sp,
                color = CloudStorePal.textSecondary,
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
                    onRevoke = onRevoke,
                )
            }
        }
    }
}

@Composable
internal fun RemoteMcpCommandRow(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            label.uppercase(Locale.getDefault()),
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.2.sp,
            color = CloudStorePal.textMuted,
        )
        Text(
            value,
            fontSize = 12.sp,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            color = CloudStorePal.textPrimary,
            modifier =
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(8.dp))
                .background(CloudStorePal.surface.copy(alpha = 0.72f), RoundedCornerShape(8.dp))
                .padding(horizontal = 10.dp, vertical = 7.dp),
        )
    }
}

@Composable
internal fun RemoteMcpConnectedClientsSection(
    clients: List<RemoteMcpClientRecord>,
    isLoading: Boolean,
    error: String?,
    revokingClientId: String?,
    onRevoke: (RemoteMcpClientRecord) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Connected clients",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = CloudStorePal.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            if (isLoading) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = CloudStorePal.ember,
                )
            }
        }

        when {
            error != null -> Text(error, fontSize = 11.sp, color = AuroraColors.error)
            clients.isEmpty() && !isLoading ->
                Text(
                    "No MCP clients are connected yet.",
                    fontSize = 12.sp,
                    color = CloudStorePal.textMuted,
                )
            else ->
                clients.forEach { client ->
                    RemoteMcpClientRow(
                        client = client,
                        isRevoking = revokingClientId == client.id,
                        onRevoke = { onRevoke(client) },
                    )
                }
        }
    }
}

@Composable
internal fun RemoteMcpClientRow(client: RemoteMcpClientRecord, isRevoking: Boolean, onRevoke: () -> Unit) {
    var showConfirm by remember { mutableStateOf(false) }

    if (showConfirm) {
        RemoteMcpRevokeDialog(
            clientName = client.displayName,
            onDismiss = { showConfirm = false },
            onConfirm = {
                showConfirm = false
                onRevoke()
            },
        )
    }

    RemoteMcpClientRowContent(
        client = client,
        isRevoking = isRevoking,
        onRequestRevoke = { showConfirm = true },
    )
}

@Composable
internal fun RemoteMcpRevokeDialog(clientName: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Revoke MCP client?") },
        text = { Text("This immediately blocks $clientName and revokes its outstanding grants.") },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Revoke", color = AuroraColors.error)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
internal fun RemoteMcpClientRowContent(
    client: RemoteMcpClientRecord,
    isRevoking: Boolean,
    onRequestRevoke: () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(CloudStorePal.surface.copy(alpha = 0.60f), RoundedCornerShape(10.dp))
            .border(
                0.5.dp,
                if (client.isRevoked) CloudStorePal.border else CloudStorePal.ember.copy(alpha = 0.30f),
                RoundedCornerShape(10.dp),
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        RemoteMcpClientRowHeader(
            client = client,
            isRevoking = isRevoking,
            onRequestRevoke = onRequestRevoke,
        )
        Text(
            when {
                client.lastUsedAt != null -> "Used ${relativeAge(client.lastUsedAt)}"
                client.createdAt != null -> "Added ${relativeAge(client.createdAt)}"
                else -> "Awaiting first use"
            },
            fontSize = 10.sp,
            color = CloudStorePal.textMuted,
        )
    }
}

@Composable
internal fun RemoteMcpClientRowHeader(
    client: RemoteMcpClientRecord,
    isRevoking: Boolean,
    onRequestRevoke: () -> Unit,
) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            if (client.isRevoked) Icons.Filled.Close else Icons.Filled.VerifiedUser,
            null,
            tint = if (client.isRevoked) CloudStorePal.textMuted else CloudStorePal.success,
            modifier = Modifier.size(16.dp),
        )
        Spacer(Modifier.width(8.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(client.displayName, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = CloudStorePal.textPrimary)
            Text("${client.displayType} · ${client.modeSummary}", fontSize = 11.sp, color = CloudStorePal.textSecondary)
            Text(client.scopeSummary, fontSize = 10.sp, color = CloudStorePal.textMuted)
        }
        if (client.isRevoked) {
            Text("Revoked", fontSize = 10.sp, color = CloudStorePal.textMuted)
        } else {
            IconButton(
                enabled = !isRevoking,
                onClick = onRequestRevoke,
                modifier = Modifier.size(28.dp),
            ) {
                if (isRevoking) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp, color = CloudStorePal.ember)
                } else {
                    Icon(Icons.Filled.Close, "Revoke ${client.displayName}", tint = AuroraColors.error)
                }
            }
        }
    }
}

internal fun relativeAge(date: java.util.Date): String {
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
internal fun CloudComparisonCard() {
    val rows =
        listOf(
            Triple("Quota refresh", "Local-only", "On-demand, anywhere"),
            Triple("Chat backup", "Metadata only", "Full content"),
            Triple("Session logs", "Manifest only", "Search metadata"),
            Triple("Hermes Remote Relay", "Local network", "Anywhere"),
        )

    AuroraGlassCard {
        Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
            Text(
                "FREE VS CLOUD",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = CloudStorePal.ember,
            )
            Spacer(Modifier.height(10.dp))
            CloudComparisonTableHeader()
            HorizontalDivider(
                modifier = Modifier.padding(vertical = 8.dp),
                color = CloudStorePal.ember.copy(alpha = 0.25f),
            )
            CloudComparisonRows(rows = rows)
        }
    }
}

@Composable
internal fun CloudComparisonTableHeader() {
    Row {
        Text(
            "Capability",
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.0.sp,
            color = CloudStorePal.textMuted,
            modifier = Modifier.weight(1f),
        )
        Text(
            "FREE",
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.4.sp,
            color = CloudStorePal.textMuted,
            modifier = Modifier.width(80.dp),
            textAlign = TextAlign.End,
        )
        Text(
            "CLOUD",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.4.sp,
            color = CloudStorePal.ember,
            modifier = Modifier.width(90.dp),
            textAlign = TextAlign.End,
        )
    }
}

@Composable
internal fun CloudComparisonRows(rows: List<Triple<String, String, String>>) {
    rows.forEachIndexed { index, (label, free, cloud) ->
        Row(modifier = Modifier.padding(vertical = 6.dp)) {
            Text(label, fontSize = 13.sp, color = CloudStorePal.textPrimary, modifier = Modifier.weight(1f))
            Text(free, fontSize = 11.sp, color = CloudStorePal.textMuted, modifier = Modifier.width(80.dp), textAlign = TextAlign.End)
            Text(
                cloud,
                fontSize = 11.sp,
                fontWeight = FontWeight.SemiBold,
                color = CloudStorePal.textPrimary,
                modifier = Modifier.width(90.dp),
                textAlign = TextAlign.End,
            )
        }
        if (index < rows.size - 1) HorizontalDivider(color = CloudStorePal.border.copy(alpha = 0.5f))
    }
}

// ── Trust ──

@Composable
internal fun CloudTrustCard() {
    val bullets =
        listOf(
            Triple(Icons.Filled.VerifiedUser, "Play-verified", "Every purchase token is checked server-side before an entitlement or top-up is credited."),
            Triple(Icons.Filled.Backup, "UID-bound", "Each purchase launches with a Firebase UID hash and verifies against your signed-in account."),
            Triple(Icons.Filled.Cloud, "Cancel anytime", "Subscriptions are managed by Google Play. We never store payment details."),
        )
    AuroraGlassCard {
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "THE TRUST MODEL",
                fontSize = 11.sp,
                fontWeight = FontWeight.Black,
                letterSpacing = 2.4.sp,
                color = CloudStorePal.ember,
            )
            bullets.forEach { (icon, title, detail) ->
                Row(verticalAlignment = Alignment.Top) {
                    Icon(icon, null, tint = CloudStorePal.amber, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(10.dp))
                    Column {
                        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = CloudStorePal.textPrimary)
                        Text(detail, fontSize = 12.sp, color = CloudStorePal.textSecondary)
                    }
                }
            }
        }
    }
}

// ── Action bar (free users) ──

@Composable
internal fun CloudStoreActionBar(priceText: String, isLoading: Boolean, onPurchase: () -> Unit, onRestore: () -> Unit, modifier: Modifier = Modifier) {
    val uriHandler = LocalUriHandler.current
    Column(
        modifier =
        modifier
            .fillMaxWidth()
            .background(
                brush =
                Brush.verticalGradient(
                    colors =
                    listOf(
                        Color.Transparent,
                        CloudStorePal.surface.copy(alpha = 0.92f),
                        CloudStorePal.surface,
                    ),
                ),
            )
            .padding(horizontal = 16.dp)
            .padding(top = 14.dp, bottom = 20.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
            Text(
                "OpenBurnBar Cloud",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = CloudStorePal.textPrimary,
            )
            Text(
                "$priceText / month · billed by Google Play",
                fontSize = 11.sp,
                color = CloudStorePal.textSecondary,
            )
        }
        AuroraPrimaryButton(
            text = "Become a Member — $priceText/mo",
            isLoading = isLoading,
            onClick = onPurchase,
            modifier = Modifier.fillMaxWidth(),
        )
        CloudStoreActionBarFooter(onRestore = onRestore, uriHandler = uriHandler)
    }
}

@Composable
internal fun CloudStoreActionBarFooter(onRestore: () -> Unit, uriHandler: androidx.compose.ui.platform.UriHandler) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(
            text = "Restore Purchases",
            fontSize = 12.sp,
            color = CloudStorePal.textSecondary,
            modifier = Modifier.clickable { onRestore() },
        )
        Spacer(Modifier.weight(1f))
        Text(
            "Privacy",
            fontSize = 11.sp,
            color = CloudStorePal.ember,
            modifier =
            Modifier.clickable {
                uriHandler.openUri("https://burnbar.ai/legal/privacy-policy")
            },
        )
        Spacer(Modifier.width(8.dp))
        Text("·", color = CloudStorePal.textMuted, fontSize = 11.sp)
        Spacer(Modifier.width(8.dp))
        Text(
            "Terms",
            fontSize = 11.sp,
            color = CloudStorePal.ember,
            modifier =
            Modifier.clickable {
                uriHandler.openUri("https://burnbar.ai/legal/terms")
            },
        )
    }
}

// ── Error ──

@Composable
internal fun CloudErrorCard(message: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(AuroraColors.error.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
            .border(0.5.dp, AuroraColors.error.copy(alpha = 0.45f), RoundedCornerShape(12.dp))
            .padding(12.dp),
    ) {
        Text(message, color = AuroraColors.error, fontSize = 12.sp)
    }
}
