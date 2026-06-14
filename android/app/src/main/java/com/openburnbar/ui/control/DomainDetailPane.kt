// Compose layout literals (dp/sp/alpha); token-per-line extraction obscures structure.

package com.openburnbar.ui.control

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.openburnbar.data.domains.DataDomain
import com.openburnbar.data.domains.PensieveControlTokens
import com.openburnbar.ui.components.AuroraGlassCard
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType

/**
 * Per-domain control pane. Header + yours<->server flip + tier promise +
 * footprint + the domain's registry-declared actions. Plaintext/sealed
 * facets, retention, and storage paths come straight from the registry so the
 * pane never hardcodes domain specifics.
 *
 * Action routing:
 *   • export / delete  → store callables (this surface owns them).
 *   • view / configure / sync / revoke / approve / recover  → deep-link into the
 *     existing owning surface (those callables live in sibling streams); we hand
 *     the route up via [onDomainAction] so the host wires the navigation.
 */
@Composable
internal fun DomainDetailPane(
    domain: DataDomain,
    row: DomainRow?,
    tier: DataTier,
    store: ControlCenterStore,
    modifier: Modifier = Modifier,
    onDomainAction: (DataDomain, String) -> Unit = { _, _ -> },
) {
    val deletingId by store.deletingDomainId.collectAsState()
    val exportingId by store.exportingDomainId.collectAsState()
    var confirmDelete by remember(domain.id) { mutableStateOf(false) }

    val locked = isDomainLocked(domain, tier)
    val isDeleting = deletingId == domain.id
    val isExporting = exportingId == domain.id

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(AuroraSpacing.LG.dp),
        verticalArrangement = Arrangement.spacedBy(AuroraSpacing.LG.dp),
    ) {
        item { DomainHeader(domain = domain, row = row, locked = locked) }
        if (locked) {
            item {
                LockedDomainNotice(domain = domain, tier = tier, onUpgrade = { onDomainAction(domain, ACTION_UPGRADE) })
            }
        }
        item { YoursServerFlipCard(domain = domain) }
        item { RetentionCard(domain = domain) }
        item {
            DomainActions(
                state = DomainActionsState(
                    domain = domain,
                    locked = locked,
                    isDeleting = isDeleting,
                    isExporting = isExporting,
                ),
                callbacks = DomainActionsCallbacks(
                    onExport = { store.export(domain.id) },
                    onDelete = { confirmDelete = true },
                    onAction = { action -> onDomainAction(domain, action) },
                ),
            )
        }
    }

    if (confirmDelete) {
        DeleteDomainDialog(
            domain = domain,
            onConfirm = {
                confirmDelete = false
                store.deleteDomain(domain.id)
            },
            onDismiss = { confirmDelete = false },
        )
    }
}

@Composable
private fun DomainHeader(domain: DataDomain, row: DomainRow?, locked: Boolean) {
    val accent = PensieveControlTokens.tierColor(domain.encryptionTier)
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier.size(44.dp).background(accent.copy(alpha = 0.16f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Box(modifier = Modifier.size(16.dp).background(accent, CircleShape))
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.MD.dp))
            Column {
                Text(
                    domain.title,
                    style = AuroraType.title.copy(fontWeight = FontWeight.Bold),
                    color = PensieveControlTokens.mercuryBright,
                )
                TierChip(domain.encryptionTier)
            }
        }
        Text(domain.summary, style = AuroraType.body, color = PensieveControlTokens.textBase)
        val footprint =
            buildList {
                row?.count?.takeIf { it > 0L }?.let { add("${formatCount(it)} items") }
                row?.bytes?.takeIf { it > 0L }?.let { add(formatBytes(it)) }
            }.ifEmpty { listOf(if (locked) "Locked" else "Empty") }.joinToString(" · ")
        Text(footprint, style = AuroraType.caption, color = PensieveControlTokens.textMute)
    }
}

@Composable
private fun RetentionCard(domain: DataDomain) {
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text("Retention", style = AuroraType.caption.copy(fontWeight = FontWeight.SemiBold), color = PensieveControlTokens.textMute)
            Text(retentionLabel(domain.retention), style = AuroraType.body, color = PensieveControlTokens.textBase)
            if (domain.storagePaths.isNotEmpty()) {
                Text(
                    "Sealed bodies live in encrypted object storage; deletion is genuine ciphertext deletion.",
                    style = AuroraType.caption,
                    color = PensieveControlTokens.textMute,
                )
            }
        }
    }
}

private data class DomainActionsState(
    val domain: DataDomain,
    val locked: Boolean,
    val isDeleting: Boolean,
    val isExporting: Boolean,
)

private data class DomainActionsCallbacks(
    val onExport: () -> Unit,
    val onDelete: () -> Unit,
    val onAction: (String) -> Unit,
)

