@file:Suppress("MagicNumber")
// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Recovery setup — forced before zero-knowledge mode. Supports a raw recovery
 * key and split-knowledge recovery contacts, with delayed re-entry confirmation
 * (Apple Advanced Data Protection pattern): a freshly set method is "pending"
 * until the user confirms after a deliberate delay.
 */
@Composable
internal fun RecoverySection(
    methods: List<RecoveryMethod>,
    busy: Boolean,
    onSetupKey: () -> Unit,
    onSetupContact: () -> Unit,
    onConfirm: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    AuroraGlassCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Shield, contentDescription = null, tint = PensieveControlTokens.tierEndToEnd)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    "Recovery",
                    style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                    color = PensieveControlTokens.mercuryBright,
                )
                if (busy) {
                    Spacer(modifier = Modifier.weight(1f))
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = PensieveControlTokens.tierEndToEnd)
                }
            }
            Text(
                "Set up at least one recovery method before turning on end-to-end encrypted mode. " +
                    "Without it, no one — not even BurnBar — can restore your sealed data.",
                style = AuroraType.caption,
                color = PensieveControlTokens.textMute,
            )

            if (methods.isEmpty()) {
                Text("No recovery method yet.", style = AuroraType.body, color = PensieveControlTokens.textDim)
            } else {
                methods.forEach { method -> RecoveryMethodRow(method = method, onConfirm = onConfirm) }
            }

            ControlActionButton(
                label = "Add a recovery key",
                icon = Icons.Filled.Key,
                enabled = !busy,
                onClick = onSetupKey,
            )
            ControlActionButton(
                label = "Add a recovery contact",
                icon = Icons.Filled.People,
                enabled = !busy,
                onClick = onSetupContact,
            )
        }
    }
}

@Composable
private fun RecoveryMethodRow(method: RecoveryMethod, onConfirm: (String) -> Unit) {
    val accent = if (method.confirmed) PensieveControlTokens.tierEndToEnd else PensieveControlTokens.brassBright
    Row(
        modifier =
        Modifier
            .fillMaxWidth()
            .background(accent.copy(alpha = 0.08f), RoundedCornerShape(AuroraRadius.md.dp))
            .border(0.75.dp, accent.copy(alpha = 0.35f), RoundedCornerShape(AuroraRadius.md.dp))
            .padding(AuroraSpacing.md.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(8.dp).background(accent, CircleShape))
        Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(method.kindLabel, style = AuroraType.headline, color = PensieveControlTokens.mercuryBright)
            Text(
                if (method.confirmed) "Confirmed" else "Pending — confirm to activate",
                style = AuroraType.tiny,
                color = if (method.confirmed) PensieveControlTokens.tierEndToEnd else PensieveControlTokens.brassBright,
            )
        }
        if (!method.confirmed) {
            Text(
                "Confirm",
                style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = PensieveControlTokens.brassBright,
                modifier = Modifier.clickable { onConfirm(method.recoveryId) },
            )
        }
    }
}

/**
 * Panic — the kill switch. Aggregates the existing revoke callables to cut off
 * every external client, device, escrow device, and provider in one move.
 * Guarded by an explicit checkbox + typed-equivalent confirm; wax-crimson is
 * reserved for exactly this destructive surface.
 */
@Composable
internal fun PanicSection(
    busy: Boolean,
    lastResult: ControlCenterStore.PanicOutcome?,
    onRevoke: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var showDialog by remember { mutableStateOf(false) }
    var scopeAll by remember { mutableStateOf(true) }

    AuroraGlassCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.md.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.WarningAmber, contentDescription = null, tint = PensieveControlTokens.sealCrimson)
                Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
                Text(
                    "Revoke all access",
                    style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                    color = PensieveControlTokens.mercuryBright,
                )
            }
            Text(
                "Instantly cut off every external agent, paired device, escrow device, and provider " +
                    "connection. Use this if a device or grant is compromised.",
                style = AuroraType.caption,
                color = PensieveControlTokens.textMute,
            )
            lastResult?.let { result ->
                Text(
                    "Last run revoked ${result.mcpClients} agents, ${result.devices} devices, " +
                        "${result.escrowDevices} escrow devices, ${result.providers} providers.",
                    style = AuroraType.tiny,
                    color = PensieveControlTokens.textDim,
                )
            }
            ControlActionButton(
                label = "Revoke all access",
                icon = Icons.Outlined.WarningAmber,
                destructive = true,
                loading = busy,
                enabled = !busy,
                onClick = { showDialog = true },
            )
        }
    }

    if (showDialog) {
        PanicConfirmDialog(
            scopeAll = scopeAll,
            onScopeChange = { scopeAll = it },
            onConfirm = {
                showDialog = false
                onRevoke(if (scopeAll) "all" else "sync")
            },
            onDismiss = { showDialog = false },
        )
    }
}

@Composable
private fun PanicConfirmDialog(
    scopeAll: Boolean,
    onScopeChange: (Boolean) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Revoke all access?") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp)) {
                Text(
                    "Every external agent, paired device, escrow device, and provider connection " +
                        "will be disconnected immediately. You'll re-pair the ones you keep.",
                )
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { onScopeChange(!scopeAll) }) {
                    Checkbox(checked = scopeAll, onCheckedChange = onScopeChange)
                    Text(
                        if (scopeAll) "Revoke everything (recommended)" else "Revoke sync access only",
                        style = AuroraType.caption,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Revoke", color = PensieveControlTokens.sealCrimson, fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}