@Composable
private fun DomainActions(state: DomainActionsState, callbacks: DomainActionsCallbacks) {
    val domain = state.domain
    Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
        domain.actions.forEach { action ->
            when (action) {
                "export" ->
                    ControlActionButton(
                        label = "Export ${domain.title}",
                        icon = Icons.Filled.Download,
                        loading = state.isExporting,
                        enabled = !state.locked && !state.isExporting,
                        onClick = callbacks.onExport,
                    )
                "delete" ->
                    ControlActionButton(
                        label = "Delete ${domain.title}",
                        icon = Icons.Outlined.DeleteOutline,
                        destructive = true,
                        loading = state.isDeleting,
                        enabled = !state.isDeleting,
                        onClick = callbacks.onDelete,
                    )
                "view" ->
                    ControlActionButton(
                        label = "View in ${domain.title}",
                        icon = Icons.AutoMirrored.Filled.OpenInNew,
                        enabled = !state.locked,
                        onClick = { callbacks.onAction(action) },
                    )
                "verify" ->
                    ControlActionButton(
                        label = "Verify integrity",
                        icon = Icons.AutoMirrored.Filled.OpenInNew,
                        onClick = { callbacks.onAction(action) },
                    )
                else ->
                    ControlActionButton(
                        label = actionLabel(action, domain),
                        icon = Icons.AutoMirrored.Filled.OpenInNew,
                        enabled = !state.locked,
                        onClick = { callbacks.onAction(action) },
                    )
            }
        }
    }
}

@Composable
internal fun ControlActionButton(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    destructive: Boolean = false,
    loading: Boolean = false,
    enabled: Boolean = true,
) {
    val accent = if (destructive) PensieveControlTokens.sealCrimson else PensieveControlTokens.brassBright
    Row(
        modifier =
        modifier
            .fillMaxWidth()
            .background(accent.copy(alpha = if (enabled) 0.10f else 0.04f), RoundedCornerShape(AuroraRadius.MD.dp))
            .border(0.75.dp, accent.copy(alpha = if (enabled) 0.45f else 0.18f), RoundedCornerShape(AuroraRadius.MD.dp))
            .then(if (enabled && !loading) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = AuroraSpacing.LG.dp, vertical = AuroraSpacing.MD.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (loading) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = accent)
        } else {
            Icon(icon, contentDescription = null, tint = accentForEnabled(accent, enabled))
        }
        Spacer(modifier = Modifier.width(AuroraSpacing.SM.dp))
        Text(
            label,
            style = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
            color = accentForEnabled(accent, enabled),
        )
    }
}

private fun accentForEnabled(accent: Color, enabled: Boolean): Color = if (enabled) accent else accent.copy(alpha = 0.4f)

@Composable
private fun LockedDomainNotice(domain: DataDomain, tier: DataTier, onUpgrade: () -> Unit) {
    AuroraGlassCard {
        Column(verticalArrangement = Arrangement.spacedBy(AuroraSpacing.SM.dp)) {
            Text(
                "Included with ${gateLabel(domain.entitlementGate)}",
                style = AuroraType.headline.copy(fontWeight = FontWeight.SemiBold),
                color = PensieveControlTokens.brassBright,
            )
            Text(
                "You're on ${tier.label}. ${domain.title} unlocks with ${gateLabel(domain.entitlementGate)}.",
                style = AuroraType.caption,
                color = PensieveControlTokens.textMute,
            )
            ControlActionButton(
                label = "Manage your plan",
                icon = Icons.AutoMirrored.Filled.OpenInNew,
                onClick = onUpgrade,
            )
        }
    }
}

@Composable
private fun DeleteDomainDialog(domain: DataDomain, onConfirm: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete ${domain.title}?") },
        text = {
            Text(
                "This permanently removes this domain's data from BurnBar's cloud — " +
                    if (domain.storagePaths.isNotEmpty()) {
                        "including the sealed ciphertext bodies. This cannot be undone."
                    } else {
                        "this cannot be undone."
                    },
            )
        },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text("Delete", color = PensieveControlTokens.sealCrimson, fontWeight = FontWeight.Bold)
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Keep") } },
    )
}

private fun retentionLabel(retention: String): String = when (retention) {
    "rolling" -> "Rolling window — older entries age out automatically."
    "until_deleted" -> "Kept until you delete it."
    "until_disconnected" -> "Kept until you disconnect the account."
    "until_revoked" -> "Kept until you revoke access."
    "permanent" -> "Kept for the life of your account."
    "append_only" -> "Append-only — entries are never edited, only added."
    else -> retention.replace("_", " ").replaceFirstChar { it.uppercase() }
}

private fun actionLabel(action: String, domain: DataDomain): String = when (action) {
    "configure" -> "Configure ${domain.title}"
    "sync" -> "Sync now"
    "revoke" -> "Revoke access"
    "approve" -> "Approve a device"
    "recover" -> "Recovery options"
    else -> action.replaceFirstChar { it.uppercase() } + " ${domain.title}"
}

private fun gateLabel(gate: String?): String = when (gate) {
    "burnbar_pro" -> "Cloud Pro"
    "burnbar_pro_max" -> "Cloud Pro"
    "burnbar_ultra", "burnbar_pro_max_ultra" -> "Ultra"
    else -> "a paid plan"
}
